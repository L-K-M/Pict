import AppKit
import Combine
import CoreGraphics
import PictKit
import SwiftUI

/// Everything the editor knows and does.
///
/// Zap kept this state on the `IconsView` struct itself. Here it has to outlive any
/// one view — the app delegate holds it so a `pict://` deep link arriving before the
/// window exists still lands somewhere — and separating it makes the actions
/// testable without standing up SwiftUI.
@MainActor
final class IconEditorModel: ObservableObject {

    let store: IconStore
    let resolver: IconResolver

    @Published var rows: [IconTargetRow] = []
    /// Keyed by `IconEntryKey.serialized`, which is what rows are identified by.
    @Published var statuses: [String: IconArtworkStatus] = [:]
    /// Keys with an import in flight, and what the row should say about it. Reading
    /// an SVG stands up a web view, so even a local file is no longer reliably
    /// instant — both paths get a caption.
    @Published var inFlight: [String: String] = [:]
    @Published var search = ""
    @Published var problem: IconProblem?
    @Published var dropTarget: String?
    @Published var selection: String?
    @Published var searchingRow: IconTargetRow?
    /// The row the web-image browser is open for, if any. Separate from
    /// `searchingRow` rather than a mode of it: one is a provider's corpus behind a
    /// query and the other is a browser, and they share no state.
    @Published var browsingWebRow: IconTargetRow?
    @Published var managingSets = false
    @Published var applyingSet: IconSet?
    @Published var applyProgress = (done: 0, total: 0)
    /// What the last bulk apply did. A footer caption rather than an alert: it
    /// reports on something that went *right*, and interrupting for that is the
    /// habit `IconProblem` exists to avoid teaching.
    @Published var applySummary: String?

    @ObservedObject var preferences = PictPreferences()
    @ObservedObject var iconSets = IconSetLibrary.shared

    /// Where a search sheet can look, best first.
    ///
    /// Installed sets lead: they are the only providers that can suggest anything
    /// before being asked — their corpus is on disk — so opening the sheet on one
    /// means opening it on a grid of likely icons rather than an empty box. The
    /// keyless remote provider is last and always present, so the list is never
    /// empty and "no sources at all" is not a state Pict can be in.
    @Published var searchProviders: [IconSearchProvider] = [IconifyClient()]

    private var watcher: IconStoreWatcher?

    init(store: IconStore = IconStore()) {
        self.store = store
        // Pict previews at one size and applies no layout flourishes: it shows what
        // the icon *is*, not how any one app chooses to lay it out.
        self.resolver = IconResolver(
            options: IconRenderOptions(mode: .originalPlusCustom,
                                       pixelSize: 128, scale: 2,
                                       bleed: 0, trimsTransparentEdges: true,
                                       drawsShadow: false),
            store: store)
    }

    /// Starts watching the store and loads the list. Separate from `init` so the app
    /// delegate can migrate Zap's old icons first.
    func start() {
        // Another app can pin an icon to the system while Pict is open — Zap's
        // Icons tab keeps that verb. Reload rather than assume we are the only writer.
        watcher = IconStoreWatcher(store: store) { [weak self] in
            self?.resolver.invalidate()
            self?.reloadStatuses()
        }
        watcher?.start()
        reload()
    }

    // MARK: Loading

    func reload() {
        InstalledApps.load(store: store) { [weak self] rows in
            guard let self else { return }
            self.rows = rows
            self.resolver.warm(rows.map(\.target))
            self.reloadStatuses()
            self.refreshProviders()
        }
    }

    /// Statuses decode bundle artwork, so they are gathered off the main thread.
    func reloadStatuses() {
        IconArtworkStatus.load(for: rows.map(\.target), store: store) { [weak self] resolved in
            self?.statuses = resolved
        }
    }

