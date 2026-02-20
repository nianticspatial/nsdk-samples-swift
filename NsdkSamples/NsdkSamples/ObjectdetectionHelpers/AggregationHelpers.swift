import CoreGraphics

func area(_ r: CGRect) -> CGFloat {
    return r.width * r.height
}

func intersectionOverUnion(_ a: CGRect, _ b: CGRect) -> CGFloat {
    let inter = a.intersection(b)
    let interArea = area(inter)
    if interArea <= 0 { return 0 }
    let unionArea = area(a) + area(b) - interArea
    return unionArea > 0 ? interArea / unionArea : 0
}

/// Smooths rectangles to avoid unchecked growth: grow slowly (small scaleRate) and shrink faster (larger scaleRate).
func smoothedRect(old: CGRect, new: CGRect) -> CGRect {
    let oldArea = area(old)
    let newArea = area(new)

    // If either rect is zero-area, prefer the other
    if oldArea <= 0 { return new }
    if newArea <= 0 { return old }

    // When new area is larger (expansion), use smaller scaleRate to slow growth.
    // When new area is smaller (shrink), use larger scaleRate so we can shrink quicker and avoid creep.
    let scaleRate: CGFloat = newArea > oldArea ? 0.18 : 0.6

    let oldCenter = CGPoint(x: old.midX, y: old.midY)
    let newCenter = CGPoint(x: new.midX, y: new.midY)
    let center = CGPoint(x: oldCenter.x + (newCenter.x - oldCenter.x) * scaleRate,
                         y: oldCenter.y + (newCenter.y - oldCenter.y) * scaleRate)

    let width = old.width + (new.width - old.width) * scaleRate
    let height = old.height + (new.height - old.height) * scaleRate

    return CGRect(x: center.x - width / 2.0, y: center.y - height / 2.0, width: width, height: height)
}
