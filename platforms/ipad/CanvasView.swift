import MetalKit
import UIKit
import QuartzCore

/// MTKView input surface for Apple Pencil. UIKit owns gesture recognition and
/// event prediction; DTEngineBridge owns the thread-safe document samples.
final class CanvasView: MTKView, UIPencilInteractionDelegate, UIGestureRecognizerDelegate {
    let engineBridge = DTEngineBridge()

    /// Called periodically on the main thread with a human-readable state
    /// string suitable for the diagnostics overlay.
    var onDiagnostics: ((String) -> Void)?

    /// Called when the first point of a new stroke is received. The controller
    /// uses this to dismiss the empty-canvas hint without coupling the UI to
    /// the C++ document model.
    var onDrawingBegan: (() -> Void)?

    /// Called once when a document mutation is committed (stroke lift-off),
    /// cancelled, or otherwise finalized. This intentionally is not called
    /// for every Pencil sample so autosave remains inexpensive.
    var onDocumentChanged: (() -> Void)?

    /// Called when a Pencil gesture changes the active drawing tool.
    /// The controller can use this to refresh its tool rail and persist the
    /// preference without polling the bridge.
    var onToolChanged: (() -> Void)?

    /// Sibling overlay view for rendering hover previews, snapping, and selection bounds
    /// without touching CAMetalLayer.
    weak var hoverOverlay: HoverOverlayView?

    /// Called on Apple Pencil Pro Squeeze gesture.
    var onSqueeze: (() -> Void)?

    /// Called when selection changes: (selectedStrokeIndices, boundingBoxInDocSpace).
    var onSelectionChanged: (([Int], CGRect?) -> Void)?

    /// Angle snapping (15-degree increments) for shapes and lines.
    var angleSnapEnabled: Bool = false

    /// Pixel grid toggle for zoomed-in editing.
    var pixelGridVisible: Bool = false {
        didSet {
            guard oldValue != pixelGridVisible else { return }
            updateGridRenderer()
            setNeedsDisplay()
        }
    }

    /// Brush preview cursor toggle.
    var brushPreviewEnabled: Bool = true {
        didSet {
            if !brushPreviewEnabled {
                hoverOverlay?.hideHover()
            }
        }
    }

    /// Whether the renderer should draw a drafting grid. This state is kept
    /// here so callers can choose whether/how to persist it in their own
    /// settings model.
    var gridVisible: Bool = false {
        didSet {
            guard oldValue != gridVisible else { return }
            updateGridRenderer()
            setNeedsDisplay()
        }
    }

    /// Minimum normalized Apple Pencil force needed to put the pen down. A
    /// small amount of hysteresis is used on lift-off so force estimates that
    /// wobble around the threshold do not fragment a stroke.
    var activationPressure: CGFloat {
        get { activationPressureValue }
        set { activationPressureValue = min(max(newValue, 0), 0.20) }
    }

    /// Motion prediction (mirrors the original app's status-bar toggle).
    /// When off, predicted samples are excluded so the stroke only contains
    /// coalesced real touches, at the cost of a little extra latency.
    var predictionEnabled: Bool = true

    /// Grid snapping for shape tools (mirrors the original's snap toggle).
    /// When on and the grid is visible, shape-tool samples round to grid
    /// intersections. Brush strokes never snap.
    var snapToGrid: Bool = false
    var gridSpacing: CGFloat = 32

    private var uiTool: DTTool = .brush
    var currentTool: DTTool {
        get { uiTool }
        set {
            uiTool = newValue
            if newValue.rawValue <= DTTool.shade.rawValue {
                engineBridge.tool = newValue
            }
            if newValue != .select && newValue != .lasso {
                clearSelection()
            }
            HapticFeedbackService.shared.toolSwitched()
            onToolChanged?()
            setNeedsDisplay()
        }
    }

    // Selection & Transform tracking
    var selectedStrokeIndices: [Int] = []
    var selectedBoundingBox: CGRect?
    private var isSelecting = false
    private var isMovingSelection = false
    private var selectionDragStartDocPoint: CGPoint = .zero
    private var selectionStartViewPoint: CGPoint = .zero
    private var shapeStartDocPoint: CGPoint?
    private var lastSnappedAngleIndex: Int = -1

    /// Document-to-view viewport transform. Translation is in view points;
    /// scale and rotation are applied around the document origin.
    private(set) var canvasScale: CGFloat = 1.0
    private(set) var canvasRotation: CGFloat = 0.0
    private(set) var canvasTranslation: CGPoint = .zero

