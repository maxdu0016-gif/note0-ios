import UIKit

/// Draws text cards (AI answers) the same way on screen, in thumbnails and in
/// exported PDFs. Card geometry is in page coordinates (PDF points).
enum CardRenderer {
    static let padding: CGFloat = 10
    static let cornerRadius: CGFloat = 8
    static let fontSize: CGFloat = 11

    private static let fill = UIColor(red: 1.0, green: 0.97, blue: 0.86, alpha: 0.96)
    private static let border = UIColor(red: 0.93, green: 0.78, blue: 0.38, alpha: 1)
    private static let badge = UIColor(red: 0.78, green: 0.55, blue: 0.1, alpha: 1)

    /// Inline Markdown (bold, italics, code) is kept; block syntax stays as text.
    static func attributedText(_ text: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        let base: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: fontSize),
            .foregroundColor: UIColor(white: 0.12, alpha: 1),
            .paragraphStyle: paragraph,
        ]
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let parsed = try? AttributedString(markdown: text, options: options) else {
            return NSAttributedString(string: text, attributes: base)
        }
        let result = NSMutableAttributedString(attributedString: NSAttributedString(parsed))
        let fullRange = NSRange(location: 0, length: result.length)
        result.addAttributes([.foregroundColor: base[.foregroundColor]!, .paragraphStyle: paragraph], range: fullRange)
        result.enumerateAttribute(.font, in: fullRange) { value, range, _ in
            if value == nil { result.addAttribute(.font, value: base[.font]!, range: range) }
        }
        // Markdown-parsed runs carry presentation intents instead of fonts.
        result.enumerateAttribute(NSAttributedString.Key("NSInlinePresentationIntent"), in: fullRange) { value, range, _ in
            guard let raw = value as? Int else { return }
            let intent = InlinePresentationIntent(rawValue: UInt(raw))
            var traits: UIFontDescriptor.SymbolicTraits = []
            if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
            if intent.contains(.emphasized) { traits.insert(.traitItalic) }
            if intent.contains(.code) { traits.insert(.traitMonoSpace) }
            let descriptor = UIFont.systemFont(ofSize: fontSize).fontDescriptor.withSymbolicTraits(traits)
            if let descriptor {
                result.addAttribute(.font, value: UIFont(descriptor: descriptor, size: fontSize), range: range)
            }
        }
        return result
    }

    static func height(for text: String, width: CGFloat) -> CGFloat {
        let textWidth = max(10, width - padding * 2)
        let bounds = attributedText(text).boundingRect(
            with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        return ceil(bounds.height) + padding * 2 + 14
    }

    /// Draws `card` into a UIKit-style context whose units are page points
    /// scaled by `scale` and offset by `origin`.
    static func draw(_ card: CardContent, in context: CGContext, scale: CGFloat = 1, offset: CGPoint = .zero) {
        let frame = card.frame
        let rect = CGRect(
            x: offset.x + frame.minX * scale,
            y: offset.y + frame.minY * scale,
            width: frame.width * scale,
            height: frame.height * scale
        )
        context.saveGState()
        let path = UIBezierPath(roundedRect: rect, cornerRadius: cornerRadius * scale)
        context.setFillColor(fill.cgColor)
        context.addPath(path.cgPath)
        context.fillPath()
        context.setStrokeColor(border.cgColor)
        context.setLineWidth(max(0.5, scale))
        context.addPath(path.cgPath)
        context.strokePath()

        UIGraphicsPushContext(context)
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: scale, y: scale)
        let label = NSAttributedString(string: "✦ AI", attributes: [
            .font: UIFont.systemFont(ofSize: 8, weight: .semibold),
            .foregroundColor: badge,
        ])
        label.draw(at: CGPoint(x: padding, y: padding - 3))
        attributedText(card.text).draw(
            with: CGRect(x: padding, y: padding + 11, width: frame.width - padding * 2, height: frame.height),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        UIGraphicsPopContext()
        context.restoreGState()
    }
}
