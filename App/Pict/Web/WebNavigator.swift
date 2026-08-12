import Foundation
import WebKit

/// The chrome's handle on the web view, and the web view's handle on the chrome.
///
/// Exists because a browser you cannot go back in is worse than no browser: the
/// whole gesture this feature is built around — click a search result to see the
/// picture full size, then right-click *that* — strands you on the image with no way
/// back to the results.
///
/// One object rather than a state closure plus a command binding, because they are
/// two halves of the same relationship and splitting them means two things to keep
/// in step.
///
/// **Deliberately not `@MainActor`**, though everything here does happen on the main
/// thread. `@StateObject`'s initializer takes a plain escaping autoclosure, so a
/// main-actor-isolated type cannot be constructed in one — the same error that
/// `AppDelegate` and Zap's `ZapIcons` both hit. Every mutation arrives from a WebKit
/// delegate callback or a SwiftUI action, both of which are already on main, so the
/// isolation would buy nothing and cost the call sites.
final class WebNavigator: ObservableObject {

    @Published private(set) var isLoading = false
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    /// What the web view is actually showing, which is not necessarily what was last
    /// asked for — the user follows links, and sites redirect.
    @Published private(set) var address: URL?

    /// Weak: the view hierarchy owns the web view, and an `ObservableObject` held by
    /// a `View` outliving it would keep a whole web content process alive.
    weak var webView: WKWebView?

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }

    func report(isLoading: Bool, canGoBack: Bool, canGoForward: Bool, address: URL?) {
        self.isLoading = isLoading
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.address = address
    }
}
