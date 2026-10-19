import CoreGraphics
import Foundation
import PencilKit

/// A clean shape recognized from a hand-drawn stroke.
enum RecognizedShape: Equatable {
    case line(CGPoint, CGPoint)
    /// Open zig-zag (e.g. an angle or a "V"): straightened corners.
    case polyline([CGPoint])
    /// Closed polygon (triangle, rectangle, quadrilateral…), corners in order.
    case polygon([CGPoint])
    case ellipse(center: CGPoint, radiusX: CGFloat, radiusY: CGFloat, angle: CGFloat)
    /// A straight arrow from `from` to `to` with a two-sided head.
    case arrow(from: CGPoint, to: CGPoint, headLength: CGFloat)

    var name: String {
        switch self {
        case .line: L("直线")
        case .polyline: L("折线")
        case .polygon(let corners):
            switch corners.count {
            case 3: L("三角形")
            case 4: L("四边形")
            case 5: L("五边形")
            case 6: L("六边形")
            default: L("多边形")
            }
        case .ellipse(_, let rx, let ry, _): abs(rx - ry) < 0.5 ? L("圆") : L("椭圆")
        case .arrow: L("箭头")
        }
    }
}

/// "Draw a shape and hold" recognition, like GoodNotes / Apple Notes.
/// Pure geometry so it can be unit tested.
enum ShapeRecognizer {
    static func recognize(_ raw: [CGPoint]) -> RecognizedShape? {
        let points = thinned(raw, minDistance: 1.5)
        guard points.count >= 3, let first = points.first, let last = points.last else { return nil }
        let bounds = boundingBox(points)
        let size = max(bounds.width, bounds.height)
        guard size >= 14 else { return nil }
        let length = pathLength(points)

        // Straight line: everything close to the segment between the ends.
        let chord = distance(first, last)
        if chord > 0.6 * length {
            let deviation = points.map { distanceToSegment($0, first, last) }.max() ?? 0
            if deviation < max(4, 0.07 * chord) {
                return .line(first, last)
            }
        }

        let gap = distance(first, last)
        let closed = gap < max(16, 0.22 * size) && length > 2.4 * size
        let epsilon = max(4, 0.05 * length)

        if closed {
            // Polygon (3–6 corners) and ellipse are both tried; a polygon only
            // wins when its sharp corners fit clearly better than a round shape.
            var polygon: (corners: [CGPoint], error: CGFloat)?
            var corners = closedCorners(points, epsilon: max(3, 0.035 * length))
            corners = removeFlatCorners(corners, closed: true, minTurn: 0.45)
            if (3...6).contains(corners.count) {
                if corners.count == 4 { corners = squaredIfRectangle(corners) }
                let error = meanDistance(points, toPolygon: corners, closed: true) / size
                if error < 0.045 { polygon = (corners, error) }
            }
            let ellipse = fitEllipse(points, size: size)
            switch (polygon, ellipse) {
            case let (polygon?, ellipse?):
                return polygon.error < ellipse.error * 0.6 ? .polygon(polygon.corners) : ellipse.shape
            case let (polygon?, nil):
                return .polygon(polygon.corners)
            case let (nil, ellipse?):
                return ellipse.shape
            case (nil, nil):
                return nil
            }
        }

        // Open shape with a few straight segments.
        var corners = rdp(points, epsilon: epsilon)
        corners = removeFlatCorners(corners, closed: false, minTurn: 0.45)

        // Arrow: a long shaft, then a short head drawn back near the tip.
        if corners.count >= 3 {
            let shaft = distance(corners[0], corners[1])
            let tip = corners[1]
            let head = corners.dropFirst(2)
            if shaft > 0.55 * length,
               head.allSatisfy({ distance($0, tip) < 0.4 * shaft }),
               turn(at: corners[1], from: corners[0], to: corners[2]) > 1.9 {
                let headLength = head.map { distance($0, tip) }.max() ?? shaft * 0.2
                return .arrow(from: corners[0], to: tip, headLength: min(max(headLength, 10), shaft * 0.35))
            }
        }
        if corners.count >= 3 && corners.count <= 4 {
            let error = meanDistance(points, toPolygon: corners, closed: false)
            if error < 0.025 * size { return .polyline(corners) }
        }
        return nil
    }

