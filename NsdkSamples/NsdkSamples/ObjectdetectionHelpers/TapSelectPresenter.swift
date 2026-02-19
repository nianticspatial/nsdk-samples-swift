import UIKit

final class TapSelectPresenter: ObjectDetectionPresenter {
    private let overlayLayer: CALayer
    private var aggregatedObjects: [AggregatedObject] = []
    private var selectedLayer: CALayer?
    private var selectionTimer: Timer?

    init(overlayLayer: CALayer) {
        self.overlayLayer = overlayLayer
    }

    func update(aggregatedObjects: [AggregatedObject]) {
        // keep aggregated objects for hit testing; do not draw them until user taps
        self.aggregatedObjects = aggregatedObjects
    }

    func handleTouchBegan(at point: CGPoint) {
        // On touch down, show selection but do NOT start timeout — clear on touch end
        if let selected = pickCandidate(at: point) {
            showSelection(for: selected, startTimer: false)
        }
    }

    func handleTouchEnded() {
        // Clear selection immediately when finger is lifted
        self.clear()
    }

    private func showSelection(for agg: AggregatedObject, startTimer: Bool) {
        DispatchQueue.main.async {
            self.selectedLayer?.removeFromSuperlayer()
            self.selectionTimer?.invalidate()

            let boxLayer = CALayer()
            boxLayer.name = "selected"
            boxLayer.borderColor = UIColor.systemYellow.cgColor
            boxLayer.borderWidth = 3.0
            boxLayer.frame = agg.rect

            let textLayer = CATextLayer()
            textLayer.name = "text"
            textLayer.string = "\(agg.className) (\(Int(agg.confidence * 100))%)"
            textLayer.fontSize = 12
            textLayer.foregroundColor = UIColor.white.cgColor
            textLayer.backgroundColor = UIColor.black.withAlphaComponent(0.7).cgColor
            textLayer.alignmentMode = .center
            textLayer.contentsScale = UIScreen.main.scale
            let padding: CGFloat = 2
            let textHeight: CGFloat = 18
            textLayer.frame = CGRect(x: 0, y: 0, width: boxLayer.frame.width, height: textHeight).insetBy(dx: padding, dy: 0)
            boxLayer.addSublayer(textLayer)

            self.overlayLayer.addSublayer(boxLayer)
            self.selectedLayer = boxLayer
        }
    }

    private func pickCandidate(at point: CGPoint) -> AggregatedObject? {
        var candidates = aggregatedObjects.filter { $0.rect.contains(point) }
        
        // nearest within a small radius
        let maxDistance: CGFloat = 40.0
        var nearest: AggregatedObject? = nil
        var bestDist = CGFloat.greatestFiniteMagnitude
        for agg in aggregatedObjects {
            let center = CGPoint(x: agg.rect.midX, y: agg.rect.midY)
            let d = hypot(center.x - point.x, center.y - point.y)
            if d < bestDist && d <= maxDistance {
                bestDist = d
                nearest = agg
            }
        }
        
        if let n = nearest { candidates = [n] }
        return candidates.first
    }

    func clear() {
        DispatchQueue.main.async {
            self.selectedLayer?.removeFromSuperlayer()
            self.selectedLayer = nil
            self.selectionTimer?.invalidate()
            self.selectionTimer = nil
        }
    }
}
