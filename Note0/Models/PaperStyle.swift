import CoreGraphics

/// Paper template drawn behind the ink of a blank page.
enum PaperStyle: String, Codable, CaseIterable, Identifiable {
    case blank
    case ruled
    case grid
    case dotted

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blank: return L("空白")
        case .ruled: return L("横线")
        case .grid: return L("方格")
        case .dotted: return L("点阵")
        }
    }
}

/// Page sizes in PDF points, so exported pages keep their real-world size.
enum PageGeometry {
    static let a4 = CGSize(width: 595, height: 842)

    /// Size a PDF page is displayed at, after its /Rotate entry is applied.
    static func displaySize(mediaBox: CGRect, rotation: Int) -> CGSize {
        let normalized = ((rotation % 360) + 360) % 360
        if normalized == 90 || normalized == 270 {
            return CGSize(width: mediaBox.height, height: mediaBox.width)
        }
        return mediaBox.size
    }

    /// Zoom range for showing a page inside a viewport with a fixed margin.
    /// `fitWidth` is the default reading zoom; `fitPage` shows the whole page.
    static func zoomRange(page: CGSize, viewport: CGSize, margin: CGFloat = 16) -> (fitPage: CGFloat, fitWidth: CGFloat)? {
        guard page.width > 0, page.height > 0 else { return nil }
        let usableWidth = viewport.width - margin * 2
        let usableHeight = viewport.height - margin * 2
        guard usableWidth > 0, usableHeight > 0 else { return nil }
        let fitWidth = usableWidth / page.width
        let fitPage = min(fitWidth, usableHeight / page.height)
        return (fitPage, fitWidth)
    }
}

struct LineSegment: Equatable {
    let start: CGPoint
    let end: CGPoint
}

/// Template geometry in page coordinates (PDF points).
enum PaperTemplate {
    static let ruledSpacing: CGFloat = 24
    static let ruledTopMargin: CGFloat = 72
    static let ruledBottomMargin: CGFloat = 36
    static let gridSpacing: CGFloat = 20

    static func lines(for style: PaperStyle, pageSize: CGSize) -> [LineSegment] {
        switch style {
        case .blank, .dotted:
            return []
        case .ruled:
            var result: [LineSegment] = []
            var y = ruledTopMargin
            while y <= pageSize.height - ruledBottomMargin {
                result.append(LineSegment(start: CGPoint(x: 0, y: y), end: CGPoint(x: pageSize.width, y: y)))
                y += ruledSpacing
            }
            return result
        case .grid:
            var result: [LineSegment] = []
            for x in stride(from: gridSpacing, to: pageSize.width, by: gridSpacing) {
                result.append(LineSegment(start: CGPoint(x: x, y: 0), end: CGPoint(x: x, y: pageSize.height)))
            }
            for y in stride(from: gridSpacing, to: pageSize.height, by: gridSpacing) {
                result.append(LineSegment(start: CGPoint(x: 0, y: y), end: CGPoint(x: pageSize.width, y: y)))
            }
            return result
        }
    }

    static func dots(for style: PaperStyle, pageSize: CGSize) -> [CGPoint] {
        guard style == .dotted else { return [] }
        var result: [CGPoint] = []
        for x in stride(from: gridSpacing, to: pageSize.width, by: gridSpacing) {
            for y in stride(from: gridSpacing, to: pageSize.height, by: gridSpacing) {
                result.append(CGPoint(x: x, y: y))
            }
        }
        return result
    }
}
