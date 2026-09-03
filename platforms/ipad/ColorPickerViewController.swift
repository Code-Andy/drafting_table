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

    private var hue: CGFloat = 0
    private var saturation: CGFloat = 0
    private var value: CGFloat = 0
    private var previousColor: UIColor = .black
    private let square = HSVSquareView()
    private let hueSlider = UISlider()
    private let hexField = UITextField()
    private let rgbLabel = UILabel()
    private let previewSwatch = UIView()
    private let previousSwatch = UIView()
    private var recentsRow: UIStackView!
    private var slotsRow: UIStackView!

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Color"
        view.backgroundColor = UIColor(red: 0.985, green: 0.975, blue: 0.945, alpha: 1)
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done,
            primaryAction: UIAction { [weak self] _ in self?.commitAndDismiss() })
        previousColor = Self.uiColor(from: initialColorRGBA)
        adopt(color: previousColor)
        buildLayout()
        refreshAll()
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
        hueSlider.minimumValue = 0
        hueSlider.maximumValue = 1
        hueSlider.value = Float(hue)
        hueSlider.accessibilityLabel = "Hue"
        hueSlider.addTarget(self, action: #selector(hueChanged(_:)), for: .valueChanged)
        hexField.placeholder = "#RRGGBB"
        hexField.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        hexField.borderStyle = .roundedRect
        hexField.autocapitalizationType = .allCharacters
        hexField.autocorrectionType = .no
        hexField.returnKeyType = .done
        hexField.delegate = self
        hexField.accessibilityLabel = "Hex color"
        rgbLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        rgbLabel.textColor = .secondaryLabel
        for swatch in [previewSwatch, previousSwatch] {
            swatch.layer.cornerRadius = 10
            swatch.layer.borderWidth = 1
            swatch.layer.borderColor = UIColor.black.withAlphaComponent(0.15).cgColor
            swatch.heightAnchor.constraint(equalToConstant: 44).isActive = true
        }
        previewSwatch.accessibilityLabel = "Current color"
        previousSwatch.accessibilityLabel = "Previous color"
        let previousTap = UITapGestureRecognizer(target: self, action: #selector(previousTapped))
        previousSwatch.addGestureRecognizer(previousTap)
        previousSwatch.isUserInteractionEnabled = true
        let swatches = UIStackView(arrangedSubviews: [previewSwatch, previousSwatch])
        swatches.axis = .horizontal
        swatches.spacing = 10
        swatches.distribution = .fillEqually
        let eyedropper = UIButton(type: .system)
        eyedropper.setTitle("◉  Eyedropper", for: .normal)
        eyedropper.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        eyedropper.addTarget(self, action: #selector(eyedropperTapped), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [
            sectionTitle("COLOR"),
            square, hueSlider, swatches, hexField, rgbLabel, eyedropper,
            sectionTitle("PALETTE"), paletteGrid(),
            sectionTitle("RECENT"), recentsRowPlaceholder(),
            sectionTitle("MY SLOTS — LONG-PRESS TO SET"), slotsRowPlaceholder()
        ])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -28),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -48),
            square.heightAnchor.constraint(equalTo: square.widthAnchor)
        ])
    }

    private func recentsRowPlaceholder() -> UIView {
        recentsRow = UIStackView()
        recentsRow.axis = .horizontal
        recentsRow.spacing = 8
        return recentsRow
    }

    private func slotsRowPlaceholder() -> UIView {
        slotsRow = UIStackView()
        slotsRow.axis = .horizontal
        slotsRow.spacing = 8
        return slotsRow
    }

    private func sectionTitle(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 12, weight: .bold)
        label.textColor = .secondaryLabel
        return label
    }

    private func paletteGrid() -> UIView {
        let grid = UIStackView()
        grid.axis = .vertical
        grid.spacing = 8
        for row in 0..<4 {
            let rowStack = UIStackView()
            rowStack.axis = .horizontal
            rowStack.spacing = 8
            rowStack.distribution = .fillEqually
            for col in 0..<8 {
                let rgb = Self.defaultPalette[row * 8 + col]
                let button = swatchButton(color: Self.uiColor(rgb: rgb), size: 34)
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
        button.layer.cornerRadius = 8
        button.layer.borderWidth = 1
        button.layer.borderColor = UIColor.black.withAlphaComponent(0.15).cgColor
        button.heightAnchor.constraint(equalToConstant: size).isActive = true
        button.accessibilityLabel = "Color swatch"
        return button
    }

    private func refreshAll() {
        square.hue = hue
        square.selectedSaturation = saturation
        square.selectedValue = value
        hueSlider.value = Float(hue)
        previewSwatch.backgroundColor = currentUIColor
        previousSwatch.backgroundColor = previousColor
        hexField.text = Self.hexString(from: currentUIColor)
        rgbLabel.text = Self.rgbString(from: currentUIColor)
        refreshRecentsRow()
        refreshSlotsRow()
    }

    private func colorDidChange(recordRecent: Bool) {
        if recordRecent { recordRecentColor(currentPacked) }
        refreshAll()
        onColorChanged?(currentPacked)
    }

    @objc private func hueChanged(_ sender: UISlider) {
        hue = CGFloat(sender.value)
        colorDidChange(recordRecent: false)
    }

    @objc private func paletteTapped(_ sender: UIButton) {
        adopt(color: Self.uiColor(rgb: UInt32(bitPattern: Int32(sender.tag))))
        colorDidChange(recordRecent: true)
    }

    @objc private func previousTapped() {
        adopt(color: previousColor)
        colorDidChange(recordRecent: false)
    }

    @objc private func eyedropperTapped() {
        onEyedropperRequested?()
    }

    private func commitAndDismiss() {
        recordRecentColor(currentPacked)
        onColorPicked?(currentPacked)
        dismiss(animated: true)
    }

    private func refreshRecentsRow() {
        recentsRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let recents = storedInts(key: Self.recentsKey)
        if recents.isEmpty {
            let hint = UILabel()
            hint.text = "Recently used colors appear here."
            hint.font = .systemFont(ofSize: 13)
            hint.textColor = .secondaryLabel
            recentsRow.addArrangedSubview(hint)
            return
        }
        for rgb in recents.prefix(Self.maximumRecents) {
            let button = swatchButton(color: Self.uiColor(rgb: UInt32(rgb)), size: 30)
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
                button = swatchButton(color: Self.uiColor(rgb: UInt32(stored)), size: 30)
                button.tag = stored
                button.addTarget(self, action: #selector(paletteTapped(_:)), for: .touchUpInside)
            } else {
                button = UIButton(type: .system)
                button.setTitle("+", for: .normal)
                button.titleLabel?.font = .systemFont(ofSize: 20, weight: .medium)
                button.setTitleColor(.secondaryLabel, for: .normal)
                button.layer.cornerRadius = 8
                button.layer.borderWidth = 1
                button.layer.borderColor = UIColor.black.withAlphaComponent(0.15).cgColor
                button.heightAnchor.constraint(equalToConstant: 30).isActive = true
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
}

extension ColorPickerViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        guard let text = textField.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { textField.resignFirstResponder(); return true }
        var hex = text.uppercased()
        if hex.hasPrefix("#") { hex.removeFirst() }
        if hex.count == 6, let rgb = UInt32(hex, radix: 16) {
            adopt(color: Self.uiColor(rgb: rgb))
            colorDidChange(recordRecent: true)
        } else {
            hexField.text = Self.hexString(from: currentUIColor)
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
        layer.cornerRadius = 10
        layer.borderWidth = 1
        layer.borderColor = UIColor.black.withAlphaComponent(0.15).cgColor
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
