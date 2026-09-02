import UIKit

/// Deterministic Core Graphics export for the retained-stroke document model.
/// Export is deliberately independent of MTKView readback so it works when the
/// canvas is offscreen and can render every page without changing selection.
enum DocumentExportService {
    private static let paperColor = UIColor(red: 0.965, green: 0.935, blue: 0.865, alpha: 1)
    private static let maximumDimension: CGFloat = 8_192
    private static let maximumPixels: CGFloat = 64 * 1_024 * 1_024

    static func pngData(strokes: [DTRenderStroke], canvasSize: CGSize) -> Data? {
        guard let size = validated(canvasSize) else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { context in
            drawPage(strokes: strokes, size: size, context: context.cgContext)
        }.pngData()
    }

    static func pdfData(pages: [[DTRenderStroke]], canvasSize: CGSize) -> Data? {
        guard let size = validated(canvasSize), !pages.isEmpty else { return nil }
        let bounds = CGRect(origin: .zero, size: size)
        return UIGraphicsPDFRenderer(bounds: bounds).pdfData { rendererContext in
            for strokes in pages {
                rendererContext.beginPage()
                drawPage(strokes: strokes, size: size, context: rendererContext.cgContext)
            }
        }
    }

    private static func validated(_ size: CGSize) -> CGSize? {
        guard size.width.isFinite, size.height.isFinite,
              size.width >= 1, size.height >= 1,
              size.width <= maximumDimension, size.height <= maximumDimension,
              size.width * size.height <= maximumPixels else { return nil }
        return CGSize(width: floor(size.width), height: floor(size.height))
    }

    private static func drawPage(strokes: [DTRenderStroke],
                                 size: CGSize,
                                 context: CGContext) {
        context.saveGState()
        context.setFillColor(paperColor.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        context.setLineCap(.round)
        context.setLineJoin(.round)

        for stroke in strokes {
            let points = renderPoints(stroke.points)
            guard !points.isEmpty else { continue }
            let color = stroke.tool == .eraser
                ? paperColor
                : decodedColor(stroke.brushColorRGBA, opacity: stroke.brushOpacity)
            context.setStrokeColor(color.cgColor)
            context.setFillColor(color.cgColor)

            switch stroke.tool {
            case .line:
                guard let first = points.first, let last = points.last else { continue }
                drawLine(from: first, to: last, width: stroke.brushSize, context: context)
            case .rectangle:
                guard let first = points.first, let last = points.last else { continue }
                context.setLineWidth(max(1, stroke.brushSize))
                context.stroke(standardizedRect(first, last))
            case .ellipse:
                guard let first = points.first, let last = points.last else { continue }
                context.setLineWidth(max(1, stroke.brushSize))
                context.strokeEllipse(in: standardizedRect(first, last))
            default:
                drawPressurePolyline(points, baseWidth: stroke.brushSize, context: context)
            }
        }
        context.restoreGState()
    }

    private static func renderPoints(_ values: [NSValue]) -> [DTRenderPoint] {
        let decoded: [DTRenderPoint] = values.map { value in
            var point = DTRenderPoint()
            value.getValue(&point)
            return point
        }
        let real = decoded.filter { $0.predicted == 0 }
        return real.isEmpty ? decoded : real
    }

    private static func decodedColor(_ packed: UInt32, opacity: CGFloat) -> UIColor {
        let red = CGFloat((packed >> 24) & 0xff) / 255
        let green = CGFloat((packed >> 16) & 0xff) / 255
        let blue = CGFloat((packed >> 8) & 0xff) / 255
        let alpha = CGFloat(packed & 0xff) / 255
        return UIColor(red: red, green: green, blue: blue,
                       alpha: min(max(alpha * opacity, 0), 1))
    }

    private static func standardizedRect(_ first: DTRenderPoint,
                                         _ last: DTRenderPoint) -> CGRect {
        CGRect(x: CGFloat(first.x), y: CGFloat(first.y),
               width: CGFloat(last.x - first.x), height: CGFloat(last.y - first.y)).standardized
    }

    private static func drawLine(from first: DTRenderPoint,
                                 to last: DTRenderPoint,
                                 width: CGFloat,
                                 context: CGContext) {
        context.setLineWidth(max(1, width))
        context.beginPath()
        context.move(to: CGPoint(x: CGFloat(first.x), y: CGFloat(first.y)))
        context.addLine(to: CGPoint(x: CGFloat(last.x), y: CGFloat(last.y)))
        context.strokePath()
    }

    private static func drawPressurePolyline(_ points: [DTRenderPoint],
                                             baseWidth: CGFloat,
                                             context: CGContext) {
        guard let first = points.first else { return }
        if points.count == 1 {
            let radius = max(0.5, baseWidth * pressureScale(first.pressure) * 0.5)
            context.fillEllipse(in: CGRect(x: CGFloat(first.x) - radius,
                                           y: CGFloat(first.y) - radius,
                                           width: radius * 2, height: radius * 2))
            return
        }
        for (start, end) in zip(points, points.dropFirst()) {
            let pressure = (pressureScale(start.pressure) + pressureScale(end.pressure)) * 0.5
            drawLine(from: start, to: end, width: max(1, baseWidth * pressure), context: context)
        }
    }

    private static func pressureScale(_ pressure: Float) -> CGFloat {
        let value = min(max(CGFloat(pressure), 0), 1)
        return 0.2 + 0.8 * value
    }
}
