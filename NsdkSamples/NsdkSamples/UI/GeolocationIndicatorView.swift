// Copyright 2026 Niantic Spatial.

import UIKit

class GeolocationIndicatorView: UIView {
    var heading: CGFloat = 0 { didSet { setNeedsDisplay() } }
    var displaysHeading: Bool = false
    var color: UIColor = .blue

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }

        let center = CGPoint(x: rect.midX, y: rect.midY)

        // Draw dot
        ctx.setFillColor(color.cgColor)
        ctx.addEllipse(in: CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10))
        ctx.fillPath()

        // Draw triangle (vision cone)
        if displaysHeading {
            ctx.saveGState()
            ctx.translateBy(x: center.x, y: center.y)
            ctx.rotate(by: heading * .pi / 180)

            let path = UIBezierPath()
            path.move(to: .zero)
            path.addLine(to: CGPoint(x: -12, y: -30))
            path.addLine(to: CGPoint(x: 12, y: -30))
            path.close()

            ctx.setFillColor(color.withAlphaComponent(0.2).cgColor)

            ctx.addPath(path.cgPath)
            ctx.fillPath()
            ctx.restoreGState()
        }
    }
}
