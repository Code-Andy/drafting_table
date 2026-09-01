import MetalKit
import UIKit

/// MTKView input surface for Apple Pencil. UIKit owns gesture recognition and
/// event prediction; DTEngineBridge owns the thread-safe document samples.
final class CanvasView: MTKView, UIPencilInteractionDelegate {
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

    private var activeTouch: UITouch?
    private var activationPressureValue: CGFloat = 0.03
    private var strokeEngaged = false
    private var renderer: DTMetalRenderer?
    private var displayLink: CADisplayLink?
    private var lastDiagnosticTime = CACurrentMediaTime()
    private var lastDiagnosticFrame: UInt = 0
    private var nextSampleID: UInt64 = 1
    private var lastPencilAction = "none"

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
        let location = touch.preciseLocation(in: self)
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
