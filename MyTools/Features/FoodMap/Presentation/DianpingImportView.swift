#if MYTOOLS_FEATURE_FOOD_MAP
import MapKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

@MainActor
private final class DianpingBrowserModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
#if os(iOS)
    @Published var currentURL = "https://m.dianping.com/"
#else
    @Published var currentURL = "https://www.dianping.com/"
#endif
    @Published var isLoading = false
    @Published private(set) var isReady = false
    @Published var errorMessage: String?
    weak var webView: WKWebView?
    private var contentURL = ""
    private var pendingNavigation: CheckedContinuation<Void, Error>?
    private var pendingWebNavigation: WKNavigation?
    private var navigationTimeoutTask: Task<Void, Never>?

    var loginButtonTitle: String {
#if os(iOS)
        "手机登录"
#else
        "网页登录"
#endif
    }

    func attach(_ webView: WKWebView) {
        guard self.webView !== webView else { return }
        self.webView = webView
        webView.navigationDelegate = self
        webView.uiDelegate = self
        isReady = true
        load(currentURL)
    }

    func load(_ rawValue: String) {
        guard let url = validatedURL(from: rawValue) else {
            errorMessage = "请输入有效的网页链接。"
            return
        }
        currentURL = url.absoluteString
        if !isAuthenticationURL(url) {
            contentURL = url.absoluteString
        }
        webView?.load(URLRequest(url: url))
    }

    func loadAndExtract(_ rawValue: String) async throws -> (url: String, items: [DianpingWebPageItem]) {
        guard let url = validatedURL(from: rawValue), let webView else {
            throw DianpingBrowserError.unavailable
        }
        currentURL = url.absoluteString
        if !isAuthenticationURL(url) { contentURL = url.absoluteString }
        try await withCheckedThrowingContinuation { continuation in
            finishPendingNavigation(.failure(CancellationError()))
            pendingNavigation = continuation
            guard let navigation = webView.load(
                URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
            ) else {
                finishPendingNavigation(.failure(DianpingBrowserError.unavailable))
                return
            }
            pendingWebNavigation = navigation
            navigationTimeoutTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(10))
                } catch {
                    return
                }
                guard let self else { return }
                self.webView?.stopLoading()
                self.finishPendingNavigation(.failure(DianpingBrowserError.timedOut))
            }
        }
        // `didFinish` only means the main document has navigated. Use the same rendered-DOM
        // extraction as the interactive importer and wait for its shop cards to appear.
        try await Task.sleep(for: .milliseconds(700))
        var lastError: Error = DianpingBrowserError.invalidPage
        for attempt in 0..<10 {
            do {
                let page = try await extractItems()
                if page.items.contains(where: {
                    !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }) {
                    return page
                }
            } catch {
                lastError = error
            }
            if attempt < 9 {
                try await Task.sleep(for: .milliseconds(700))
            }
        }
        throw lastError
    }

    func openWebLogin() {
        let returnURL: String
        if !contentURL.isEmpty {
            returnURL = contentURL
        } else if let current = URL(string: currentURL),
                  current.host?.lowercased().contains("dianping.com") == true,
                  !isAuthenticationURL(current) {
            returnURL = currentURL
        } else {
            returnURL = platformHomeURL.absoluteString
        }
#if os(iOS)
        var components = URLComponents(string: "https://m.dianping.com/mlogin/smslogin")!
        components.queryItems = [
            URLQueryItem(name: "needtoken", value: "true"),
            URLQueryItem(name: "redir", value: returnURL)
        ]
#else
        var components = URLComponents(string: "https://account.dianping.com/pclogin")!
        components.queryItems = [URLQueryItem(name: "redir", value: returnURL)]
#endif
        guard let url = components.url else { return }
        currentURL = url.absoluteString
        webView?.load(URLRequest(url: url))
    }

    func extractItems() async throws -> (url: String, items: [DianpingWebPageItem]) {
        guard let webView else { throw DianpingBrowserError.unavailable }
        let script = #"""
        (() => {
          const containers = Array.from(document.querySelectorAll('.relation-container'));
          const isCollection = /collectionlist/i.test(location.pathname);
          if (isCollection && containers.length === 0) { return '[]'; }

          // ── Single-shop page helpers ─────────────────────────────────────
          const isShopPage = /\/(?:shopinfo|appshare\/shop|shop)\//i.test(location.pathname);

          function extractSingleShopAddress() {
            // og:description is the most reliable: "品类 · 区域 · 地址"
            const desc = document.querySelector('meta[property="og:description"]')?.content || '';
            if (desc) {
              const parts = desc.split(/[·｜|]/).map(s => s.trim()).filter(Boolean);
              if (parts.length >= 2) {
                const candidate = parts[parts.length - 1];
                if (candidate.length > 5) return candidate;
              }
            }
            // Walk all elements looking for one that starts with a label like "地址"
            const allElements = Array.from(document.querySelectorAll('*'));
            for (const el of allElements) {
              if (el.children.length > 0) continue;
              const t = (el.innerText || el.textContent || '').trim();
              const stripped = t.replace(/^地址[：:]\s*/, '');
              if (t !== stripped && stripped.length > 5) return stripped;
            }
            return '';
          }

          function extractPhone() {
            // tel: links are canonical
            const telLink = document.querySelector('a[href^="tel:"]');
            if (telLink) return telLink.href.replace('tel:', '').trim();
            // Walk text nodes for a phone-number pattern (mainland / HK / intl)
            const allElements = Array.from(document.querySelectorAll('*'));
            for (const el of allElements) {
              if (el.children.length > 0) continue;
              const t = (el.innerText || el.textContent || '').trim();
              const m = t.match(/^(?:\+?86[-\s]?)?(?:1[3-9]\d{9}|0\d{2,3}[-\s]\d{7,8}|\d{3,4}[-\s]\d{7,8})$/);
              if (m) return m[0].replace(/\s/g, '');
            }
            return '';
          }

          function extractBusinessHours() {
            // Walk text nodes for one that starts with "营业时间"
            const allElements = Array.from(document.querySelectorAll('*'));
            for (const el of allElements) {
              if (el.children.length > 0) continue;
              const t = (el.innerText || el.textContent || '').trim();
              const stripped = t.replace(/^营业时间[：:]\s*/, '');
              if (t !== stripped && stripped.length > 3) return stripped;
            }
            // Fallback: a sibling/parent pattern — find a label node then grab next sibling text
            const labelNodes = Array.from(document.querySelectorAll('*')).filter(el => {
              const t = (el.innerText || el.textContent || '').trim();
              return t === '营业时间' && el.children.length === 0;
            });
            for (const label of labelNodes) {
              const sibling = label.nextElementSibling;
              if (sibling) {
                const t = (sibling.innerText || sibling.textContent || '').trim();
                if (t.length > 3 && !t.includes('打开')) return t.replace(/\n+/g, ' ');
              }
              const parent = label.parentElement;
              if (parent) {
                const combined = (parent.innerText || '').trim()
                  .replace(/^营业时间[：:]\s*/, '').replace(/\n+/g, ' ');
                if (combined.length > 3 && !combined.includes('打开')) return combined;
              }
            }
            return '';
          }

          function extractLatLng() {
            // Many Dianping pages embed lat/lng in data attributes or window state
            const mapNode = document.querySelector('[data-lat], [data-lng], [data-latitude], [data-longitude]');
            if (mapNode && mapNode.dataset) {
              const lat = parseFloat(mapNode.dataset.lat || mapNode.dataset.latitude || '');
              const lng = parseFloat(mapNode.dataset.lng || mapNode.dataset.longitude || '');
              if (!isNaN(lat) && !isNaN(lng)) return { lat, lng };
            }
            // Try window.__InitialState__ or similar global JS state
            try {
              const stateStr = JSON.stringify(window.__InitialState__ || window._data || {});
              const latMatch = stateStr.match(/"lat(?:itude)?"\s*:\s*([\d.]+)/);
              const lngMatch = stateStr.match(/"l(?:ng|ongitude)"\s*:\s*([\d.]+)/);
              if (latMatch && lngMatch) {
                const lat = parseFloat(latMatch[1]);
                const lng = parseFloat(lngMatch[1]);
                if (lat > 0 && lng > 0) return { lat, lng };
              }
            } catch (_) {}
            return null;
          }

          // ── Per-node extraction ─────────────────────────────────────────
          const nodes = containers.length ? containers : [document.body];
          return JSON.stringify(nodes.map(node => {
            const image = node.querySelector('img.pic, img');
            const shopLink = (node.matches && node.matches('a[href*="/shopinfo/"]'))
              ? node
              : ((node.closest && node.closest('a[href*="/shopinfo/"]'))
                  || node.querySelector('a[href*="/shopinfo/"]'));
            const shopNode = node.querySelector('[data-shopuuid], [data-shopid], [data-shop-id]') || node;
            const shopID = shopNode.dataset
              ? (shopNode.dataset.shopuuid || shopNode.dataset.shopid || shopNode.dataset.shopId || '')
              : '';
            const currentShopURL = isShopPage ? location.href : '';
            const titleNode = document.querySelector('h1, .shop-name, .shopName, [class*="shopName"]');
            const metadataTitle = document.querySelector('meta[property="og:title"]')?.content || '';
            const pageTitle = (metadataTitle || (titleNode ? titleNode.textContent : '') || '')
              .replace(/[-_｜|]\s*(?:大众点评.*)?$/i, '')
              .trim();
            let capturedURL = '';
            if (!shopLink && containers.length) {
              const originalOpen = window.open;
              try {
                window.open = url => { capturedURL = String(url || ''); return null; };
                (node.parentElement || node).click();
              } catch (_) {
              } finally {
                window.open = originalOpen;
              }
            }
            const shopURL = shopLink
              ? new URL(shopLink.getAttribute('href'), location.href).href
              : (capturedURL || currentShopURL || (shopID ? `https://m.dianping.com/shopinfo/${shopID}` : ''));
            const bodyText = (node.innerText || '').trim();
            const text = pageTitle && !bodyText.startsWith(pageTitle)
              ? `${pageTitle}\n${bodyText}`
              : bodyText;

            // Pick the best cover image: prefer a large photo (src contains /photos/ or /shopimgs/)
            // and skip tiny icons / placeholder images (< 50px or dianping logo)
            let bestImage = null;
            const imgCandidates = Array.from(node.querySelectorAll('img'));
            for (const img of imgCandidates) {
              const src = img.currentSrc || img.src || '';
              if (!src || src.includes('icon') || src.includes('logo') || src.includes('default')) continue;
              if (img.naturalWidth > 0 && img.naturalWidth < 50) continue;
              bestImage = src;
              if (/\/(photos?|shopimgs?|upload)\//i.test(src)) break;
            }
            if (!bestImage) {
              // Fallback: og:image meta is the shop cover photo
              bestImage = document.querySelector('meta[property="og:image"]')?.content || '';
            }

            // Extra fields — only meaningful on a single-shop detail page
            const address = isShopPage ? extractSingleShopAddress() : '';
            const phone = isShopPage ? extractPhone() : '';
            const businessHours = isShopPage ? extractBusinessHours() : '';
            const coords = isShopPage ? extractLatLng() : null;

            return {
              text,
              imageURL: bestImage || (imgCandidates[0] ? (imgCandidates[0].currentSrc || imgCandidates[0].src || '') : ''),
              shopURL,
              address,
              phone,
              businessHours,
              latitude: coords ? coords.lat : null,
              longitude: coords ? coords.lng : null
            };
          }).filter(item => item.text));
        })()
        """#
        let value = try await webView.evaluateJavaScript(script)
        guard let json = value as? String,
              let data = json.data(using: .utf8) else { throw DianpingBrowserError.invalidPage }
        let items = try JSONDecoder().decode([DianpingWebPageItem].self, from: data)
        return (webView.url?.absoluteString ?? currentURL, items)
    }

    func clearSession() async {
        let store = WKWebsiteDataStore.default()
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records)
        currentURL = platformHomeURL.absoluteString
        contentURL = ""
        webView?.load(URLRequest(url: platformHomeURL))
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        currentURL = webView.url?.absoluteString ?? currentURL
        if let url = webView.url, !isAuthenticationURL(url) {
            contentURL = url.absoluteString
        }
        guard pendingWebNavigation === navigation else { return }
        finishPendingNavigation(.success(()))
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "http" || scheme == "https" || scheme == "about" {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
            openWebLogin()
        }
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard navigationAction.targetFrame == nil,
              let url = navigationAction.request.url,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        webView.load(URLRequest(url: url))
        return nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        errorMessage = error.localizedDescription
        guard pendingWebNavigation === navigation else { return }
        finishPendingNavigation(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        errorMessage = error.localizedDescription
        guard pendingWebNavigation === navigation else { return }
        finishPendingNavigation(.failure(error))
    }

    private func finishPendingNavigation(_ result: Result<Void, Error>) {
        navigationTimeoutTask?.cancel()
        navigationTimeoutTask = nil
        guard let continuation = pendingNavigation else {
            pendingWebNavigation = nil
            return
        }
        pendingNavigation = nil
        pendingWebNavigation = nil
        continuation.resume(with: result)
    }

    private var platformHomeURL: URL {
#if os(iOS)
        URL(string: "https://m.dianping.com/")!
#else
        URL(string: "https://www.dianping.com/")!
#endif
    }

    private func isAuthenticationURL(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        if host == "account.dianping.com" || host == "maccount.dianping.com" {
            return true
        }
        guard host == "m.dianping.com" else { return false }
        let path = url.path.lowercased()
        return path.hasPrefix("/mlogin") || path.hasPrefix("/login")
    }

    private func validatedURL(from rawValue: String) -> URL? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased(),
              host == "dianping.com" || host.hasSuffix(".dianping.com")
                || host == "meituan.com" || host.hasSuffix(".meituan.com") else { return nil }
        return url
    }
}

private enum DianpingBrowserError: LocalizedError {
    case unavailable
    case invalidPage
    case timedOut

    var errorDescription: String? {
        switch self {
        case .unavailable: "登录页面尚未准备好。"
        case .invalidPage: "当前页面没有可识别的店铺内容。"
        case .timedOut: "来源页面加载超时，请稍后重试。"
        }
    }
}

private struct DianpingBrowserView: View {
    @ObservedObject var model: DianpingBrowserModel

    var body: some View {
        DianpingWebViewRepresentable(model: model)
            .overlay {
                if model.isLoading { ProgressView().controlSize(.large) }
            }
    }
}

#if os(iOS)
private struct DianpingWebViewRepresentable: UIViewRepresentable {
    let model: DianpingBrowserModel

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile
        let view = WKWebView(frame: .zero, configuration: configuration)
        model.attach(view)
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#else
private struct DianpingWebViewRepresentable: NSViewRepresentable {
    let model: DianpingBrowserModel

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        let view = WKWebView(frame: .zero, configuration: configuration)
        model.attach(view)
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#endif

struct DianpingImportView: View {
    @EnvironmentObject private var store: FoodMapStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var browser = DianpingBrowserModel()
    @State private var shareText = ""
    @State private var candidates: [DianpingImportCandidate] = []
    @State private var importedIDs = Set<String>()
    @State private var isExtracting = false
    @State private var isImporting = false
    @State private var showingBrowser = false
    @State private var showingClearConfirmation = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("分享内容或链接") {
                    TextEditor(text: $shareText)
                        .frame(minHeight: 110)
                        .overlay(alignment: .topLeading) {
                            if shareText.isEmpty {
                                Text("粘贴大众点评单店分享文字、单店链接或收藏夹链接")
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 8)
                                    .allowsHitTesting(false)
                            }
                        }
                    Button {
                        Task { await parseShareText() }
                    } label: {
                        if isExtracting {
                            Label("正在解析…", systemImage: "doc.text.magnifyingglass")
                        } else {
                            Label("解析分享内容", systemImage: "doc.text.magnifyingglass")
                        }
                    }
                    .disabled(isExtracting)
                    Button {
                        prepareBrowser()
                    } label: {
                        Label("登录并加载链接", systemImage: "person.crop.circle.badge.checkmark")
                    }
                }

                if !candidates.isEmpty {
                    Section("待导入（\(candidates.count)）") {
                        ForEach(candidates) { candidate in
                            candidateRow(candidate)
                                .appDeleteSwipeAction {
                                    deleteCandidate(candidate)
                                }
                        }
                        Button {
                            Task { await importAll() }
                        } label: {
                            if isImporting {
                                ProgressView()
                            } else {
                                Label("全部添加到地图", systemImage: "mappin.and.ellipse")
                            }
                        }
                        .disabled(isImporting || candidates.allSatisfy { importedIDs.contains($0.id) })
                    }
                }

                Section("登录数据") {
                    Text("登录状态由系统 WebKit 保存在本机，不会写入美食档案或上传到 iCloud。")
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                    Button("清除大众点评登录数据", role: .destructive) {
                        showingClearConfirmation = true
                    }
                }
            }
            .appNavigationTitle("从大众点评导入")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(isPresented: $showingBrowser) {
                browserSheet
                    .iOSLargeSheet()
            }
            .background {
                DianpingWebViewRepresentable(model: browser)
                    .frame(width: 1, height: 1)
                    .opacity(0)
                    .allowsHitTesting(false)
            }
            .confirmationDialog("清除登录数据？", isPresented: $showingClearConfirmation) {
                Button("清除", role: .destructive) {
                    Task { await browser.clearSession() }
                }
            } message: {
                Text("这会删除大众点评在 App 内登录页面保存的 Cookie 和网站数据。")
            }
            .alert("无法完成操作", isPresented: Binding(
                get: { errorMessage != nil || browser.errorMessage != nil },
                set: { if !$0 { errorMessage = nil; browser.errorMessage = nil } }
            )) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(errorMessage ?? browser.errorMessage ?? "")
            }
        }
    }

    private var browserSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    TextField("大众点评链接", text: $browser.currentURL)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { browser.load(browser.currentURL) }
                    Button("加载") { browser.load(browser.currentURL) }
                }
                .padding()
                Divider()
                DianpingBrowserView(model: browser)
            }
            .appNavigationTitle("大众点评登录与导入")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { showingBrowser = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    HStack {
                        Button(browser.loginButtonTitle) {
                            browser.openWebLogin()
                        }
                        Button(isExtracting ? "解析中…" : "解析当前页面") {
                            Task { await extractCurrentPage() }
                        }
                        .disabled(isExtracting || browser.isLoading)
                    }
                }
            }
        }
    }

    private func candidateRow(_ candidate: DianpingImportCandidate) -> some View {
        HStack(alignment: .top, spacing: 12) {
            AsyncImage(url: URL(string: candidate.imageURL)) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    Image(systemName: "storefront")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.quaternary)
                }
            }
            .frame(width: 74, height: 74)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(candidate.name)
                        .appFont(.headline)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    if importedIDs.contains(candidate.id) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("添加") { Task { await importCandidate(candidate) } }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(isImporting)
                    }
                }

                FoodPlaceMetricsView(
                    rating: candidate.rating,
                    reviewCount: candidate.reviewCount,
                    averagePrice: candidate.pricePerPerson.map { Decimal($0) },
                    averagePriceCurrency: .cny
                )

                HStack(spacing: 12) {
                    compactCandidateFact(
                        title: "主打",
                        value: candidate.category.isEmpty ? "暂无" : candidate.category
                    )
                    compactCandidateFact(
                        title: "地址",
                        value: candidate.address.isEmpty ? "待补充" : candidate.address
                    )
                }
                compactCandidateFact(title: "推荐", value: "暂无")
                compactCandidateFact(
                    title: "来源",
                    value: candidate.shopURL.isEmpty
                        ? "大众点评 · 未解析到单店链接"
                        : "大众点评 · 已解析单店链接"
                )
            }
        }
        .padding(.vertical, 5)
    }

    private func compactCandidateFact(title: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(title).foregroundStyle(.tertiary)
            Text(value).foregroundStyle(.secondary).lineLimit(1)
        }
        .appFont(.caption)
    }

    private func parseShareText() async {
        let parsed = DianpingImportParser.parseSharedText(shareText)
        if parsed.isEmpty {
            guard let url = extractDianpingURL(from: shareText) else {
                errorMessage = "没有识别到单店分享内容或大众点评链接。"
                return
            }
            if DianpingImportCandidate.shopIdentifier(in: url) != nil,
               !DianpingImportParser.isCollectionPageURL(url) {
                isExtracting = true
                defer { isExtracting = false }
                do {
                    let page = try await browser.loadAndExtract(url)
                    let autoparsed = DianpingImportParser.parseWebItems(page.items, sourceURL: page.url)
                    guard !autoparsed.isEmpty else { throw DianpingBrowserError.invalidPage }
                    candidates = autoparsed
                } catch {
                    errorMessage = error.localizedDescription
                }
            } else {
                browser.currentURL = url
                showingBrowser = true
            }
        } else {
            candidates = parsed
        }
    }

    private func prepareBrowser() {
        if let url = extractDianpingURL(from: shareText) {
            browser.currentURL = url
        }
        showingBrowser = true
    }

    private func extractCurrentPage() async {
        isExtracting = true
        defer { isExtracting = false }
        do {
            let page = try await browser.extractItems()
            let parsed = DianpingImportParser.parseWebItems(page.items, sourceURL: page.url)
            guard !parsed.isEmpty else { throw DianpingBrowserError.invalidPage }
            candidates = parsed
            showingBrowser = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func importAll() async {
        isImporting = true
        defer { isImporting = false }
        for candidate in candidates where !importedIDs.contains(candidate.id) {
            await importCandidate(candidate, managesProgress: false)
        }
    }

    private func deleteCandidate(_ candidate: DianpingImportCandidate) {
        withAnimation {
            candidates.removeAll { $0.id == candidate.id }
            importedIDs.remove(candidate.id)
        }
    }

    private func importCandidate(_ candidate: DianpingImportCandidate, managesProgress: Bool = true) async {
        if managesProgress { isImporting = true }
        defer { if managesProgress { isImporting = false } }
        if store.places.contains(where: candidate.matchesExisting) {
            importedIDs.insert(candidate.id)
            return
        }
        var place = FoodPlace(
                shopName: candidate.name,
                recommendedFood: "",
                administrativeLocation: ChinaAdministrativeDivisions.infer(
                    from: [candidate.city, candidate.address].joined(separator: " ")
                ),
                address: candidate.address,
                status: .wantToTry,
                sourceTitle: "大众点评",
                sourceURL: candidate.sourceURL,
                shopURL: candidate.shopURL,
                rating: candidate.rating,
                reviewCount: candidate.reviewCount,
                averagePrice: candidate.pricePerPerson.map { Decimal($0) },
                averagePriceCurrency: .cny,
                specialty: candidate.category,
                tags: candidate.tags,
                phone: candidate.phone,
                businessHours: candidate.businessHours
            )
            // Use coordinates from Dianping page when available; otherwise fall back to MapKit search
            if let lat = candidate.latitude, let lng = candidate.longitude {
                let coord = FoodCoordinate(latitude: lat, longitude: lng)
                if coord.isValid { place.coordinate = coord }
            }
            if place.coordinate == nil {
                let query = [candidate.city, candidate.name, candidate.address]
                    .filter { !$0.isEmpty }.joined(separator: " ")
                if let item = try? await MapLocationSearchService.search(query: query).first {
                    place.coordinate = FoodCoordinate(
                        latitude: item.location.coordinate.latitude,
                        longitude: item.location.coordinate.longitude
                    )
                    let mapAddress = item.address?.fullAddress
                        ?? item.addressRepresentations?.fullAddress(includingRegion: false, singleLine: true)
                        ?? ""
                    if place.address.isEmpty { place.address = mapAddress }
                    if place.administrativeLocation == nil {
                        place.administrativeLocation = ChinaAdministrativeDivisions.infer(from: mapAddress)
                    }
                }
            }
            if let imageURL = URL(string: candidate.imageURL), imageURL.scheme == "https" {
                if let (data, response) = try? await URLSession.shared.data(from: imageURL),
                   data.count <= 10_000_000,
                   let response = response as? HTTPURLResponse,
                   (200..<300).contains(response.statusCode),
                   let photo = try? store.savePhoto(
                       data: data,
                       fileName: "大众点评-\(candidate.id.prefix(12)).jpg",
                       contentType: .jpeg
                   ) {
                    place.photos = [photo]
                }
            }
        store.upsert(place)
        importedIDs.insert(candidate.id)
    }

    private func extractDianpingURL(from text: String) -> String? {
        let normalized = text.replacingOccurrences(of: "\\_", with: "_")
            .replacingOccurrences(of: "\\&", with: "&")
        guard let range = normalized.range(of: "https://", options: .caseInsensitive) else { return nil }
        let suffix = normalized[range.lowerBound...]
        let value = suffix.prefix { !$0.isWhitespace && $0 != ")" && $0 != "]" }
        let url = String(value)
        return url.contains("dianping.com") ? url : nil
    }
}

private struct FoodPlaceSourceRefreshWork {
    let adapter: any FoodPlaceSourceAdapter
    let url: String
    var places: [FoodPlace]
}

struct FoodPlaceSourceRefreshView: View {
    @EnvironmentObject private var store: FoodMapStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var browser = DianpingBrowserModel()
    @State private var isRefreshing = false
    @State private var completedCount = 0
    @State private var totalCount = 0
    @State private var updatedCount = 0
    @State private var unchangedCount = 0
    @State private var missingCount = 0
    @State private var unsupportedCount = 0
    @State private var failedCount = 0
    @State private var errorDetails: [String] = []
    @State private var hasFinished = false
    @State private var sourceProgress = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("可更新记录") {
                    LabeledContent("全部美食记录", value: "\(store.places.count)")
                    LabeledContent("具有支持来源", value: "\(refreshableCount)")
                    LabeledContent("收藏夹来源", value: "\(collectionSourceCount)")
                    Text("大众点评会先对导入记录中的收藏夹链接去重，再逐个取得收藏夹内的完整店铺列表，并通过单店链接或店名与本地记录匹配。来源列表中找不到对应店铺时，才会回退单店链接。吃过状态、日期、推荐食物、标签、备注、照片和地图位置不会被覆盖。")
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("批量更新") {
                    if isRefreshing || hasFinished {
                        ProgressView(value: Double(completedCount), total: Double(max(totalCount, 1))) {
                            Text(isRefreshing
                                ? "\(sourceProgress) · 已处理 \(completedCount)/\(totalCount)"
                                : "更新完成")
                        }
                    }

                    Button {
                        Task { await refreshAll() }
                    } label: {
                        if isRefreshing {
                            Label("正在更新…", systemImage: "arrow.triangle.2.circlepath")
                        } else {
                            Label("更新全部链接", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    .disabled(isRefreshing || !browser.isReady || refreshableCount == 0)
                }

                if hasFinished {
                    Section("更新结果") {
                        LabeledContent("已更新", value: "\(updatedCount)")
                        LabeledContent("内容未变化", value: "\(unchangedCount)")
                        if missingCount > 0 {
                            LabeledContent("来源中未找到", value: "\(missingCount)")
                        }
                        if unsupportedCount > 0 {
                            LabeledContent("暂不支持", value: "\(unsupportedCount)")
                        }
                        if failedCount > 0 {
                            LabeledContent("更新失败", value: "\(failedCount)")
                        }
                        ForEach(errorDetails, id: \.self) { detail in
                            Text(detail)
                                .appFont(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("来源扩展") {
                    Text("刷新流程与来源解析已经分离。后续接入美团时只需增加一个来源适配器，不需要改动本地档案合并和批量更新界面。")
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .appNavigationTitle("更新店铺资料")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                        .disabled(isRefreshing)
                }
            }
            .background {
                DianpingBrowserView(model: browser)
                    // Dianping only renders the same mobile shop-card DOM used by manual
                    // import when the page has a real viewport.
                    .frame(width: 390, height: 844)
                    .opacity(0.001)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    private var refreshableCount: Int {
        store.places.filter { place in
            FoodPlaceSourceAdapters.all.contains { $0.refreshURL(for: place) != nil }
        }.count
    }

    private var collectionSourceCount: Int {
        Set(store.places.compactMap { place -> String? in
            let sourceURL = place.sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
            return DianpingImportParser.isCollectionPageURL(sourceURL) ? sourceURL : nil
        }).count
    }

    @MainActor
    private func refreshAll() async {
        isRefreshing = true
        hasFinished = false
        completedCount = 0
        updatedCount = 0
        unchangedCount = 0
        missingCount = 0
        failedCount = 0
        errorDetails = []
        sourceProgress = "准备来源"

        let snapshot = store.places
        var claimedIDs = Set<UUID>()
        var work: [FoodPlaceSourceRefreshWork] = []

        for adapter in FoodPlaceSourceAdapters.all {
            var groups: [String: [FoodPlace]] = [:]
            for place in snapshot where !claimedIDs.contains(place.id) {
                guard let refreshURL = adapter.refreshURL(for: place) else { continue }
                groups[refreshURL, default: []].append(place)
                claimedIDs.insert(place.id)
            }
            work.append(contentsOf: groups.map {
                FoodPlaceSourceRefreshWork(adapter: adapter, url: $0.key, places: $0.value)
            })
        }

        unsupportedCount = snapshot.count - claimedIDs.count
        totalCount = claimedIDs.count

        var fallbackWork: [FoodPlaceSourceRefreshWork] = []
        for (index, item) in work.enumerated() {
            sourceProgress = "正在获取来源 \(index + 1)/\(work.count)"
            do {
                let page = try await browser.loadAndExtract(item.url)
                let candidates = item.adapter.candidates(from: page.items, pageURL: page.url)
                for place in item.places {
                    if let candidate = candidates.first(where: { $0.matchesExisting(place) }) {
                        apply(candidate, to: place)
                        completedCount += 1
                    } else if !enqueueFallback(
                        for: place,
                        adapter: item.adapter,
                        excluding: item.url,
                        in: &fallbackWork
                    ) {
                        recordMissing(place, candidates: candidates)
                        completedCount += 1
                    }
                }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                for place in item.places {
                    failedCount += 1
                    completedCount += 1
                    errorDetails.append("\(place.displayTitle)：来源获取失败，\(message)")
                }
            }
        }

        // A collection may have expired or removed one shop. Only those unresolved records
        // fall back to their persisted concrete shop URL instead of blocking the whole batch.
        for (index, item) in fallbackWork.enumerated() {
            sourceProgress = "正在回退单店 \(index + 1)/\(fallbackWork.count)"
            do {
                let page = try await browser.loadAndExtract(item.url)
                let candidates = item.adapter.candidates(from: page.items, pageURL: page.url)
                for place in item.places {
                    if let candidate = candidates.first(where: { $0.matchesExisting(place) }) {
                        apply(candidate, to: place)
                    } else {
                        recordMissing(place, candidates: candidates)
                    }
                    completedCount += 1
                }
            } catch {
                failedCount += item.places.count
                completedCount += item.places.count
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                for place in item.places {
                    errorDetails.append("\(place.displayTitle)：回退来源更新失败，\(message)")
                }
            }
        }

        isRefreshing = false
        hasFinished = true
    }

    @MainActor
    private func apply(_ candidate: DianpingImportCandidate, to place: FoodPlace) {
        let merged = FoodPlaceSourceRefreshMerge.merging(candidate, into: place)
        if merged == place {
            unchangedCount += 1
        } else {
            store.upsert(merged)
            updatedCount += 1
        }
    }

    private func enqueueFallback(
        for place: FoodPlace,
        adapter: any FoodPlaceSourceAdapter,
        excluding attemptedURL: String,
        in work: inout [FoodPlaceSourceRefreshWork]
    ) -> Bool {
        guard let fallbackURL = adapter.fallbackRefreshURL(for: place),
              fallbackURL != attemptedURL else { return false }
        if let index = work.firstIndex(where: {
            $0.adapter.sourceTitle == adapter.sourceTitle && $0.url == fallbackURL
        }) {
            work[index].places.append(place)
        } else {
            work.append(FoodPlaceSourceRefreshWork(
                adapter: adapter,
                url: fallbackURL,
                places: [place]
            ))
        }
        return true
    }

    private func recordMissing(
        _ place: FoodPlace,
        candidates: [DianpingImportCandidate]
    ) {
        missingCount += 1
        let parsedNames = candidates.map(\.name).joined(separator: "、")
        if candidates.isEmpty {
            errorDetails.append("\(place.displayTitle)：来源页面未解析出店铺")
        } else {
            errorDetails.append("\(place.displayTitle)：未匹配；来源包含 \(parsedNames)")
        }
    }
}

#endif
