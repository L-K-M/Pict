import AppKit
import SwiftUI
import WebKit

/// The browser behind "Get Image from the Web": a `WKWebView` whose context menu
/// gains **Use This Image** when the pointer is over one.
///
/// ## Why there is a JavaScript bridge
///
/// macOS's `WKWebView` will let you edit the context menu (`willOpenMenu`) but will
/// not tell you what was clicked — there is no macOS equivalent of iOS's
/// `contextMenuConfigurationForElement`. So a small script records the element under
/// the pointer on right-click and posts it over; the menu is then built from what
/// arrived.
///
/// The obvious version of that has a race — the menu can open before the message
/// crosses from the web content process — so the *data* is not read from the
/// message. The message only decides whether the item appears; picking it re-reads
/// the recorded element from the page, hundreds of milliseconds later, when there is
/// nothing left to race with.
///
/// ## What this costs
///
/// JavaScript is enabled here, unlike the `WKWebView` in `SVGRasterizer` which
/// disables it outright. That is the real price of the feature and it is not
/// nothing: this is the app that writes the store three other apps read. Against it:
/// the data store is non-persistent, so nothing survives the window closing; the
/// injected script only listens; and no byte reaches the store without going through
/// `RemoteIconFetcher`'s bounds and `IconImport`'s validation — the same door a
/// dragged file uses. A page can offer Pict a picture. It cannot make Pict keep one.
struct WebImageBrowser: NSViewRepresentable {

