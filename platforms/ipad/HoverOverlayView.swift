import UIKit

/// Transparent sibling view layered on top of `CanvasView` in `DraftingTableViewController`.
/// Renders Apple Pencil hover previews (brush diameter, tilt needle, azimuth/altitude,
/// barrel roll indicator), snapping target markers, and selection bounding boxes.
///
/// NOTE: Kept completely separate from `CanvasView`'s layer hierarchy so `MTKView`'s
/// `CAMetalLayer` remains undisturbed (preventing the v0.7.0 heap corruption crash).
@MainActor
final class HoverOverlayView: UIView {
    // MARK: - Hover State

    var isHoverVisible: Bool = false {
        didSet { if oldValue != isHoverVisible { setNeedsDisplay() } }
    }

    var hoverPoint: CGPoint = .zero
    var brushDiameter: CGFloat = 8.0
    var brushColor: UIColor = .darkText
    var activeTool: DTTool = .brush
    var altitudeAngle: CGFloat = .pi / 2
    var azimuthAngle: CGFloat = 0
    var rollAngle: CGFloat = 0

    // MARK: - Snapping State

    var snappedPoint: CGPoint? {
        didSet { if oldValue != snappedPoint { setNeedsDisplay() } }
    }

    // MARK: - Selection State

    var isSelecting: Bool = false {
        didSet { if oldValue != isSelecting { setNeedsDisplay() } }
    }
    var selectionRect: CGRect? {
        didSet { setNeedsDisplay() }
    }
    var lassoPoints: [CGPoint] = [] {
        didSet { setNeedsDisplay() }
    }
    var selectedBounds: CGRect? {
        didSet { setNeedsDisplay() }
    }
    var selectedStrokeCount: Int = 0 {
        didSet { setNeedsDisplay() }
    }

    // MARK: - Lifecycle

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        clipsToBounds = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Update Methods

    func updateHover(at point: CGPoint,
                     diameter: CGFloat,
                     color: UIColor,
                     tool: DTTool,
                     altitude: CGFloat,
                     azimuth: CGFloat,
                     roll: CGFloat) {
        isHoverVisible = true
        hoverPoint = point
        brushDiameter = diameter
        brushColor = color
        activeTool = tool
        altitudeAngle = altitude
        azimuthAngle = azimuth
        rollAngle = roll
        setNeedsDisplay()
    }

    func hideHover() {
        if isHoverVisible || snappedPoint != nil {
            isHoverVisible = false
            snappedPoint = nil
            setNeedsDisplay()
        }
    }

    func clearSelectionOverlay() {
        isSelecting = false
        selectionRect = nil
        lassoPoints.removeAll()
        selectedBounds = nil
        selectedStrokeCount = 0
        setNeedsDisplay()
    }

