import Combine
import PDFKit
import PencilKit
import UIKit

/// Everything the editor needs to show one page.
struct PageContent {
    let id: UUID
    let size: CGSize
    let paper: PaperStyle
    let pdfPage: PDFPage?
    let drawing: PKDrawing
    let cards: [CardContent]
}

/// A rectangle the user picked on a page, with a rendered image of it.
struct RegionSelection: Identifiable {
    let id = UUID()
    let pageID: UUID
    let rect: CGRect
    let image: UIImage
}

/// One reusable PencilKit canvas that shows a single fixed-size page.
/// Ink is always in page coordinates; zooming only changes the scroll view's
/// zoom scale, so strokes never move relative to the page.
final class PageEditorController: UIViewController, PKCanvasViewDelegate, UIGestureRecognizerDelegate, UIPencilInteractionDelegate {
    /// The live canvas. Replaced by a fresh one on every page change:
    /// swapping `drawing` on the same canvas (especially mid-swipe) could keep
    /// the previous page's ink on screen until the next relayout.
    private(set) var canvas = PKCanvasView()
    private var fingerDrawingEnabled = false
    /// The window's writing tools (compact toolbar or Apple's palette).
    private let tools: InkTools
    private var toolsObservation: AnyCancellable?
    private var showsSystemPalette = false
    private let pencilInteraction = UIPencilInteraction()

