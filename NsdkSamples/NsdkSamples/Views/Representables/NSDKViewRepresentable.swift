// Copyright 2026 Niantic Spatial.

import SwiftUI
import NSDK

struct NSDKViewRepresentable: UIViewRepresentable {
    let arManager: ARManager

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        arManager.nsdkView.setup(in: container)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
