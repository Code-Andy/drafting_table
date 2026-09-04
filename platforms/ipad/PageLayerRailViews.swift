import UIKit

// MARK: - Pages

final class PagesRailView: UIView {
    var onSelect: ((Int) -> Void)?
    var onAdd: (() -> Void)?
    var onRename: ((Int) -> Void)?
    var onDelete: ((Int) -> Void)?
    var onDuplicate: ((Int) -> Void)?
    var onMove: ((Int, Int) -> Void)?
    var onDocsMenu: (() -> Void)?
    var thumbnailForPage: ((UInt) -> UIImage?)?
    var pageInfos: [DTPageInfo] = [] { didSet { reload() } }

    private let scroll = UIScrollView()
    private let stack = UIStackView()

    override init(frame: CGRect) { super.init(frame: frame); configure() }
    required init?(coder: NSCoder) { super.init(coder: coder); configure() }

    private func configure() {
        backgroundColor = DraftingTheme.paper
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        scroll.showsVerticalScrollIndicator = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 4
        scroll.addSubview(stack)
        addSubview(scroll)
        let edge = UIView()
        edge.translatesAutoresizingMaskIntoConstraints = false
        edge.backgroundColor = DraftingTheme.rule
        addSubview(edge)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor), stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor), stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -4),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            edge.trailingAnchor.constraint(equalTo: trailingAnchor), edge.topAnchor.constraint(equalTo: topAnchor), edge.bottomAnchor.constraint(equalTo: bottomAnchor), edge.widthAnchor.constraint(equalToConstant: 1)
        ])
    }

    private func reload() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let docs = UIButton(type: .system)
        docs.setImage(DraftingIcon.image(named: "docs", fallback: "doc.text"), for: .normal)
        docs.setTitle("  DOCS ⌄", for: .normal)
        docs.titleLabel?.font = DraftingTheme.mono(size: 10, weight: .semibold)
        docs.tintColor = DraftingTheme.ink
        docs.setTitleColor(DraftingTheme.ink, for: .normal)
        docs.backgroundColor = DraftingTheme.paperDeep
        docs.heightAnchor.constraint(equalToConstant: 40).isActive = true
        docs.addAction(UIAction { [weak self] _ in self?.onDocsMenu?() }, for: .touchUpInside)
        docs.accessibilityLabel = "Documents"
        stack.addArrangedSubview(docs)

        let canDelete = pageInfos.count > 1
        for info in pageInfos {
            let row = PageThumbnailRow(info: info, thumbnail: thumbnailForPage?(info.index), canDelete: canDelete,
                                       canMoveUp: info.index > 0, canMoveDown: info.index + 1 < UInt(pageInfos.count))
            row.onSelect = { [weak self] in self?.onSelect?(Int(info.index)) }
            row.onRename = { [weak self] in self?.onRename?(Int(info.index)) }
            row.onDelete = { [weak self] in self?.onDelete?(Int(info.index)) }
            row.onDuplicate = { [weak self] in self?.onDuplicate?(Int(info.index)) }
            row.onMove = { [weak self] delta in self?.onMove?(Int(info.index), Int(info.index) + delta) }
            stack.addArrangedSubview(row)
        }
        let add = DashedAddPageButton()
        add.heightAnchor.constraint(equalToConstant: 48).isActive = true
        add.addAction(UIAction { [weak self] _ in self?.onAdd?() }, for: .touchUpInside)
        stack.addArrangedSubview(add)
    }
}

private final class PageThumbnailRow: UIView {
    var onSelect: (() -> Void)?
    var onRename: (() -> Void)?
    var onDelete: (() -> Void)?
    var onDuplicate: (() -> Void)?
    var onMove: ((Int) -> Void)?
    private let info: DTPageInfo
    private let canDelete: Bool
    private let canMoveUp: Bool
    private let canMoveDown: Bool