    private var activeTouch: UITouch?
    private var activationPressureValue: CGFloat = 0.03
    private var strokeEngaged = false
    private var renderer: DTMetalRenderer?
    private var displayLink: CADisplayLink?
    private var lastDiagnosticTime = CACurrentMediaTime()
    private var lastDiagnosticFrame: UInt = 0
    private var nextSampleID: UInt64 = 1
    private var lastPencilAction = "none"
    private var squeezeToggleConsumed = false
    private var hoverActive = false
    private var hoverPoint: CGPoint = .zero

    private lazy var hoverGesture: UIHoverGestureRecognizer = {
        let gesture = UIHoverGestureRecognizer(target: self, action: #selector(handlePencilHover(_:)))
        gesture.delegate = self
        return gesture
    }()

    private lazy var panGesture: UIPanGestureRecognizer = {
        let gesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        gesture.minimumNumberOfTouches = 2
        gesture.maximumNumberOfTouches = 2
        gesture.delegate = self
        gesture.cancelsTouchesInView = false
        return gesture
    }()
    private lazy var pinchGesture: UIPinchGestureRecognizer = {
        let gesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        gesture.delegate = self
        gesture.cancelsTouchesInView = false
        return gesture
    }()
    private lazy var rotationGesture: UIRotationGestureRecognizer = {
        let gesture = UIRotationGestureRecognizer(target: self, action: #selector(handleRotation(_:)))
        gesture.delegate = self
        gesture.cancelsTouchesInView = false
        return gesture
    }()

    private static let scaleDefaultsKey = "draftingTable.canvasScale"
    private static let rotationDefaultsKey = "draftingTable.canvasRotation"
    private static let translationXDefaultsKey = "draftingTable.canvasTranslationX"
    private static let translationYDefaultsKey = "draftingTable.canvasTranslationY"

    override init(frame frameRect: CGRect, device: MTLDevice?) {
        let selectedDevice = device ?? MTLCreateSystemDefaultDevice()
        super.init(frame: frameRect, device: selectedDevice)
        configure()
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        device = MTLCreateSystemDefaultDevice()
        configure()
    }

    private func configure() {
        DTLaunchBreadcrumb("canvas:configure:start")
        colorPixelFormat = .bgra8Unorm
        // Keep the canvas useful even when no Metal pipeline is available. A
        // light, warm paper tone also makes the first blank state obvious.
        clearColor = MTLClearColor(red: 0.965, green: 0.935, blue: 0.865, alpha: 1.0)
        framebufferOnly = true
        isMultipleTouchEnabled = true
        isOpaque = true
        // v0.7.2: on-demand rendering. Continuous 120fps full-document
        // re-rasterization (snapshot + NSValue boxing + Catmull-Rom + one
        // MTLBuffer per stroke) ran every frame even while idle. On a
        // physical iPad that stalls first-frame commit and trips the launch
        // watchdog (beige launch screen, then exit). Now a frame is only
        // produced after real input, transform, or settings changes.
        enableSetNeedsDisplay = true
        isPaused = true
        preferredFramesPerSecond = 60
        presentsWithTransaction = false
        renderer = DTMetalRenderer(view: self, engine: engineBridge)
        DTLaunchBreadcrumb("canvas:rendererCreated")
        delegate = renderer
        addInteraction(UIPencilInteraction(delegate: self))
        addGestureRecognizer(hoverGesture)
        addGestureRecognizer(panGesture)
        addGestureRecognizer(pinchGesture)
        addGestureRecognizer(rotationGesture)
        restoreViewTransform()
        updateGridRenderer()
        DTLaunchBreadcrumb("canvas:configure:done")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            displayLink?.invalidate()
            let link = CADisplayLink(target: self, selector: #selector(displayTick))
            link.add(to: .main, forMode: .common)
            displayLink = link
        } else {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    deinit { displayLink?.invalidate() }

    private func updateGridRenderer() {
        renderer?.updateGridVisible(gridVisible, spacing: 32)
        renderer?.updatePixelGridVisible(pixelGridVisible)
    }

    private var activeToolName: String {
        switch currentTool {
        case .eraser: return "eraser"
        case .line: return "line"
        case .rectangle: return "rectangle"
        case .ellipse: return "ellipse"
        case .circle: return "circle"
        case .shade: return "shade"
        case .select: return "select"
        case .lasso: return "lasso"
        default: return "brush"
        }
    }

    /// Status-bar display name for the active tool.
    var activeToolDisplayName: String { activeToolName }

    func togglePencilTool(source: String) {
        switch currentTool {
        case .brush: currentTool = .eraser
        case .eraser: currentTool = .brush
        default: currentTool = .brush
        }
        lastPencilAction = "\(source) → \(activeToolName)"
        HapticFeedbackService.shared.toolSwitched()
        onToolChanged?()
        setNeedsDisplay()
    }

    func hideHoverPreview() {
        hoverActive = false
        hoverOverlay?.hideHover()
    }

    @objc private func handlePencilHover(_ gesture: UIHoverGestureRecognizer) {
        guard brushPreviewEnabled else {
            hideHoverPreview()
            return
        }
        switch gesture.state {
        case .began, .changed:
            guard !strokeEngaged else {
                hideHoverPreview()
                return
            }
            let location = gesture.location(in: self)
            guard bounds.contains(location) else {
                hideHoverPreview()
                return
            }
            hoverActive = true
            hoverPoint = location
            let diameter = min(max(engineBridge.brushSize * canvasScale, 3), 240)
            let color = UIColor(red: CGFloat((engineBridge.brushColorRGBA >> 24) & 0xff) / 255.0,
                                green: CGFloat((engineBridge.brushColorRGBA >> 16) & 0xff) / 255.0,
                                blue: CGFloat((engineBridge.brushColorRGBA >> 8) & 0xff) / 255.0,
                                alpha: CGFloat(engineBridge.brushColorRGBA & 0xff) / 255.0)
            hoverOverlay?.updateHover(at: location,
                                      diameter: diameter,
                                      color: color,
                                      tool: currentTool,
                                      altitude: gesture.altitudeAngle,
                                      azimuth: gesture.azimuthAngle(in: self),
                                      roll: gesture.rollAngle)
            if snapToGrid, gridVisible, gridSpacing >= 1 {
                let docLoc = documentPoint(for: location)
                let snappedDoc = CGPoint(x: round(docLoc.x / gridSpacing) * gridSpacing,
                                         y: round(docLoc.y / gridSpacing) * gridSpacing)
                let snappedView = viewPoint(for: snappedDoc)
                let dist = hypot(snappedView.x - location.x, snappedView.y - location.y)
                if dist < 24.0 {
                    if hoverOverlay?.snappedPoint == nil {
                        HapticFeedbackService.shared.snapLock()
                    }
                    hoverOverlay?.snappedPoint = snappedView
                } else {
                    hoverOverlay?.snappedPoint = nil
                }
            } else {
                hoverOverlay?.snappedPoint = nil
            }
        case .ended, .cancelled, .failed:
            hideHoverPreview()
        default:
            break
        }
    }

    private func accepts(_ touch: UITouch) -> Bool {
        touch.type == .pencil ||
            (!UIPencilInteraction.prefersPencilOnlyDrawing && touch.type == .direct)
    }

    private func normalizedForce(of touch: UITouch) -> CGFloat {
        guard touch.maximumPossibleForce > 0 else { return 1.0 }
        return min(max(CGFloat(touch.force / touch.maximumPossibleForce), 0), 1)
    }

    private var releasePressure: CGFloat {
        activationPressure == 0 ? 0 : max(0.001, activationPressure * 0.55)
    }

    private func makeSample(_ touch: UITouch,
                            predicted: Bool,
                            coalesced: Bool = false) -> DTPencilSample {
        var location = documentPoint(for: touch.preciseLocation(in: self))

        // 15-degree angle snapping for shapes
        switch currentTool {
        case .line, .rectangle, .ellipse, .circle:
            if angleSnapEnabled, let start = shapeStartDocPoint {
                let dx = location.x - start.x
                let dy = location.y - start.y
                let dist = hypot(dx, dy)
                if dist > 4.0 {
                    let angle = atan2(dy, dx)
                    let step = CGFloat.pi / 12.0 // 15 degrees
                    let angleIndex = Int(round(angle / step))
                    if angleIndex != lastSnappedAngleIndex {
                        lastSnappedAngleIndex = angleIndex
                        HapticFeedbackService.shared.snapLock()
                    }
                    let snappedAngle = CGFloat(angleIndex) * step
                    location.x = start.x + dist * cos(snappedAngle)
                    location.y = start.y + dist * sin(snappedAngle)
                }
            }
            if snapToGrid, gridVisible, gridSpacing >= 1 {
                location.x = round(location.x / gridSpacing) * gridSpacing
                location.y = round(location.y / gridSpacing) * gridSpacing
            }
        default:
            break
        }

        let force = touch.maximumPossibleForce > 0
            ? touch.force / touch.maximumPossibleForce
            : 1.0
        var flags: DTPencilSampleFlags = predicted ? .predicted : .real
        if coalesced { flags.insert(.coalesced) }
        let estimated = touch.estimatedProperties
        if estimated.contains(.force) { flags.insert(.pressureEstimated) }
        if estimated.contains(.altitude) { flags.insert(.altitudeEstimated) }
        if estimated.contains(.azimuth) { flags.insert(.azimuthEstimated) }
        if estimated.contains(.roll) { flags.insert(.rollEstimated) }

        var sample = DTPencilSample()
        sample.x = Float(location.x)
        sample.y = Float(location.y)
        sample.pressure = Float(max(0, min(1, force)))
        sample.altitude = Float(touch.altitudeAngle)
        sample.azimuth = Float(touch.azimuthAngle(in: self))
        sample.roll = Float(touch.rollAngle)
        sample.hoverDistance = 0
        sample.timestamp = touch.timestamp
        sample.sampleID = nextSampleID
        nextSampleID &+= 1
        sample.estimationUpdateIndex = touch.estimationUpdateIndex?.uint64Value ?? 0
        sample.flags = flags
        return sample
    }

    private func appendBatch(for touch: UITouch,
                             event: UIEvent?,
                             includePredicted: Bool = true,
                             minimumPencilPressure: CGFloat? = nil) {
        let coalescedTouches = event?.coalescedTouches(for: touch) ?? [touch]
        let eligibleTouches: [UITouch]
        if touch.type == .pencil, let minimumPencilPressure {
            eligibleTouches = coalescedTouches.filter {
                normalizedForce(of: $0) >= minimumPencilPressure
            }
        } else {
            eligibleTouches = coalescedTouches
        }
        let real = eligibleTouches.map {
            makeSample($0, predicted: false, coalesced: $0 !== touch)
        }
        let predicted = includePredicted && predictionEnabled && !real.isEmpty
            ? (event?.predictedTouches(for: touch) ?? []).map {
            makeSample($0, predicted: true)
            }
            : []
        guard !real.isEmpty || !predicted.isEmpty else { return }
        let samples = real + predicted
        samples.withUnsafeBufferPointer { buffer in
            engineBridge.appendSamples(buffer.baseAddress,
                                       count: UInt(buffer.count),
                                       realCount: UInt(real.count))
        }
        // On-demand rendering: schedule exactly one frame per input batch.
        setNeedsDisplay()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard activeTouch == nil, let touch = touches.first(where: accepts) else { return }
        activeTouch = touch

        // Selection & Transform mode
        if currentTool == .select || currentTool == .lasso {
            let loc = touch.preciseLocation(in: self)
            let docLoc = documentPoint(for: loc)
            if let box = selectedBoundingBox, box.contains(docLoc) {
                isMovingSelection = true
                selectionDragStartDocPoint = docLoc
            } else {
                isMovingSelection = false
                clearSelection()
                isSelecting = true
                selectionStartViewPoint = loc
                if currentTool == .select {
                    hoverOverlay?.isSelecting = true
                    hoverOverlay?.selectionRect = CGRect(origin: loc, size: .zero)
                } else {
                    hoverOverlay?.isSelecting = true
                    hoverOverlay?.lassoPoints = [loc]
                }
            }
            return
        }

        if currentTool == .line || currentTool == .rectangle || currentTool == .ellipse || currentTool == .circle {
            shapeStartDocPoint = documentPoint(for: touch.preciseLocation(in: self))
            lastSnappedAngleIndex = -1
        }

        if touch.type == .pencil && normalizedForce(of: touch) < activationPressure {
            return
        }
        strokeEngaged = true
        hideHoverPreview()
        engineBridge.beginStroke()
        onDrawingBegan?()
        appendBatch(for: touch,
                    event: event,
                    minimumPencilPressure: touch.type == .pencil ? activationPressure : nil)
        setNeedsDisplay()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let activeTouch, touches.contains(activeTouch) else { return }

        // Selection & Transform mode
        if currentTool == .select || currentTool == .lasso {
            let loc = activeTouch.preciseLocation(in: self)
            let docLoc = documentPoint(for: loc)
            if isMovingSelection {
                let dx = docLoc.x - selectionDragStartDocPoint.x
                let dy = docLoc.y - selectionDragStartDocPoint.y
                if abs(dx) >= 0.5 || abs(dy) >= 0.5 {
                    let nsIndices = selectedStrokeIndices.map { NSNumber(value: $0) }
                    _ = engineBridge.moveStrokes(at: nsIndices, dx: dx, dy: dy)
                    selectionDragStartDocPoint = docLoc
                    if let oldBox = selectedBoundingBox {
                        selectedBoundingBox = oldBox.offsetBy(dx: dx, dy: dy)
                        updateSelectionBoundsOverlay()
                    }
                    setNeedsDisplay()
                }
            } else if isSelecting {
                if currentTool == .select {
                    let rect = CGRect(x: min(selectionStartViewPoint.x, loc.x),
                                      y: min(selectionStartViewPoint.y, loc.y),
                                      width: abs(loc.x - selectionStartViewPoint.x),
                                      height: abs(loc.y - selectionStartViewPoint.y))
                    hoverOverlay?.selectionRect = rect
                } else {
                    hoverOverlay?.lassoPoints.append(loc)
                }
            }
            return
        }

        if activeTouch.type == .pencil {
            let latest = event?.coalescedTouches(for: activeTouch)?.last ?? activeTouch
            if strokeEngaged {
                if normalizedForce(of: latest) < releasePressure {
                    appendBatch(for: activeTouch,
                                event: event,
                                includePredicted: false,
                                minimumPencilPressure: releasePressure)
                    engineBridge.endStroke()
                    onDocumentChanged?()
                    strokeEngaged = false
                    setNeedsDisplay()
                } else {
                    appendBatch(for: activeTouch, event: event)
                }
            } else if normalizedForce(of: latest) >= activationPressure {
                strokeEngaged = true
                hideHoverPreview()
                engineBridge.beginStroke()
                onDrawingBegan?()
                appendBatch(for: activeTouch,
                            event: event,
                            includePredicted: false,
                            minimumPencilPressure: activationPressure)
                setNeedsDisplay()
            }
            return
        }
        appendBatch(for: activeTouch, event: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let activeTouch, touches.contains(activeTouch) else { return }

        // Selection & Transform mode
        if currentTool == .select || currentTool == .lasso {
            if isMovingSelection {
                isMovingSelection = false
                onDocumentChanged?()
            } else if isSelecting {
                isSelecting = false
                finishSelection()
            }
            self.activeTouch = nil
            return
        }

        if strokeEngaged {
            if activeTouch.type != .pencil || normalizedForce(of: activeTouch) >= releasePressure {
                var finalSample = makeSample(activeTouch, predicted: false)
                withUnsafePointer(to: &finalSample) { pointer in
                    engineBridge.appendSamples(pointer, count: 1, realCount: 1)
                }
            }
            engineBridge.endStroke()
            onDocumentChanged?()
        }
        strokeEngaged = false
        shapeStartDocPoint = nil
        lastSnappedAngleIndex = -1
        self.activeTouch = nil
        hideHoverPreview()
        setNeedsDisplay()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard activeTouch != nil else { return }
        shapeStartDocPoint = nil
        lastSnappedAngleIndex = -1
        if currentTool == .select || currentTool == .lasso {
            isMovingSelection = false
            isSelecting = false
            hoverOverlay?.clearSelectionOverlay()
            self.activeTouch = nil
            return
        }
        if strokeEngaged {
            engineBridge.cancelStroke()
            onDocumentChanged?()
        }
        strokeEngaged = false
        activeTouch = nil
        hideHoverPreview()
        setNeedsDisplay()
    }

    // MARK: - Selection Operations

    func clearSelection() {
        selectedStrokeIndices.removeAll()
        selectedBoundingBox = nil
        hoverOverlay?.clearSelectionOverlay()
    }

    func updateSelectionBoundsOverlay() {
        guard let box = selectedBoundingBox else {
            hoverOverlay?.selectedBounds = nil
            hoverOverlay?.selectedStrokeCount = 0
            return
        }
        let p0 = viewPoint(for: CGPoint(x: box.minX, y: box.minY))
        let p1 = viewPoint(for: CGPoint(x: box.maxX, y: box.maxY))
        let viewRect = CGRect(x: min(p0.x, p1.x),
                              y: min(p0.y, p1.y),
                              width: max(16.0, abs(p1.x - p0.x)),
                              height: max(16.0, abs(p1.y - p0.y)))
        hoverOverlay?.selectedBounds = viewRect
        hoverOverlay?.selectedStrokeCount = selectedStrokeIndices.count
    }

    func duplicateSelection() {
        guard !selectedStrokeIndices.isEmpty else { return }
        let currentCount = engineBridge.activeLayerStrokeCount
        let nsIndices = selectedStrokeIndices.map { NSNumber(value: $0) }
        if engineBridge.duplicateStrokes(at: nsIndices, dx: 16.0, dy: 16.0) {
            HapticFeedbackService.shared.success()
            let newIndices = Array(currentCount..<(currentCount + selectedStrokeIndices.count))
            selectedStrokeIndices = newIndices
            if let oldBox = selectedBoundingBox {
                selectedBoundingBox = oldBox.offsetBy(dx: 16.0, dy: 16.0)
                updateSelectionBoundsOverlay()
            }
            setNeedsDisplay()
            onDocumentChanged?()
        }
    }

    func deleteSelection() {
        guard !selectedStrokeIndices.isEmpty else { return }
        let nsIndices = selectedStrokeIndices.map { NSNumber(value: $0) }
        if engineBridge.deleteStrokes(at: nsIndices) {
            HapticFeedbackService.shared.undoRedo()
            clearSelection()
            setNeedsDisplay()
            onDocumentChanged?()
            onSelectionChanged?([], nil)
        }
    }

    private func finishSelection() {
        hoverOverlay?.isSelecting = false
        let selectionRect = hoverOverlay?.selectionRect
        let lassoPts = hoverOverlay?.lassoPoints ?? []
        hoverOverlay?.selectionRect = nil
        hoverOverlay?.lassoPoints.removeAll()

        let strokes = engineBridge.renderableStrokes
        var matchedIndices: [Int] = []
        var unionBounds: CGRect?

        if currentTool == .select, let rect = selectionRect {
            let p0 = documentPoint(for: CGPoint(x: rect.minX, y: rect.minY))
            let p1 = documentPoint(for: CGPoint(x: rect.maxX, y: rect.maxY))
            let docRect = CGRect(x: min(p0.x, p1.x),
                                 y: min(p0.y, p1.y),
                                 width: max(1.0, abs(p1.x - p0.x)),
                                 height: max(1.0, abs(p1.y - p0.y)))
            for (index, stroke) in strokes.enumerated() {
                var strokeBox: CGRect?
                for val in stroke.points {
                    var pt = DTRenderPoint()
                    val.getValue(&pt)
                    let p = CGPoint(x: CGFloat(pt.x), y: CGFloat(pt.y))
                    strokeBox = strokeBox == nil ? CGRect(origin: p, size: .zero) : strokeBox!.union(CGRect(origin: p, size: .zero))
                }
                if let box = strokeBox, docRect.intersects(box) || docRect.contains(box.origin) {
                    matchedIndices.append(index)
                    unionBounds = unionBounds == nil ? box : unionBounds!.union(box)
                }
            }
        } else if currentTool == .lasso, lassoPts.count > 2 {
            let docLassoPts = lassoPts.map { documentPoint(for: $0) }
            let lassoPath = UIBezierPath()
            lassoPath.move(to: docLassoPts[0])
            for i in 1..<docLassoPts.count {
                lassoPath.addLine(to: docLassoPts[i])
            }
            lassoPath.close()

            for (index, stroke) in strokes.enumerated() {
                var strokeBox: CGRect?
                var hit = false
                for val in stroke.points {
                    var pt = DTRenderPoint()
                    val.getValue(&pt)
                    let p = CGPoint(x: CGFloat(pt.x), y: CGFloat(pt.y))
                    strokeBox = strokeBox == nil ? CGRect(origin: p, size: .zero) : strokeBox!.union(CGRect(origin: p, size: .zero))
                    if lassoPath.contains(p) {
                        hit = true
                    }
                }
                if hit, let box = strokeBox {
                    matchedIndices.append(index)
                    unionBounds = unionBounds == nil ? box : unionBounds!.union(box)
                }
            }
        }

        selectedStrokeIndices = matchedIndices
        selectedBoundingBox = unionBounds
        if !matchedIndices.isEmpty {
            HapticFeedbackService.shared.snapLock()
            updateSelectionBoundsOverlay()
        } else {
            clearSelection()
        }
        onSelectionChanged?(selectedStrokeIndices, selectedBoundingBox)
    }

    // MARK: - Canvas transform and gestures

    private func restoreViewTransform() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.scaleDefaultsKey) != nil {
            canvasScale = clampedScale(CGFloat(defaults.double(forKey: Self.scaleDefaultsKey)))
        }
        if defaults.object(forKey: Self.rotationDefaultsKey) != nil {
            let value = CGFloat(defaults.double(forKey: Self.rotationDefaultsKey))
            canvasRotation = value.isFinite ? value : 0
        }
        if defaults.object(forKey: Self.translationXDefaultsKey) != nil {
            let value = CGFloat(defaults.double(forKey: Self.translationXDefaultsKey))
            canvasTranslation.x = value.isFinite ? value : 0
        }
        if defaults.object(forKey: Self.translationYDefaultsKey) != nil {
            let value = CGFloat(defaults.double(forKey: Self.translationYDefaultsKey))
            canvasTranslation.y = value.isFinite ? value : 0
        }
        publishViewTransform()
    }

    private func persistViewTransform() {
        let defaults = UserDefaults.standard
        defaults.set(Double(canvasScale), forKey: Self.scaleDefaultsKey)
        defaults.set(Double(canvasRotation), forKey: Self.rotationDefaultsKey)
        defaults.set(Double(canvasTranslation.x), forKey: Self.translationXDefaultsKey)
        defaults.set(Double(canvasTranslation.y), forKey: Self.translationYDefaultsKey)
    }

    private func clampedScale(_ value: CGFloat) -> CGFloat {
        min(max(value.isFinite ? value : 1.0, 0.1), 8.0)
    }

    private func publishViewTransform(persist: Bool = false) {
        renderer?.updateCanvasScale(canvasScale,
                                    rotation: canvasRotation,
                                    translationX: canvasTranslation.x,
                                    translationY: canvasTranslation.y)
        if persist { persistViewTransform() }
        updateSelectionBoundsOverlay()
        setNeedsDisplay()
    }

    /// Resets zoom, rotation and pan to the default page viewport.
    func resetView() {
        cancelDirectFingerStrokeIfNeeded()
        canvasScale = 1.0
        canvasRotation = 0.0
        canvasTranslation = .zero
        publishViewTransform(persist: true)
    }

    func documentPoint(for viewPoint: CGPoint) -> CGPoint {
        let translated = CGPoint(x: (viewPoint.x - canvasTranslation.x) / canvasScale,
                                 y: (viewPoint.y - canvasTranslation.y) / canvasScale)
        let cosine = cos(canvasRotation)
        let sine = sin(canvasRotation)
        // Inverse of the document-to-view rotation.
        return CGPoint(x: translated.x * cosine + translated.y * sine,
                       y: -translated.x * sine + translated.y * cosine)
    }

    func viewPoint(for docPoint: CGPoint) -> CGPoint {
        let cosine = cos(canvasRotation)
        let sine = sin(canvasRotation)
        let rotated = CGPoint(x: (docPoint.x * cosine - docPoint.y * sine) * canvasScale,
                              y: (docPoint.x * sine + docPoint.y * cosine) * canvasScale)
        return CGPoint(x: rotated.x + canvasTranslation.x,
                       y: rotated.y + canvasTranslation.y)
    }

    private func applyTransform(scale newScale: CGFloat? = nil,
                                rotation newRotation: CGFloat? = nil,
                                around centroid: CGPoint?) {
        let pivot = centroid ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let documentPivot = documentPoint(for: pivot)
        if let newScale { canvasScale = clampedScale(newScale) }
        if let newRotation {
            canvasRotation = newRotation.isFinite
                ? newRotation.truncatingRemainder(dividingBy: .pi * 2)
                : 0
        }

        // Keep the document point beneath the gesture centroid stationary.
        let cosine = cos(canvasRotation)
        let sine = sin(canvasRotation)
        let rotated = CGPoint(
            x: (documentPivot.x * cosine - documentPivot.y * sine) * canvasScale,
            y: (documentPivot.x * sine + documentPivot.y * cosine) * canvasScale
        )
        canvasTranslation = CGPoint(x: pivot.x - rotated.x,
                                    y: pivot.y - rotated.y)
        publishViewTransform()
    }

    private func cancelDirectFingerStrokeIfNeeded() {
        guard activeTouch?.type == .direct else { return }
        if strokeEngaged {
            engineBridge.cancelStroke()
            onDocumentChanged?()
        }
        strokeEngaged = false
        activeTouch = nil
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            cancelDirectFingerStrokeIfNeeded()
        case .changed:
            let delta = gesture.translation(in: self)
            gesture.setTranslation(.zero, in: self)
            canvasTranslation.x += delta.x
            canvasTranslation.y += delta.y
            publishViewTransform()
        case .ended, .cancelled, .failed:
            persistViewTransform()
        default:
            break
        }
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            cancelDirectFingerStrokeIfNeeded()
        case .changed:
            applyTransform(scale: canvasScale * gesture.scale,
                           around: gesture.location(in: self))
            gesture.scale = 1.0
        case .ended, .cancelled, .failed:
            persistViewTransform()
        default:
            break
        }
    }

    @objc private func handleRotation(_ gesture: UIRotationGestureRecognizer) {
        switch gesture.state {
        case .began:
            cancelDirectFingerStrokeIfNeeded()
        case .changed:
            applyTransform(rotation: canvasRotation + gesture.rotation,
                           around: gesture.location(in: self))
            gesture.rotation = 0.0
        case .ended, .cancelled, .failed:
            persistViewTransform()
        default:
            break
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {
        // Pencil input remains exclusively owned by the sample path.
        return touch.type == .direct
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // Never change the view transform under an active Pencil stroke; the
        // input samples for one stroke must remain in a single coordinate map.
        activeTouch?.type != .pencil
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        (gestureRecognizer === panGesture || gestureRecognizer === pinchGesture || gestureRecognizer === rotationGesture) &&
            (otherGestureRecognizer === panGesture || otherGestureRecognizer === pinchGesture || otherGestureRecognizer === rotationGesture)
    }

    override func touchesEstimatedPropertiesUpdated(_ touches: Set<UITouch>) {
        guard let activeTouch else { return }
        for touch in touches where touch.type == .pencil {
            if !strokeEngaged && normalizedForce(of: touch) >= activationPressure {
                strokeEngaged = true
                hideHoverPreview()
                engineBridge.beginStroke()
                onDrawingBegan?()
                appendBatch(for: touch,
                            event: nil,
                            includePredicted: false,
                            minimumPencilPressure: activationPressure)
            }
            guard let index = touch.estimationUpdateIndex?.uint64Value else { continue }
            guard strokeEngaged, touch === activeTouch else { continue }
            let corrected = makeSample(touch, predicted: false)
            _ = engineBridge.updateEstimatedSample(at: index, sample: corrected)
        }
    }

    func pencilInteraction(_ interaction: UIPencilInteraction,
                            didReceiveTap tap: UIPencilInteraction.Tap) {
        HapticFeedbackService.shared.toolSwitched()
        togglePencilTool(source: "double tap")
    }

    func pencilInteraction(_ interaction: UIPencilInteraction,
                            didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        lastPencilAction = "squeeze \(squeeze.phase)"
        switch squeeze.phase {
        case .began:
            HapticFeedbackService.shared.squeeze()
            if let onSqueeze {
                onSqueeze()
            } else {
                squeezeToggleConsumed = false
            }
        case .ended:
            if onSqueeze == nil && !squeezeToggleConsumed {
                squeezeToggleConsumed = true
                togglePencilTool(source: "squeeze")
            }
        case .cancelled:
            squeezeToggleConsumed = false
        default:
            break
        }
    }

    @objc private func displayTick() {
        guard let renderer else { return }
        let now = CACurrentMediaTime()
        let elapsed = now - lastDiagnosticTime
        guard elapsed >= 0.25 else { return }
        let frames = renderer.frameCount
        let fps = Double(frames - lastDiagnosticFrame) / elapsed
        lastDiagnosticTime = now
        lastDiagnosticFrame = frames
        let state = activeTouch == nil ? "idle" : "pencil input"
        let hover = hoverActive ? String(format: "yes (%.0f, %.0f)", hoverPoint.x, hoverPoint.y) : "no"
        onDiagnostics?(String(format: "Metal  %.0f fps\nStrokes  %lu   Samples  %lu\nState  %@\nTool  %@\nHover  %@\nPencil  %@",
                             fps,
                             engineBridge.strokeCount,
                             engineBridge.sampleCount,
                             state,
                             activeToolName,
                             hover,
                             lastPencilAction))
    }
}
