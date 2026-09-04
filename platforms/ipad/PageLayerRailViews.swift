import UIKit

/// Compact, metadata-driven page rail. The controller owns mutations; this
/// view only presents cards and reports user intent through closures.
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

    private let stack = UIStackView()
    private let scroll = UIScrollView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        backgroundColor = UIColor(red: 0.99, green: 0.98, blue: 0.95, alpha: 0.94)
        layer.cornerRadius = 12
        layer.borderWidth = 1
        layer.borderColor = UIColor(red: 0.35, green: 0.30, blue: 0.23, alpha: 0.14).cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.08
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 2)

        stack.axis = .vertical
        stack.spacing = 6
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        scroll.showsVerticalScrollIndicator = false
        scroll.addSubview(stack)
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -10),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -16)
        ])
    }

    private func titleLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 10, weight: .bold)
        label.textColor = UIColor(red: 0.38, green: 0.33, blue: 0.27, alpha: 0.70)
        label.textAlignment = .center
        return label
    }

    private func reload() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let docsBtn = UIButton(type: .system)
        var docCfg = UIButton.Configuration.plain()
        docCfg.image = UIImage(systemName: "doc.text")
        var docTitle = AttributedString("DOCS ∨")
        docTitle.font = .systemFont(ofSize: 9.5, weight: .bold)
        docCfg.attributedTitle = docTitle
        docCfg.imagePadding = 3
        docCfg.baseForegroundColor = UIColor(red: 0.22, green: 0.19, blue: 0.15, alpha: 1)
        docCfg.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 4)
        docsBtn.configuration = docCfg
        docsBtn.backgroundColor = UIColor.white.withAlphaComponent(0.85)
        docsBtn.layer.cornerRadius = 6
        docsBtn.layer.borderWidth = 1
        docsBtn.layer.borderColor = UIColor.black.withAlphaComponent(0.08).cgColor
        docsBtn.heightAnchor.constraint(equalToConstant: 26).isActive = true
        docsBtn.addAction(UIAction { [weak self] _ in self?.onDocsMenu?() }, for: .touchUpInside)
        stack.addArrangedSubview(docsBtn)
        stack.addArrangedSubview(titleLabel("PAGES"))
        let canDelete = pageInfos.count > 1
        for info in pageInfos {
            let card = PageCardButton(info: info, canDelete: canDelete,
                                      canMoveUp: info.index > 0,
                                      canMoveDown: info.index + 1 < UInt(pageInfos.count),
                                      thumbnail: thumbnailForPage?(info.index))
            card.onSelect = { [weak self] in self?.onSelect?(Int(info.index)) }
            card.onRename = { [weak self] in self?.onRename?(Int(info.index)) }
            card.onDelete = { [weak self] in self?.onDelete?(Int(info.index)) }
            card.onDuplicate = { [weak self] in self?.onDuplicate?(Int(info.index)) }
            card.onMove = { [weak self] offset in
                let destination = Int(info.index) + offset
                self?.onMove?(Int(info.index), destination)
            }
            stack.addArrangedSubview(card)
        }
        let add = UIButton(type: .system)
        add.setImage(UIImage(systemName: "plus"), for: .normal)
        add.tintColor = .systemBlue
        add.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.08)
        add.layer.cornerRadius = 6
        add.heightAnchor.constraint(equalToConstant: 28).isActive = true
        add.accessibilityLabel = "Add page"
        add.addAction(UIAction { [weak self] _ in self?.onAdd?() }, for: .touchUpInside)
        stack.addArrangedSubview(add)
    }
}

private final class PageCardButton: UIButton {
    var onSelect: (() -> Void)?
    var onRename: (() -> Void)?
    var onDelete: (() -> Void)?
    var onDuplicate: (() -> Void)?
    var onMove: ((Int) -> Void)?
    private let info: DTPageInfo
    private let canDelete: Bool
    private let canMoveUp: Bool
    private let canMoveDown: Bool

