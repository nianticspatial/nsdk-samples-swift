// Copyright 2026 Niantic Spatial.

import Foundation
import NSDK

/// A playable scan's identity and display fields; `duration` and `createdDate` are nil for a scan
/// known only by its ID.
struct PlaybackScan: Identifiable, Equatable {
    let id: String
    let name: String
    let duration: TimeInterval?
    let createdDate: Date?

    init(_ info: ScanInfo) {
        id = info.id
        name = info.name
        duration = info.duration
        createdDate = info.createdDate
    }

    /// A scan known only by its ID.
    init(id: String) {
        self.id = id
        name = ""
        duration = nil
        createdDate = nil
    }

    /// The scan's name, or its ID when it has none.
    var displayName: String { name.isEmpty ? id : name }
}
