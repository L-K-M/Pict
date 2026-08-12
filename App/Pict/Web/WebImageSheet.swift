import SwiftUI

/// "Get Image from the Web" — a browser, and a way to take a picture out of it.
///
/// Deliberately a browser rather than a search box over an API. Zap's
/// `UNJAILED.md §5.2` found every general image-search API dead, closing, or behind
/// a card, and `§5.3` concluded that "the search can happen where search is still
/// free: the user's browser". This is that conclusion with the browser moved inside,
/// so taking the picture is a right-click rather than a drag between two apps.
struct WebImageSheet: View {

    let row: IconTargetRow
    var onPick: (PickedWebImage) -> Void
    var onCancel: () -> Void

    @State private var source: WebImageSource = .default
    @State private var typed = ""
    @State private var destination: URL = WebImageSource.default.url
    @StateObject private var navigator = WebNavigator()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            WebImageBrowser(url: destination, onPick: onPick, navigator: navigator)
            Divider()
            footer
        }
        .frame(minWidth: 720, idealWidth: 900, minHeight: 480, idealHeight: 620)
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
                                              // Switching source re-runs what was
                                              // typed: changing where you are
                                              // looking should not lose what you
                                              // are looking for.
                                              destination = WebImageSource
                                                  .destination(for: typed, on: chosen) ?? chosen.url
                                          })) {
                ForEach(WebImageSource.all) { candidate in
                    Text(candidate.name).tag(candidate)
                }
            }
            .labelsHidden()
            .frame(width: 170)
            .help(source.note)

            TextField("Search, or type an address", text: $typed)
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

    /// Empty input is not a no-op: it returns to the current source's starting page,
    /// which is the natural "take me back to where I began" after wandering off.
    private func go() {
        guard let url = WebImageSource.destination(for: typed, on: source) else { return }
        destination = url
    }
}
