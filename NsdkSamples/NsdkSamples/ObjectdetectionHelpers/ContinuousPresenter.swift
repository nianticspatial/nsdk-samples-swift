import UIKit

final class ContinuousPresenter: ObjectDetectionPresenter {
    
    
    private let overlayLayer: CALayer

    init(overlayLayer: CALayer) {
        self.overlayLayer = overlayLayer
    }

    func update(aggregatedObjects: [AggregatedObject]) {
        // Keep a map of existing layers by id
        var existing: [String: CALayer] = [:]
        if let subs = overlayLayer.sublayers {
            for layer in subs {
                if let name = layer.name {
                    existing[name] = layer
                }
            }
        }

        var keepLayerIDs: Set<String> = []
        for agg in aggregatedObjects {
            keepLayerIDs.insert(agg.id)
            if let layer = existing[agg.id] {
                layer.frame = agg.rect
                layer.borderColor = UIColor.red.cgColor
                layer.borderWidth = 2.0
                if let textLayer = layer.sublayers?.first(where: { $0.name == "text" }) as? CATextLayer {
                    textLayer.string = "\(agg.className) (\(Int(agg.confidence * 100))%)"
                    let padding: CGFloat = 2
                    let textHeight: CGFloat = 16
                    textLayer.frame = CGRect(x: 0, y: 0, width: layer.frame.width, height: textHeight).insetBy(dx: padding, dy: 0)
                    textLayer.contentsScale = UIScreen.main.scale
                }
            } else {
                let boxLayer = CALayer()
                boxLayer.name = agg.id
                boxLayer.borderColor = UIColor.red.cgColor
                boxLayer.borderWidth = 2.0
                boxLayer.frame = agg.rect

                let textLayer = CATextLayer()
                textLayer.name = "text"
                textLayer.string = "\(agg.className) (\(Int(agg.confidence * 100))%)"
                textLayer.fontSize = 12
                textLayer.foregroundColor = UIColor.white.cgColor
                textLayer.backgroundColor = UIColor.black.withAlphaComponent(0.6).cgColor
                textLayer.alignmentMode =  .center
                textLayer.contentsScale = UIScreen.main.scale
                let padding: CGFloat = 2
                let textHeight: CGFloat = 16
                textLayer.frame = CGRect(x: 0, y: 0, width: boxLayer.frame.width, height: textHeight).insetBy(dx: padding, dy: 0)
                boxLayer.addSublayer(textLayer)

                overlayLayer.addSublayer(boxLayer)
            }
        }

        // Remove layers that don't correspond to any aggregated object
        if let subs = overlayLayer.sublayers {
            for layer in subs {
                if let name = layer.name, !keepLayerIDs.contains(name) {
                    layer.removeFromSuperlayer()
                }
            }
        }

        overlayLayer.setNeedsDisplay()
        overlayLayer.displayIfNeeded()
    }
    
    func handleTouchBegan(at point: CGPoint) {
        // no-op for continuous presenter
    }

    func handleTouchEnded() {
        // no-op for continuous presenter
    }

    func clear() {
        overlayLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
    }
}
