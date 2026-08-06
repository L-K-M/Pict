import AppKit
import PictKit
import SwiftUI

/// One row in the editor: what will be drawn for this target, what that artwork
/// is, and the ways to change it.
///
/// Deliberately dumb — it holds no state and reaches for nothing. `IconEditorModel` owns
/// the store, the resolver and every decision; this just renders what it's handed
/// and reports back.
struct IconRow: View {

    let row: IconTargetRow
    /// The icon that will actually be drawn, already resolved.
    let icon: NSImage?
    /// Caption under the app name.
    let status: String
    /// Whether there is an override to revert.
    let hasOverride: Bool
    /// Whether this app is already pinned to the system icon.
    let isPinnedToSystemIcon: Bool
    /// Whether a drag is currently over this row.
    let isDropTarget: Bool

    var onChooseFile: () -> Void
    var onSearch: () -> Void
    var onUseOriginalArtwork: () -> Void
    var onUseSystemIcon: () -> Void
    /// Returns whether the drop was accepted; refusing makes the drag snap back.
    var onDrop: (URL) -> Bool
    var onDropTargeted: (Bool) -> Void

    var body: some View {
        HStack(spacing: 8) {
            // A placeholder rather than a blank tile: the resolver may not have
            // reached this app yet, and an empty square reads as a broken row.
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 24, height: 24)
            } else {
                Image(systemName: "app.dashed")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 24, height: 24)
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(row.name)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Menu {
                Button("Choose File…", action: onChooseFile)
                Button("Search for an Icon…", action: onSearch)
                Button("Use Original Artwork", action: onUseOriginalArtwork)
                    .disabled(!hasOverride)
                Button("Use System Icon", action: onUseSystemIcon)
                    .disabled(isPinnedToSystemIcon)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .fixedSize()
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        // The browser is the search box. A drag from one carries a URL rather
        // than a file, and that is the more important ingestion path of the two.
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            return onDrop(url)
        } isTargeted: { onDropTargeted($0) }
        .listRowBackground(isDropTarget ? Color.accentColor.opacity(0.15) : Color.clear)
    }
}
