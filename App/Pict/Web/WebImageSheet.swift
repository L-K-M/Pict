import SwiftUI

/// "Get Image from the Web" — a browser, and a way to take a picture out of it.
///
/// Deliberately a browser rather than a search box over an API. Zap's
/// `UNJAILED.md §5.2` found every general image-search API dead, closing, or behind
/// a card, and `§5.3` concluded that "the search can happen where search is still
/// free: the user's browser". This is that conclusion with the browser moved inside,
/// so taking the picture is a right-click rather than a drag between two apps.
///
/// Picking does not close the sheet. The candidate is fetched, decoded and shown
/// **over** the page (`IconCandidateView`), and only committed if the user says so —
/// because the question "is this actually a good icon?" is worth nothing once the
/// results it would send you back to are gone.
struct WebImageSheet: View {

    let row: IconTargetRow
    /// Fetch and decode without applying, so this can be previewed.
    var candidate: (PickedWebImage) async -> Result<IconCandidate, IconProblem>
    /// Apply one the user has looked at and accepted.
    var onUse: (IconCandidate) -> Void
    var onCancel: () -> Void

    @State private var source: WebImageSource = .default
    @State private var typed = ""
    @State private var destination: URL = WebImageSource.default.url
    @StateObject private var navigator = WebNavigator()

    @State private var pending: IconCandidate?
    @State private var isFetching = false
    /// A failure while fetching a pick. Shown here rather than on the window behind,
    /// which is covered by this sheet — an alert nobody can see is worse than none.
    @State private var failure: IconProblem?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            browser
            Divider()
            footer
        }
        .frame(minWidth: 720, idealWidth: 900, minHeight: 480, idealHeight: 620)
        .alert(iconProblem: $failure)
    }

    private var browser: some View {
        WebImageBrowser(url: destination, onPick: pick, navigator: navigator)
            .overlay {
                if isFetching {
                    // Dim the page while fetching: the click has been taken, and a
                    // page that still looks live invites a second right-click.
                    ZStack {
                        Color.black.opacity(0.28)
                        ProgressView("Fetching the image…")
                            .padding(20)
                            .background(.regularMaterial,
                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .transition(.opacity)
                } else if let pending {
                    ZStack {
                        Color.black.opacity(0.28)
                        IconCandidateView(
                            candidate: pending,
                            row: row,
                            onUse: { onUse(pending) },
                            // Just a dismissal. The page, the scroll position and the
                            // search results are all still behind it, which is the
                            // entire point of previewing here.
                            onCancel: { self.pending = nil })
                    }
                    .transition(.opacity)
                }
            }
    }

    private func pick(_ picked: PickedWebImage) {
        guard !isFetching, pending == nil else { return }
        isFetching = true
        // `@MainActor` explicitly: this method is not isolated, so a bare `Task`
        // would inherit nothing and mutate `@State` off the main actor.
        Task { @MainActor in
            let result = await candidate(picked)
            isFetching = false
            switch result {
            case .success(let found): pending = found
            case .failure(let problem): failure = problem
            }
        }
    }

    // MARK: Chrome

    private var header: some View {
        HStack(spacing: 8) {
            // Going back is not a nicety here: the intended gesture is to click a
            // result to see it full size and right-click that, which without these
            // leaves you stranded on the image.
            Button(action: navigator.goBack) {
                Image(systemName: "chevron.left")
            }
            .disabled(!navigator.canGoBack)
            .help("Back")

            Button(action: navigator.goForward) {
                Image(systemName: "chevron.right")
            }
            .disabled(!navigator.canGoForward)
            .help("Forward")

            // The side effect lives in the binding rather than in `onChange`,
            // which changed shape in macOS 14 and would force either a deprecated
            // spelling or an availability check on a deployment target of 13.
            Picker("", selection: Binding(get: { source },
                                          set: { chosen in
                                              source = chosen
                                              destination = WebImageSource
                                                  .destination(for: typed, on: chosen) ?? chosen.url
                                          })) {
                ForEach(WebImageSource.all) { option in
                    Text(option.name).tag(option)
                }
            }
            .labelsHidden()
            .frame(width: 170)
            .help(source.note)

            TextField(source.canSearchByURL
                        ? "Search, or type an address"
                        : "Type an address — \(source.name) has its own search box",
                      text: $typed)
                .textFieldStyle(.roundedBorder)
                .onSubmit(go)

            Button("Go", action: go)

            if navigator.isLoading {
                ProgressView().controlSize(.small)
            }
        }
        .padding(10)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            // The instruction is the feature. Without it this is a browser with no
            // obvious purpose, and the one gesture that makes it useful is hidden
            // behind a right-click nobody has a reason to try.
            Label {
                Text("Right-click any image and choose **Use This Image** to set \(row.name)'s icon.")
            } icon: {
                Image(systemName: "cursorarrow.click")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(2)

            Spacer(minLength: 12)

            Button("Cancel", role: .cancel, action: onCancel)
                .keyboardShortcut(.cancelAction)
        }
        .padding(10)
    }

    /// Empty input returns to the current source's starting page, which is the
    /// natural "take me back to where I began" after wandering off.
    private func go() {
        guard let url = WebImageSource.destination(for: typed, on: source) else { return }
        destination = url
    }
}