    /// Where to go. Changing it navigates.
    let url: URL
    /// Called when the user picks an image out of the page.
    let onPick: (PickedWebImage) -> Void
    /// Drives the chrome, and lets it drive the web view back.
    @ObservedObject var navigator: WebNavigator

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> ImageContextWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: Coordinator.messageName)
        controller.addUserScript(WKUserScript(source: Self.bridgeScript,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false))

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        // Nothing this browser does should outlive the window: no cookies, no local
        // storage, no cache carried into the next session. It is for looking at
        // pictures, not for being logged in anywhere.
        configuration.websiteDataStore = .nonPersistent()

        let webView = ImageContextWebView(frame: .zero, configuration: configuration)
        webView.coordinator = context.coordinator
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        // Note the absence of a `customUserAgent`. WebKit's own string is the honest
        // one, and dressing Pict up as Safari to get past a site that does not want
        // embedded browsers would be working around a refusal rather than respecting
        // it. Some sites will serve a degraded page or a consent wall as a result;
        // that is their call to make, and the address field is the way out of it.
        webView.allowsBackForwardNavigationGestures = true

        context.coordinator.webView = webView
        navigator.webView = webView
        webView.load(URLRequest(url: url))
        context.coordinator.loadedURL = url
        return webView
    }

    func updateNSView(_ webView: ImageContextWebView, context: Context) {
        context.coordinator.parent = self
        // Only navigate when the *request* changed. Without this guard every SwiftUI
        // re-render would reload the page and throw away the user's scroll position
        // and history.
        guard context.coordinator.loadedURL != url else { return }
        context.coordinator.loadedURL = url
        webView.load(URLRequest(url: url))
    }

    static func dismantleNSView(_ webView: ImageContextWebView, coordinator: Coordinator) {
        // The content controller retains the handler strongly, so without this the
        // coordinator — and the web view through it — outlives the sheet.
        webView.configuration.userContentController
            .removeScriptMessageHandler(forName: Coordinator.messageName)
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.coordinator = nil
        webView.stopLoading()
    }

    // MARK: The injected listener

    /// Records the image under the pointer, and exposes it for the menu item to read.
    ///
    /// Listens on `mousedown` in the capture phase as well as `contextmenu`: the
    /// capture-phase handler runs before any of the page's own handlers, so a site
    /// that swallows `contextmenu` (image galleries do this constantly, to stop
    /// people saving pictures) cannot hide the image from Pict. The user asked for
    /// this menu; the page does not get a vote.
    private static let bridgeScript = """
    (function () {
      if (window.__pictBridgeInstalled) { return; }
      window.__pictBridgeInstalled = true;
      window.__pictPicked = null;

      function describe(target) {
        var img = target && target.closest ? target.closest('img, [style*="background-image"]') : null;
        if (!img) { return null; }

        var src = img.currentSrc || img.src || '';
        if (!src) {
          // A CSS background image — common in grid layouts that avoid <img>.
          var background = window.getComputedStyle(img).backgroundImage || '';
          var match = background.match(/url\\(["']?(.*?)["']?\\)/);
          if (match) { src = match[1]; }
        }
        if (!src) { return null; }

        var anchor = img.closest ? img.closest('a') : null;
        return {
          src: new URL(src, document.baseURI).href,
          page: document.location.href,
          link: anchor && anchor.href ? new URL(anchor.href, document.baseURI).href : null,
          width: img.naturalWidth || 0,
          height: img.naturalHeight || 0
        };
      }

      function record(event) {
        if (event.button !== undefined && event.button !== 2) { return; }
        var found = describe(event.target);
        window.__pictPicked = found;
        try {
          window.webkit.messageHandlers.pictImagePicked.postMessage(found ? found : {});
        } catch (ignored) {}
      }

      document.addEventListener('mousedown', record, true);
      document.addEventListener('contextmenu', record, true);
    })();
    """

    // MARK: Coordinator

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {

        static let messageName = "pictImagePicked"

        var parent: WebImageBrowser
        weak var webView: ImageContextWebView?
        var loadedURL: URL?
        /// Whether the last right-click landed on an image. Only ever used to decide
        /// whether the menu item appears — never as the payload, which is re-read at
        /// click time precisely because this can be stale.
        private(set) var lastPickWasImage = false

        init(_ parent: WebImageBrowser) {
            self.parent = parent
        }

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let payload = message.body as? [String: Any] else {
                lastPickWasImage = false
                return
            }
            lastPickWasImage = PickedWebImage(payload: payload) != nil
        }

        /// Reads whatever the page last recorded, at the moment the user picks the
        /// menu item. This is the race-free half: the script wrote `__pictPicked`
        /// during the right-click, and by now that is long settled.
        func pickCurrentImage() {
            guard let webView else { return }
            webView.evaluateJavaScript("window.__pictPicked") { [weak self] value, _ in
                guard let self,
                      let payload = value as? [String: Any],
                      let picked = PickedWebImage(payload: payload) else { return }
                self.parent.onPick(picked)
            }
        }

        // MARK: Navigation

        private func report(_ webView: WKWebView, loading: Bool) {
            parent.navigator.report(isLoading: loading,
                                    canGoBack: webView.canGoBack,
                                    canGoForward: webView.canGoForward,
                                    address: webView.url)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            report(webView, loading: true)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            report(webView, loading: false)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            report(webView, loading: false)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            report(webView, loading: false)
        }

        /// `target="_blank"` links have no window to open into, and returning nil
        /// makes them do nothing at all — which reads as a broken page. Load them
        /// here instead, which is also what keeps a results grid navigable.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
            }
            return nil
        }
    }
}

/// The `WKWebView` subclass that owns the menu.
///
/// A subclass rather than a delegate because `willOpenMenu(_:with:)` is `NSView`'s,
/// and it is the only hook macOS offers for editing a web view's context menu.
final class ImageContextWebView: WKWebView {

    weak var coordinator: WebImageBrowser.Coordinator?

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        guard coordinator?.lastPickWasImage == true else { return }

        let item = NSMenuItem(title: "Use This Image",
                              action: #selector(useThisImage(_:)),
                              keyEquivalent: "")
        item.target = self
        // First, with a separator under it: this is the reason the window exists, and
        // it should not be the seventh thing in a list headed by "Reload".
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
    }

    @objc private func useThisImage(_ sender: NSMenuItem) {
        coordinator?.pickCurrentImage()
    }
}