    var filteredRows: [IconTargetRow] {
        guard !search.isEmpty else { return rows }
        return rows.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    /// Selects the row a `pict://edit` link named, loading the list first if the
    /// link beat the initial load.
    func select(_ key: IconEntryKey?) {
        guard let key else { return }
        selection = key.serialized
        if rows.isEmpty { reload() }
    }

    // MARK: Row state

    /// The icon that will actually be drawn, falling back to the system's while the
    /// resolver is still warming.
    func icon(for row: IconTargetRow) -> NSImage? {
        resolver.icon(for: row.target) ?? row.systemIcon
    }

    /// What the row's caption says, including transient states the status fetch
    /// doesn't know about.
    func status(for row: IconTargetRow) -> String {
        if let label = inFlight[row.id] { return label }
        return statuses[row.id]?.label ?? "Checking…"
    }

    func hasOverride(_ row: IconTargetRow) -> Bool {
        guard let status = statuses[row.id] else { return false }
        return status.hasCustomIcon || status.isPinnedToSystemIcon
    }

    func isPinnedToSystemIcon(_ row: IconTargetRow) -> Bool {
        statuses[row.id]?.isPinnedToSystemIcon == true
    }

    // MARK: Ingestion

    func chooseFile(for row: IconTargetRow) {
        let panel = NSOpenPanel()
        // `.image` covers everything ImageIO decodes *and* SVG, which conforms to
        // `public.image` without ImageIO being able to read a byte of it. PDF is
        // listed separately because Core Graphics renders it natively. The real gate
        // is `IconImport`, which decides from the bytes rather than trusting any of
        // this.
        panel.allowedContentTypes = [.image, .pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importFile(url, for: row)
    }

    /// Takes on a dragged or pasted URL: a file is imported directly, an http(s)
    /// link is fetched first. Returns whether the drop was accepted — refusing makes
    /// the drag snap back, which is the platform's own way of saying "not this, not
    /// now", and is better than dropping it on the floor silently.
    @discardableResult
    func adopt(_ url: URL, for row: IconTargetRow) -> Bool {
        guard !url.isFileURL else { return importFile(url, for: row) }
        guard RemoteIconFetcher.isFetchable(url) else {
            problem = .unfetchableLink(row: row)
            return false
        }
        guard claim(row, saying: "Downloading…") else { return false }

        let key = row.id
        Task {
            let fetched = await fetchedImage(from: url, for: row)
            inFlight[key] = nil
            switch fetched {
            case .failure(let failure):
                problem = failure
            case .success(let image):
                // Provenance is captured at save time, not display time — the link
                // the user dragged from is the credit.
                apply(store.setIcon(image, for: row.target, origin: .search,
                                    provider: "web", creditURL: url.absoluteString),
                      for: row)
            }
        }
        // Accepted: the download is under way and the row says so.
        return true
    }

    /// Takes on an image picked out of the web browser.
    ///
    /// The picked image is usually not the one worth having: in a results grid the
    /// pointer is over a thumbnail. `OriginalImageResolver` looks for the full-size
    /// original first and falls back to the thumbnail with a warning, so the user
    /// gets the best available picture and is told when that isn't a good one —
    /// rather than silently getting a soft icon and blaming Pict for it.
    ///
    /// Everything after the URL is decided is the *same* path a dragged link takes,
    /// deliberately: one door for remote images, with one set of bounds and one
    /// validator behind it.
    @discardableResult
    func adopt(_ picked: PickedWebImage, for row: IconTargetRow) -> Bool {
        let resolution = OriginalImageResolver.resolve(picked)
        guard RemoteIconFetcher.isFetchable(resolution.url) else {
            problem = .unfetchableLink(row: row)
            return false
        }
        guard claim(row, saying: resolution.isOriginal ? "Downloading…" : "Downloading thumbnail…")
        else { return false }

        let key = row.id
        Task {
            let fetched = await fetchedImage(from: resolution.url, for: row)
            inFlight[key] = nil
            switch fetched {
            case .failure(let failure):
                problem = failure
            case .success(let image):
                // The *page* is the credit, not the image file: a bare CDN address
                // says nothing about where a picture came from or who made it, and
                // the page is what the user could go back and check.
                let written = store.setIcon(image, for: row.target, origin: .search,
                                            provider: "web",
                                            creditURL: (picked.pageURL ?? resolution.url).absoluteString)
                apply(written, for: row)
                // Only when the icon actually landed. `apply` reports a failed write
                // through `problem`, and overwriting that with "this may look soft"
                // would replace a real error with a cosmetic note about an icon that
                // was never saved.
                if case .success = written, let warning = resolution.warning {
                    problem = .lowResolutionImage(warning, row: row)
                }
            }
        }
        return true
    }

    /// Downloads `url` and decodes what comes back. Both halves can fail and they
    /// fail differently — a link that never answered is not a file Pict turned down —
    /// so each failure arrives already phrased for the alert.
    private func fetchedImage(from url: URL,
                              for row: IconTargetRow) async -> Result<CGImage, IconProblem> {
        switch await RemoteIconFetcher.fetch(url) {
        case .failure(let error):
            return .failure(.fetchFailed(error.message, row: row))
        case .success(let data):
            // SVG arrives by this route too — it is most of what a browser has to
            // drag — so the bytes go through the same door a chosen file does.
            switch await IconImport.image(from: data) {
            case .failure(let rejection): return .failure(.rejected(rejection, row: row))
            case .success(let image): return .success(image)
            }
        }
    }

    /// Reads a local file and adopts it. `true` means "started", not "finished": an
    /// SVG goes through a web view, so the outcome lands later, in the row or an alert.
    @discardableResult
    func importFile(_ url: URL, for row: IconTargetRow) -> Bool {
        guard claim(row, saying: "Adding…") else { return false }

        let key = row.id
        Task {
            let imported = await IconImport.image(contentsOf: url)
            inFlight[key] = nil
            switch imported {
            case .failure(let rejection):
                problem = .rejected(rejection, row: row)
            case .success(let image):
                apply(store.setIcon(image, for: row.target), for: row)
            }
        }
        return true
    }

    /// Stores a searched-for icon, carrying its credit into the entry — attribution
    /// is the condition for a provider being allowed to exist at all, so it is
    /// persisted rather than looked up at display time.
    func adopt(_ result: IconSearchResult, image: CGImage, for row: IconTargetRow) {
        apply(store.setIcon(image, for: row.target, origin: .search,
                            provider: result.providerID,
                            credit: result.credit,
                            creditURL: result.creditURL?.absoluteString,
                            license: result.license),
              for: row)
    }

    /// Marks `row` as busy, or refuses when it already is.
    ///
    /// One import per target at a time. Two in flight would race: the first to
    /// finish clears the caption for both, and the last to *land* wins the icon,
    /// which need not be the one the user asked for last.
    private func claim(_ row: IconTargetRow, saying label: String) -> Bool {
        guard inFlight[row.id] == nil else {
            problem = .alreadyInFlight(row: row)
            return false
        }
        inFlight[row.id] = label
        return true
    }

    /// Shared outcome handling for every ingestion path.
    ///
    /// Nothing clears `problem` on success: an alert is dismissed by the person
    /// reading it, not by the next thing that happens to go right.
    private func apply(_ result: Result<IconEntry, IconStore.WriteFailure>,
                       for row: IconTargetRow) {
        switch result {
        case .failure(let failure):
            problem = .writeFailed(failure, row: row)
        case .success:
            refresh(row)
        }
    }

    // MARK: The other verbs

    func useOriginalArtwork(for row: IconTargetRow) {
        store.clear(for: row.target)
        refresh(row)
    }

    func useSystemIcon(for row: IconTargetRow) {
        _ = store.pinToSystemIcon(for: row.target)
        refresh(row)
    }

    func resetAll() {
        store.removeAll()
        resolver.invalidate()
        reloadStatuses()
    }

    private func refresh(_ row: IconTargetRow) {
        resolver.invalidate(row.target)
        reloadStatuses()
    }

    // MARK: Icon sets

    /// The sets currently installed, in catalogue order.
    var installedSets: [IconSet] {
        IconSetCatalogue.all.filter { iconSets.records[$0.id] != nil }
    }

    /// Rebuilds the provider list from what is installed now, keeping the remote
    /// provider that is already there. It is always last — sets lead — so `last` is it.
    func refreshProviders() {
        let remote = searchProviders.last ?? IconifyClient()
        searchProviders = iconSets.installedProviders() + [remote]
    }

    /// Walks the listed rows, applying the set's icon wherever `IconSetAutoMatch` is
    /// confident enough to act without anyone looking.
    ///
    /// Sequential on purpose. Every icon is an SVG that has to be rasterised, which
    /// is the most expensive thing this app does; one at a time keeps a single
    /// `WKWebView` alive (`SVGRenderGate`) and makes the count in the button label
    /// mean something. Repeat runs are much faster — `IconImport` consults the
    /// render cache.
    func applyMatching(from set: IconSet) {
        guard let provider = iconSets.provider(for: set) else {
            problem = .setUnavailable(set)
            return
        }

        let candidates = rows
        applySummary = nil
        applyingSet = set
        applyProgress = (0, candidates.count)

        Task {
            var outcome = IconSetAutoMatch.Outcome()
            for (index, row) in candidates.enumerated() {
                applyProgress = (index, candidates.count)

                // A target the user has already decided about is left alone —
                // including one pinned to the system icon, which is a decision too.
                guard store.entry(for: row.target) == nil else {
                    outcome.skipped += 1
                    continue
                }
                guard let name = IconSetAutoMatch.confidentMatch(
                        appName: row.name,
                        bundleIdentifier: row.bundleIdentifier,
                        in: provider.iconNames),
                      let result = provider.result(forIconName: name) else {
                    outcome.unmatched += 1
                    continue
                }

                // Claimed the same way a chosen file is, so a drop landing mid-run
                // can't race this one to the store — and so the row says what is
                // happening to it. Claimed only once there is something to apply:
                // matching is free, rendering is not.
                guard inFlight[row.id] == nil else {
                    outcome.skipped += 1
                    continue
                }
                inFlight[row.id] = "Matching…"

                let rendered = await renderedIcon(for: result, from: provider)
                inFlight[row.id] = nil
                if let rendered {
                    // Credit carried into the entry exactly as a hand-picked icon's
                    // is — a bulk apply is not a reason to lose it.
                    _ = store.setIcon(rendered, for: row.target, origin: .theme,
                                      provider: result.providerID,
                                      credit: result.credit,
                                      creditURL: result.creditURL?.absoluteString,
                                      license: result.license)
                    outcome.applied += 1
                } else {
                    outcome.failed += 1
                }
            }
            finishApplying(outcome, from: set)
        }
    }

    /// One set icon, read and rasterised, or `nil` if either half fails.
    private func renderedIcon(for result: IconSearchResult,
                              from provider: IconSetProvider) async -> CGImage? {
        guard case .success(let data) = await provider.fetchImageData(for: result) else { return nil }
        guard case .success(let image) = await IconImport.image(from: data) else { return nil }
        return image
    }

    private func finishApplying(_ outcome: IconSetAutoMatch.Outcome, from set: IconSet) {
        applyingSet = nil
        applyProgress = (0, 0)
        applySummary = IconSetAutoMatch.summary(outcome, setName: set.name)
        resolver.invalidate()
        reloadStatuses()
    }
}
