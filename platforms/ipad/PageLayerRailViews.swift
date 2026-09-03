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
        stack.spacing = 10
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
        docCfg.title = "DOCS ∨"
        docCfg.imagePadding = 4
        docCfg.baseForegroundColor = UIColor(red: 0.22, green: 0.19, blue: 0.15, alpha: 1)
        docsBtn.configuration = docCfg
        docsBtn.titleLabel?.font = .systemFont(ofSize: 11, weight: .bold)
        docsBtn.backgroundColor = UIColor.white.withAlphaComponent(0.85)
        docsBtn.layer.cornerRadius = 6
        docsBtn.layer.borderWidth = 1
        docsBtn.layer.borderColor = UIColor.black.withAlphaComponent(0.08).cgColor
        docsBtn.heightAnchor.constraint(equalToConstant: 30).isActive = true
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
        add.layer.cornerRadius = 7
        add.heightAnchor.constraint(equalToConstant: 38).isActive = true
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
        config.title = "\(Int(info.index) + 1)\n\(info.name)"
        config.titleAlignment = .center
        config.image = thumbnail
        config.imagePlacement = .top
        config.imagePadding = 3
        config.baseForegroundColor = UIColor(red: 0.22, green: 0.19, blue: 0.15, alpha: 1)
        config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 3, bottom: 8, trailing: 3)
        self.configuration = config
        titleLabel?.font = .systemFont(ofSize: 13, weight: info.selected ? .semibold : .regular)
        titleLabel?.numberOfLines = 2
        backgroundColor = info.selected ? UIColor.systemBlue.withAlphaComponent(0.12) : UIColor.white.withAlphaComponent(0.9)
        layer.cornerRadius = 7
        layer.borderWidth = info.selected ? 2 : 1
        layer.borderColor = (info.selected ? UIColor.systemBlue.withAlphaComponent(0.75) : UIColor.black.withAlphaComponent(0.08)).cgColor
        heightAnchor.constraint(greaterThanOrEqualToConstant: 64).isActive = true
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
        stack.spacing = 8
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
        stack.addArrangedSubview(titleLabel("LAYERS"))
        let canDelete = layerInfos.count > 1
        for info in layerInfos {
            let row = LayerRowView(info: info, canDelete: canDelete,
                                   canMoveUp: info.index > 0,
                                   canMoveDown: info.index + 1 < UInt(layerInfos.count))
            row.onSelect = { [weak self] in self?.onSelect?(Int(info.index)) }
            row.onRename = { [weak self] in self?.onRename?(Int(info.index)) }
            row.onDelete = { [weak self] in self?.onDelete?(Int(info.index)) }
            row.onDuplicate = { [weak self] in self?.onDuplicate?(Int(info.index)) }
            row.onMove = { [weak self] offset in self?.onMove?(Int(info.index), Int(info.index) + offset) }
            row.onVisibility = { [weak self] visible in self?.onVisibility?(visible, Int(info.index)) }
            row.onOpacity = { [weak self] opacity in self?.onOpacity?(opacity, Int(info.index)) }
            row.onOpacityCommit = { [weak self] opacity in self?.onOpacityCommit?(opacity, Int(info.index)) }
            stack.addArrangedSubview(row)
        }
        let add = UIButton(type: .system)
        var addCfg = UIButton.Configuration.plain()
        addCfg.image = UIImage(systemName: "plus")
        addCfg.title = "Layer"
        addCfg.imagePadding = 4
        addCfg.baseForegroundColor = .systemBlue
        add.configuration = addCfg
        add.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.08)
        add.layer.cornerRadius = 7
        add.heightAnchor.constraint(equalToConstant: 34).isActive = true
        add.accessibilityLabel = "Add layer"
        add.addAction(UIAction { [weak self] _ in self?.onAdd?() }, for: .touchUpInside)
        stack.addArrangedSubview(add)
    }
}

private final class LayerRowView: UIView, UIContextMenuInteractionDelegate {
    var onSelect: (() -> Void)?
    var onRename: (() -> Void)?
    var onDelete: (() -> Void)?
    var onDuplicate: (() -> Void)?
    var onMove: ((Int) -> Void)?
    var onVisibility: ((Bool) -> Void)?
    var onOpacity: ((CGFloat) -> Void)?
    var onOpacityCommit: ((CGFloat) -> Void)?
    private let info: DTLayerInfo
    private let canDelete: Bool
    private let canMoveUp: Bool
    private let canMoveDown: Bool
    private let nameLabel = UILabel()
    private let opacityLabel = UILabel()
    private let visibilityButton = UIButton(type: .system)
    private let opacitySlider = UISlider()

