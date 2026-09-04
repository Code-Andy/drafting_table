import UIKit

/// HSV color picker mirroring the original app's picker dialog: HSV square,
/// hue slider, HEX/RGB readout, the shared drafting palette, LRU recents,
/// and long-press user slots. Colors cross the bridge as 0xRRGGBBAA; the
/// picker itself stays opaque (brush opacity remains a separate slider),
/// matching the original.
final class ColorPickerViewController: UIViewController {
    static let recentsKey = "draftingTable.colorRecents"
    static let slotsKey = "draftingTable.colorSlots"
    private static let maximumRecents = 8
    private static let slotCount = 4

    /// The upstream 32-cell drafting palette (4 rows x 8): deep hues,
    /// standard chromatics, mid-light tints, pale neutrals. Stored as
    /// 0xRRGGBB to match the original source.
    static let defaultPalette: [UInt32] = [
        0x000000, 0x6E2218, 0x8A3F0F, 0x886C18,
        0x3D5E26, 0x195049, 0x1A3D60, 0x4A2A65,
        0x1A1A1A, 0xB5482E, 0xC77A1F, 0xC8A030,
        0x5A8C3A, 0x2F7E78, 0x2A5D8F, 0x6B3A8A,
        0x6E6457, 0xC07A60, 0xD0A270, 0xCAB870,
        0x95B070, 0x6FA59E, 0x6F95C0, 0xA088B5,
        0xFFFFFF, 0x7A7368, 0xA89E8A, 0xD9CFB8,
        0xF2D89A, 0xF2A48F, 0x9DB8D8, 0xC7D2A8
    ]

    var initialColorRGBA: UInt32 = DrawingSettingsViewController.defaultBrushColorRGBA
    var onColorChanged: ((UInt32) -> Void)?
    var onColorPicked: ((UInt32) -> Void)?
    var onEyedropperRequested: (() -> Void)?
    var onDismiss: (() -> Void)?

    private var hue: CGFloat = 0
    private var saturation: CGFloat = 0
    private var value: CGFloat = 0
    private var previousColor: UIColor = .black
    private let square = HSVSquareView()
    private let hueSlider = HueSliderView()
    private let hexField = UITextField()
    private let redField = UITextField()
    private let greenField = UITextField()
    private let blueField = UITextField()
    private let hValue = UILabel()
    private let sValue = UILabel()
    private let vValue = UILabel()
    private let previewSwatch = UIView()
    private var recentsRow: UIStackView!
    private var slotsRow: UIStackView!

    override func viewDidLoad() {
        super.viewDidLoad()
        title = nil
        view.backgroundColor = DraftingTheme.paper
        // The Android picker is an in-content paper dialog. Hide the UIKit
        // navigation chrome so the content header and paper buttons remain
        // the only title/action treatment.
        navigationController?.setNavigationBarHidden(true, animated: false)
        previousColor = Self.uiColor(from: initialColorRGBA)
        adopt(color: previousColor)
        buildLayout()
        refreshAll()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        onDismiss?()
    }

