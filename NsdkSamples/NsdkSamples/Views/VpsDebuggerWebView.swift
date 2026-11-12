// Copyright 2026 Niantic Spatial.

import SwiftUI
import WebKit

struct VpsDebuggerWebView: UIViewRepresentable {
    let bridge: VpsDebuggerWebBridge
    /// Loads the viewer when true, blanks it when false. The WebView stays mounted either way;
    /// `VPS2View` says why it must not be unmounted on hide.
    let isVisible: Bool

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        bridge.attach(webView)
        return webView
    }

    // SwiftUI runs this right after makeUIView, so the first show() always has a WebView.
    func updateUIView(_ uiView: WKWebView, context: Context) {
        if isVisible {
            bridge.show()
        } else {
            bridge.hide()
        }
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.bridge.detach()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(bridge: bridge)
    }

    final class Coordinator {
        let bridge: VpsDebuggerWebBridge
        init(bridge: VpsDebuggerWebBridge) { self.bridge = bridge }
    }
}