    init(info: DTLayerInfo, canDelete: Bool, canMoveUp: Bool, canMoveDown: Bool) {
        self.info = info
        self.canDelete = canDelete
        self.canMoveUp = canMoveUp
        self.canMoveDown = canMoveDown
        super.init(frame: .zero)
        backgroundColor = info.selected ? UIColor.systemBlue.withAlphaComponent(0.12) : .clear
        layer.cornerRadius = 7
        heightAnchor.constraint(equalToConstant: 58).isActive = true
        nameLabel.text = info.name
        nameLabel.font = .systemFont(ofSize: 12, weight: info.selected ? .semibold : .regular)
        nameLabel.textColor = UIColor(red: 0.22, green: 0.19, blue: 0.15, alpha: 1)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        opacityLabel.text = String(format: "%.0f%%", max(0, min(1, info.opacity)) * 100)
        opacityLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        opacityLabel.textColor = .secondaryLabel
        opacityLabel.textAlignment = .right
        opacityLabel.translatesAutoresizingMaskIntoConstraints = false
        visibilityButton.setImage(UIImage(systemName: info.visible ? "eye.fill" : "eye.slash"), for: .normal)
        visibilityButton.tintColor = info.visible ? .systemBlue : .secondaryLabel
        visibilityButton.accessibilityLabel = info.visible ? "Hide layer" : "Show layer"
        visibilityButton.translatesAutoresizingMaskIntoConstraints = false
        visibilityButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.onVisibility?(!self.info.visible)
        }, for: .touchUpInside)
        opacitySlider.minimumValue = 0
        opacitySlider.maximumValue = 1
        opacitySlider.value = Float(max(0, min(1, info.opacity)))
        opacitySlider.isContinuous = true
        opacitySlider.accessibilityLabel = "Layer opacity"
        opacitySlider.accessibilityValue = opacityLabel.text
        opacitySlider.translatesAutoresizingMaskIntoConstraints = false
        opacitySlider.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            let slider = self.opacitySlider
            self.opacityLabel.text = String(format: "%.0f%%", slider.value * 100)
            self.opacitySlider.accessibilityValue = self.opacityLabel.text
            self.onOpacity?(CGFloat(slider.value))
        }, for: .valueChanged)
        opacitySlider.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.onOpacityCommit?(CGFloat(self.opacitySlider.value))
        }, for: [.touchUpInside, .touchUpOutside, .touchCancel])
        addSubview(nameLabel); addSubview(opacityLabel); addSubview(visibilityButton); addSubview(opacitySlider)
        NSLayoutConstraint.activate([
            visibilityButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            visibilityButton.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            visibilityButton.widthAnchor.constraint(equalToConstant: 24),
            visibilityButton.heightAnchor.constraint(equalToConstant: 24),
            nameLabel.leadingAnchor.constraint(equalTo: visibilityButton.trailingAnchor, constant: 2),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: opacityLabel.leadingAnchor, constant: -2),
            nameLabel.centerYAnchor.constraint(equalTo: visibilityButton.centerYAnchor),
            opacityLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            opacityLabel.centerYAnchor.constraint(equalTo: visibilityButton.centerYAnchor),
            opacityLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 30),
            opacitySlider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            opacitySlider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            opacitySlider.topAnchor.constraint(equalTo: visibilityButton.bottomAnchor, constant: 0),
            opacitySlider.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2)
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
            let moveUp = UIAction(title: "Move Up", image: UIImage(systemName: "arrow.up"), attributes: self.canMoveUp ? [] : [.disabled]) { [weak self] _ in self?.onMove?(-1) }
            let moveDown = UIAction(title: "Move Down", image: UIImage(systemName: "arrow.down"), attributes: self.canMoveDown ? [] : [.disabled]) { [weak self] _ in self?.onMove?(1) }
            let delete = UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: self.canDelete ? [] : [.disabled]) { [weak self] _ in self?.onDelete?() }
            return UIMenu(title: self.info.name, children: [rename, duplicate, UIMenu(title: "Move", options: .displayInline, children: [moveUp, moveDown]), delete])
        }
    }
}
