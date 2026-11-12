// Copyright 2026 Niantic Spatial.

import Foundation
import NSDK
import SwiftProtobuf

/// Session-scoped buffer of VPS debugger events for the hosted WebView overlay.
final class VpsDebuggerEventBuffer {
    private let maxEvents: Int
    private var events: [String] = []
    private var maxEventsWarningLogged = false

    init(maxEvents: Int = 50_000) {
        self.maxEvents = maxEvents
    }

    var count: Int { events.count }

    func clear() {
        events.removeAll()
        maxEventsWarningLogged = false
    }

    func eventJson(at index: Int) -> String { events[index] }

    func add(_ event: Nsdk_Vps_VpsDebuggerDataEvent) {
        guard Self.shouldInclude(event) else { return }
        guard events.count < maxEvents else {
            if !maxEventsWarningLogged {
                maxEventsWarningLogged = true
                NSLog("VpsDebuggerEventBuffer: max event cap (\(maxEvents)) reached; dropping further events.")
            }
            return
        }
        do {
            let json = try event.jsonString()
            events.append(json)
        } catch {
            NSLog("VpsDebuggerEventBuffer: failed to serialize event: \(error)")
        }
    }

    static func shouldInclude(_ event: Nsdk_Vps_VpsDebuggerDataEvent) -> Bool {
        switch event.vpsDebuggerEvent {
        case .mapPoint2D, .assetReceived, .anchor:
            return false
        default:
            return true
        }
    }
}