    init(info: DTPageInfo, canDelete: Bool, canMoveUp: Bool, canMoveDown: Bool, thumbnail: UIImage?) {
        self.info = info
        self.canDelete = canDelete
        self.canMoveUp = canMoveUp
        self.canMoveDown = canMoveDown
        super.init(frame: .zero)
        var config = UIButton.Configuration.plain()
        var titleAttr = AttributedString("\(Int(info.index) + 1)\n\(info.name)")
        titleAttr.font = .systemFont(ofSize: 9.5, weight: info.selected ? .semibold : .regular)
        config.attributedTitle = titleAttr
        config.titleAlignment = .center
        config.image = thumbnail
        config.imagePlacement = .top
        config.imagePadding = 2
        config.baseForegroundColor = UIColor(red: 0.22, green: 0.19, blue: 0.15, alpha: 1)
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 2, bottom: 4, trailing: 2)
        self.configuration = config
        backgroundColor = info.selected ? UIColor.systemBlue.withAlphaComponent(0.12) : UIColor.white.withAlphaComponent(0.9)
        layer.cornerRadius = 6
        layer.borderWidth = info.selected ? 1.5 : 1
        layer.borderColor = (info.selected ? UIColor.systemBlue.withAlphaComponent(0.75) : UIColor.black.withAlphaComponent(0.08)).cgColor
        heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        accessibilityLabel = "Page \(Int(info.index) + 1), \(info.name)"
        accessibilityValue = info.selected ? "Selected" : "Not selected"
        accessibilityTraits = info.selected ? [.button, .selected] : [.button]
        addTarget(self, action: #selector(selected), for: .touchUpInside)
        addInteraction(UIContextMenuInteraction(delegate: self))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func selected() { onSelect?() }

    override func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                          configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return UIMenu(title: "", children: []) }
            let rename = UIAction(title: "Rename", image: UIImage(systemName: "pencil")) { [weak self] _ in self?.onRename?() }
            let duplicate = UIAction(title: "Duplicate", image: UIImage(systemName: "plus.square.on.square")) { [weak self] _ in self?.onDuplicate?() }
            let moveUp = UIAction(title: "Move Up", image: UIImage(systemName: "arrow.up"), attributes: self.canMoveUp ? [] : [.disabled]) { [weak self] _ in self?.onMove?(-1) }
            let moveDown = UIAction(title: "Move Down", image: UIImage(systemName: "arrow.down"), attributes: self.canMoveDown ? [] : [.disabled]) { [weak self] _ in self?.onMove?(1) }
            let delete = UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: self.canDelete ? [] : [.disabled]) { [weak self] _ in self?.onDelete?() }
            return UIMenu(title: self.info.name, children: [rename, duplicate, UIMenu(title: "Move", options: .displayInline, children: [moveUp, moveDown]), delete])
        }
    }
}

/// Layer rail with selection, visibility, opacity and context actions.
final class LayersRailView: UIView {
    var onSelect: ((Int) -> Void)?
    var onAdd: (() -> Void)?
    var onRename: ((Int) -> Void)?
    var onDelete: ((Int) -> Void)?
    var onDuplicate: ((Int) -> Void)?
    var onMove: ((Int, Int) -> Void)?
    var onVisibility: ((Bool, Int) -> Void)?
    var onOpacity: ((CGFloat, Int) -> Void)?
    var onOpacityCommit: ((CGFloat, Int) -> Void)?

    var layerInfos: [DTLayerInfo] = [] { didSet { reload() } }

