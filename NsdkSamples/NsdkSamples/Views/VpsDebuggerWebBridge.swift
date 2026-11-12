// Copyright 2026 Niantic Spatial.

import Foundation
import WebKit

/// Streams buffered VPS debugger events into the hosted Firebase viewer via `window.__vpsBridge`.
final class VpsDebuggerWebBridge: NSObject {
    static let defaultViewerURL = URL(string: "https://vpsdebugger.nianticspatial.com/?embedded=true")!

    private let eventBuffer: VpsDebuggerEventBuffer
    private let viewerURL: URL
    private weak var webView: WKWebView?

    private var visible = false
    private var bridgeReady = false
    private var isFlushing = false
    private var nextSendIndex = 0
    private var flushTask: Task<Void, Never>?

    init(eventBuffer: VpsDebuggerEventBuffer, viewerURL: URL = VpsDebuggerWebBridge.defaultViewerURL) {
        self.eventBuffer = eventBuffer
        self.viewerURL = viewerURL
    }

    func attach(_ webView: WKWebView) {
        self.webView = webView
        webView.navigationDelegate = self
        webView.configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
    }

    func detach() {
        hide()
        webView?.navigationDelegate = nil
        webView = nil
    }

    func show() {
        guard let webView else { return }
        guard !visible else { return }
        visible = true
        bridgeReady = false
        nextSendIndex = 0
        webView.load(URLRequest(url: viewerURL))
        startFlushLoop()
    }

    func hide() {
        guard visible else { return }
        visible = false
        let shouldReset = bridgeReady
        bridgeReady = false
        flushTask?.cancel()
        flushTask = nil
        let view = webView

        // Await resetViewer before blanking; otherwise about:blank wins the race and reset never runs.
        // Skip blank if show() resumed this WebView before the task finished.
        Task {
            if shouldReset {
                await evalJs(
                    "if (window.__vpsBridge && window.__vpsBridge.resetViewer) { " +
                        "window.__vpsBridge.resetViewer(); }"
                )
            }
            guard !self.visible, self.webView === view else { return }
            view?.load(URLRequest(url: URL(string: "about:blank")!))
        }
    }

    private func startFlushLoop() {
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.visible, self.bridgeReady, !self.isFlushing else {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    continue
                }
                if self.nextSendIndex < self.eventBuffer.count {
                    await self.flush(catchUp: false)
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    private func prepareBridge(catchUp: Bool) async {
        guard visible else { return }
        let ready = await waitForBridgeFunction()
        guard ready else {
            NSLog("VpsDebuggerWebBridge: window.__vpsBridge.onEvents was not ready.")
            return
        }
        let configJson = #"{"bridgeVersion":1,"embedded":true}"#
        await evalJs(
            "if (window.__vpsBridge.applyViewerConfig) { " +
                "window.__vpsBridge.applyViewerConfig(\(configJson)); " +
                "} else { window.__vpsViewerConfig = \(configJson); }"
        )
        await evalJs("if (window.__vpsBridge.beginLive) { window.__vpsBridge.beginLive('live'); }")
        bridgeReady = true
        nextSendIndex = 0
        NSLog("VpsDebuggerWebBridge: bridge ready. Session events: \(eventBuffer.count)")
        await flush(catchUp: catchUp)
    }

    private func waitForBridgeFunction() async -> Bool {
        for _ in 0..<50 {
            guard visible else { return false }
            if await evalJsBool("Boolean(window.__vpsBridge && typeof window.__vpsBridge.onEvents === 'function')") {
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    private func flush(catchUp: Bool) async {
        guard visible, bridgeReady, !isFlushing else { return }
        guard nextSendIndex < eventBuffer.count else { return }

        isFlushing = true
        defer { isFlushing = false }

        let batchSize = catchUp ? 50 : 25
        while nextSendIndex < eventBuffer.count, visible {
            let take = min(eventBuffer.count - nextSendIndex, batchSize)
            var batch = "["
            for i in 0..<take {
                if i > 0 { batch += "," }
                batch += eventBuffer.eventJson(at: nextSendIndex + i)
            }
            batch += "]"
            let ok = await evalJsBool("window.__vpsBridge.onEvents(\(batch)); true")
            if !ok {
                NSLog("VpsDebuggerWebBridge: onEvents JavaScript evaluation failed.")
                break
            }
            nextSendIndex += take
            if !catchUp { break }
            await Task.yield()
        }
    }

    private func evalJs(_ script: String) async {
        guard let webView else { return }
        _ = try? await webView.evaluateJavaScript(script)
    }

    private func evalJsBool(_ script: String) async -> Bool {
        guard let webView else { return false }
        do {
            let value = try await webView.evaluateJavaScript(script)
            if let bool = value as? Bool { return bool }
            if let num = value as? NSNumber { return num.boolValue }
            if let str = value as? String { return str == "true" }
            return false
        } catch {
            return false
        }
    }
}

extension VpsDebuggerWebBridge: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            guard self.visible else { return }
            await self.prepareBridge(catchUp: true)
        }
    }
}
