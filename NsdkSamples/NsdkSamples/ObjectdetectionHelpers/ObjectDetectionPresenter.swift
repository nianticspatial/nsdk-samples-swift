import UIKit

protocol ObjectDetectionPresenter: AnyObject {
    /// Called when aggregated objects are updated each frame
    func update(aggregatedObjects: [AggregatedObject])
    
    /// Called when a touch goes down (finger placed). Use when you want to show UI while pressed.
    func handleTouchBegan(at point: CGPoint)

    /// Called when the touch ends or is cancelled (finger lifted).
    func handleTouchEnded()

    /// Clear any UI the presenter owns (e.g., on stop)
    func clear()
}
