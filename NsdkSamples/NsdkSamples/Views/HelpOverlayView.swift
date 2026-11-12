// Copyright 2026 Niantic Spatial.

import SwiftUI

struct HelpOverlayView: View {
    let helpText: String
    @Binding var isVisible: Bool

    var body: some View {
        if isVisible {
            Text(helpText)
                .font(.system(size: 15))
                .foregroundColor(.white)
                .multilineTextAlignment(.leading)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.7))
                .cornerRadius(8)
                .padding(.horizontal, 15)
        }
    }
}