    private let stack = UIStackView()
    private let scroll = UIScrollView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        backgroundColor = UIColor(red: 0.99, green: 0.98, blue: 0.95, alpha: 0.94)
        layer.cornerRadius = 12
        layer.borderWidth = 1
        layer.borderColor = UIColor(red: 0.35, green: 0.30, blue: 0.23, alpha: 0.14).cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.08
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 2)
        stack.axis = .vertical
        stack.spacing = 3
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        scroll.showsVerticalScrollIndicator = false
        scroll.addSubview(stack)
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 5),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -5),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -6),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -10)
        ])
    }

    private func titleLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 9.5, weight: .bold)
        label.textColor = UIColor(red: 0.38, green: 0.33, blue: 0.27, alpha: 0.70)
        label.textAlignment = .center
        return label
    }

    private func reload() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let headerRow = UIStackView()
        headerRow.axis = .horizontal
        headerRow.alignment = .center
        headerRow.distribution = .fill
        headerRow.spacing = 4

        let lbl = titleLabel("LAYERS")
        headerRow.addArrangedSubview(lbl)

        let addBtn = UIButton(type: .system)
        let addCfg = UIImage.SymbolConfiguration(pointSize: 11, weight: .bold)
        addBtn.setImage(UIImage(systemName: "plus", withConfiguration: addCfg), for: .normal)
        addBtn.tintColor = .systemBlue
        addBtn.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.08)
        addBtn.layer.cornerRadius = 4
        addBtn.widthAnchor.constraint(equalToConstant: 22).isActive = true
        addBtn.heightAnchor.constraint(equalToConstant: 22).isActive = true
        addBtn.addAction(UIAction { [weak self] _ in self?.onAdd?() }, for: .touchUpInside)
        headerRow.addArrangedSubview(addBtn)

        stack.addArrangedSubview(headerRow)

        let canDelete = layerInfos.count > 1
        var activeInfo: DTLayerInfo? = nil

        for info in layerInfos.reversed() {
            if info.selected { activeInfo = info }
            let row = LayerRowView(info: info, canDelete: canDelete,
                                   canMoveUp: info.index + 1 < UInt(layerInfos.count),
                                   canMoveDown: info.index > 0)
            row.onSelect = { [weak self] in self?.onSelect?(Int(info.index)) }
            row.onRename = { [weak self] in self?.onRename?(Int(info.index)) }
            row.onDelete = { [weak self] in self?.onDelete?(Int(info.index)) }
            row.onDuplicate = { [weak self] in self?.onDuplicate?(Int(info.index)) }
            row.onMove = { [weak self] offset in self?.onMove?(Int(info.index), Int(info.index) + offset) }
            row.onVisibility = { [weak self] visible in self?.onVisibility?(visible, Int(info.index)) }
            stack.addArrangedSubview(row)
        }

        if let active = activeInfo {
            let opacityBox = UIView()
            opacityBox.backgroundColor = UIColor.white.withAlphaComponent(0.7)
            opacityBox.layer.cornerRadius = 6
            opacityBox.layer.borderWidth = 1
            opacityBox.layer.borderColor = UIColor.black.withAlphaComponent(0.06).cgColor

            let opStack = UIStackView()
            opStack.axis = .vertical
            opStack.spacing = 2
            opStack.translatesAutoresizingMaskIntoConstraints = false
            opacityBox.addSubview(opStack)
            NSLayoutConstraint.activate([
                opStack.leadingAnchor.constraint(equalTo: opacityBox.leadingAnchor, constant: 6),
                opStack.trailingAnchor.constraint(equalTo: opacityBox.trailingAnchor, constant: -6),
                opStack.topAnchor.constraint(equalTo: opacityBox.topAnchor, constant: 4),
                opStack.bottomAnchor.constraint(equalTo: opacityBox.bottomAnchor, constant: -4)
            ])

            let topRow = UIStackView()
            topRow.axis = .horizontal
            topRow.distribution = .equalSpacing

            let alphaLabel = UILabel()
            alphaLabel.text = "α OPACITY"
            alphaLabel.font = .systemFont(ofSize: 8.5, weight: .bold)
            alphaLabel.textColor = UIColor(red: 0.38, green: 0.33, blue: 0.27, alpha: 0.70)
            topRow.addArrangedSubview(alphaLabel)

            let valLabel = UILabel()
            valLabel.text = String(format: "%.0f%%", max(0, min(1, active.opacity)) * 100)
            valLabel.font = .monospacedDigitSystemFont(ofSize: 8.5, weight: .bold)
            valLabel.textColor = UIColor(red: 0.22, green: 0.19, blue: 0.15, alpha: 1)
            topRow.addArrangedSubview(valLabel)
            opStack.addArrangedSubview(topRow)

            let slider = UISlider()
            slider.minimumValue = 0
            slider.maximumValue = 1
            slider.value = Float(max(0, min(1, active.opacity)))
            slider.tintColor = UIColor(red: 0.22, green: 0.19, blue: 0.15, alpha: 1)
            slider.addAction(UIAction { [weak self, weak valLabel] _ in
                valLabel?.text = String(format: "%.0f%%", slider.value * 100)
                self?.onOpacity?(CGFloat(slider.value), Int(active.index))
            }, for: .valueChanged)
            slider.addAction(UIAction { [weak self] _ in
                self?.onOpacityCommit?(CGFloat(slider.value), Int(active.index))
            }, for: [.touchUpInside, .touchUpOutside, .touchCancel])
            opStack.addArrangedSubview(slider)

            stack.addArrangedSubview(opacityBox)
        }
    }
}

private final class LayerRowView: UIView, UIContextMenuInteractionDelegate {
    var onSelect: (() -> Void)?
    var onRename: (() -> Void)?
    var onDelete: (() -> Void)?
    var onDuplicate: (() -> Void)?
    var onMove: ((Int) -> Void)?
    var onVisibility: ((Bool) -> Void)?
    private let info: DTLayerInfo
    private let canDelete: Bool
    private let canMoveUp: Bool
    private let canMoveDown: Bool
    private let nameLabel = UILabel()
    private let opacityLabel = UILabel()
    private let visibilityButton = UIButton(type: .system)
    private let accentBar = UIView()

