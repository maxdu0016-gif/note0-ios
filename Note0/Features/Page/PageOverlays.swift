import UIKit

/// Holds the text cards of a page. Laid out in page coordinates and scaled to
/// the zoom like the background; touches outside cards fall through to ink.
final class CardsLayerView: UIView {
    var onMove: ((UUID, CGPoint) -> Void)?
    var onDelete: ((UUID) -> Void)?
    private var cardViews: [UUID: CardView] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        layer.anchorPoint = .zero
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }

    func apply(pageSize: CGSize, zoom: CGFloat) {
        bounds = CGRect(origin: .zero, size: pageSize)
        layer.position = .zero
        transform = CGAffineTransform(scaleX: zoom, y: zoom)
        let scale = (window?.screen.scale ?? 2) * min(zoom, 4)
        for view in cardViews.values where abs(view.contentScaleFactor - scale) > 0.01 {
            view.contentScaleFactor = scale
            view.setNeedsDisplay()
        }
    }

    func setCards(_ cards: [CardContent]) {
        let ids = Set(cards.map(\.id))
        for (id, view) in cardViews where !ids.contains(id) {
            view.removeFromSuperview()
            cardViews[id] = nil
        }
        for card in cards {
            if let view = cardViews[card.id] {
                view.card = card
            } else {
                let view = CardView(card: card)
                view.onMove = { [weak self] id, origin in self?.onMove?(id, origin) }
                view.onDelete = { [weak self] id in self?.onDelete?(id) }
                addSubview(view)
                cardViews[card.id] = view
            }
        }
    }
}

/// One AI answer card. Drag to move; long-press for copy / delete.
final class CardView: UIView, UIContextMenuInteractionDelegate {
    var card: CardContent {
        didSet {
            frame = card.frame
            setNeedsDisplay()
        }
    }
    var onMove: ((UUID, CGPoint) -> Void)?
    var onDelete: ((UUID) -> Void)?
    private var dragStartOrigin: CGPoint = .zero

    init(card: CardContent) {
        self.card = card
        super.init(frame: card.frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:))))
        addInteraction(UIContextMenuInteraction(delegate: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        var local = card
        local.origin = .zero
        CardRenderer.draw(local, in: context)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let container = superview else { return }
        switch gesture.state {
        case .began:
            dragStartOrigin = card.origin
        case .changed:
            let delta = gesture.translation(in: container)
            frame.origin = CGPoint(x: dragStartOrigin.x + delta.x, y: dragStartOrigin.y + delta.y)
        case .ended:
            let delta = gesture.translation(in: container)
            let bounds = container.bounds
            var origin = CGPoint(x: dragStartOrigin.x + delta.x, y: dragStartOrigin.y + delta.y)
            origin.x = min(max(origin.x, -frame.width / 2), bounds.width - frame.width / 2)
            origin.y = min(max(origin.y, 0), bounds.height - 20)
            card.origin = origin
            onMove?(card.id, origin)
        case .cancelled, .failed:
            frame.origin = dragStartOrigin
        default:
            break
        }
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            let copy = UIAction(title: L("复制文字"), image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.string = self.card.text
            }
            let delete = UIAction(title: L("删除"), image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                self.onDelete?(self.card.id)
            }
            return UIMenu(children: [copy, delete])
        }
    }
}

/// Drag a rectangle over the page to pick what to ask the AI about.
final class RegionSelectionView: UIView {
    /// Called with the selected rectangle in this view's coordinates.
    var onSelect: ((CGRect) -> Void)?
    private var start: CGPoint?
    private let shape = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.systemIndigo.withAlphaComponent(0.04)
        shape.fillColor = UIColor.systemIndigo.withAlphaComponent(0.12).cgColor
        shape.strokeColor = UIColor.systemIndigo.cgColor
        shape.lineWidth = 2
        shape.lineDashPattern = [6, 4]
        layer.addSublayer(shape)
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:))))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let point = gesture.location(in: self)
        switch gesture.state {
        case .began:
            start = point
            update(to: point)
        case .changed:
            update(to: point)
        case .ended:
            if let start {
                let rect = Self.rect(from: start, to: point)
                shape.path = nil
                self.start = nil
                if rect.width >= 12, rect.height >= 12 { onSelect?(rect) }
            }
        default:
            shape.path = nil
            start = nil
        }
    }

    private func update(to point: CGPoint) {
        guard let start else { return }
        shape.path = UIBezierPath(roundedRect: Self.rect(from: start, to: point), cornerRadius: 4).cgPath
    }

    static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}