    init(info: DTPageInfo, thumbnail: UIImage?, canDelete: Bool, canMoveUp: Bool, canMoveDown: Bool) {
        self.info = info; self.canDelete = canDelete; self.canMoveUp = canMoveUp; self.canMoveDown = canMoveDown
        super.init(frame: .zero)
        heightAnchor.constraint(equalToConstant: 84).isActive = true
        let thumb = UIButton(type: .custom)
        thumb.translatesAutoresizingMaskIntoConstraints = false
        thumb.backgroundColor = .white
        thumb.layer.borderWidth = info.selected ? 2 : 1
        thumb.layer.borderColor = (info.selected ? DraftingTheme.hot : DraftingTheme.rule).cgColor
        thumb.clipsToBounds = true
        thumb.setImage(thumbnail, for: .normal)
        thumb.imageView?.contentMode = .scaleAspectFit
        thumb.addAction(UIAction { [weak self] _ in self?.onSelect?() }, for: .touchUpInside)
        thumb.accessibilityLabel = "Page \(Int(info.index) + 1), \(info.name)"
        addSubview(thumb)
        let badge = UILabel()
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.text = String(format: "%02d", Int(info.index) + 1)
        badge.font = DraftingTheme.mono(size: 8, weight: .semibold)
        badge.textColor = info.selected ? DraftingTheme.hot : DraftingTheme.inkSoft
        badge.backgroundColor = DraftingTheme.paper.withAlphaComponent(0.82)
        badge.textAlignment = .center
        thumb.addSubview(badge)
        let icons = UIStackView()
        icons.translatesAutoresizingMaskIntoConstraints = false
        icons.axis = .vertical; icons.alignment = .center; icons.spacing = 4
        let grip = UIImageView(image: DraftingIcon.image(named: "drag_handle", fallback: "line.3.horizontal"))
        grip.tintColor = DraftingTheme.inkDisabled; grip.contentMode = .scaleAspectFit
        let more = UIButton(type: .system)
        more.setImage(DraftingIcon.image(named: "more", fallback: "ellipsis"), for: .normal)
        more.tintColor = DraftingTheme.inkDisabled; more.showsMenuAsPrimaryAction = true; more.menu = pageMenu()
        for view in [grip, more] { view.translatesAutoresizingMaskIntoConstraints = false; view.widthAnchor.constraint(equalToConstant: 18).isActive = true; view.heightAnchor.constraint(equalToConstant: 18).isActive = true; icons.addArrangedSubview(view) }
        addSubview(icons)
        NSLayoutConstraint.activate([
            thumb.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4), thumb.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            thumb.widthAnchor.constraint(equalToConstant: 60), thumb.heightAnchor.constraint(equalToConstant: 78),
            badge.leadingAnchor.constraint(equalTo: thumb.leadingAnchor), badge.topAnchor.constraint(equalTo: thumb.topAnchor), badge.widthAnchor.constraint(equalToConstant: 18), badge.heightAnchor.constraint(equalToConstant: 14),
            icons.leadingAnchor.constraint(equalTo: thumb.trailingAnchor, constant: 1), icons.centerYAnchor.constraint(equalTo: thumb.centerYAnchor), icons.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -1)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func pageMenu() -> UIMenu {
        let rename = UIAction(title: "Rename") { [weak self] _ in self?.onRename?() }
        let duplicate = UIAction(title: "Duplicate") { [weak self] _ in self?.onDuplicate?() }
        let up = UIAction(title: "Move Up", attributes: canMoveUp ? [] : [.disabled]) { [weak self] _ in self?.onMove?(-1) }
        let down = UIAction(title: "Move Down", attributes: canMoveDown ? [] : [.disabled]) { [weak self] _ in self?.onMove?(1) }
        let delete = UIAction(title: "Delete", attributes: canDelete ? .destructive : [.disabled, .destructive]) { [weak self] _ in self?.onDelete?() }
        return UIMenu(title: info.name, children: [rename, duplicate, up, down, delete])
    }
}

private final class DashedAddPageButton: UIButton {
    private let dash = CAShapeLayer()
    override init(frame: CGRect) {
        super.init(frame: frame)
        setImage(DraftingIcon.image(named: "plus", fallback: "plus"), for: .normal); tintColor = DraftingTheme.inkDisabled
        accessibilityLabel = "Add page"; dash.strokeColor = DraftingTheme.inkFaint.cgColor; dash.fillColor = UIColor.clear.cgColor
        dash.lineWidth = 1; dash.lineDashPattern = [4, 3]; layer.addSublayer(dash)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() { super.layoutSubviews(); dash.path = UIBezierPath(rect: CGRect(x: 12, y: 5, width: bounds.width - 24, height: bounds.height - 10)).cgPath }
}

// MARK: - Layer / brush / color inspector

final class LayersRailView: UIView {
    var onSelect: ((Int) -> Void)?
    var onAdd: (() -> Void)?
    var onAddVector: (() -> Void)?
    var onUnavailable: (() -> Void)?
    var onRename: ((Int) -> Void)?
    var onDelete: ((Int) -> Void)?
    var onDuplicate: ((Int) -> Void)?
    var onMove: ((Int, Int) -> Void)?
    var onVisibility: ((Bool, Int) -> Void)?
    var onOpacity: ((CGFloat, Int) -> Void)?
    var onOpacityCommit: ((CGFloat, Int) -> Void)?
    var onBrushSize: ((CGFloat) -> Void)?
    var onBrushAlpha: ((CGFloat) -> Void)?
    var onBrushHardness: ((CGFloat) -> Void)?
    var onColor: ((UInt32) -> Void)?
    var onOpenColor: (() -> Void)?
    var layerInfos: [DTLayerInfo] = [] { didSet { rebuildLayerSection() } }
    var brushSize: CGFloat = 8 { didSet { syncBrushControls() } }
    var brushAlpha: CGFloat = 1 { didSet { syncBrushControls() } }
    var brushHardness: CGFloat = 0.8 { didSet { syncBrushControls() } }
    var brushColorRGBA: UInt32 = 0x2A2620FF { didSet { syncColorControls() } }
    var showsLayersSection: Bool {
        get { !layerSection.isHidden }
        set { layerSection.isHidden = !newValue }
    }
    var showsColorSection: Bool {
        get { !(colorSectionView?.isHidden ?? true) }
        set { colorSectionView?.isHidden = !newValue }
    }

