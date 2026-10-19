import PDFKit
import UIKit

/// Paper or PDF page shown under the ink. It is laid out at the page's
/// natural size and scaled with a transform; the tiled layer re-renders sharp
/// tiles at each zoom level instead of stretching one big bitmap.
final class PageBackgroundView: UIView {
    override class var layerClass: AnyClass { CATiledLayer.self }

    private let pageSize: CGSize
    private let paper: PaperStyle
    private let pdfPage: PDFPage?

    init(pageSize: CGSize, paper: PaperStyle, pdfPage: PDFPage?) {
        self.pageSize = pageSize
        self.paper = paper
        self.pdfPage = pdfPage
        super.init(frame: CGRect(origin: .zero, size: pageSize))
        backgroundColor = .white
        isUserInteractionEnabled = false
        layer.anchorPoint = .zero
        layer.position = .zero
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.12
        layer.shadowRadius = 6
        layer.shadowOffset = CGSize(width: 0, height: 2)
        layer.shadowPath = UIBezierPath(rect: CGRect(origin: .zero, size: pageSize)).cgPath
        if let tiled = layer as? CATiledLayer {
            tiled.levelsOfDetail = 4
            tiled.levelsOfDetailBias = 3
            tiled.tileSize = CGSize(width: 512, height: 512)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Keeps the view's bounds in page coordinates and scales it to the zoom.
    func apply(zoom: CGFloat) {
        bounds = CGRect(origin: .zero, size: pageSize)
        layer.position = .zero
        transform = CGAffineTransform(scaleX: zoom, y: zoom)
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        PageRenderer.drawBackground(in: context, rect: bounds, pageSize: pageSize, paper: paper, pdfPage: pdfPage)
    }
}
