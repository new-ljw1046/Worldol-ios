import UIKit
import WebKit

/// 承载整个游戏的 WebView 容器。
///
/// 启动流程：
///   1. 在 bundle 里找到解包出来的 `webroot/`（client / web / data / analysis）
///   2. 在 127.0.0.1 上起一个静态 HTTP 服务
///   3. 用 WKWebView 打开 `http://127.0.0.1:<port>/client/standalone.html`
///
/// 这样 fetch / XHR / localStorage / WebGL 的行为和 Android 端完全一致，
/// 游戏侧代码一行都不用改。
final class WebViewController: UIViewController {

    private var webView: WKWebView!
    private let server: LocalHTTPServer
    private let rootURL: URL
    private var didLoad = false

    init() {
        let bundleRoot = Bundle.main.resourceURL ?? Bundle.main.bundleURL
        self.rootURL = bundleRoot.appendingPathComponent("webroot", isDirectory: true)
        self.server = LocalHTTPServer(root: rootURL)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) 未实现")
    }

    // MARK: - 视图

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupWebView()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // 游戏过程中不要自动锁屏。
        UIApplication.shared.isIdleTimerDisabled = true
        if !didLoad {
            didLoad = true
            boot()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func setupWebView() {
        let config = WKWebViewConfiguration()

        // 存档写在 localStorage 里，必须用持久化的数据存储。
        config.websiteDataStore = .default()

        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.suppressesIncrementalRendering = false

        let preferences = config.preferences
        preferences.javaScriptCanOpenWindowsAutomatically = true
        // iOS 14+ 的现代写法（preferences.javaScriptEnabled 已废弃，别用）。
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.scrollView.bounces = false
        webView.scrollView.bouncesZoom = false
        webView.scrollView.maximumZoomScale = 1
        webView.scrollView.minimumZoomScale = 1
        // 注意：这里**不**关闭 isScrollEnabled。
        // 关掉之后「游玩前承诺」弹窗在小屏手机上会滚不动，没法输入。
        webView.allowsBackForwardNavigationGestures = false

        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }

        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    // MARK: - 启动

    private func boot() {
        // 资源缺失时给出可诊断的提示，而不是白屏。
        guard FileManager.default.fileExists(atPath: rootURL.path) else {
            showFatal("未找到内置资源目录 webroot。\n\n请确认构建时 webroot 已被加入 App Bundle（预期路径：\(rootURL.path)）。")
            return
        }

        do {
            try server.start()
        } catch {
            showFatal("本地资源服务启动失败：\n\(error.localizedDescription)")
            return
        }

        let urlString = "http://127.0.0.1:\(server.port)/client/standalone.html"
        guard let url = URL(string: urlString) else {
            showFatal("启动地址无效：\(urlString)")
            return
        }
        webView.load(URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 60))
    }

    private func showFatal(_ message: String) {
        let label = UILabel()
        label.numberOfLines = 0
        label.textColor = .white
        label.font = .systemFont(ofSize: 15)
        label.textAlignment = .center
        label.text = message
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    // MARK: - 方向

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return .allButUpsideDown
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
}

// MARK: - WKNavigationDelegate

extension WebViewController: WKNavigationDelegate {

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {

        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        // 站内（本地资源服务）一律放行。
        if url.scheme == "http", url.host == "127.0.0.1" || url.host == "localhost" {
            decisionHandler(.allow)
            return
        }

        // about:blank / data: 等内部导航放行。
        if url.scheme == "about" || url.scheme == "data" || url.scheme == "blob" {
            decisionHandler(.allow)
            return
        }

        // 其余外部链接（TapTap 公告等）交给系统浏览器，不在游戏内打开。
        if navigationAction.navigationType == .linkActivated {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
            decisionHandler(.cancel)
            return
        }

        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        NSLog("[WorldOL] 首次加载失败: \(error.localizedDescription)")
    }
}

// MARK: - WKUIDelegate

extension WebViewController: WKUIDelegate {

    /// 游戏内可能有 target="_blank" 的链接（例如「装备与技能资料」）。
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            if url.scheme == "http", url.host == "127.0.0.1" || url.host == "localhost" {
                webView.load(navigationAction.request)
            } else {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            }
        }
        return nil
    }
}
