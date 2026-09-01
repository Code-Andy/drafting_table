import MetalKit
import UIKit

/// MTKView input surface for Apple Pencil. UIKit owns gesture recognition and
/// event prediction; DTEngineBridge owns the thread-safe document samples.
final class CanvasView: MTKView, UIPencilInteractionDelegate {
    let engineBridge = DTEngineBridge()

    /// Called periodically on the main thread with a human-readable state
    /// string suitable for the diagnostics overlay.
    var onDiagnostics: ((String) -> Void)?

    private var activeTouch: UITouch?
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
        clearColor = MTLClearColor(red: 0.055, green: 0.065, blue: 0.08, alpha: 1.0)
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
        // Pencil-only input prevents a palm or a resting finger from creating
        // a stroke. A mouse/finger can still be used in UI tests by setting
        // the accessibility identifier and sending pencil events in XCTest.
        touch.type == .pencil
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

    private func appendBatch(for touch: UITouch, event: UIEvent?) {
        let coalescedTouches = event?.coalescedTouches(for: touch) ?? [touch]
        let real = coalescedTouches.map {
            makeSample($0, predicted: false, coalesced: $0 !== touch)
        }
        let predicted = (event?.predictedTouches(for: touch) ?? []).map {
            makeSample($0, predicted: true)
        }
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
        engineBridge.beginStroke()
        appendBatch(for: touch, event: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let activeTouch, touches.contains(activeTouch) else { return }
        appendBatch(for: activeTouch, event: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let activeTouch, touches.contains(activeTouch) else { return }
        var finalSample = makeSample(activeTouch, predicted: false)
        withUnsafePointer(to: &finalSample) { pointer in
            engineBridge.appendSamples(pointer, count: 1, realCount: 1)
        }
        engineBridge.endStroke()
        self.activeTouch = nil
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard activeTouch != nil else { return }
        engineBridge.cancelStroke()
        activeTouch = nil
    }

    override func touchesEstimatedPropertiesUpdated(_ touches: Set<UITouch>) {
        guard activeTouch != nil else { return }
        for touch in touches where touch.type == .pencil {
            guard let index = touch.estimationUpdateIndex?.uint64Value else { continue }
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
