import UIKit
import WebKit
import os

private let log = Logger(subsystem: "io.hammant.psion5", category: "emulator")

/// Full-screen, landscape-only host for the WindEmu page.
final class EmulatorViewController: UIViewController, WKNavigationDelegate {
    private static let startURL = URL(string: "psion://app/index.html")!

    private var webView: WKWebView!
    private var claude: ClaudeController!

    override func loadView() {
        let webRoot = Bundle.main.resourceURL!.appendingPathComponent("Web", isDirectory: true)

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(BundleSchemeHandler(root: webRoot), forURLScheme: "psion")
        config.userContentController.add(LogHandler(), name: "log")
        config.userContentController.add(MessageHandler { [weak self] body in self?.layoutMessage(body) }, name: "layout")
        config.userContentController.add(MessageHandler { [weak self] _ in self?.claude.typingFinished() }, name: "typing")
        config.preferences.isTextInteractionEnabled = false

        let webView = EdgeToEdgeWebView(frame: .zero, configuration: config)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.navigationDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.pinchGestureRecognizer?.isEnabled = false
        #if DEBUG
        webView.isInspectable = true
        #endif

        // A plain container keeps the real safe area, which the web view hides.
        let container = UIView()
        container.backgroundColor = .black
        webView.frame = container.bounds
        container.addSubview(webView)

        self.webView = webView
        view = container
        KeyboardBridge.shared.webView = webView
        claude = ClaudeController(container: container, webView: webView)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        claude.layoutChrome(in: view.bounds, safeArea: view.safeAreaInsets)
    }

    private func layoutMessage(_ body: Any) {
        guard let lcd = body as? [String: Any],
              let x = lcd["x"] as? Double, let y = lcd["y"] as? Double,
              let width = lcd["width"] as? Double, let height = lcd["height"] as? Double,
              let scale = lcd["scale"] as? Double else { return }
        claude.lcdMoved(to: CGRect(x: x, y: y, width: width, height: height), scale: scale)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        webView.load(URLRequest(url: Self.startURL))
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        sendInsets()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        sendInsets()
    }

    /// Tells the page where the camera cutout is, so the Psion screen avoids it.
    private func sendInsets() {
        let i = view.safeAreaInsets
        webView.evaluateJavaScript("window.psion && psion.setInsets(\(i.top),\(i.left),\(i.right))")
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    // Edge swipes need a second swipe, so taps on the silkscreen icons near
    // the screen edge don't throw you out of the app.
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        log.error("web content process terminated; restarting emulator")
        webView.load(URLRequest(url: Self.startURL))
    }
}

/// WebKit centres the page inside the safe area, which pushes the Psion
/// screen half off the folded outer display. Hiding the safe area from WebKit
/// lets the page lay itself out (see sendInsets).
private final class EdgeToEdgeWebView: WKWebView {
    override var safeAreaInsets: UIEdgeInsets { .zero }
}

/// Hands a page message to a closure. WKUserContentController keeps its
/// handlers alive, so this lets the view controller be held weakly.
private final class MessageHandler: NSObject, WKScriptMessageHandler {
    private let handler: (Any) -> Void

    init(_ handler: @escaping (Any) -> Void) {
        self.handler = handler
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        handler(message.body)
    }
}

/// Forwards the page's `nativeLog()` messages (emulator output, errors) to the unified log.
private final class LogHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        log.info("\(String(describing: message.body), privacy: .public)")
    }
}