    /// Dense points along the shape, ready to become a stroke path.
    static func samples(for shape: RecognizedShape, spacing: CGFloat = 2.5) -> [CGPoint] {
        switch shape {
        case .line(let a, let b):
            return densify([a, b], spacing: spacing)
        case .polyline(let corners):
            return densify(corners, spacing: spacing)
        case .polygon(let corners):
            return densify(corners + [corners[0]], spacing: spacing)
        case .arrow(let from, let to, let headLength):
            let angle = atan2(to.y - from.y, to.x - from.x)
            let spread: CGFloat = 0.5 // ~28° each side
            let left = CGPoint(x: to.x - headLength * cos(angle - spread), y: to.y - headLength * sin(angle - spread))
            let right = CGPoint(x: to.x - headLength * cos(angle + spread), y: to.y - headLength * sin(angle + spread))
            return densify([from, to, left, to, right], spacing: spacing)
        case .ellipse(let center, let rx, let ry, let angle):
            let circumference = 2 * CGFloat.pi * sqrt((rx * rx + ry * ry) / 2)
            let count = max(48, Int(circumference / spacing))
            return (0...count).map { i in
                let t = CGFloat(i) / CGFloat(count) * 2 * .pi
                let x = rx * cos(t), y = ry * sin(t)
                return CGPoint(x: center.x + x * cos(angle) - y * sin(angle),
                               y: center.y + x * sin(angle) + y * cos(angle))
            }
        }
    }

    /// The clean stroke that replaces a hand-drawn one: same ink, thickness
    /// and position, new path.
    /// `shape` is the one already shown as a preview, if any, so the result
    /// matches what the student saw.
    static func cleanStroke(replacing stroke: PKStroke, shape known: RecognizedShape? = nil) -> PKStroke? {
        let path = stroke.path
        guard path.count >= 3 else { return nil }
        let usable = known.flatMap { stroke.transform == .identity ? $0 : nil }
        guard let shape = usable ?? recognize(path.map(\.location)) else { return nil }

        let reference = path[path.count / 2]
        var time: TimeInterval = 0
        let points = samples(for: shape).map { location -> PKStrokePoint in
            time += 0.004
            return PKStrokePoint(
                location: location, timeOffset: time, size: reference.size, opacity: reference.opacity,
                force: reference.force, azimuth: reference.azimuth, altitude: reference.altitude
            )
        }
        let newPath = PKStrokePath(controlPoints: points, creationDate: path.creationDate)
        return PKStroke(ink: stroke.ink, path: newPath, transform: stroke.transform, mask: stroke.mask)
    }

    // MARK: - Geometry helpers

