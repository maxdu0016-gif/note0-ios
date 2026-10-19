import PDFKit
import PencilKit
import UIKit

/// Shared drawing code for the live page background, thumbnails and PDF
/// export, so all three always look the same.
/// All functions expect a UIKit-style context (origin top-left, y down).
enum PageRenderer {
    private static let lineColor = UIColor(red: 0.62, green: 0.71, blue: 0.82, alpha: 0.55).cgColor
    private static let dotColor = UIColor(red: 0.55, green: 0.6, blue: 0.68, alpha: 0.7).cgColor

    static func drawBackground(in context: CGContext, rect: CGRect, pageSize: CGSize, paper: PaperStyle, pdfPage: PDFPage?) {
        context.saveGState()
        context.setFillColor(UIColor.white.cgColor)
        context.fill(rect)
        if let pdfPage {
            drawPDFPage(pdfPage, in: context, rect: rect)
        } else {
            drawTemplate(paper, in: context, rect: rect, pageSize: pageSize)
        }
        context.restoreGState()
    }

    static func drawTemplate(_ paper: PaperStyle, in context: CGContext, rect: CGRect, pageSize: CGSize) {
        guard pageSize.width > 0 else { return }
        let scale = rect.width / pageSize.width
        func map(_ point: CGPoint) -> CGPoint {
            CGPoint(x: rect.minX + point.x * scale, y: rect.minY + point.y * scale)
        }

        let lines = PaperTemplate.lines(for: paper, pageSize: pageSize)
        if !lines.isEmpty {
            context.setStrokeColor(lineColor)
            context.setLineWidth(max(0.5, 0.75 * scale))
            for line in lines {
                context.move(to: map(line.start))
                context.addLine(to: map(line.end))
            }
            context.strokePath()
        }

        let dots = PaperTemplate.dots(for: paper, pageSize: pageSize)
        if !dots.isEmpty {
            context.setFillColor(dotColor)
            let radius = max(0.6, 1.0 * scale)
            for dot in dots {
                let center = map(dot)
                context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            }
        }
    }

    /// Draws a PDF page (honouring its /Rotate entry) stretched to `rect`.
    static func drawPDFPage(_ page: PDFPage, in context: CGContext, rect: CGRect) {
        guard let pageRef = page.pageRef else { return }
        let box = page.bounds(for: .mediaBox)
        let rotation = ((page.rotation % 360) + 360) % 360
        let displayed = PageGeometry.displaySize(mediaBox: box, rotation: rotation)
        guard displayed.width > 0, displayed.height > 0 else { return }

        context.saveGState()
        // Switch to PDF space: origin bottom-left, y up.
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.scaleBy(x: rect.width / displayed.width, y: rect.height / displayed.height)
        switch rotation {
        case 90:
            context.translateBy(x: 0, y: box.width)
            context.rotate(by: -.pi / 2)
        case 180:
            context.translateBy(x: box.width, y: box.height)
            context.rotate(by: .pi)
        case 270:
            context.translateBy(x: box.height, y: 0)
            context.rotate(by: .pi / 2)
        default:
            break
        }
        context.translateBy(x: -box.minX, y: -box.minY)
        context.clip(to: box)
        context.drawPDFPage(pageRef)
        context.restoreGState()
    }

    /// Renders ink in light appearance; PencilKit would otherwise invert dark
    /// ink when the system is in dark mode, but our paper is always white.
    static func inkImage(_ drawing: PKDrawing, pageSize: CGSize, scale: CGFloat) -> UIImage {
        var image = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = drawing.image(from: CGRect(origin: .zero, size: pageSize), scale: scale)
        }
        return image
    }

    /// Small PNG preview for the sidebar and bookshelf.
    static func thumbnailPNG(pageSize: CGSize, paper: PaperStyle, pdfPage: PDFPage?, drawing: PKDrawing, cards: [CardContent] = [], targetWidth: CGFloat = 240) -> Data? {
        guard pageSize.width > 0, pageSize.height > 0 else { return nil }
        let scale = targetWidth / pageSize.width
        let size = CGSize(width: targetWidth, height: pageSize.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { rendererContext in
            let rect = CGRect(origin: .zero, size: size)
            drawBackground(in: rendererContext.cgContext, rect: rect, pageSize: pageSize, paper: paper, pdfPage: pdfPage)
            if !drawing.strokes.isEmpty {
                inkImage(drawing, pageSize: pageSize, scale: scale).draw(in: rect)
            }
            for card in cards {
                CardRenderer.draw(card, in: rendererContext.cgContext, scale: scale)
            }
        }
        return image.pngData()
    }

    /// Everything inside `region` (page coordinates): background, ink and
    /// cards, as an image for the AI. The longest side is capped at `maxPixels`.
    static func regionImage(region: CGRect, pageSize: CGSize, paper: PaperStyle, pdfPage: PDFPage?, drawing: PKDrawing, cards: [CardContent], maxPixels: CGFloat = 1600) -> UIImage? {
        let clipped = region.intersection(CGRect(origin: .zero, size: pageSize))
        guard !clipped.isNull, clipped.width >= 4, clipped.height >= 4 else { return nil }
        let scale = min(3, maxPixels / max(clipped.width, clipped.height))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: (clipped.width * scale).rounded(), height: (clipped.height * scale).rounded())
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { rendererContext in
            let context = rendererContext.cgContext
            let pageRect = CGRect(x: -clipped.minX * scale, y: -clipped.minY * scale,
                                  width: pageSize.width * scale, height: pageSize.height * scale)
            drawBackground(in: context, rect: pageRect, pageSize: pageSize, paper: paper, pdfPage: pdfPage)
            if !drawing.strokes.isEmpty {
                inkImage(drawing, pageSize: pageSize, scale: scale).draw(in: pageRect)
            }
            for card in cards {
                CardRenderer.draw(card, in: context, scale: scale, offset: pageRect.origin)
            }
        }
    }
}