    private let scroll = UIScrollView(), content = UIStackView(), layerSection = UIStackView()
    private let sizeSlider = UISlider(), alphaSlider = UISlider(), hardnessSlider = UISlider()
    private let sizeValue = UILabel(), alphaValue = UILabel(), hardnessValue = UILabel()
    private let activeSwatch = UIButton(type: .custom), hexLabel = UILabel()
    private var colorSectionView: UIView!

    override init(frame: CGRect) { super.init(frame: frame); configure() }
    required init?(coder: NSCoder) { super.init(coder: coder); configure() }

    private func configure() {
        backgroundColor = DraftingTheme.paper
        scroll.translatesAutoresizingMaskIntoConstraints = false; scroll.alwaysBounceVertical = true; scroll.showsVerticalScrollIndicator = false
        content.translatesAutoresizingMaskIntoConstraints = false; content.axis = .vertical; content.spacing = 0
        scroll.addSubview(content); addSubview(scroll)
        let edge = UIView(); edge.translatesAutoresizingMaskIntoConstraints = false; edge.backgroundColor = DraftingTheme.rule; addSubview(edge)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor), scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor), content.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor), content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor), content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor), content.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            edge.trailingAnchor.constraint(equalTo: trailingAnchor), edge.topAnchor.constraint(equalTo: topAnchor), edge.bottomAnchor.constraint(equalTo: bottomAnchor), edge.widthAnchor.constraint(equalToConstant: 1)
        ])
        layerSection.axis = .vertical; layerSection.spacing = 0
        colorSectionView = buildColorSection()
        content.addArrangedSubview(layerSection); content.addArrangedSubview(rule()); content.addArrangedSubview(buildBrushSection()); content.addArrangedSubview(rule()); content.addArrangedSubview(colorSectionView)
        rebuildLayerSection()
    }

    private func rebuildLayerSection() {
        guard layerSection.superview != nil else { return }
        layerSection.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let header = sectionHeader("LAYERS")
        let plus = iconButton("plus", "plus", "Add raster layer") { [weak self] in self?.onAdd?() }; plus.tintColor = DraftingTheme.inkDisabled
        let vector = iconButton("plus_vector", "point.3.connected.trianglepath.dotted", "Add vector layer") { [weak self] in self?.onUnavailable?() }; vector.tintColor = DraftingTheme.inkDisabled
        let more = iconButton("more", "ellipsis", "Layer actions") { [weak self] in self?.onUnavailable?() }; more.tintColor = DraftingTheme.inkDisabled
        let actions = UIStackView(arrangedSubviews: [plus, vector, more]); actions.translatesAutoresizingMaskIntoConstraints = false; actions.axis = .horizontal
        header.addSubview(actions)
        NSLayoutConstraint.activate([actions.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -4), actions.topAnchor.constraint(equalTo: header.topAnchor), actions.bottomAnchor.constraint(equalTo: header.bottomAnchor)])
        layerSection.addArrangedSubview(header)
        var activeInfo: DTLayerInfo?
        for info in layerInfos.reversed() {
            if info.selected { activeInfo = info }
            let row = OriginalLayerRow(info: info)
            row.onSelect = { [weak self] in self?.onSelect?(Int(info.index)) }
            row.onVisibility = { [weak self] visible in self?.onVisibility?(visible, Int(info.index)) }
            row.menu = layerMenu(info, count: layerInfos.count)
            layerSection.addArrangedSubview(row); layerSection.addArrangedSubview(rule())
        }
        if let activeInfo {
            let slider = UISlider(); slider.minimumValue = 0; slider.maximumValue = 1; slider.value = Float(activeInfo.opacity); style(slider)
            let value = valueLabel(String(format: "%.0f", activeInfo.opacity * 100))
            slider.addAction(UIAction { [weak self, weak value] _ in value?.text = String(format: "%.0f", slider.value * 100); self?.onOpacity?(CGFloat(slider.value), Int(activeInfo.index)) }, for: .valueChanged)
            slider.addAction(UIAction { [weak self] _ in self?.onOpacityCommit?(CGFloat(slider.value), Int(activeInfo.index)) }, for: [.touchUpInside, .touchUpOutside, .touchCancel])
            layerSection.addArrangedSubview(sliderRow("α", slider, value))
        }
    }

    private func layerMenu(_ info: DTLayerInfo, count: Int) -> UIMenu {
        let rename = UIAction(title: "Rename") { [weak self] _ in self?.onRename?(Int(info.index)) }
        let duplicate = UIAction(title: "Duplicate") { [weak self] _ in self?.onDuplicate?(Int(info.index)) }
        let up = UIAction(title: "Move Up", attributes: info.index + 1 < UInt(count) ? [] : [.disabled]) { [weak self] _ in self?.onMove?(Int(info.index), Int(info.index) + 1) }
        let down = UIAction(title: "Move Down", attributes: info.index > 0 ? [] : [.disabled]) { [weak self] _ in self?.onMove?(Int(info.index), Int(info.index) - 1) }
        let delete = UIAction(title: "Delete", attributes: count > 1 ? .destructive : [.disabled, .destructive]) { [weak self] _ in self?.onDelete?(Int(info.index)) }
        return UIMenu(title: info.name, children: [rename, duplicate, up, down, delete])
    }

    private func buildBrushSection() -> UIView {
        let section = UIStackView(); section.axis = .vertical; section.spacing = 0; section.addArrangedSubview(sectionHeader("BRUSH"))
        sizeSlider.minimumValue = 1; sizeSlider.maximumValue = 40; alphaSlider.minimumValue = 0.05; alphaSlider.maximumValue = 1; hardnessSlider.minimumValue = 0; hardnessSlider.maximumValue = 1
        [sizeSlider, alphaSlider, hardnessSlider].forEach(style)
        sizeSlider.addAction(UIAction { [weak self] _ in guard let self else { return }; self.sizeValue.text = String(format: "%.1f", self.sizeSlider.value); self.onBrushSize?(CGFloat(self.sizeSlider.value)) }, for: .valueChanged)
        alphaSlider.addAction(UIAction { [weak self] _ in guard let self else { return }; self.alphaValue.text = String(format: "%.0f", self.alphaSlider.value * 100); self.onBrushAlpha?(CGFloat(self.alphaSlider.value)) }, for: .valueChanged)
        hardnessSlider.addAction(UIAction { [weak self] _ in guard let self else { return }; self.hardnessValue.text = String(format: "%.0f", self.hardnessSlider.value * 100); self.onBrushHardness?(CGFloat(self.hardnessSlider.value)) }, for: .valueChanged)
        section.addArrangedSubview(sliderRow("size", sizeSlider, sizeValue)); section.addArrangedSubview(sliderRow("α", alphaSlider, alphaValue)); section.addArrangedSubview(stubRow("uniform α", "off")); section.addArrangedSubview(sliderRow("hard", hardnessSlider, hardnessValue)); section.addArrangedSubview(stubRow("press", "100")); syncBrushControls()
        return section
    }

    private func buildColorSection() -> UIView {
        let section = UIStackView(); section.axis = .vertical; section.spacing = 0; section.addArrangedSubview(sectionHeader("COLOR"))
        let activeRow = UIView(); activeRow.heightAnchor.constraint(equalToConstant: 48).isActive = true
        activeSwatch.translatesAutoresizingMaskIntoConstraints = false; activeSwatch.layer.borderWidth = 1; activeSwatch.layer.borderColor = DraftingTheme.inkSoft.cgColor; activeSwatch.addAction(UIAction { [weak self] _ in self?.onOpenColor?() }, for: .touchUpInside)
        hexLabel.translatesAutoresizingMaskIntoConstraints = false; hexLabel.font = DraftingTheme.mono(size: 10, weight: .regular); hexLabel.textColor = DraftingTheme.inkSoft
        let picker = iconButton("eyedropper", "eyedropper", "Open color picker") { [weak self] in self?.onOpenColor?() }; picker.translatesAutoresizingMaskIntoConstraints = false
        [activeSwatch, hexLabel, picker].forEach(activeRow.addSubview)
        NSLayoutConstraint.activate([activeSwatch.leadingAnchor.constraint(equalTo: activeRow.leadingAnchor, constant: 10), activeSwatch.centerYAnchor.constraint(equalTo: activeRow.centerYAnchor), activeSwatch.widthAnchor.constraint(equalToConstant: 34), activeSwatch.heightAnchor.constraint(equalToConstant: 28), hexLabel.leadingAnchor.constraint(equalTo: activeSwatch.trailingAnchor, constant: 8), hexLabel.centerYAnchor.constraint(equalTo: activeRow.centerYAnchor), picker.trailingAnchor.constraint(equalTo: activeRow.trailingAnchor, constant: -6), picker.centerYAnchor.constraint(equalTo: activeRow.centerYAnchor)])
        section.addArrangedSubview(activeRow)
        let palette = UIStackView(); palette.axis = .vertical; palette.spacing = 3; palette.isLayoutMarginsRelativeArrangement = true; palette.layoutMargins = UIEdgeInsets(top: 0, left: 10, bottom: 10, right: 10)
        let colors: [UInt32] = [
            0x000000FF,0x6E2218FF,0x8A3F0FFF,0x886C18FF,0x3D5E26FF,0x195049FF,0x1A3D60FF,0x4A2A65FF,
            0x1A1A1AFF,0xB5482EFF,0xC77A1FFF,0xC8A030FF,0x5A8C3AFF,0x2F7E78FF,0x2A5D8FFF,0x6B3A8AFF,
            0x6E6457FF,0xC07A60FF,0xD0A270FF,0xCAB870FF,0x95B070FF,0x6FA59EFF,0x6F95C0FF,0xA088B5FF,
            0xFFFFFFFF,0x7A7368FF,0xA89E8AFF,0xD9CFB8FF,0xF2D89AFF,0xF2A48FFF,0x9DB8D8FF,0xC7D2A8FF
        ]
        for start in stride(from: 0, to: colors.count, by: 8) {
            let row = UIStackView(); row.axis = .horizontal; row.distribution = .fillEqually; row.spacing = 3
            for color in colors[start..<min(start + 8, colors.count)] { let swatch = UIButton(type: .custom); swatch.backgroundColor = uiColor(color); swatch.layer.borderWidth = 0.5; swatch.layer.borderColor = DraftingTheme.rule.cgColor; swatch.heightAnchor.constraint(equalToConstant: 16).isActive = true; swatch.addAction(UIAction { [weak self] _ in self?.onColor?(color) }, for: .touchUpInside); row.addArrangedSubview(swatch) }
            palette.addArrangedSubview(row)
        }
        section.addArrangedSubview(palette); syncColorControls(); return section
    }

    private func sectionHeader(_ title: String) -> UIView { let view = UIView(); view.backgroundColor = DraftingTheme.paperDeep; view.heightAnchor.constraint(equalToConstant: 28).isActive = true; let label = UILabel(); label.translatesAutoresizingMaskIntoConstraints = false; label.text = title; label.font = DraftingTheme.mono(size: 10, weight: .semibold); label.textColor = DraftingTheme.ink; view.addSubview(label); NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10), label.centerYAnchor.constraint(equalTo: view.centerYAnchor)]); return view }
    private func sliderRow(_ title: String, _ slider: UISlider, _ value: UILabel) -> UIView { let row = UIStackView(); row.axis = .horizontal; row.alignment = .center; row.spacing = 4; row.isLayoutMarginsRelativeArrangement = true; row.layoutMargins = UIEdgeInsets(top: 3, left: 10, bottom: 3, right: 10); row.heightAnchor.constraint(equalToConstant: 38).isActive = true; let name = UILabel(); name.text = title; name.font = DraftingTheme.mono(size: 11, weight: .regular); name.textColor = DraftingTheme.inkSoft; name.widthAnchor.constraint(equalToConstant: 42).isActive = true; value.widthAnchor.constraint(equalToConstant: 36).isActive = true; row.addArrangedSubview(name); row.addArrangedSubview(slider); row.addArrangedSubview(value); return row }
    private func stubRow(_ title: String, _ value: String) -> UIView { let row = UIView(); row.heightAnchor.constraint(equalToConstant: 34).isActive = true; let name = UILabel(), val = UILabel(); for label in [name,val] { label.translatesAutoresizingMaskIntoConstraints = false; label.font = DraftingTheme.mono(size: 11, weight: .regular); label.textColor = DraftingTheme.inkDisabled; row.addSubview(label) }; name.text = title; val.text = value; val.textAlignment = .right; NSLayoutConstraint.activate([name.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 10),name.centerYAnchor.constraint(equalTo: row.centerYAnchor),val.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -10),val.centerYAnchor.constraint(equalTo: row.centerYAnchor)]); row.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(unavailableTapped))); return row }
    private func iconButton(_ name: String, _ fallback: String, _ label: String, _ action: @escaping () -> Void) -> UIButton { let button = UIButton(type: .system); button.setImage(DraftingIcon.image(named: name, fallback: fallback), for: .normal); button.tintColor = DraftingTheme.inkSoft; button.widthAnchor.constraint(equalToConstant: 28).isActive = true; button.heightAnchor.constraint(equalToConstant: 28).isActive = true; button.accessibilityLabel = label; button.addAction(UIAction { _ in action() }, for: .touchUpInside); return button }
    private func rule() -> UIView { let view = UIView(); view.backgroundColor = DraftingTheme.rule; view.heightAnchor.constraint(equalToConstant: 1).isActive = true; return view }
    private func valueLabel(_ text: String = "") -> UILabel { let label = UILabel(); label.text = text; label.font = DraftingTheme.mono(size: 11, weight: .regular); label.textColor = DraftingTheme.ink; label.textAlignment = .right; return label }
    private func style(_ slider: UISlider) { slider.minimumTrackTintColor = DraftingTheme.accent; slider.maximumTrackTintColor = DraftingTheme.rule }
    private func syncBrushControls() { guard sizeSlider.superview != nil else { return }; sizeSlider.value = Float(brushSize); alphaSlider.value = Float(brushAlpha); hardnessSlider.value = Float(brushHardness); sizeValue.text = String(format: "%.1f", brushSize); alphaValue.text = String(format: "%.0f", brushAlpha * 100); hardnessValue.text = String(format: "%.0f", brushHardness * 100) }
    private func syncColorControls() { guard activeSwatch.superview != nil else { return }; activeSwatch.backgroundColor = uiColor(brushColorRGBA); hexLabel.text = String(format: "#%06X", (brushColorRGBA >> 8) & 0xFFFFFF) }
    private func uiColor(_ rgba: UInt32) -> UIColor { UIColor(red: CGFloat((rgba >> 24) & 0xFF)/255, green: CGFloat((rgba >> 16) & 0xFF)/255, blue: CGFloat((rgba >> 8) & 0xFF)/255, alpha: CGFloat(rgba & 0xFF)/255) }
    @objc private func unavailableTapped() { onUnavailable?() }
}