    private func adopt(color: UIColor) {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        guard color.getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return }
        hue = h.isFinite ? h : 0
        saturation = min(max(s, 0), 1)
        value = min(max(b, 0), 1)
    }

    private var currentUIColor: UIColor {
        UIColor(hue: hue, saturation: saturation, brightness: value, alpha: 1)
    }

    private var currentPacked: UInt32 {
        (Self.rgbInt(from: currentUIColor) << 8) | 0xFF
    }

    private func buildLayout() {
        square.onSVChanged = { [weak self] s, v in
            self?.saturation = s
            self?.value = v
            self?.colorDidChange(recordRecent: false)
        }
        square.accessibilityLabel = "Saturation and brightness"
        square.isAccessibilityElement = true
        hueSlider.hue = hue
        hueSlider.accessibilityLabel = "Hue"
        hueSlider.onHueChanged = { [weak self] h in
            self?.hue = h
            self?.colorDidChange(recordRecent: false)
        }
        configureHexField()
        configureRGBField(redField, label: "Red", tag: 0)
        configureRGBField(greenField, label: "Green", tag: 1)
        configureRGBField(blueField, label: "Blue", tag: 2)
        for swatch in [previewSwatch] {
            swatch.layer.cornerRadius = 0
            swatch.layer.borderWidth = 1
            swatch.layer.borderColor = DraftingTheme.rule.cgColor
            swatch.heightAnchor.constraint(equalToConstant: 36).isActive = true
        }
        previewSwatch.accessibilityLabel = "Current color"
        let eyedropper = UIButton(type: .system)
        eyedropper.setTitle("◉  Eyedropper", for: .normal)
        eyedropper.titleLabel?.font = DraftingTheme.mono(size: 12, weight: .semibold)
        eyedropper.setTitleColor(DraftingTheme.ink, for: .normal)
        eyedropper.tintColor = DraftingTheme.ink
        eyedropper.contentHorizontalAlignment = .leading
        eyedropper.contentEdgeInsets = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        eyedropper.addTarget(self, action: #selector(eyedropperTapped), for: .touchUpInside)
        let titleRow = UIStackView(arrangedSubviews: [
            sectionTitle("PICKER"),
            sectionCaption("HSV · square + hue")
        ])
        titleRow.axis = .horizontal
        titleRow.alignment = .firstBaseline
        titleRow.spacing = 8
        titleRow.distribution = .fill

        let hsvRow = UIStackView(arrangedSubviews: [
            readoutCell(label: "H", value: hValue),
            readoutCell(label: "S", value: sValue),
            readoutCell(label: "V", value: vValue)
        ])
        hsvRow.axis = .horizontal
        hsvRow.spacing = 6
        hsvRow.distribution = .fillEqually

        let rgbRow = UIStackView(arrangedSubviews: [
            inputCell(label: "R", field: redField),
            inputCell(label: "G", field: greenField),
            inputCell(label: "B", field: blueField)
        ])
        rgbRow.axis = .horizontal
        rgbRow.spacing = 6
        rgbRow.distribution = .fillEqually

        let buttons = UIStackView(arrangedSubviews: [
            paperButton(title: "Cancel", color: DraftingTheme.ink, action: #selector(cancelAndDismiss)),
            paperButton(title: "Done", color: DraftingTheme.hot, action: #selector(doneAndDismiss))
        ])
        buttons.axis = .horizontal
        buttons.alignment = .center
        buttons.distribution = .fill
        buttons.spacing = 4

        let stack = UIStackView(arrangedSubviews: [
            titleRow, square, hueSlider, hsvRow, labeledRow(label: "HEX", content: hexField),
            rgbRow, sectionCaption("PREVIEW"), previewSwatch, eyedropper,
            sectionTitle("PALETTE"), paletteGrid(),
            sectionTitle("RECENT"), recentsRowPlaceholder(),
            sectionTitle("MY SLOTS"), slotsRowPlaceholder(), buttons
        ])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.backgroundColor = DraftingTheme.paper
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
            stack.widthAnchor.constraint(equalToConstant: 240),
            square.widthAnchor.constraint(equalToConstant: 240),
            square.heightAnchor.constraint(equalToConstant: 240),
            hueSlider.widthAnchor.constraint(equalToConstant: 240),
            hueSlider.heightAnchor.constraint(equalToConstant: 16),
            previewSwatch.widthAnchor.constraint(equalToConstant: 240),
            buttons.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
    }

    private func configureHexField() {
        hexField.placeholder = "#RRGGBB"
        hexField.font = DraftingTheme.mono(size: 12, weight: .semibold)
        hexField.textColor = DraftingTheme.ink
        hexField.tintColor = DraftingTheme.hot
        hexField.backgroundColor = DraftingTheme.paper
        hexField.layer.cornerRadius = 0
        hexField.layer.borderWidth = 1
        hexField.layer.borderColor = DraftingTheme.rule.cgColor
        hexField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        hexField.setContentCompressionResistancePriority(.required, for: .horizontal)
        hexField.contentVerticalAlignment = .center
        hexField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 8, height: 1))
        hexField.leftViewMode = .always
        hexField.autocapitalizationType = .allCharacters
        hexField.autocorrectionType = .no
        hexField.returnKeyType = .done
        hexField.delegate = self
        hexField.accessibilityLabel = "Hex color"
        hexField.addTarget(self, action: #selector(hexEditingEnded), for: .editingDidEnd)
        hexField.addTarget(self, action: #selector(hexEditingEnded), for: .editingDidEndOnExit)
    }

    private func configureRGBField(_ field: UITextField, label: String, tag: Int) {
        field.tag = tag
        field.font = DraftingTheme.mono(size: 12, weight: .semibold)
        field.textColor = DraftingTheme.ink
        field.tintColor = DraftingTheme.hot
        field.backgroundColor = DraftingTheme.paper
        field.layer.cornerRadius = 0
        field.layer.borderWidth = 1
        field.layer.borderColor = DraftingTheme.rule.cgColor
        field.keyboardType = .numberPad
        field.returnKeyType = .done
        field.textAlignment = .left
        field.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 8, height: 1))
        field.leftViewMode = .always
        field.accessibilityLabel = label
        field.addTarget(self, action: #selector(rgbEditingEnded(_:)), for: .editingDidEnd)
    }

    private func sectionCaption(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = DraftingTheme.mono(size: 9)
        label.textColor = DraftingTheme.inkSoft
        label.textAlignment = .right
        label.setContentHuggingPriority(.required, for: .horizontal)
        return label
    }

    private func labeledRow(label: String, content: UIView) -> UIView {
        let row = UIStackView(arrangedSubviews: [sectionCaption(label), content])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8
        return row
    }

    private func readoutCell(label: String, value: UILabel) -> UIView {
        let title = UILabel()
        title.text = label
        title.font = DraftingTheme.mono(size: 9)
        title.textColor = DraftingTheme.inkSoft
        value.font = DraftingTheme.mono(size: 12, weight: .semibold)
        value.textColor = DraftingTheme.ink
        let cell = UIStackView(arrangedSubviews: [title, value])
        cell.axis = .vertical
        cell.spacing = 2
        cell.alignment = .leading
        cell.isLayoutMarginsRelativeArrangement = true
        cell.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)
        cell.backgroundColor = DraftingTheme.paperDeep
        cell.layer.borderWidth = 1
        cell.layer.borderColor = DraftingTheme.rule.cgColor
        return cell
    }

    private func inputCell(label: String, field: UITextField) -> UIView {
        let title = UILabel()
        title.text = label
        title.font = DraftingTheme.mono(size: 9)
        title.textColor = DraftingTheme.inkSoft
        let cell = UIStackView(arrangedSubviews: [title, field])
        cell.axis = .vertical
        cell.spacing = 2
        return cell
    }

    private func paperButton(title: String, color: UIColor, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.setTitleColor(color, for: .normal)
        button.titleLabel?.font = DraftingTheme.mono(size: 12, weight: .semibold)
        button.contentEdgeInsets = UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
        button.backgroundColor = DraftingTheme.paper
        button.layer.cornerRadius = 0
        button.layer.borderWidth = 1
        button.layer.borderColor = DraftingTheme.rule.cgColor
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    private func recentsRowPlaceholder() -> UIView {
        recentsRow = UIStackView()
        recentsRow.axis = .horizontal
        recentsRow.spacing = 2
        return recentsRow
    }

    private func slotsRowPlaceholder() -> UIView {
        slotsRow = UIStackView()
        slotsRow.axis = .horizontal
        slotsRow.spacing = 2
        return slotsRow
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
        label.contentMode = .center
        label.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return label
    }

    private func paletteGrid() -> UIView {
        let grid = UIStackView()
        grid.axis = .vertical
        grid.spacing = 2
        for row in 0..<4 {
            let rowStack = UIStackView()
            rowStack.axis = .horizontal
            rowStack.spacing = 2
            rowStack.distribution = .fill
            for col in 0..<8 {
                let rgb = Self.defaultPalette[row * 8 + col]
                let button = swatchButton(color: Self.uiColor(rgb: rgb), size: 16)
                button.addTarget(self, action: #selector(paletteTapped(_:)), for: .touchUpInside)
                button.tag = Int(rgb)
                rowStack.addArrangedSubview(button)
            }
            grid.addArrangedSubview(rowStack)
        }
        return grid
    }

    private func swatchButton(color: UIColor, size: CGFloat) -> UIButton {
        let button = UIButton(type: .custom)
        button.backgroundColor = color
        button.layer.cornerRadius = 0
        button.layer.borderWidth = 1
        button.layer.borderColor = DraftingTheme.rule.cgColor
        button.heightAnchor.constraint(equalToConstant: size).isActive = true
        button.widthAnchor.constraint(equalTo: button.heightAnchor).isActive = true
        button.accessibilityLabel = "Color swatch"
        return button
    }

    private func refreshAll() {
        square.hue = hue
        square.selectedSaturation = saturation
        square.selectedValue = value
        hueSlider.hue = hue
        previewSwatch.backgroundColor = currentUIColor
        hValue.text = String(format: "%3.0f°", hue * 360)
        sValue.text = String(format: "%3.0f%%", saturation * 100)
        vValue.text = String(format: "%3.0f%%", value * 100)
        let rgb = Self.rgbComponents(from: currentUIColor)
        if !hexField.isFirstResponder { hexField.text = Self.hexString(from: currentUIColor) }
        if !redField.isFirstResponder { redField.text = String(rgb.0) }
        if !greenField.isFirstResponder { greenField.text = String(rgb.1) }
        if !blueField.isFirstResponder { blueField.text = String(rgb.2) }
        refreshRecentsRow()
        refreshSlotsRow()
    }

    private func colorDidChange(recordRecent: Bool) {
        if recordRecent { recordRecentColor(currentPacked) }
        refreshAll()
        onColorChanged?(currentPacked)
    }

    @objc private func paletteTapped(_ sender: UIButton) {
        adopt(color: Self.uiColor(rgb: UInt32(sender.tag)))
        colorDidChange(recordRecent: true)
    }

    @objc private func eyedropperTapped() {
        onEyedropperRequested?()
    }

    @objc private func cancelAndDismiss() {
        dismiss(animated: true)
    }

    @objc private func doneAndDismiss() {
        recordRecentColor(currentPacked)
        onColorPicked?(currentPacked)
        dismiss(animated: true)
    }

    @objc private func hexEditingEnded() {
        guard let text = hexField.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { refreshAll(); return }
        var value = text.uppercased()
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let rgb = UInt32(value, radix: 16) else {
            hexField.text = Self.hexString(from: currentUIColor)
            return
        }
        adopt(color: Self.uiColor(rgb: rgb))
        colorDidChange(recordRecent: true)
    }

    @objc private func rgbEditingEnded(_ sender: UITextField) {
        let values = [redField, greenField, blueField].compactMap { Int($0.text ?? "") }
        guard values.count == 3, values.allSatisfy({ (0...255).contains($0) }) else {
            refreshAll()
            return
        }
        let rgb = (UInt32(values[0]) << 16) | (UInt32(values[1]) << 8) | UInt32(values[2])
        adopt(color: Self.uiColor(rgb: rgb))
        colorDidChange(recordRecent: true)
    }

    private func refreshRecentsRow() {
        recentsRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let recents = storedInts(key: Self.recentsKey)
        if recents.isEmpty {
            let hint = UILabel()
            hint.text = "— none yet —"
            hint.font = DraftingTheme.mono(size: 10)
            hint.textColor = DraftingTheme.inkFaint
            recentsRow.addArrangedSubview(hint)
            return
        }
        for rgb in recents.prefix(Self.maximumRecents) {
            let button = swatchButton(color: Self.uiColor(rgb: UInt32(rgb)), size: 18)
            button.tag = rgb
            button.addTarget(self, action: #selector(paletteTapped(_:)), for: .touchUpInside)
            recentsRow.addArrangedSubview(button)
        }
        let spacer = UIView()
        recentsRow.addArrangedSubview(spacer)
    }

    private func refreshSlotsRow() {
        slotsRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let slots = storedInts(key: Self.slotsKey)
        for index in 0..<Self.slotCount {
            let stored = index < slots.count ? slots[index] : -1
            let button: UIButton
            if stored >= 0 {
                button = swatchButton(color: Self.uiColor(rgb: UInt32(stored)), size: 28)
                button.tag = stored
                button.addTarget(self, action: #selector(paletteTapped(_:)), for: .touchUpInside)
            } else {
                button = UIButton(type: .system)
                button.setTitle("+", for: .normal)
                button.titleLabel?.font = DraftingTheme.mono(size: 16, weight: .regular)
                button.setTitleColor(DraftingTheme.inkSoft, for: .normal)
                button.backgroundColor = DraftingTheme.paperDeep
                button.layer.cornerRadius = 0
                button.layer.borderWidth = 1
                button.layer.borderColor = DraftingTheme.rule.cgColor
                button.heightAnchor.constraint(equalToConstant: 28).isActive = true
                button.widthAnchor.constraint(equalToConstant: 28).isActive = true
            }
            button.accessibilityLabel = "My color slot \(index + 1)"
            button.accessibilityIdentifier = "slot-\(index)"
            let press = UILongPressGestureRecognizer(target: self, action: #selector(slotLongPressed(_:)))
            press.minimumPressDuration = 0.5
            button.addGestureRecognizer(press)
            slotsRow.addArrangedSubview(button)
        }
        let spacer = UIView()
        slotsRow.addArrangedSubview(spacer)
    }

    @objc private func slotLongPressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began,
              let identifier = (gesture.view as? UIButton)?.accessibilityIdentifier,
              identifier.hasPrefix("slot-"),
              let index = Int(identifier.dropFirst(5)),
              index < Self.slotCount else { return }
        var slots = storedInts(key: Self.slotsKey)
        while slots.count < Self.slotCount { slots.append(-1) }
        slots[index] = Int(Self.rgbInt(from: currentUIColor))
        UserDefaults.standard.set(slots, forKey: Self.slotsKey)
        refreshSlotsRow()
    }

    private func recordRecentColor(_ packed: UInt32) {
        let rgb = Int(Self.rgbInt(from: Self.uiColor(from: packed)))
        var recents = storedInts(key: Self.recentsKey).filter { $0 != rgb }
        recents.insert(rgb, at: 0)
        UserDefaults.standard.set(Array(recents.prefix(Self.maximumRecents)), forKey: Self.recentsKey)
    }

    private func storedInts(key: String) -> [Int] {
        (UserDefaults.standard.array(forKey: key) as? [Int]) ?? []
    }

    static func uiColor(rgb: UInt32) -> UIColor {
        UIColor(red: CGFloat((rgb >> 16) & 0xff) / 255,
                green: CGFloat((rgb >> 8) & 0xff) / 255,
                blue: CGFloat(rgb & 0xff) / 255,
                alpha: 1)
    }

    static func uiColor(from packed: UInt32) -> UIColor {
        uiColor(rgb: packed >> 8).withAlphaComponent(CGFloat(packed & 0xff) / 255)
    }

    static func rgbInt(from color: UIColor) -> UInt32 {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return 0 }
        let ri = UInt32(min(max(r, CGFloat(0)), CGFloat(1)) * CGFloat(255) + CGFloat(0.5))
        let gi = UInt32(min(max(g, CGFloat(0)), CGFloat(1)) * CGFloat(255) + CGFloat(0.5))
        let bi = UInt32(min(max(b, CGFloat(0)), CGFloat(1)) * CGFloat(255) + CGFloat(0.5))
        return (ri << 16) | (gi << 8) | bi
    }

    static func hexString(from color: UIColor) -> String {
        String(format: "#%06X", rgbInt(from: color))
    }

    static func rgbString(from color: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return "R –  G –  B –" }
        return String(format: "R %3d  G %3d  B %3d", Int(r * 255 + 0.5), Int(g * 255 + 0.5), Int(b * 255 + 0.5))
    }

    static func rgbComponents(from color: UIColor) -> (Int, Int, Int) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return (0, 0, 0) }
        return (Int(r * 255 + 0.5), Int(g * 255 + 0.5), Int(b * 255 + 0.5))
    }
}

