import MetalKit
import UIKit

/// MTKView input surface for Apple Pencil. UIKit owns gesture recognition and
/// event prediction; DTEngineBridge owns the thread-safe document samples.
final class CanvasView: MTKView {
    let engineBridge = DTEngineBridge()

    /// Called periodically on the main thread with a human-readable state
    /// string suitable for the diagnostics overlay.
    var onDiagnostics: ((String) -> Void)?

    private var activeTouch: UITouch?
    private var renderer: DTMetalRenderer?
    private var displayLink: CADisplayLink?
    private var lastDiagnosticTime = CACurrentMediaTime()
    private var lastDiagnosticFrame: UInt = 0

    override init(frame frameRect: CGRect, device: MTLDevice?) {
        let selectedDevice = device ?? MTLCreateSystemDefaultDevice()
        super.init(frame: frameRect, device: selectedDevice)
        configure()
    }

    required init?(coder: NSCoder) {
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
        renderer = DTMetalRenderer(view: self, engine: engineBridge)
        delegate = renderer
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

    private func append(_ touch: UITouch, predicted: Bool) {
        let location = touch.preciseLocation(in: self)
        let force = touch.maximumPossibleForce > 0
            ? touch.force / touch.maximumPossibleForce
            : 1.0
        engineBridge.appendPoint(atX: location.x,
                                 y: location.y,
                                 pressure: CGFloat(max(0.05, min(1.0, force))),
                                 timestamp: touch.timestamp,
                                 predicted: predicted)
    }

    private func appendRealSamples(for touch: UITouch, event: UIEvent?) {
        let samples = event?.coalescedTouches(for: touch) ?? [touch]
        for sample in samples { append(sample, predicted: false) }
    }

    private func appendPredictedSamples(for touch: UITouch, event: UIEvent?) {
        guard let predicted = event?.predictedTouches(for: touch) else { return }
        for sample in predicted { append(sample, predicted: true) }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard activeTouch == nil, let touch = touches.first(where: accepts) else { return }
        activeTouch = touch
        engineBridge.beginStroke()
        appendRealSamples(for: touch, event: event)
        appendPredictedSamples(for: touch, event: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let activeTouch, touches.contains(activeTouch) else { return }
        appendRealSamples(for: activeTouch, event: event)
        appendPredictedSamples(for: activeTouch, event: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let activeTouch, touches.contains(activeTouch) else { return }
        appendRealSamples(for: activeTouch, event: event)
        engineBridge.endStroke()
        self.activeTouch = nil
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard activeTouch != nil else { return }
        engineBridge.endStroke()
        activeTouch = nil
    }

    override func touchesEstimatedPropertiesUpdated(_ touches: Set<UITouch>) {
        guard let activeTouch else { return }
        for touch in touches where touch == activeTouch {
            // UIKit may revise force/location after the initial event. The
            // engine accepts this as another real sample; consumers can use
            // timestamps to replace an estimated sample in a future engine.
            append(touch, predicted: false)
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
        onDiagnostics?(String(format: "Metal  %.0f fps\nStrokes  %lu   Samples  %lu\nState  %@",
                             fps,
                             engineBridge.strokeCount,
                             engineBridge.sampleCount,
                             state))
    }
}
