import SwiftUI
import WebKit
import Observation

/// 网页扫号：内嵌运营商官方选号页，在用户自己的网络上加载（能正常通过各家的反爬验证），
/// 自动点「换一批」，并把页面和接口返回里出现的号码收进来。
enum WebCarrier: String, CaseIterable, Identifiable, Codable {
    case mobile = "中国移动"
    case telecom = "中国电信"
    case broadnet = "中国广电"
    case unicom = "中国联通"

    var id: String { rawValue }

    var short: String {
        switch self {
        case .mobile: return "移动"
        case .telecom: return "电信"
        case .broadnet: return "广电"
        case .unicom: return "联通"
        }
    }

    /// 默认打开的官方选号页（可以在地址栏换成你所在省份的页面，会记住）
    var defaultURL: String {
        switch self {
        case .mobile: return "https://service.bj.10086.cn/m/num/"
        case .telecom: return "https://waphn.189.cn/selfResource/mallx/xinxiliu/29heixh221102/index.html"
        case .broadnet: return "https://www.10099.com.cn/transaction-manage-number-selection.html"
        case .unicom: return "https://card.10010.com/numberPro/numberH5Page"
        }
    }

    /// 号段前三位，用来过滤页面上不属于该运营商的数字
    var prefixes: Set<String> {
        switch self {
        case .mobile:
            return ["134", "135", "136", "137", "138", "139", "147", "148", "150", "151", "152", "157", "158", "159",
                    "165", "172", "178", "182", "183", "184", "187", "188", "195", "197", "198"]
        case .telecom:
            return ["133", "149", "153", "162", "173", "174", "177", "180", "181", "189", "190", "191", "193", "199"]
        case .broadnet:
            return ["192"]
        case .unicom:
            return ["130", "131", "132", "145", "146", "155", "156", "166", "167", "171", "175", "176", "185", "186", "196"]
        }
    }
}

/// 接收页面脚本消息的中转（避免 WKUserContentController 强引用造成循环）
final class WebMessageProxy: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    var onNumbers: (([String]) -> Void)?
    var onFinish: (() -> Void)?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let dict = message.body as? [String: Any], let nums = dict["nums"] as? [String] else { return }
        let cb = onNumbers
        DispatchQueue.main.async { cb?(nums) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let cb = onFinish
        DispatchQueue.main.async { cb?() }
    }
}

@Observable
@MainActor
final class WebScanner {
    var carrier: WebCarrier = .mobile
    var urlText = ""
    var autoNext = false
    var interval: Double = 8
    var pageNumbers = 0        // 本次在页面上看到的号码数
    var pageNew = 0            // 其中新收进来的
    var note = ""
    var canGoBack = false
    var title = ""

    @ObservationIgnored weak var model: AppModel?
    @ObservationIgnored let webView: WKWebView
    @ObservationIgnored private let proxy: WebMessageProxy
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastClick = Date.distantPast
    @ObservationIgnored private var savedURLs: [String: String] = [:]

    private static let script = """
    (function(){
      if (window.__lh) return; window.__lh = true;
      var re = /(?<!\\d)1[3-9]\\d{9}(?!\\d)/g;
      var pending = {};
      function scan(t){ if(!t) return; var m = String(t).match(re); if(m){ for(var i=0;i<m.length;i++) pending[m[i]] = 1; } }
      function flush(){
        var k = Object.keys(pending);
        if (k.length) { try { window.webkit.messageHandlers.lh.postMessage({nums:k}); } catch(e){} pending = {}; }
      }
      setInterval(function(){ try { if (document.body) scan(document.body.innerText); } catch(e){} flush(); }, 1500);
      var oSend = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.send = function(){
        this.addEventListener('load', function(){
          try {
            if (this.responseType === '' || this.responseType === 'text') scan(this.responseText);
            else if (this.responseType === 'json') scan(JSON.stringify(this.response));
          } catch(e){}
        });
        return oSend.apply(this, arguments);
      };
      if (window.fetch) {
        var oFetch = window.fetch;
        window.fetch = function(){
          return oFetch.apply(this, arguments).then(function(r){
            try { r.clone().text().then(scan).catch(function(){}); } catch(e){}
            return r;
          });
        };
      }
      window.__lhNext = function(){
        var words = ['换一批','换一换','换一组','再换一批','换批号码','刷新号码','下一批','下一页','更多号码'];
        var els = document.querySelectorAll('a,button,span,div,p,li,em,i');
        for (var w = 0; w < words.length; w++) {
          for (var i = 0; i < els.length; i++) {
            var el = els[i], t = (el.innerText || '').trim();
            if (t === words[w] || (t.length <= 8 && t.indexOf(words[w]) >= 0)) {
              var r = el.getBoundingClientRect();
              if (r.width > 0 && r.height > 0) { el.click(); return true; }
            }
          }
        }
        return false;
      };
    })();
    """