extension ColorPickerViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField === hexField {
            hexEditingEnded()
        } else {
            rgbEditingEnded(textField)
        }
        textField.resignFirstResponder()
        return true
    }
}

/// Saturation/brightness plane for the current hue. Rendered once per hue
/// into a small bitmap; touch maps directly to SV.
private final class HSVSquareView: UIView {
    var hue: CGFloat = 0 { didSet { setNeedsDisplay() } }
    var selectedSaturation: CGFloat = 0 { didSet { setNeedsDisplay() } }
    var selectedValue: CGFloat = 0 { didSet { setNeedsDisplay() } }
    var onSVChanged: ((CGFloat, CGFloat) -> Void)?
    private static let resolution = 120

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        layer.cornerRadius = 0
        layer.borderWidth = 1
        layer.borderColor = DraftingTheme.rule.cgColor
        clipsToBounds = true
        isUserInteractionEnabled = true
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleTouch(_:)))
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTouch(_:)))
        addGestureRecognizer(pan)
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { nil }

    @objc private func handleTouch(_ gesture: UIGestureRecognizer) {
        let point = gesture.location(in: self)
        guard bounds.width > 0, bounds.height > 0 else { return }
        let s = min(max(point.x / bounds.width, 0), 1)
        let v = min(max(1 - point.y / bounds.height, 0), 1)
        onSVChanged?(s, v)
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(),
              rect.width >= 1, rect.height >= 1 else { return }
        let size = Self.resolution
        guard let data = malloc(size * size * 4) else { return }
        defer { free(data) }
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        for y in 0..<size {
            for x in 0..<size {
                let s = CGFloat(x) / CGFloat(size - 1)
                let v = 1 - CGFloat(y) / CGFloat(size - 1)
                let color = UIColor(hue: hue, saturation: s, brightness: v, alpha: 1)
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
                color.getRed(&r, green: &g, blue: &b, alpha: &a)
                let offset = (y * size + x) * 4
                pixels[offset] = UInt8(min(max(r, 0), 1) * 255)
                pixels[offset + 1] = UInt8(min(max(g, 0), 1) * 255)
                pixels[offset + 2] = UInt8(min(max(b, 0), 1) * 255)
                pixels[offset + 3] = 255
            }
        }
        guard let provider = CGDataProvider(dataInfo: nil, data: data,
                                            size: size * size * 4,
                                            releaseData: { _, _, _ in }),
              let image = CGImage(width: size, height: size,
                                  bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: size * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                  provider: provider, decode: nil,
                                  shouldInterpolate: true, intent: .defaultIntent) else { return }
        context.setFillColor(UIColor.black.cgColor)
        context.fill(rect)
        context.draw(image, in: rect)
        let marker = CGPoint(x: selectedSaturation * rect.width,
                             y: (1 - selectedValue) * rect.height)
        context.setStrokeColor(UIColor.white.cgColor)
        context.setLineWidth(2)
        context.strokeEllipse(in: CGRect(x: marker.x - 8, y: marker.y - 8, width: 16, height: 16))
        context.setStrokeColor(UIColor.black.withAlphaComponent(0.4).cgColor)
        context.setLineWidth(1)
        context.strokeEllipse(in: CGRect(x: marker.x - 9, y: marker.y - 9, width: 18, height: 18))
    }
}

