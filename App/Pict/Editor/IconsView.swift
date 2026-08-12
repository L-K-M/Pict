import AppKit
import PictKit
import SwiftUI
import UniformTypeIdentifiers

/// The editor: every app on this Mac, the icon each will be drawn with, and the
/// ways to change one.
struct IconsView: View {

    @ObservedObject var model: IconEditorModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            List(model.filteredRows, selection: $model.selection) { row in
                self.row(for: row)
                    .tag(row.id)
            }
            .listStyle(.inset)

            Divider()
            footer
        }
        .alert(iconProblem: $model.problem)
        .sheet(item: $model.searchingRow) { row in
            IconSearchSheet(
                row: row,
                providers: model.searchProviders,
                preferences: model.preferences,
                onAdopt: { result, image in
                    model.searchingRow = nil
                    model.adopt(result, image: image, for: row)
                },
                onCancel: { model.searchingRow = nil })
        }
        .sheet(item: $model.browsingWebRow) { row in
            WebImageSheet(
                row: row,
                // Fetch and decode only. The sheet previews the result over the page
                // and closes on acceptance, so a picture that turns out to be wrong
                // costs a dismissal rather than finding the search again.
                candidate: { await model.candidate(for: $0, row: row) },
                onUse: { candidate in
                    model.browsingWebRow = nil
                    model.commit(candidate, for: row)
                },
                onCancel: { model.browsingWebRow = nil })
        }
        .sheet(isPresented: $model.managingSets) {
            IconSetsSheet(library: model.iconSets, onDone: {
                model.managingSets = false
                // A set may have been installed or removed; the next search sheet
                // should offer what is actually there.
                model.refreshProviders()
            })
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The reach of a change, stated rather than discovered. This is the one
            // thing about Pict a user has to understand, and the whole reason it
            // exists rather than each app keeping its own icons.
            Label("Icons set here are used by Zap, Jetty and Top Drawer. The Dock and Finder keep showing the system's.",
                  systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !IconSourceMode.isSquircleJailed {
                Text("This version of macOS doesn't mask app icons, so there's nothing to un-jail — an app's original artwork and its system icon are the same picture. Custom icons still apply.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search apps", text: $model.search)
                    .textFieldStyle(.plain)
                Button("Refresh", action: model.reload)
            }
        }
        .padding(10)
    }

    // MARK: Rows

    private func row(for row: IconTargetRow) -> some View {
        IconRow(
            row: row,
            icon: model.icon(for: row),
            status: model.status(for: row),
            hasOverride: model.hasOverride(row),
            isPinnedToSystemIcon: model.isPinnedToSystemIcon(row),
            isDropTarget: model.dropTarget == row.id,
            onChooseFile: { model.chooseFile(for: row) },
            onSearch: { model.searchingRow = row },
            onBrowseWeb: { model.browsingWebRow = row },
            onUseOriginalArtwork: { model.useOriginalArtwork(for: row) },
            onUseSystemIcon: { model.useSystemIcon(for: row) },
            onDrop: { model.adopt($0, for: row) },
            onDropTargeted: { targeted in
                if targeted {
                    model.dropTarget = row.id
                } else if model.dropTarget == row.id {
                    model.dropTarget = nil
                }
            })
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("Reset All Icons", role: .destructive, action: model.resetAll)
                    .disabled(model.applyingSet != nil)
                applyMatchingButton
                Spacer()
                Button("Icon Sets…") { model.managingSets = true }
            }

            Text(model.iconSets.records.isEmpty
                 ? "Install an icon set for a few thousand app icons to pick from, offline, with matches suggested per app."
                 : "Icon sets are offered in each app's search sheet, with matches suggested for that app.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !model.iconSets.records.isEmpty {
                Text("Applying matching icons only touches apps you haven't given an icon yourself, and only where the set's name matches the app exactly or by a known alias — near-misses are left for you to pick. Reset All Icons undoes it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let summary = model.applySummary {
                Label(summary, systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Drag an image onto a row from Finder, or straight from a browser — searching the web for an icon is free there, and Google Images can filter to transparent backgrounds only (Tools → Color → Transparent). Nothing about your apps is ever sent anywhere.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
    }

    /// Applies a whole set in one go, beside Reset All Icons.
    ///
    /// A menu when more than one set is installed, because *which* set is the whole
    /// question: mixing two themes defeats the point of a theme, so a run draws from
    /// exactly one.
    @ViewBuilder
    private var applyMatchingButton: some View {
        let sets = model.installedSets
        if let applying = model.applyingSet {
            Button("Applying \(applying.name)… \(model.applyProgress.done) of \(model.applyProgress.total)") {}
                .disabled(true)
        } else if sets.isEmpty {
            Button("Apply Matching Icons") {}
                .disabled(true)
                .help("Install an icon set first — see Icon Sets…")
        } else if let only = sets.first, sets.count == 1 {
            Button("Apply Matching \(only.name) Icons") { model.applyMatching(from: only) }
        } else {
            Menu("Apply Matching Icons") {
                // `iconSet`, not `set`: this is a computed property, and a `set` at
                // the head of a statement inside one is read as a setter.
                ForEach(sets) { iconSet in
                    Button(iconSet.name) { model.applyMatching(from: iconSet) }
                }
            }
            .fixedSize()
        }
    }
}
