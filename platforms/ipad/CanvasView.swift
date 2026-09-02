import MetalKit
import UIKit

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

    /// Minimum normalized Apple Pencil force needed to put the pen down. A
    /// small amount of hysteresis is used on lift-off so force estimates that
    /// wobble around the threshold do not fragment a stroke.
    var activationPressure: CGFloat {
        get { activationPressureValue }
        set { activationPressureValue = min(max(newValue, 0), 0.20) }
    }

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
        colorPixelFormat = .bgra8Unorm
        // Keep the canvas useful even when no Metal pipeline is available. A
        // light, warm paper tone also makes the first blank state obvious.
        clearColor = MTLClearColor(red: 0.965, green: 0.935, blue: 0.865, alpha: 1.0)
        framebufferOnly = true
        isMultipleTouchEnabled = true
        isOpaque = true
        enableSetNeedsDisplay = false
        isPaused = false
        preferredFramesPerSecond = UIScreen.main.maximumFramesPerSecond
        presentsWithTransaction = false
        renderer = DTMetalRenderer(view: self, engine: engineBridge)
        delegate = renderer
        addInteraction(UIPencilInteraction(delegate: self))
        addGestureRecognizer(panGesture)
        addGestureRecognizer(pinchGesture)
        addGestureRecognizer(rotationGesture)
        restoreViewTransform()
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
        let location = documentPoint(for: touch.preciseLocation(in: self))
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
        let predicted = includePredicted && !real.isEmpty
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
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard activeTouch == nil, let touch = touches.first(where: accepts) else { return }
        activeTouch = touch
        if touch.type == .pencil && normalizedForce(of: touch) < activationPressure {
            // Keep tracking this contact, but do not create an engine stroke
            // until the user has intentionally pressed the Pencil down.
            return
        }
        strokeEngaged = true
        engineBridge.beginStroke()
        onDrawingBegan?()
        appendBatch(for: touch,
                    event: event,
                    minimumPencilPressure: touch.type == .pencil ? activationPressure : nil)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let activeTouch, touches.contains(activeTouch) else { return }
        if activeTouch.type == .pencil {
            let latest = event?.coalescedTouches(for: activeTouch)?.last ?? activeTouch
            if strokeEngaged {
                if normalizedForce(of: latest) < releasePressure {
                    // Flush real samples before ending; predicted points are
                    // intentionally discarded at lift-off.
                    appendBatch(for: activeTouch,
                                event: event,
                                includePredicted: false,
                                minimumPencilPressure: releasePressure)
                    engineBridge.endStroke()
                    onDocumentChanged?()
                    strokeEngaged = false
                } else {
                    appendBatch(for: activeTouch, event: event)
                }
            } else if normalizedForce(of: latest) >= activationPressure {
                strokeEngaged = true
                engineBridge.beginStroke()
                onDrawingBegan?()
                appendBatch(for: activeTouch,
                            event: event,
                            includePredicted: false,
                            minimumPencilPressure: activationPressure)
            }
            return
        }
        appendBatch(for: activeTouch, event: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let activeTouch, touches.contains(activeTouch) else { return }
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
        self.activeTouch = nil
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard activeTouch != nil else { return }
        if strokeEngaged {
            engineBridge.cancelStroke()
            onDocumentChanged?()
        }
        strokeEngaged = false
        activeTouch = nil
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

    private func documentPoint(for viewPoint: CGPoint) -> CGPoint {
        let translated = CGPoint(x: (viewPoint.x - canvasTranslation.x) / canvasScale,
                                 y: (viewPoint.y - canvasTranslation.y) / canvasScale)
        let cosine = cos(canvasRotation)
        let sine = sin(canvasRotation)
        // Inverse of the document-to-view rotation.
        return CGPoint(x: translated.x * cosine + translated.y * sine,
                       y: -translated.x * sine + translated.y * cosine)
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
        touch.type == .direct
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
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
        lastPencilAction = "double tap"
    }

    func pencilInteraction(_ interaction: UIPencilInteraction,
                           didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        lastPencilAction = "squeeze \(squeeze.phase)"
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
        onDiagnostics?(String(format: "Metal  %.0f fps\nStrokes  %lu   Samples  %lu\nState  %@\nPencil  %@",
                             fps,
                             engineBridge.strokeCount,
                             engineBridge.sampleCount,
                             state,
                             lastPencilAction))
    }
}
