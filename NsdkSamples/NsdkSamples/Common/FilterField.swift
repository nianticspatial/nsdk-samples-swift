// Copyright 2026 Niantic Spatial.

import SwiftUI

/// A text field for filtering a list by name, with a clear button.
struct FilterField: View {
    @Binding var text: String
    var placeholder = "Filter..."

    var body: some View {
        HStack {
            TextField(placeholder, text: $text)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }
            }
        }
        .textFieldStyle(.roundedBorder)
    }
}
