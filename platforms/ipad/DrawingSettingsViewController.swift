import UIKit

/// Settings presented from the canvas rail. Values are intentionally kept in
/// UserDefaults so a screen protector or preferred brush feel survives relaunch.
final class DrawingSettingsViewController: UIViewController {
    static let activationKey = "draftingTable.penActivationPressure"
    static let brushSizeKey = "draftingTable.brushSize"
    static let brushOpacityKey = "draftingTable.brushOpacity"
    static let brushHardnessKey = "draftingTable.brushHardness"
    static let brushColorKey = "draftingTable.brushColorRGBA"
    static let gridKey = "draftingTable.gridVisible"
    static let showDiagnosticsKey = "draftingTable.showDiagnostics"
    static let shapeCenterModeKey = "draftingTable.shapeCenterMode"
    static let transparentExportKey = "draftingTable.transparentExport"
    static let defaultBrushColorRGBA: UInt32 = 0x1B1712FF

    var onActivationChanged: ((CGFloat) -> Void)?
    var onBrushSizeChanged: ((CGFloat) -> Void)?
    var onBrushOpacityChanged: ((CGFloat) -> Void)?
    var onBrushHardnessChanged: ((CGFloat) -> Void)?
    var onBrushColorChanged: ((UInt32) -> Void)?
    var onGridChanged: ((Bool) -> Void)?
    var onDiagnosticsChanged: ((Bool) -> Void)?
    var onShapeCenterModeChanged: ((Bool) -> Void)?
    var onTransparentExportChanged: ((Bool) -> Void)?

    private let activationSlider = UISlider()
    private let sizeSlider = UISlider()
    private let opacitySlider = UISlider()
    private let hardnessSlider = UISlider()
    private let colorWell = UIColorWell()
    private let gridSwitch = UISwitch()
    private let diagnosticsSwitch = UISwitch()
    private let centerModeSwitch = UISwitch()
    private let transparentExportSwitch = UISwitch()
    private let activationValue = UILabel()
    private let sizeValue = UILabel()
    private let opacityValue = UILabel()
    private let hardnessValue = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "SETTINGS"
        view.backgroundColor = DraftingTheme.paper
        let navAppearance = UINavigationBarAppearance()
        navAppearance.configureWithOpaqueBackground()
        navAppearance.backgroundColor = DraftingTheme.paperDeep
        navAppearance.shadowColor = DraftingTheme.rule
        navAppearance.titleTextAttributes = [
            .font: DraftingTheme.mono(size: 11, weight: .semibold),
            .foregroundColor: DraftingTheme.ink
        ]
        navigationController?.navigationBar.standardAppearance = navAppearance
        navigationController?.navigationBar.scrollEdgeAppearance = navAppearance
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
        let hardness = min(max(storedFloat(defaults, key: Self.brushHardnessKey, fallback: 80), 0), 100)
        let colorRGBA = storedUInt32(defaults, key: Self.brushColorKey,
                                     fallback: Self.defaultBrushColorRGBA)