    // Shape recognition: where the pencil last moved, and when.
    private var lastMovePoint: CGPoint = .zero
    private var lastMoveTime = Date()
    private var strokeCountAtBegin = 0
    private var pendingShapeStrokeCount: Int?
    /// The stroke being drawn, in page coordinates (PencilKit doesn't expose it).
    private var livePoints: [CGPoint] = []
    private var holdTimer: Timer?
    /// Shape shown as a dashed preview while the pencil holds still.
    private var previewShape: RecognizedShape?
    /// The previewed shape for the stroke that just ended.
    private var previewShapeForStroke: RecognizedShape?
    private let previewLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.fillColor = nil
        layer.strokeColor = UIColor.systemBlue.withAlphaComponent(0.85).cgColor
        layer.lineWidth = 2
        layer.lineDashPattern = [6, 4]
        layer.lineJoin = .round
        layer.lineCap = .round
        return layer
    }()
    /// How long the pencil must stay still at the end of a stroke.
    static let shapeHoldDuration: TimeInterval = 0.45
    private var background: PageBackgroundView?
    private let cardsLayer = CardsLayerView(frame: .zero)
    private var selectionView: RegionSelectionView?

    private var content: PageContent?
    private var cards: [CardContent] = []
    private var pageSize: CGSize = PageGeometry.a4
    private var lastLayoutSize: CGSize = .zero
    private var lastFitWidth: CGFloat = 0

    private(set) var currentPageID: UUID?
    private var isLoadingPage = false
    private var hasUnsavedChanges = false
    private var pendingSave: DispatchWorkItem?

    /// Called with the latest drawing after a short pause, on page change,
    /// and whenever `flush()` is called.
    var onDrawingChanged: ((UUID, PKDrawing) -> Void)?
    var onCardMoved: ((UUID, UUID, CGPoint) -> Void)?
    var onCardDeleted: ((UUID, UUID) -> Void)?
    var onRegionSelected: ((RegionSelection) -> Void)?
    /// Finger page turn: +1 next page, -1 previous page.
    var onPageTurn: ((Int) -> Void)?

    private let swipeNext = UISwipeGestureRecognizer()
    private let swipePrevious = UISwipeGestureRecognizer()
    /// Set when a page turn was requested here, so the next `show` animates
    /// in that direction (and lands at the bottom when going back by scrolling).
    private var pendingTurn: (delta: Int, startAtBottom: Bool)?
    /// Picture of the old page that slides away during a page turn. The live
    /// canvas itself is never animated: a layer transition on PencilKit's
    /// canvas could leave the old ink on screen until the next relayout.
    private var turnSnapshot: UIView?
    /// How far past the top/bottom edge a drag must go to turn the page.
    static let overscrollToTurn: CGFloat = 70

    init(tools: InkTools) {
        self.tools = tools
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Saves pending ink and detaches from the shared tool picker.
    func detach() {
        flush()
        stopHoldTimer()
        toolsObservation = nil
        if showsSystemPalette {
            tools.picker.setVisible(false, forFirstResponder: canvas)
            tools.picker.removeObserver(canvas)
            showsSystemPalette = false
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .secondarySystemBackground

        canvas = makeCanvas()
        view.addSubview(canvas)
        pin(canvas)
        canvas.delegate = self
        canvas.addSubview(cardsLayer)

        cardsLayer.onMove = { [weak self] id, origin in
            guard let self, let pageID = self.currentPageID else { return }
            if let index = self.cards.firstIndex(where: { $0.id == id }) { self.cards[index].origin = origin }
            self.onCardMoved?(pageID, id, origin)
        }
        cardsLayer.onDelete = { [weak self] id in
            guard let self, let pageID = self.currentPageID else { return }
            self.cards.removeAll { $0.id == id }
            self.cardsLayer.setCards(self.cards)
            self.onCardDeleted?(pageID, id)
        }

        for (swipe, direction) in [(swipeNext, UISwipeGestureRecognizer.Direction.left), (swipePrevious, .right)] {
            swipe.direction = direction
            // Fingers only: an Apple Pencil stroke must never turn the page.
            swipe.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            swipe.delegate = self
            swipe.addTarget(self, action: #selector(handleSwipe(_:)))
            canvas.addGestureRecognizer(swipe)
        }

        // Apple Pencil double-tap / squeeze (follows iPad Settings → Apple Pencil).
        pencilInteraction.delegate = self
        view.addInteraction(pencilInteraction)

        toolsObservation = tools.objectWillChange.sink { [weak self] _ in
            // objectWillChange fires before the new value is stored.
            DispatchQueue.main.async { self?.applyTools() }
        }
        applyTools()
    }

    private func makeCanvas() -> PKCanvasView {
        let newCanvas = PKCanvasView()
        newCanvas.translatesAutoresizingMaskIntoConstraints = false
        newCanvas.backgroundColor = .clear
        newCanvas.isOpaque = false
        // Paper is always white, so ink must render in light appearance.
        newCanvas.overrideUserInterfaceStyle = .light
        newCanvas.drawingPolicy = fingerDrawingEnabled ? .anyInput : .pencilOnly
        newCanvas.contentInsetAdjustmentBehavior = .never
        newCanvas.alwaysBounceVertical = true
        newCanvas.alwaysBounceHorizontal = false
        // Watches the pencil so "draw a shape and hold" can be recognized.
        newCanvas.drawingGestureRecognizer.addTarget(self, action: #selector(trackDrawing(_:)))
        return newCanvas
    }

    private func pin(_ subview: UIView) {
        NSLayoutConstraint.activate([
            subview.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            subview.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            subview.topAnchor.constraint(equalTo: view.topAnchor),
            subview.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    /// Swaps in a brand-new canvas (empty, same size, same tool) before the
    /// next page is loaded into it. The old canvas and its rendering go away.
    private func replaceCanvas() {
        let old = canvas
        let fresh = makeCanvas()
        let wasFirstResponder = old.isFirstResponder

        view.insertSubview(fresh, aboveSubview: old)
        pin(fresh)
        for swipe in [swipeNext, swipePrevious] {
            old.removeGestureRecognizer(swipe)
            fresh.addGestureRecognizer(swipe)
        }
        cardsLayer.removeFromSuperview()
        fresh.addSubview(cardsLayer)

        if showsSystemPalette {
            tools.picker.removeObserver(old)
            tools.picker.addObserver(fresh)
            tools.picker.setVisible(true, forFirstResponder: fresh)
            fresh.tool = tools.picker.selectedTool
        } else {
            fresh.tool = tools.tool
            fresh.isRulerActive = tools.rulerActive
        }

        stopHoldTimer()
        hidePreview()
        old.delegate = nil
        old.removeFromSuperview()
        canvas = fresh
        fresh.delegate = self
        pendingShapeStrokeCount = nil
        view.layoutIfNeeded()
        if wasFirstResponder || view.window != nil { fresh.becomeFirstResponder() }
    }

    /// Puts the current tool on the canvas, or hands the canvas to Apple's palette.
    private func applyTools() {
        if tools.useSystemPalette {
            pencilInteraction.isEnabled = false
            guard !showsSystemPalette else { return }
            showsSystemPalette = true
            tools.picker.addObserver(canvas)
            tools.picker.setVisible(true, forFirstResponder: canvas)
            if view.window != nil, !canvas.isFirstResponder { canvas.becomeFirstResponder() }
        } else {
            if showsSystemPalette {
                tools.picker.setVisible(false, forFirstResponder: canvas)
                tools.picker.removeObserver(canvas)
                showsSystemPalette = false
            }
            canvas.tool = tools.tool
            canvas.isRulerActive = tools.rulerActive
            pencilInteraction.isEnabled = true
        }
    }

    // MARK: - Apple Pencil gestures

    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        tools.handlePencil(UIPencilInteraction.preferredTapAction)
    }

    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        tools.handlePencil(UIPencilInteraction.preferredTapAction)
    }

    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        guard squeeze.phase == .ended else { return }
        tools.handlePencil(UIPencilInteraction.preferredSqueezeAction)
    }

    // MARK: - Shape recognition

    @objc private func trackDrawing(_ gesture: UIGestureRecognizer) {
        let point = gesture.location(in: view)
        let zoom = max(canvas.zoomScale, 0.01)
        let inCanvas = gesture.location(in: canvas)
        let pagePoint = CGPoint(x: inCanvas.x / zoom, y: inCanvas.y / zoom)
        switch gesture.state {
        case .began:
            lastMovePoint = point
            lastMoveTime = Date()
            strokeCountAtBegin = canvas.drawing.strokes.count
            livePoints = [pagePoint]
            hidePreview()
            if tools.shapeRecognition, canvas.tool is PKInkingTool { startHoldTimer() }
        case .changed:
            if let last = livePoints.last, hypot(pagePoint.x - last.x, pagePoint.y - last.y) >= 1 {
                livePoints.append(pagePoint)
            }
            if hypot(point.x - lastMovePoint.x, point.y - lastMovePoint.y) > 3 {
                lastMovePoint = point
                lastMoveTime = Date()
                hidePreview() // moving again: no longer a finished shape
            }
        case .ended:
            stopHoldTimer()
            let held = Date().timeIntervalSince(lastMoveTime) >= Self.shapeHoldDuration
            let shown = previewShape
            hidePreview()
            guard held, tools.shapeRecognition, canvas.tool is PKInkingTool else { return }
            previewShapeForStroke = shown
            pendingShapeStrokeCount = strokeCountAtBegin + 1
            // The finished stroke reaches the drawing right after the gesture ends.
            DispatchQueue.main.async { [weak self] in self?.recognizeShapeIfPending() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.pendingShapeStrokeCount = nil }
        default:
            stopHoldTimer()
            hidePreview()
        }
    }

    /// While drawing, checks whether the pencil has been still long enough to
    /// show what the stroke will become.
    private func startHoldTimer() {
        stopHoldTimer()
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkHold() }
        }
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }

    private func stopHoldTimer() {
        holdTimer?.invalidate()
        holdTimer = nil
    }

    private func checkHold() {
        guard previewShape == nil,
              Date().timeIntervalSince(lastMoveTime) >= Self.shapeHoldDuration,
              let shape = ShapeRecognizer.recognize(livePoints) else { return }
        showPreview(shape)
    }

    private func showPreview(_ shape: RecognizedShape) {
        previewShape = shape
        let zoom = canvas.zoomScale
        let points = ShapeRecognizer.samples(for: shape, spacing: 4).map {
            canvas.convert(CGPoint(x: $0.x * zoom, y: $0.y * zoom), to: view)
        }
        guard let first = points.first else { return }
        let path = UIBezierPath()
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        previewLayer.path = path.cgPath
        view.layer.addSublayer(previewLayer) // on top of the canvas
        previewLayer.opacity = 1
    }

    private func hidePreview() {
        previewShape = nil
        previewLayer.path = nil
        previewLayer.removeFromSuperlayer()
    }

    private func recognizeShapeIfPending() {
        guard let expected = pendingShapeStrokeCount else { return }
        let strokes = canvas.drawing.strokes
        guard strokes.count == expected else {
            if strokes.count > expected { pendingShapeStrokeCount = nil }
            return
        }
        pendingShapeStrokeCount = nil
        let shown = previewShapeForStroke
        previewShapeForStroke = nil
        guard let last = strokes.last, let clean = ShapeRecognizer.cleanStroke(replacing: last, shape: shown) else { return }
        var drawing = canvas.drawing
        drawing.strokes[drawing.strokes.count - 1] = clean
        replaceDrawingUndoably(with: drawing)
    }

    private func replaceDrawingUndoably(with drawing: PKDrawing) {
        let previous = canvas.drawing
        canvas.undoManager?.registerUndo(withTarget: self) { controller in
            controller.replaceDrawingUndoably(with: previous)
        }
        canvas.drawing = drawing
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        canvas.becomeFirstResponder()
        Self.installAskAIMenuItem()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard canvas.bounds.size != lastLayoutSize else { return }
        let isFirstLayout = lastLayoutSize == .zero || lastFitWidth == 0
        lastLayoutSize = canvas.bounds.size
        if isFirstLayout {
            configureZoom(resetToFitWidth: true)
        } else {
            refitKeepingPosition()
        }
    }

    // MARK: - Page switching

    func show(_ content: PageContent) {
        flush()
        isLoadingPage = true
        defer { isLoadingPage = false }

        if currentPageID != nil { replaceCanvas() }
        self.content = content
        currentPageID = content.id
        pageSize = content.size

        background?.removeFromSuperview()
        let newBackground = PageBackgroundView(pageSize: content.size, paper: content.paper, pdfPage: content.pdfPage)
        canvas.insertSubview(newBackground, at: 0)
        background = newBackground

        cards = content.cards
        cardsLayer.setCards(cards)
        canvas.bringSubviewToFront(cardsLayer)

        canvas.drawing = content.drawing
        canvas.undoManager?.removeAllActions()

        configureZoom(resetToFitWidth: true)

        if let turn = pendingTurn {
            pendingTurn = nil
            if turn.startAtBottom {
                let bottom = max(-canvas.contentInset.top,
                                 canvas.contentSize.height + canvas.contentInset.bottom - canvas.bounds.height)
                canvas.contentOffset = CGPoint(x: canvas.contentOffset.x, y: bottom)
            }
            animateTurn(turn.delta)
        } else {
            turnSnapshot = nil
        }
    }

    /// Replaces the cards on the current page (e.g. after an AI answer).
    func setCards(_ newCards: [CardContent]) {
        cards = newCards
        cardsLayer.setCards(newCards)
        canvas.bringSubviewToFront(cardsLayer)
        cardsLayer.apply(pageSize: pageSize, zoom: canvas.zoomScale)
    }

    // MARK: - Commands

    func setFingerDrawing(_ enabled: Bool) {
        fingerDrawingEnabled = enabled
        canvas.drawingPolicy = enabled ? .anyInput : .pencilOnly
        // One finger writes when finger drawing is on, so swiping takes two.
        swipeNext.numberOfTouchesRequired = enabled ? 2 : 1
        swipePrevious.numberOfTouchesRequired = enabled ? 2 : 1
    }

    func undo() { canvas.undoManager?.undo() }
    func redo() { canvas.undoManager?.redo() }

    /// Hands the current drawing to the owner immediately if it changed.
    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        guard hasUnsavedChanges, let id = currentPageID else { return }
        hasUnsavedChanges = false
        onDrawingChanged?(id, canvas.drawing)
    }

    /// While active, dragging on the page selects a region for the AI
    /// instead of writing.
    func setRegionSelection(_ active: Bool) {
        if active, selectionView == nil {
            let overlay = RegionSelectionView(frame: view.bounds)
            overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            overlay.onSelect = { [weak self] rect in self?.finishSelection(rect, in: overlay) }
            view.addSubview(overlay)
            selectionView = overlay
        } else if !active {
            selectionView?.removeFromSuperview()
            selectionView = nil
        }
    }

    private func finishSelection(_ rect: CGRect, in overlay: UIView) {
        guard let content, let pageID = currentPageID else { return }
        let zoom = max(canvas.zoomScale, 0.01)
        let topLeft = canvas.convert(rect.origin, from: overlay)
        let pageRect = CGRect(x: topLeft.x / zoom, y: topLeft.y / zoom, width: rect.width / zoom, height: rect.height / zoom)
        guard let image = PageRenderer.regionImage(
            region: pageRect, pageSize: pageSize, paper: content.paper, pdfPage: content.pdfPage,
            drawing: canvas.drawing, cards: cards
        ) else { return }
        onRegionSelected?(RegionSelection(pageID: pageID, rect: pageRect.intersection(CGRect(origin: .zero, size: pageSize)), image: image))
    }

    // MARK: - Zoom & layout

    private func configureZoom(resetToFitWidth: Bool) {
        guard let range = PageGeometry.zoomRange(page: pageSize, viewport: canvas.bounds.size) else { return }
        lastFitWidth = range.fitWidth
        canvas.minimumZoomScale = range.fitPage
        canvas.maximumZoomScale = range.fitWidth * 4
        if resetToFitWidth {
            canvas.zoomScale = range.fitWidth
        }
        updateLayoutForZoom()
        if resetToFitWidth {
            // Start at the top of the page.
            canvas.contentOffset = CGPoint(x: -canvas.contentInset.left, y: -canvas.contentInset.top)
        }
    }

    /// The viewport changed size (rotation, split view divider): keep the same
    /// relative zoom and the same spot of the page in view.
    private func refitKeepingPosition() {
        guard lastFitWidth > 0, let range = PageGeometry.zoomRange(page: pageSize, viewport: canvas.bounds.size) else { return }
        let relativeZoom = canvas.zoomScale / lastFitWidth
        let contentHeight = max(canvas.contentSize.height, 1)
        let fractionY = (canvas.contentOffset.y + canvas.contentInset.top) / contentHeight

        lastFitWidth = range.fitWidth
        canvas.minimumZoomScale = range.fitPage
        canvas.maximumZoomScale = range.fitWidth * 4
        canvas.zoomScale = min(max(range.fitWidth * relativeZoom, range.fitPage), range.fitWidth * 4)
        updateLayoutForZoom()

        let maxY = max(-canvas.contentInset.top, canvas.contentSize.height + canvas.contentInset.bottom - canvas.bounds.height)
        let y = min(max(fractionY * canvas.contentSize.height - canvas.contentInset.top, -canvas.contentInset.top), maxY)
        let fitsHorizontally = canvas.contentSize.width <= canvas.bounds.width
        let x = fitsHorizontally ? -canvas.contentInset.left : canvas.contentOffset.x
        canvas.contentOffset = CGPoint(x: x, y: y)
    }

    private func updateLayoutForZoom() {
        let zoom = canvas.zoomScale
        let scaledSize = CGSize(width: pageSize.width * zoom, height: pageSize.height * zoom)
        canvas.contentSize = scaledSize
        background?.apply(zoom: zoom)
        cardsLayer.apply(pageSize: pageSize, zoom: zoom)

        // Center the page when it is smaller than the viewport.
        let horizontal = max(16, (canvas.bounds.width - scaledSize.width) / 2)
        let vertical = max(16, (canvas.bounds.height - scaledSize.height) / 2)
        canvas.contentInset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
    }

    // MARK: - Delegates

    // MARK: - Finger page turning

    @objc private func handleSwipe(_ gesture: UISwipeGestureRecognizer) {
        requestTurn(gesture === swipeNext ? 1 : -1, startAtBottom: false)
    }

    private func requestTurn(_ delta: Int, startAtBottom: Bool) {
        guard currentPageID != nil, selectionView == nil else { return }
        let fromPage = currentPageID
        turnSnapshot = view.snapshotView(afterScreenUpdates: false)
        pendingTurn = (delta, startAtBottom)
        onPageTurn?(delta)
        // If the page did not change (already on the first/last page), forget the request.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            if let self, self.currentPageID == fromPage {
                self.pendingTurn = nil
                self.turnSnapshot = nil
            }
        }
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === swipeNext || gestureRecognizer === swipePrevious else { return true }
        // When zoomed in, a sideways drag pans the page instead.
        return canvas.contentSize.width <= canvas.bounds.width + 1
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        gestureRecognizer === swipeNext || gestureRecognizer === swipePrevious
    }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        guard selectionView == nil else { return }
        let top = -canvas.contentInset.top
        let bottom = max(top, canvas.contentSize.height + canvas.contentInset.bottom - canvas.bounds.height)
        let y = canvas.contentOffset.y
        if y > bottom + Self.overscrollToTurn {
            targetContentOffset.pointee = scrollView.contentOffset
            requestTurn(1, startAtBottom: false)
        } else if y < top - Self.overscrollToTurn {
            targetContentOffset.pointee = scrollView.contentOffset
            requestTurn(-1, startAtBottom: true)
        }
    }

    /// The old page slides out over the new one. Only a static picture moves;
    /// the live canvas already shows the new page underneath.
    private func animateTurn(_ delta: Int) {
        guard let snapshot = turnSnapshot else { return }
        turnSnapshot = nil
        snapshot.frame = view.bounds
        view.addSubview(snapshot)
        let width = view.bounds.width
        UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseOut]) {
            snapshot.transform = CGAffineTransform(translationX: delta > 0 ? -width : width, y: 0)
            snapshot.alpha = 0.3
        } completion: { _ in
            snapshot.removeFromSuperview()
        }
    }

    // MARK: - Lasso → AI

    /// Adds "问 AI" to the menu PencilKit shows for a lasso selection.
    private static func installAskAIMenuItem() {
        let action = #selector(PageEditorController.askAIFromMenu(_:))
        let controller = UIMenuController.shared
        var items = controller.menuItems ?? []
        if !items.contains(where: { $0.action == action }) {
            items.append(UIMenuItem(title: L("问 AI"), action: action))
            controller.menuItems = items
        }
    }

    @objc func askAIFromMenu(_ sender: Any?) {
        askAIAboutLassoSelection()
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(askAIFromMenu(_:)) { return currentPageID != nil }
        return super.canPerformAction(action, withSender: sender)
    }

    /// Sends what the lasso has selected (with the page under it) to the AI.
    /// Returns false when nothing is selected. Copies the selection the same
    /// way the "拷贝" menu item does, reads it, then restores the clipboard.
    @discardableResult
    func askAIAboutLassoSelection() -> Bool {
        guard let content, let pageID = currentPageID else { return false }
        let pasteboard = UIPasteboard.general
        let savedItems = pasteboard.items
        let before = pasteboard.changeCount
        UIApplication.shared.sendAction(#selector(UIResponderStandardEditActions.copy(_:)), to: nil, from: self, for: nil)
        guard pasteboard.changeCount != before else { return false }
        let copied = Self.drawing(in: pasteboard)
        let copiedImage = pasteboard.image
        pasteboard.items = savedItems

        let page = CGRect(origin: .zero, size: pageSize)
        var region = visiblePageRect()
        if let copied, !copied.bounds.isEmpty, copied.bounds.intersects(page) {
            region = copied.bounds.insetBy(dx: -16, dy: -16).intersection(page)
        }
        let rendered = PageRenderer.regionImage(
            region: region, pageSize: pageSize, paper: content.paper, pdfPage: content.pdfPage,
            drawing: canvas.drawing, cards: cards
        )
        guard let image = rendered ?? copiedImage else { return false }
        onRegionSelected?(RegionSelection(pageID: pageID, rect: region, image: image))
        return true
    }

    /// The strokes PencilKit put on the clipboard, if any.
    private static func drawing(in pasteboard: UIPasteboard) -> PKDrawing? {
        for item in pasteboard.items {
            for (type, value) in item where type.lowercased().contains("drawing") {
                if let data = value as? Data, let drawing = try? PKDrawing(data: data) {
                    return drawing
                }
            }
        }
        return nil
    }

    /// Part of the page currently on screen, in page coordinates.
    private func visiblePageRect() -> CGRect {
        let zoom = max(canvas.zoomScale, 0.01)
        let visible = CGRect(
            x: canvas.contentOffset.x / zoom, y: canvas.contentOffset.y / zoom,
            width: canvas.bounds.width / zoom, height: canvas.bounds.height / zoom
        )
        let clipped = visible.intersection(CGRect(origin: .zero, size: pageSize))
        return clipped.isNull ? CGRect(origin: .zero, size: pageSize) : clipped
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        updateLayoutForZoom()
    }

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        // Tapping the other split pane or a toolbar can take first responder
        // away, which hides Apple's palette; writing here brings it back.
        if !canvas.isFirstResponder { canvas.becomeFirstResponder() }
        // The ruler is per canvas; keep it in sync with the toolbar.
        if !tools.useSystemPalette, canvas.isRulerActive != tools.rulerActive {
            canvas.isRulerActive = tools.rulerActive
        }
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !isLoadingPage, currentPageID != nil else { return }
        if pendingShapeStrokeCount != nil {
            DispatchQueue.main.async { [weak self] in self?.recognizeShapeIfPending() }
        }
        hasUnsavedChanges = true
        scheduleSave()
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }
}
