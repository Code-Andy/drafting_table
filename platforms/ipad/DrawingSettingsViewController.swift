import UIKit

/// Settings presented from the canvas rail. Values are intentionally kept in
/// UserDefaults so a screen protector or preferred brush feel survives relaunch.
final class DrawingSettingsViewController: UIViewController {
    static let activationKey = "draftingTable.penActivationPressure"
    static let brushSizeKey = "draftingTable.brushSize"
    static let brushOpacityKey = "draftingTable.brushOpacity"

    var onActivationChanged: ((CGFloat) -> Void)?
    var onBrushSizeChanged: ((CGFloat) -> Void)?
    var onBrushOpacityChanged: ((CGFloat) -> Void)?

    private let activationSlider = UISlider()
    private let sizeSlider = UISlider()
    private let opacitySlider = UISlider()
    private let activationValue = UILabel()
    private let sizeValue = UILabel()
    private let opacityValue = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Settings"
        view.backgroundColor = UIColor(red: 0.985, green: 0.975, blue: 0.945, alpha: 1)
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done,
                                                              primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        configureControls()
    }

    private func configureControls() {
        let defaults = UserDefaults.standard
        let activation = min(max(storedFloat(defaults, key: Self.activationKey, fallback: 3), 0), 20)
        let size = min(max(storedFloat(defaults, key: Self.brushSizeKey, fallback: 8), 1), 40)
        let opacity = min(max(storedFloat(defaults, key: Self.brushOpacityKey, fallback: 100), 5), 100)

        configureSlider(activationSlider, min: 0, max: 20, value: activation,
                        label: "Pen activation", hint: "Higher values ignore lighter contact and screen-protector noise.",
                        action: #selector(activationChanged(_:)))
        configureSlider(sizeSlider, min: 1, max: 40, value: size,
                        label: "Brush size", hint: "Brush diameter in points.",
                        action: #selector(sizeChanged(_:)))
        configureSlider(opacitySlider, min: 5, max: 100, value: opacity,
                        label: "Brush opacity", hint: "Opacity of new brush strokes.",
                        action: #selector(opacityChanged(_:)))
        updateLabels()

        let stack = UIStackView(arrangedSubviews: [
            sectionTitle("PENCIL & BRUSH"),
            settingRow(title: "Pen activation", detail: "Start drawing only after this pressure threshold.", slider: activationSlider, value: activationValue),
            settingRow(title: "Brush size", detail: "Set the diameter of new brush strokes.", slider: sizeSlider, value: sizeValue),
            settingRow(title: "Brush opacity", detail: "Set the opacity of new brush strokes.", slider: opacitySlider, value: opacityValue),
            infoLabel()
        ])
        stack.axis = .vertical
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        scroll.addSubview(stack)
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -28),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -48)
        ])
    }

    private func storedFloat(_ defaults: UserDefaults, key: String, fallback: Float) -> Float {
        defaults.object(forKey: key) == nil ? fallback : defaults.float(forKey: key)
    }

    private func configureSlider(_ slider: UISlider, min: Float, max: Float, value: Float,
                                 label: String, hint: String, action: Selector) {
        slider.minimumValue = min
        slider.maximumValue = max
        slider.value = value
        slider.isContinuous = true
        slider.addTarget(self, action: action, for: .valueChanged)
        slider.accessibilityLabel = label
        slider.accessibilityHint = hint
    }

    private func settingRow(title: String, detail: String, slider: UISlider, value: UILabel) -> UIView {
        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = UIColor(red: 0.16, green: 0.14, blue: 0.11, alpha: 1)
        let detailLabel = UILabel()
        detailLabel.text = detail
        detailLabel.font = .systemFont(ofSize: 13)
        detailLabel.textColor = .secondaryLabel
        detailLabel.numberOfLines = 0
        value.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        value.textColor = .secondaryLabel
        value.textAlignment = .right
        let header = UIStackView(arrangedSubviews: [titleLabel, value])
        header.axis = .horizontal
        header.alignment = .firstBaseline
        let stack = UIStackView(arrangedSubviews: [header, detailLabel, slider])
        stack.axis = .vertical
        stack.spacing = 5
        return stack
    }

    private func sectionTitle(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 12, weight: .bold)
        label.textColor = .secondaryLabel
        return label
    }

    private func infoLabel() -> UILabel {
        let label = UILabel()
        label.text = "Lower activation responds to a lighter touch. Brush settings apply to new strokes."
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        label.accessibilityLabel = label.text
        return label
    }

    @objc private func activationChanged(_ sender: UISlider) {
        let value = min(max(sender.value, 0), 20)
        sender.value = value
        UserDefaults.standard.set(value, forKey: Self.activationKey)
        updateLabels()
        onActivationChanged?(CGFloat(value / 100))
    }

    @objc private func sizeChanged(_ sender: UISlider) {
        let value = min(max(sender.value, 1), 40)
        sender.value = value
        UserDefaults.standard.set(value, forKey: Self.brushSizeKey)
        updateLabels()
        onBrushSizeChanged?(CGFloat(value))
    }

    @objc private func opacityChanged(_ sender: UISlider) {
        let value = min(max(sender.value, 5), 100)
        sender.value = value
        UserDefaults.standard.set(value, forKey: Self.brushOpacityKey)
        updateLabels()
        onBrushOpacityChanged?(CGFloat(value / 100))
    }

    private func updateLabels() {
        activationValue.text = String(format: "%.0f%%", activationSlider.value)
        sizeValue.text = String(format: "%.0f pt", sizeSlider.value)
        opacityValue.text = String(format: "%.0f%%", opacitySlider.value)
        activationSlider.accessibilityValue = activationValue.text
        sizeSlider.accessibilityValue = sizeValue.text
        opacitySlider.accessibilityValue = opacityValue.text
    }
}