    init(info: DTLayerInfo, canDelete: Bool, canMoveUp: Bool, canMoveDown: Bool) {
        self.info = info
        self.canDelete = canDelete
        self.canMoveUp = canMoveUp
        self.canMoveDown = canMoveDown
        super.init(frame: .zero)

        backgroundColor = info.selected ? UIColor.systemBlue.withAlphaComponent(0.12) : UIColor.white.withAlphaComponent(0.65)
        layer.cornerRadius = 5
        layer.borderWidth = info.selected ? 1.5 : 1
        layer.borderColor = (info.selected ? UIColor.systemBlue.withAlphaComponent(0.6) : UIColor.black.withAlphaComponent(0.06)).cgColor
        heightAnchor.constraint(equalToConstant: 30).isActive = true

        accentBar.backgroundColor = info.selected ? UIColor.systemBlue : .clear
        accentBar.layer.cornerRadius = 1
        accentBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(accentBar)

        let eyeCfg = UIImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        visibilityButton.setImage(UIImage(systemName: info.visible ? "eye.fill" : "eye.slash", withConfiguration: eyeCfg), for: .normal)
        visibilityButton.tintColor = info.visible ? UIColor(red: 0.22, green: 0.19, blue: 0.15, alpha: 1) : .tertiaryLabel
        visibilityButton.accessibilityLabel = info.visible ? "Hide layer" : "Show layer"
        visibilityButton.translatesAutoresizingMaskIntoConstraints = false
        visibilityButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.onVisibility?(!self.info.visible)
        }, for: .touchUpInside)
        addSubview(visibilityButton)

        nameLabel.text = info.name
        nameLabel.font = .systemFont(ofSize: 9.5, weight: info.selected ? .bold : .regular)
        nameLabel.textColor = UIColor(red: 0.22, green: 0.19, blue: 0.15, alpha: 1)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameLabel)

        opacityLabel.text = String(format: "%.0f%%", max(0, min(1, info.opacity)) * 100)
        opacityLabel.font = .monospacedDigitSystemFont(ofSize: 8.5, weight: .regular)
        opacityLabel.textColor = .secondaryLabel
        opacityLabel.textAlignment = .right
        opacityLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(opacityLabel)

        NSLayoutConstraint.activate([
            accentBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            accentBar.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            accentBar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            accentBar.widthAnchor.constraint(equalToConstant: 2.5),

            visibilityButton.leadingAnchor.constraint(equalTo: accentBar.trailingAnchor, constant: 3),
            visibilityButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            visibilityButton.widthAnchor.constraint(equalToConstant: 20),
            visibilityButton.heightAnchor.constraint(equalToConstant: 20),

            nameLabel.leadingAnchor.constraint(equalTo: visibilityButton.trailingAnchor, constant: 3),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: opacityLabel.leadingAnchor, constant: -2),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            opacityLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            opacityLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            opacityLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 26)
        ])

        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(selected)))
        addInteraction(UIContextMenuInteraction(delegate: self))
        accessibilityLabel = "Layer \(info.name)"
        accessibilityValue = "\(info.visible ? "Visible" : "Hidden"), \(opacityLabel.text ?? "")"
        accessibilityTraits = info.selected ? [.button, .selected] : [.button]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func selected() { onSelect?() }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return UIMenu(title: "", children: []) }
            let rename = UIAction(title: "Rename", image: UIImage(systemName: "pencil")) { [weak self] _ in self?.onRename?() }
            let duplicate = UIAction(title: "Duplicate", image: UIImage(systemName: "plus.square.on.square")) { [weak self] _ in self?.onDuplicate?() }
            let moveUp = UIAction(title: "Move Up", image: UIImage(systemName: "arrow.up"), attributes: self.canMoveUp ? [] : [.disabled]) { [weak self] _ in self?.onMove?(1) }
            let moveDown = UIAction(title: "Move Down", image: UIImage(systemName: "arrow.down"), attributes: self.canMoveDown ? [] : [.disabled]) { [weak self] _ in self?.onMove?(-1) }
            let delete = UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: self.canDelete ? [] : [.disabled]) { [weak self] _ in self?.onDelete?() }
            return UIMenu(title: self.info.name, children: [rename, duplicate, UIMenu(title: "Move", options: .displayInline, children: [moveUp, moveDown]), delete])
        }
    }
}
