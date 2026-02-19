import UIKit

struct AggregatedObject {
    let id: String
    var rect: CGRect
    var className: String
    var confidence: Float
    var unseenFrames: Int
    /// consecutive frames where incoming detections indicated a larger box than current
    var expansionStreak: Int
}