/// The upstream picker uses a 240×16 horizontal hue strip with a full
/// spectrum gradient and a small white/ink marker. Keeping it as a UIControl
/// avoids the default iOS slider track/thumb geometry that otherwise makes
/// this dialog look like a system form instead of the paper picker.
private final class HueSliderView: UIControl {
    var hue: CGFloat = 0 { didSet { setNeedsDisplay() } }
    var onHueChanged: ((CGFloat) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = true
        accessibilityTraits = [.adjustable]
    }

    required init?(coder: NSCoder) { nil }

    private func update(at point: CGPoint) {
        guard bounds.width > 0 else { return }
        hue = min(max(point.x / bounds.width, 0), 1)
        accessibilityValue = String(format: "%.0f°", hue * 360)
        onHueChanged?(hue)
        sendActions(for: .valueChanged)
        setNeedsDisplay()
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        update(at: touch.location(in: self))
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        update(at: touch.location(in: self))
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        if let touch { update(at: touch.location(in: self)) }
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), rect.width > 0, rect.height > 0 else { return }
        let stops: [CGFloat] = [0, 1.0 / 6, 2.0 / 6, 3.0 / 6, 4.0 / 6, 5.0 / 6, 1]
        let colors: [CGColor] = stops.map { UIColor(hue: $0, saturation: 1, brightness: 1, alpha: 1).cgColor }
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                         colors: colors as CFArray, locations: stops) else { return }
        context.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.midY),
                                   end: CGPoint(x: rect.maxX, y: rect.midY), options: [])
        context.setStrokeColor(DraftingTheme.rule.cgColor)
        context.setLineWidth(1)
        context.stroke(rect.insetBy(dx: 0.5, dy: 0.5))

        let x = rect.minX + min(max(hue, 0), 1) * rect.width
        let marker = CGRect(x: x - 2, y: rect.minY - 2, width: 4, height: rect.height + 4)
        context.setFillColor(UIColor.white.cgColor)
        context.fill(marker)
        context.setStrokeColor(DraftingTheme.ink.cgColor)
        context.setLineWidth(1)
        context.stroke(marker.insetBy(dx: 0.5, dy: 0.5))
    }
}