    // MARK: - Drawing

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }

        // 1. Draw Selection Active Drag or Bounding Box
        drawSelection(in: context)

        // 2. Draw Snapping Lock Marker
        if let snap = snappedPoint {
            drawSnapMarker(at: snap, in: context)
        }

        // 3. Draw Apple Pencil Pro Hover Cursor
        if isHoverVisible {
            drawHoverCursor(at: hoverPoint, in: context)
        }
    }

    private func drawHoverCursor(at point: CGPoint, in context: CGContext) {
        context.saveGState()

        switch activeTool {
        case .eraser:
            // Dashed red circle for eraser
            let radius = max(2.5, brushDiameter * 0.5)
            let circleRect = CGRect(x: point.x - radius, y: point.y - radius,
                                    width: radius * 2, height: radius * 2)
            context.setStrokeColor(UIColor.systemRed.withAlphaComponent(0.75).cgColor)
            context.setLineWidth(1.2)
            context.setLineDash(phase: 0, lengths: [4, 3])
            context.strokeEllipse(in: circleRect)

        case .line, .rectangle, .ellipse, .circle:
            // Precision crosshair for shape tools
            context.setStrokeColor(UIColor.systemTeal.withAlphaComponent(0.85).cgColor)
            context.setLineWidth(1.0)
            let crosshairSize: CGFloat = 8.0
            context.strokeLineSegments(between: [
                CGPoint(x: point.x - crosshairSize, y: point.y),
                CGPoint(x: point.x + crosshairSize, y: point.y),
                CGPoint(x: point.x, y: point.y - crosshairSize),
                CGPoint(x: point.x, y: point.y + crosshairSize)
            ])
            let centerDot = CGRect(x: point.x - 1.5, y: point.y - 1.5, width: 3, height: 3)
            context.setFillColor(UIColor.systemTeal.cgColor)
            context.fillEllipse(in: centerDot)

        case .select, .lasso:
            // Selection tool crosshair
            context.setStrokeColor(UIColor.systemBlue.withAlphaComponent(0.9).cgColor)
            context.setLineWidth(1.2)
            context.strokeLineSegments(between: [
                CGPoint(x: point.x - 6, y: point.y),
                CGPoint(x: point.x + 6, y: point.y),
                CGPoint(x: point.x, y: point.y - 6),
                CGPoint(x: point.x, y: point.y + 6)
            ])

        case .brush, .shade:
            fallthrough
        default:
            // Circular brush outline matching diameter
            let radius = max(2.0, brushDiameter * 0.5)
            let circleRect = CGRect(x: point.x - radius, y: point.y - radius,
                                    width: radius * 2, height: radius * 2)
            context.setStrokeColor(brushColor.withAlphaComponent(0.65).cgColor)
            context.setLineWidth(1.2)
            context.strokeEllipse(in: circleRect)

            // Center pip
            let pip = CGRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2)
            context.setFillColor(brushColor.withAlphaComponent(0.85).cgColor)
            context.fillEllipse(in: pip)

            // Apple Pencil Pro Tilt & Azimuth Directional Needle:
            // altitudeAngle: pi/2 is perpendicular to screen; < 1.4 rad indicates tilt.
            if altitudeAngle < 1.45 {
                let tiltLength = max(6.0, min(36.0, (1.57 - altitudeAngle) * 24.0))
                let needleX = point.x + cos(azimuthAngle) * (radius + tiltLength)
                let needleY = point.y + sin(azimuthAngle) * (radius + tiltLength)

                context.setStrokeColor(UIColor.systemOrange.withAlphaComponent(0.70).cgColor)
                context.setLineWidth(1.2)
                context.strokeLineSegments(between: [
                    CGPoint(x: point.x + cos(azimuthAngle) * radius,
                            y: point.y + sin(azimuthAngle) * radius),
                    CGPoint(x: needleX, y: needleY)
                ])

                // Small directional tip
                let pipRect = CGRect(x: needleX - 2, y: needleY - 2, width: 4, height: 4)
                context.setFillColor(UIColor.systemOrange.withAlphaComponent(0.85).cgColor)
                context.fillEllipse(in: pipRect)
            }

            // Apple Pencil Pro Barrel Roll Indicator:
            // Draw a subtle roll tick mark on the rim rotated by rollAngle
            if abs(rollAngle) > 0.001 {
                let tickAngle = azimuthAngle + rollAngle
                let innerX = point.x + cos(tickAngle) * (radius - 2)
                let innerY = point.y + sin(tickAngle) * (radius - 2)
                let outerX = point.x + cos(tickAngle) * (radius + 3)
                let outerY = point.y + sin(tickAngle) * (radius + 3)

                context.setStrokeColor(UIColor.systemIndigo.withAlphaComponent(0.75).cgColor)
                context.setLineWidth(1.5)
                context.strokeLineSegments(between: [
                    CGPoint(x: innerX, y: innerY),
                    CGPoint(x: outerX, y: outerY)
                ])
            }
        }

        context.restoreGState()
    }

    private func drawSnapMarker(at point: CGPoint, in context: CGContext) {
        context.saveGState()
        let size: CGFloat = 6.0
        let diamondPath = UIBezierPath()
        diamondPath.move(to: CGPoint(x: point.x, y: point.y - size))
        diamondPath.addLine(to: CGPoint(x: point.x + size, y: point.y))
        diamondPath.addLine(to: CGPoint(x: point.x, y: point.y + size))
        diamondPath.addLine(to: CGPoint(x: point.x - size, y: point.y))
        diamondPath.close()

        context.setStrokeColor(UIColor.systemTeal.cgColor)
        context.setLineWidth(1.5)
        context.addPath(diamondPath.cgPath)
        context.strokePath()

        let center = CGRect(x: point.x - 1.5, y: point.y - 1.5, width: 3, height: 3)
        context.setFillColor(UIColor.systemTeal.cgColor)
        context.fillEllipse(in: center)
        context.restoreGState()
    }

    private func drawSelection(in context: CGContext) {
        context.saveGState()

        // Dragging Marquee Rect
        if let rect = selectionRect {
            context.setStrokeColor(UIColor.systemBlue.cgColor)
            context.setLineWidth(1.5)
            context.setLineDash(phase: 0, lengths: [5, 3])
            context.stroke(rect)
            context.setFillColor(UIColor.systemBlue.withAlphaComponent(0.08).cgColor)
            context.fill(rect)
        }

        // Dragging Lasso Path
        if lassoPoints.count > 1 {
            let path = UIBezierPath()
            path.move(to: lassoPoints[0])
            for i in 1..<lassoPoints.count {
                path.addLine(to: lassoPoints[i])
            }
            context.setStrokeColor(UIColor.systemBlue.cgColor)
            context.setLineWidth(1.5)
            context.setLineDash(phase: 0, lengths: [5, 3])
            context.addPath(path.cgPath)
            context.strokePath()
        }

        // Active Selection Bounding Box & Handles
        if let bounds = selectedBounds {
            let insetBounds = bounds.insetBy(dx: -4, dy: -4)
            context.setStrokeColor(UIColor.systemBlue.cgColor)
            context.setLineWidth(1.8)
            context.setLineDash(phase: 0, lengths: [6, 4])
            context.stroke(insetBounds)
            context.setFillColor(UIColor.systemBlue.withAlphaComponent(0.06).cgColor)
            context.fill(insetBounds)

            // Draw Corner & Edge Handles
            let handleSize: CGFloat = 8.0
            let handlePoints = [
                CGPoint(x: insetBounds.minX, y: insetBounds.minY),
                CGPoint(x: insetBounds.midX, y: insetBounds.minY),
                CGPoint(x: insetBounds.maxX, y: insetBounds.minY),
                CGPoint(x: insetBounds.minX, y: insetBounds.midY),
                CGPoint(x: insetBounds.maxX, y: insetBounds.midY),
                CGPoint(x: insetBounds.minX, y: insetBounds.maxY),
                CGPoint(x: insetBounds.midX, y: insetBounds.maxY),
                CGPoint(x: insetBounds.maxX, y: insetBounds.maxY)
            ]
            context.setLineDash(phase: 0, lengths: [])
            context.setFillColor(UIColor.white.cgColor)
            context.setStrokeColor(UIColor.systemBlue.cgColor)
            context.setLineWidth(1.5)

            for p in handlePoints {
                let handleRect = CGRect(x: p.x - handleSize * 0.5,
                                        y: p.y - handleSize * 0.5,
                                        width: handleSize,
                                        height: handleSize)
                context.fill(handleRect)
                context.stroke(handleRect)
            }
        }

        context.restoreGState()
    }
}