    init() {
        let p = WebMessageProxy()
        proxy = p
        let config = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        ucc.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        ucc.add(p, name: "lh")
        config.userContentController = ucc
        config.websiteDataStore = .default()   // 记住登录状态
        webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = p
        if let d = UserDefaults.standard.dictionary(forKey: "webURLs") as? [String: String] { savedURLs = d }
        if let c = UserDefaults.standard.string(forKey: "webCarrier").flatMap(WebCarrier.init(rawValue:)) { carrier = c }

        proxy.onNumbers = { [weak self] nums in self?.receive(nums) }
        proxy.onFinish = { [weak self] in self?.pageLoaded() }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func start() {
        if webView.url == nil { load(carrier) }
    }

    func load(_ c: WebCarrier) {
        carrier = c
        UserDefaults.standard.set(c.rawValue, forKey: "webCarrier")
        let s = savedURLs[c.rawValue] ?? c.defaultURL
        urlText = s
        pageNumbers = 0
        pageNew = 0
        open(s)
    }

    func open(_ s: String) {
        var t = s.trimmingCharacters(in: .whitespaces)
        if !t.hasPrefix("http") { t = "https://" + t }
        guard let u = URL(string: t) else { note = "地址不对"; return }
        note = ""
        webView.load(URLRequest(url: u))
    }

    func goHome() {
        savedURLs[carrier.rawValue] = nil
        UserDefaults.standard.set(savedURLs, forKey: "webURLs")
        load(carrier)
    }

    /// 把当前页面记为这个运营商的默认页
    func rememberCurrent() {
        guard let u = webView.url?.absoluteString else { return }
        savedURLs[carrier.rawValue] = u
        UserDefaults.standard.set(savedURLs, forKey: "webURLs")
        note = "已记住，下次打开「\(carrier.short)」直接进这个页面"
    }

    func nextBatch() {
        lastClick = Date()
        webView.evaluateJavaScript("window.__lhNext ? window.__lhNext() : false") { [weak self] result, _ in
            let ok = (result as? Bool) ?? false
            Task { @MainActor in
                guard let self else { return }
                if !ok {
                    self.note = "页面上没找到「换一批」按钮，请先手动点一次页面里的选号 / 换一批"
                } else if self.note.hasPrefix("页面上没找到") {
                    self.note = ""
                }
            }
        }
    }

    private func pageLoaded() {
        canGoBack = webView.canGoBack
        title = webView.title ?? ""
        if let u = webView.url?.absoluteString { urlText = u }
    }

    private func tick() {
        canGoBack = webView.canGoBack
        guard autoNext, Date().timeIntervalSince(lastClick) >= max(3, interval) else { return }
        nextBatch()
    }

    private func receive(_ nums: [String]) {
        let mine = nums.filter { carrier.prefixes.contains(String($0.prefix(3))) }
        guard !mine.isEmpty, let model else { return }
        pageNumbers += mine.count
        pageNew += model.ingestWeb(mine, carrier: carrier)
    }
}

// MARK: - 界面

struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct WebScanView: View {
    @Environment(AppModel.self) private var model
    @Environment(WebScanner.self) private var web

    var body: some View {
        @Bindable var web = web
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("运营商", selection: Binding(get: { web.carrier }, set: { web.load($0) })) {
                    ForEach(WebCarrier.allCases) { Text($0.short).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)

                Button { web.webView.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!web.canGoBack)
                Button { web.webView.reload() } label: { Image(systemName: "arrow.clockwise") }
                TextField("官方选号页地址", text: $web.urlText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { web.open(web.urlText) }
                Menu {
                    Button("把当前页设为「\(web.carrier.short)」默认页") { web.rememberCurrent() }
                    Button("恢复默认页") { web.goHome() }
                } label: { Image(systemName: "bookmark") }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(10)

            HStack(spacing: 14) {
                Toggle("自动换一批", isOn: $web.autoNext)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Stepper("每 \(Int(web.interval)) 秒", value: $web.interval, in: 3...60, step: 1)
                    .controlSize(.small)
                    .disabled(!web.autoNext)
                Button("换一批") { web.nextBatch() }
                    .controlSize(.small)
                Spacer()
                Text("本页看到 \(web.pageNumbers) 个 · 新收 \(web.pageNew) 个 · 命中 \(model.hits.count)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            if !web.note.isEmpty {
                Text(web.note)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }

            Divider()
            WebViewHost(webView: web.webView)
        }
        .frame(minWidth: 520, minHeight: 640)
        .onAppear { web.model = model; web.start() }
        .navigationTitle("网页扫号 · \(web.carrier.rawValue)")
    }
}
