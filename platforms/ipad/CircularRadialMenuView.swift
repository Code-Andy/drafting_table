import UIKit

/// Radial contextual tool wheel for Apple Pencil Pro squeeze gestures.
/// Displays tools arranged circularly around the pencil tip / hover point on the glass,
/// replacing the fallback action sheet menu tab with a fluid, native radial experience.
final class CircularRadialMenuView: UIView {
    enum RadialAction: Equatable {
        case selectTool(DTTool)
        case openColorPicker
        case undo
    }

    var onAction: ((RadialAction) -> Void)?

    private struct RadialItem {
        let title: String
        let systemImage: String
        let action: RadialAction
        let tool: DTTool?
    }

    private let menuDiameter: CGFloat = 260.0
    private let innerRadius: CGFloat = 85.0
    private let itemSize: CGFloat = 40.0
    private var itemButtons: [UIButton] = []
    private var items: [RadialItem] = []
    private let centerDisc = UIView()
    private let centerIconView = UIImageView()
    private let centerTitleLabel = UILabel()
    private let activeTool: DTTool
    private let activeColor: UIColor

    init(activeTool: DTTool, activeColor: UIColor) {
        self.activeTool = activeTool
        self.activeColor = activeColor
        super.init(frame: CGRect(x: 0, y: 0, width: menuDiameter, height: menuDiameter))
        configureItems()
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configureItems() {
        items = [
            RadialItem(title: "Brush", systemImage: "pencil.tip", action: .selectTool(.brush), tool: .brush),
            RadialItem(title: "Eraser", systemImage: "eraser", action: .selectTool(.eraser), tool: .eraser),
            RadialItem(title: "Bucket", systemImage: "drop.fill", action: .selectTool(.bucket), tool: .bucket),
            RadialItem(title: "Shade", systemImage: "skew", action: .selectTool(.shade), tool: .shade),
            RadialItem(title: "Line", systemImage: "line.diagonal", action: .selectTool(.line), tool: .line),
            RadialItem(title: "Rect", systemImage: "rectangle", action: .selectTool(.rectangle), tool: .rectangle),
            RadialItem(title: "Circle", systemImage: "circle", action: .selectTool(.circle), tool: .circle),
            RadialItem(title: "Ellipse", systemImage: "oval", action: .selectTool(.ellipse), tool: .ellipse),
            RadialItem(title: "Select", systemImage: "rectangle.dashed", action: .selectTool(.select), tool: .select),
            RadialItem(title: "Lasso", systemImage: "lasso", action: .selectTool(.lasso), tool: .lasso),
            RadialItem(title: "Color", systemImage: "circle.fill", action: .openColorPicker, tool: nil),
            RadialItem(title: "Undo", systemImage: "arrow.uturn.backward", action: .undo, tool: nil)
        ]
    }

    private func setupUI() {
        backgroundColor = .clear
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.22
        layer.shadowRadius = 14
        layer.shadowOffset = CGSize(width: 0, height: 4)

        // Frosted radial backdrop
        let blur = UIBlurEffect(style: .systemUltraThinMaterialLight)
        let blurView = UIVisualEffectView(effect: blur)
        blurView.frame = bounds
        blurView.layer.cornerRadius = menuDiameter * 0.5
        blurView.layer.masksToBounds = true
        blurView.layer.borderWidth = 1.5
        blurView.layer.borderColor = UIColor(red: 0.38, green: 0.33, blue: 0.25, alpha: 0.28).cgColor
        addSubview(blurView)

        // Subtle warm paper gradient ring
        let ringLayer = CAShapeLayer()
        let ringPath = UIBezierPath(ovalIn: bounds.insetBy(dx: 3, dy: 3))
        ringLayer.path = ringPath.cgPath
        ringLayer.fillColor = UIColor(red: 0.98, green: 0.96, blue: 0.92, alpha: 0.72).cgColor
        ringLayer.strokeColor = UIColor(red: 0.35, green: 0.30, blue: 0.22, alpha: 0.18).cgColor
        ringLayer.lineWidth = 1.0
        layer.insertSublayer(ringLayer, above: blurView.layer)

        // Center preview disc
        let centerSize: CGFloat = 62.0
        centerDisc.frame = CGRect(x: (menuDiameter - centerSize) * 0.5,
                                  y: (menuDiameter - centerSize) * 0.5,
                                  width: centerSize, height: centerSize)
        centerDisc.layer.cornerRadius = centerSize * 0.5
        centerDisc.backgroundColor = UIColor(red: 0.94, green: 0.91, blue: 0.85, alpha: 0.92)
        centerDisc.layer.borderWidth = 1.5
        centerDisc.layer.borderColor = UIColor(red: 0.38, green: 0.33, blue: 0.25, alpha: 0.35).cgColor
        addSubview(centerDisc)

        centerIconView.frame = CGRect(x: (centerSize - 22) * 0.5, y: 12, width: 22, height: 22)
        centerIconView.contentMode = .scaleAspectFit
        centerIconView.tintColor = DraftingTheme.ink
        centerDisc.addSubview(centerIconView)

        centerTitleLabel.frame = CGRect(x: 2, y: 36, width: centerSize - 4, height: 16)
        centerTitleLabel.font = .systemFont(ofSize: 10, weight: .bold)
        centerTitleLabel.textColor = DraftingTheme.inkSoft
        centerTitleLabel.textAlignment = .center
        centerDisc.addSubview(centerTitleLabel)

        updateCenterPreview(tool: activeTool)

        // Position item buttons circularly
        let count = items.count
        let center = CGPoint(x: menuDiameter * 0.5, y: menuDiameter * 0.5)

        for (index, item) in items.enumerated() {
            let angle = (CGFloat(index) / CGFloat(count)) * (2.0 * .pi) - (.pi / 2.0)
            let itemX = center.x + innerRadius * cos(angle) - (itemSize * 0.5)
            let itemY = center.y + innerRadius * sin(angle) - (itemSize * 0.5)

            let button = UIButton(type: .system)
            button.frame = CGRect(x: itemX, y: itemY, width: itemSize, height: itemSize)
            button.layer.cornerRadius = itemSize * 0.5
            button.tag = index

            let isSelected = item.tool == activeTool
            button.backgroundColor = isSelected
                ? UIColor.systemBlue.withAlphaComponent(0.20)
                : UIColor.white.withAlphaComponent(0.85)
            button.layer.borderWidth = isSelected ? 2.0 : 1.0
            button.layer.borderColor = isSelected
                ? UIColor.systemBlue.cgColor
                : UIColor(red: 0.38, green: 0.33, blue: 0.25, alpha: 0.22).cgColor

            let cfg = UIImage.SymbolConfiguration(pointSize: 15, weight: isSelected ? .bold : .medium)
            button.setImage(UIImage(systemName: item.systemImage, withConfiguration: cfg), for: .normal)
            if item.action == .openColorPicker {
                button.tintColor = activeColor
            } else {
                button.tintColor = isSelected ? .systemBlue : DraftingTheme.ink
            }

            button.addTarget(self, action: #selector(itemTapped(_:)), for: .touchUpInside)
            addSubview(button)
            itemButtons.append(button)
        }
    }

    private func updateCenterPreview(tool: DTTool) {
        let item = items.first(where: { $0.tool == tool }) ?? items[0]
        let cfg = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        centerIconView.image = UIImage(systemName: item.systemImage, withConfiguration: cfg)
        centerTitleLabel.text = item.title
    }

    @objc private func itemTapped(_ sender: UIButton) {
        let idx = sender.tag
        guard idx >= 0 && idx < items.count else { return }
        let item = items[idx]
        HapticFeedbackService.shared.toolSwitched()
        dismiss(animated: true) { [weak self] in
            self?.onAction?(item.action)
        }
    }

    func present(in parentView: UIView, around point: CGPoint) {
        let half = menuDiameter * 0.5
        let safeMargin: CGFloat = 12.0
        let clampedX = min(max(point.x, half + safeMargin), parentView.bounds.width - half - safeMargin)
        let clampedY = min(max(point.y, half + safeMargin), parentView.bounds.height - half - safeMargin)

        center = CGPoint(x: clampedX, y: clampedY)
        transform = CGAffineTransform(scaleX: 0.15, y: 0.15)
        alpha = 0.0

        let dismissOverlay = UIView(frame: parentView.bounds)
        dismissOverlay.backgroundColor = .clear
        dismissOverlay.tag = 88192
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleOutsideTap))
        dismissOverlay.addGestureRecognizer(tap)
        parentView.addSubview(dismissOverlay)

        parentView.addSubview(self)

        HapticFeedbackService.shared.squeeze()

        UIView.animate(withDuration: 0.28, delay: 0, usingSpringWithDamping: 0.72, initialSpringVelocity: 0.8, options: .curveEaseOut) {
            self.transform = .identity
            self.alpha = 1.0
        }
    }

    @objc private func handleOutsideTap() {
        dismiss(animated: true, completion: nil)
    }

    func dismiss(animated: Bool, completion: (() -> Void)?) {
        superview?.viewWithTag(88192)?.removeFromSuperview()
        if animated {
            UIView.animate(withDuration: 0.18, delay: 0, options: .curveEaseIn, animations: {
                self.transform = CGAffineTransform(scaleX: 0.2, y: 0.2)
                self.alpha = 0.0
            }) { _ in
                self.removeFromSuperview()
                completion?()
            }
        } else {
            self.removeFromSuperview()
            completion?()
        }
    }
}
