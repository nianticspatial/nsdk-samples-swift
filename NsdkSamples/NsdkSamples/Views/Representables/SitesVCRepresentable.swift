// Copyright 2026 Niantic Spatial.

import SwiftUI

struct SitesVCRepresentable: UIViewControllerRepresentable {
    let arManager: ARManager
    func makeUIViewController(context: Context) -> SitesViewController {
        SitesViewController(arManager: arManager)
    }
    func updateUIViewController(_ vc: SitesViewController, context: Context) {}
}