private final class OriginalLayerRow: UIView {
    var onSelect: (() -> Void)?
    var onVisibility: ((Bool) -> Void)?
    var menu: UIMenu? { didSet { more.menu = menu } }
    private let info: DTLayerInfo
    private let more = UIButton(type: .system)
    init(info: DTLayerInfo) {
        self.info = info; super.init(frame: .zero); backgroundColor = info.selected ? DraftingTheme.paperDeep : DraftingTheme.paper; heightAnchor.constraint(equalToConstant: 40).isActive = true
        if info.selected { let active = UIView(); active.translatesAutoresizingMaskIntoConstraints = false; active.backgroundColor = DraftingTheme.hot; addSubview(active); NSLayoutConstraint.activate([active.leadingAnchor.constraint(equalTo: leadingAnchor),active.topAnchor.constraint(equalTo: topAnchor),active.bottomAnchor.constraint(equalTo: bottomAnchor),active.widthAnchor.constraint(equalToConstant: 2)]) }
        let eye = UIButton(type: .system); eye.translatesAutoresizingMaskIntoConstraints = false; eye.setImage(DraftingIcon.image(named: info.visible ? "eye" : "eye_off", fallback: info.visible ? "eye" : "eye.slash"), for: .normal); eye.tintColor = info.visible ? DraftingTheme.ink : DraftingTheme.inkFaint; eye.addAction(UIAction { [weak self] _ in guard let self else { return }; self.onVisibility?(!self.info.visible) }, for: .touchUpInside); addSubview(eye)
        let name = UILabel(); name.translatesAutoresizingMaskIntoConstraints = false; name.text = info.name; name.font = DraftingTheme.mono(size: 11, weight: info.selected ? .semibold : .regular); name.textColor = DraftingTheme.ink; name.lineBreakMode = .byTruncatingTail; addSubview(name)
        let type = UILabel(); type.translatesAutoresizingMaskIntoConstraints = false; type.text = info.name.lowercased().contains("vector") ? "V" : "R"; type.font = DraftingTheme.mono(size: 7, weight: .semibold); type.textColor = DraftingTheme.inkFaint; type.layer.borderWidth = 1; type.layer.borderColor = DraftingTheme.rule.cgColor; type.layer.cornerRadius = 3; type.textAlignment = .center; addSubview(type)
        more.translatesAutoresizingMaskIntoConstraints = false; more.setImage(DraftingIcon.image(named: "more", fallback: "ellipsis"), for: .normal); more.tintColor = DraftingTheme.inkSoft; more.showsMenuAsPrimaryAction = true; addSubview(more)
        let grip = UIImageView(image: DraftingIcon.image(named: "drag_handle", fallback: "line.3.horizontal")); grip.translatesAutoresizingMaskIntoConstraints = false; grip.tintColor = DraftingTheme.inkSoft; grip.contentMode = .scaleAspectFit; addSubview(grip)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(selected)))
        NSLayoutConstraint.activate([eye.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),eye.centerYAnchor.constraint(equalTo: centerYAnchor),eye.widthAnchor.constraint(equalToConstant: 30),eye.heightAnchor.constraint(equalToConstant: 30),name.leadingAnchor.constraint(equalTo: eye.trailingAnchor, constant: 2),name.centerYAnchor.constraint(equalTo: centerYAnchor),type.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 3),type.centerYAnchor.constraint(equalTo: centerYAnchor),type.widthAnchor.constraint(equalToConstant: 16),type.heightAnchor.constraint(equalToConstant: 14),more.leadingAnchor.constraint(equalTo: type.trailingAnchor, constant: 1),more.centerYAnchor.constraint(equalTo: centerYAnchor),more.widthAnchor.constraint(equalToConstant: 26),more.heightAnchor.constraint(equalToConstant: 30),grip.leadingAnchor.constraint(equalTo: more.trailingAnchor),grip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),grip.centerYAnchor.constraint(equalTo: centerYAnchor),grip.widthAnchor.constraint(equalToConstant: 20),grip.heightAnchor.constraint(equalToConstant: 20)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func selected() { onSelect?() }
}