    static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    static func distanceToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return distance(p, a) }
        let t = min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared, 0), 1)
        return distance(p, CGPoint(x: a.x + t * dx, y: a.y + t * dy))
    }

    private static func thinned(_ points: [CGPoint], minDistance: CGFloat) -> [CGPoint] {
        var result: [CGPoint] = []
        for point in points where result.last.map({ distance($0, point) >= minDistance }) ?? true {
            result.append(point)
        }
        if let last = points.last, result.last != last { result.append(last) }
        return result
    }

    private static func boundingBox(_ points: [CGPoint]) -> CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    private static func pathLength(_ points: [CGPoint]) -> CGFloat {
        zip(points, points.dropFirst()).reduce(0) { $0 + distance($1.0, $1.1) }
    }

    /// Ramer–Douglas–Peucker simplification (keeps both ends).
    static func rdp(_ points: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
        guard points.count > 2, let first = points.first, let last = points.last else { return points }
        var maxDistance: CGFloat = 0
        var index = 0
        for i in 1..<(points.count - 1) {
            let d = distanceToSegment(points[i], first, last)
            if d > maxDistance { maxDistance = d; index = i }
        }
        guard maxDistance > epsilon else { return [first, last] }
        let left = rdp(Array(points[...index]), epsilon: epsilon)
        let right = rdp(Array(points[index...]), epsilon: epsilon)
        return Array(left.dropLast()) + right
    }

    /// Corners of a closed path: split at the point farthest from the start,
    /// simplify both halves.
    private static func closedCorners(_ points: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
        let start = points[0]
        let far = points.indices.max { distance(points[$0], start) < distance(points[$1], start) } ?? 0
        guard far > 0 else { return [] }
        let first = rdp(Array(points[...far]), epsilon: epsilon)
        let second = rdp(Array(points[far...]) + [start], epsilon: epsilon)
        return Array((first.dropLast() + second).dropLast())
    }

    /// Removes points where the path barely turns (and duplicates).
    private static func removeFlatCorners(_ corners: [CGPoint], closed: Bool, minTurn: CGFloat) -> [CGPoint] {
        var result = corners
        var changed = true
        while changed && result.count > (closed ? 3 : 2) {
            changed = false
            let range = closed ? Array(result.indices) : Array(result.indices.dropFirst().dropLast())
            for i in range {
                let prev = result[(i - 1 + result.count) % result.count]
                let next = result[(i + 1) % result.count]
                let p = result[i]
                let a1 = atan2(p.y - prev.y, p.x - prev.x)
                let a2 = atan2(next.y - p.y, next.x - p.x)
                var turn = abs(a2 - a1)
                if turn > .pi { turn = 2 * .pi - turn }
                if turn < minTurn || distance(p, prev) < 1 {
                    result.remove(at: i)
                    changed = true
                    break
                }
            }
        }
        return result
    }

    /// A four-cornered shape whose sides are close to horizontal/vertical
    /// becomes an exact upright rectangle.
    private static func squaredIfRectangle(_ corners: [CGPoint]) -> [CGPoint] {
        let tolerance: CGFloat = 0.21 // ~12°
        for i in 0..<4 {
            let a = corners[i], b = corners[(i + 1) % 4]
            var angle = abs(atan2(b.y - a.y, b.x - a.x)).truncatingRemainder(dividingBy: .pi / 2)
            angle = min(angle, .pi / 2 - angle)
            if angle > tolerance { return corners }
        }
        let box = boundingBox(corners)
        return [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)]
    }

    private static func meanDistance(_ points: [CGPoint], toPolygon corners: [CGPoint], closed: Bool) -> CGFloat {
        let edges = closed ? Array(zip(corners, corners.dropFirst() + [corners[0]])) : Array(zip(corners, corners.dropFirst()))
        guard !edges.isEmpty else { return .infinity }
        let total = points.reduce(CGFloat(0)) { sum, p in
            sum + (edges.map { distanceToSegment(p, $0.0, $0.1) }.min() ?? 0)
        }
        return total / CGFloat(points.count)
    }

    /// Ellipse from the points' principal axes; nil if the drawing isn't round enough.
    /// How sharply a path turns at `point` (0 = straight on, π = straight back).
    private static func turn(at point: CGPoint, from previous: CGPoint, to next: CGPoint) -> CGFloat {
        let a1 = atan2(point.y - previous.y, point.x - previous.x)
        let a2 = atan2(next.y - point.y, next.x - point.x)
        var value = abs(a2 - a1)
        if value > .pi { value = 2 * .pi - value }
        return value
    }

    /// Ellipse plus its fit error (mean distance from the drawing, relative to `size`).
    private static func fitEllipse(_ points: [CGPoint], size: CGFloat) -> (shape: RecognizedShape, error: CGFloat)? {
        let n = CGFloat(points.count)
        let cx = points.reduce(0) { $0 + $1.x } / n
        let cy = points.reduce(0) { $0 + $1.y } / n
        var sxx: CGFloat = 0, syy: CGFloat = 0, sxy: CGFloat = 0
        for p in points {
            let dx = p.x - cx, dy = p.y - cy
            sxx += dx * dx; syy += dy * dy; sxy += dx * dy
        }
        var angle = 0.5 * atan2(2 * sxy, sxx - syy)
        // Snap nearly upright ellipses to upright.
        if abs(angle) < 0.17 { angle = 0 }
        if abs(abs(angle) - .pi / 2) < 0.17 { angle = .pi / 2 }

        var maxU: CGFloat = 0, minU: CGFloat = 0, maxV: CGFloat = 0, minV: CGFloat = 0
        for p in points {
            let dx = p.x - cx, dy = p.y - cy
            let u = dx * cos(angle) + dy * sin(angle)
            let v = -dx * sin(angle) + dy * cos(angle)
            maxU = max(maxU, u); minU = min(minU, u); maxV = max(maxV, v); minV = min(minV, v)
        }
        var rx = (maxU - minU) / 2, ry = (maxV - minV) / 2
        guard rx > 4, ry > 4 else { return nil }
        let center = CGPoint(x: cx + ((maxU + minU) / 2) * cos(angle) - ((maxV + minV) / 2) * sin(angle),
                             y: cy + ((maxU + minU) / 2) * sin(angle) + ((maxV + minV) / 2) * cos(angle))

        // How far each point is from the ellipse, relative to its size.
        var error: CGFloat = 0
        for p in points {
            let dx = p.x - center.x, dy = p.y - center.y
            let u = dx * cos(angle) + dy * sin(angle)
            let v = -dx * sin(angle) + dy * cos(angle)
            error += abs(sqrt((u * u) / (rx * rx) + (v * v) / (ry * ry)) - 1)
        }
        guard error / n < 0.13 else { return nil }
        let relativeError = (error / n) * ((rx + ry) / 2) / size

        if min(rx, ry) / max(rx, ry) > 0.85 {
            let r = (rx + ry) / 2
            rx = r; ry = r
            angle = 0
        }
        return (.ellipse(center: center, radiusX: rx, radiusY: ry, angle: angle), relativeError)
    }

    private static func densify(_ corners: [CGPoint], spacing: CGFloat) -> [CGPoint] {
        guard let first = corners.first else { return [] }
        var result = [first]
        for (a, b) in zip(corners, corners.dropFirst()) {
            let steps = max(1, Int(distance(a, b) / spacing))
            for i in 1...steps {
                let t = CGFloat(i) / CGFloat(steps)
                result.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
            // Repeat the corner so the spline keeps it sharp.
            result.append(b)
        }
        return result
    }
}