        configureSlider(activationSlider, min: 0, max: 20, value: activation,
                        label: "activate", hint: "Higher values ignore lighter contact and screen-protector noise.",
                        action: #selector(activationChanged(_:)))
        configureSlider(sizeSlider, min: 1, max: 40, value: size,
                        label: "size", hint: "Brush diameter in points.",
                        action: #selector(sizeChanged(_:)))
        configureSlider(opacitySlider, min: 5, max: 100, value: opacity,
                        label: "α", hint: "Opacity of new brush strokes.",
                        action: #selector(opacityChanged(_:)))
        configureSlider(hardnessSlider, min: 0, max: 100, value: hardness,
                        label: "hard", hint: "Controls edge softness for new brush strokes.",
                        action: #selector(hardnessChanged(_:)))
        colorWell.selectedColor = Self.uiColor(from: colorRGBA)
        colorWell.supportsAlpha = true
        colorWell.accessibilityLabel = "Brush color"
        colorWell.addTarget(self, action: #selector(colorChanged(_:)), for: .valueChanged)
        gridSwitch.isOn = defaults.bool(forKey: Self.gridKey)
        gridSwitch.accessibilityLabel = "Show grid"
        gridSwitch.addTarget(self, action: #selector(gridChanged(_:)), for: .valueChanged)

        diagnosticsSwitch.isOn = defaults.bool(forKey: Self.showDiagnosticsKey)
        diagnosticsSwitch.accessibilityLabel = "Show diagnostics overlay"
        diagnosticsSwitch.addTarget(self, action: #selector(diagnosticsChanged(_:)), for: .valueChanged)

        centerModeSwitch.isOn = defaults.bool(forKey: Self.shapeCenterModeKey)
        centerModeSwitch.accessibilityLabel = "Center-out circle and ellipse"
        centerModeSwitch.addTarget(self, action: #selector(centerModeChanged(_:)), for: .valueChanged)

        transparentExportSwitch.isOn = defaults.bool(forKey: Self.transparentExportKey)
        transparentExportSwitch.accessibilityLabel = "Transparent PNG export"
        transparentExportSwitch.addTarget(self, action: #selector(transparentExportChanged(_:)), for: .valueChanged)

        updateLabels()

        let stack = UIStackView(arrangedSubviews: [
            sectionTitle("PENCIL & BRUSH"),
            settingRow(title: "size", detail: "Set the diameter of new brush strokes.", slider: sizeSlider, value: sizeValue),
            settingRow(title: "α", detail: "Set the opacity of new brush strokes.", slider: opacitySlider, value: opacityValue),
            settingRow(title: "hard", detail: "Soft edges blend naturally; hard edges stay crisp.", slider: hardnessSlider, value: hardnessValue),
            colorRow(),
            sectionTitle("CANVAS & INTERACTION"),
            switchRow(title: "grid", detail: "Show a drafting grid over the page.", control: gridSwitch),
            sectionTitle("DIAGNOSTICS & DEBUG"),
            switchRow(title: "diagnostics", detail: "Show FPS, latency, hover coordinates, and touch count.", control: diagnosticsSwitch),
            infoLabel()
        ])
        stack.axis = .vertical
        stack.spacing = 0
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
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -18),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -36)
        ])
    }

    private func storedFloat(_ defaults: UserDefaults, key: String, fallback: Float) -> Float {
        defaults.object(forKey: key) == nil ? fallback : defaults.float(forKey: key)
    }

    private func storedUInt32(_ defaults: UserDefaults, key: String, fallback: UInt32) -> UInt32 {
        guard let number = defaults.object(forKey: key) as? NSNumber else { return fallback }
        let value = number.int64Value
        guard value >= 0, UInt64(value) <= UInt64(UInt32.max) else { return fallback }
        return UInt32(value)
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
        slider.minimumTrackTintColor = DraftingTheme.hot
        slider.maximumTrackTintColor = DraftingTheme.rule
        slider.thumbTintColor = DraftingTheme.ink
    }

    private func settingRow(title: String, detail: String, slider: UISlider, value: UILabel) -> UIView {
        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = DraftingTheme.mono(size: 11)
        titleLabel.textColor = DraftingTheme.inkSoft
        titleLabel.accessibilityLabel = title
        titleLabel.accessibilityHint = detail
        value.font = DraftingTheme.mono(size: 11, weight: .semibold)
        value.textColor = DraftingTheme.ink
        value.textAlignment = .right
        let row = UIStackView(arrangedSubviews: [titleLabel, slider, value])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8
        row.isLayoutMarginsRelativeArrangement = true
        row.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10)
        titleLabel.widthAnchor.constraint(equalToConstant: 54).isActive = true
        value.widthAnchor.constraint(equalToConstant: 44).isActive = true
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true
        return row
    }

    private func sectionTitle(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = DraftingTheme.mono(size: 10, weight: .semibold)
        label.textColor = DraftingTheme.ink
        label.backgroundColor = DraftingTheme.paperDeep
        label.layer.borderWidth = 1
        label.layer.borderColor = DraftingTheme.rule.cgColor
        label.textAlignment = .left
        label.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return label
    }

    private func infoLabel() -> UILabel {
        let label = UILabel()
        label.text = "activate: higher values ignore lighter touch. Settings apply to new strokes."
        label.font = DraftingTheme.mono(size: 9)
        label.textColor = DraftingTheme.inkFaint
        label.numberOfLines = 0
        label.accessibilityLabel = label.text
        label.isAccessibilityElement = true
        label.heightAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true
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

    @objc private func hardnessChanged(_ sender: UISlider) {
        let value = min(max(sender.value, 0), 100)
        sender.value = value
        UserDefaults.standard.set(value, forKey: Self.brushHardnessKey)
        updateLabels()
        onBrushHardnessChanged?(CGFloat(value / 100))
    }

    @objc private func colorChanged(_ sender: UIColorWell) {
        let packed = Self.rgba(from: sender.selectedColor ?? Self.uiColor(from: Self.defaultBrushColorRGBA))
        UserDefaults.standard.set(Int(packed), forKey: Self.brushColorKey)
        onBrushColorChanged?(packed)
    }

    @objc private func gridChanged(_ sender: UISwitch) {
        UserDefaults.standard.set(sender.isOn, forKey: Self.gridKey)
        onGridChanged?(sender.isOn)
    }

    @objc private func diagnosticsChanged(_ sender: UISwitch) {
        UserDefaults.standard.set(sender.isOn, forKey: Self.showDiagnosticsKey)
        onDiagnosticsChanged?(sender.isOn)
    }

    @objc private func centerModeChanged(_ sender: UISwitch) {
        UserDefaults.standard.set(sender.isOn, forKey: Self.shapeCenterModeKey)
        onShapeCenterModeChanged?(sender.isOn)
    }

    @objc private func transparentExportChanged(_ sender: UISwitch) {
        UserDefaults.standard.set(sender.isOn, forKey: Self.transparentExportKey)
        onTransparentExportChanged?(sender.isOn)
    }

    private func updateLabels() {
        activationValue.text = String(format: "%.0f%%", activationSlider.value)
        sizeValue.text = String(format: "%.0f pt", sizeSlider.value)
        opacityValue.text = String(format: "%.0f%%", opacitySlider.value)
        hardnessValue.text = String(format: "%.0f%%", hardnessSlider.value)
        activationSlider.accessibilityValue = activationValue.text
        sizeSlider.accessibilityValue = sizeValue.text
        opacitySlider.accessibilityValue = opacityValue.text
        hardnessSlider.accessibilityValue = hardnessValue.text
    }

    private func colorRow() -> UIView {
        let label = UILabel()
        label.text = "color"
        label.font = DraftingTheme.mono(size: 11)
        label.textColor = DraftingTheme.inkSoft
        label.widthAnchor.constraint(equalToConstant: 54).isActive = true
        colorWell.widthAnchor.constraint(equalToConstant: 28).isActive = true
        colorWell.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let paletteButton = UIButton(type: .system)
        paletteButton.setTitle("palette…", for: .normal)
        paletteButton.tintColor = DraftingTheme.ink
        paletteButton.setTitleColor(DraftingTheme.ink, for: .normal)
        paletteButton.titleLabel?.font = DraftingTheme.mono(size: 11, weight: .semibold)
        paletteButton.contentHorizontalAlignment = .leading
        paletteButton.contentEdgeInsets = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        paletteButton.backgroundColor = DraftingTheme.paper
        paletteButton.layer.borderWidth = 1
        paletteButton.layer.borderColor = DraftingTheme.rule.cgColor
        paletteButton.accessibilityLabel = "Open color palette"
        paletteButton.addTarget(self, action: #selector(openPalette), for: .touchUpInside)
        let row = UIStackView(arrangedSubviews: [label, colorWell, paletteButton, UIView()])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8
        row.isLayoutMarginsRelativeArrangement = true
        row.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10)
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        return row
    }

    @objc private func openPalette() {
        let picker = ColorPickerViewController()
        picker.initialColorRGBA = Self.rgba(from: colorWell.selectedColor ?? Self.uiColor(from: Self.defaultBrushColorRGBA))
        picker.onColorChanged = { [weak self] packed in self?.applyPickedColor(packed) }
        picker.onColorPicked = { [weak self] packed in self?.applyPickedColor(packed) }
        picker.onEyedropperRequested = { [weak self] in
            self?.dismiss(animated: true)
            self?.onEyedropperToast?()
        }
        let navigation = UINavigationController(rootViewController: picker)
        navigation.modalPresentationStyle = .formSheet
        present(navigation, animated: true)
    }

    /// Fired when the picker asks for the eyedropper (no pixel sampler yet).
    var onEyedropperToast: (() -> Void)?

    private func applyPickedColor(_ packed: UInt32) {
        colorWell.selectedColor = Self.uiColor(from: packed)
        UserDefaults.standard.set(Int(packed), forKey: Self.brushColorKey)
        onBrushColorChanged?(packed)
    }

    private func switchRow(title: String, detail: String, control: UISwitch) -> UIView {
        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = DraftingTheme.mono(size: 11)
        titleLabel.textColor = DraftingTheme.inkSoft
        titleLabel.accessibilityLabel = title
        titleLabel.accessibilityHint = detail
        control.onTintColor = DraftingTheme.hot
        control.tintColor = DraftingTheme.inkFaint
        let row = UIStackView(arrangedSubviews: [titleLabel, UIView(), control])
        row.axis = .horizontal
        row.alignment = .center
        row.isLayoutMarginsRelativeArrangement = true
        row.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10)
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        return row
    }

    static func uiColor(from packed: UInt32) -> UIColor {
        UIColor(red: CGFloat((packed >> 24) & 0xff) / 255,
                green: CGFloat((packed >> 16) & 0xff) / 255,
                blue: CGFloat((packed >> 8) & 0xff) / 255,
                alpha: CGFloat(packed & 0xff) / 255)
    }

    static func rgba(from color: UIColor) -> UInt32 {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else {
            return defaultBrushColorRGBA
        }
        return (UInt32(r * 255 + 0.5) << 24) | (UInt32(g * 255 + 0.5) << 16) |
            (UInt32(b * 255 + 0.5) << 8) | UInt32(a * 255 + 0.5)
    }
}
