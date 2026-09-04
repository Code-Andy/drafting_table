import UIKit

/// Built-in in-app menu window replacing modal action sheets with a compact,
/// non-scrolling palette window styled in the Drafting Table paper design.
final class AppMenuWindowView: UIView {
    enum Action {
        case notebooksGallery
        case renameDocument
        case exportPNG
        case exportPDF
        case saveArchive
        case importPhoto
        case settings
        case resetView
        case clearDocument
    }

    var onAction: ((Action) -> Void)?

    private let windowWidth: CGFloat = 270.0
    private let windowHeight: CGFloat = 345.0

    private let mainContainer = UIView()
    private let exportContainer = UIView()
    private let headerTitleLabel = UILabel()
    private let backButton = UIButton(type: .system)
    private var headerLeadingWithoutBack: NSLayoutConstraint?
    private var headerLeadingWithBack: NSLayoutConstraint?

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: windowWidth, height: windowHeight))
        setupWindow()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupWindow() {
        backgroundColor = DraftingTheme.paperDeep.withAlphaComponent(0.98)
        layer.cornerRadius = 14
        layer.borderWidth = 1.5
        layer.borderColor = DraftingTheme.rule.cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.20
        layer.shadowRadius = 14
        layer.shadowOffset = CGSize(width: 0, height: 4)
        clipsToBounds = false

        // Header
        let header = UIView()
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)

        headerTitleLabel.text = "Drafting Table"
        headerTitleLabel.font = .systemFont(ofSize: 13, weight: .bold)
        headerTitleLabel.textColor = DraftingTheme.ink
        headerTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(headerTitleLabel)

        let closeBtn = UIButton(type: .system)
        let closeCfg = UIImage.SymbolConfiguration(pointSize: 12, weight: .bold)
        closeBtn.setImage(UIImage(systemName: "xmark", withConfiguration: closeCfg), for: .normal)
        closeBtn.tintColor = DraftingTheme.inkSoft
        closeBtn.translatesAutoresizingMaskIntoConstraints = false
        closeBtn.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)
        header.addSubview(closeBtn)

        let backCfg = UIImage.SymbolConfiguration(pointSize: 12, weight: .bold)
        backButton.setImage(UIImage(systemName: "chevron.backward", withConfiguration: backCfg), for: .normal)
        backButton.tintColor = DraftingTheme.ink
        backButton.translatesAutoresizingMaskIntoConstraints = false
        backButton.isHidden = true
        backButton.addAction(UIAction { [weak self] _ in self?.showMainMenuMode() }, for: .touchUpInside)
        header.addSubview(backButton)

        headerLeadingWithoutBack = headerTitleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 4)
        headerLeadingWithBack = headerTitleLabel.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 6)
        headerLeadingWithoutBack?.isActive = true

        let rule = UIView()
        rule.backgroundColor = DraftingTheme.rule
        rule.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rule)

        // Main actions container
        mainContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(mainContainer)
        setupMainActions()

        // Export sub-view container
        exportContainer.translatesAutoresizingMaskIntoConstraints = false
        exportContainer.isHidden = true
        addSubview(exportContainer)
        setupExportActions()

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            header.heightAnchor.constraint(equalToConstant: 32),

            backButton.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            backButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 24),
            backButton.heightAnchor.constraint(equalToConstant: 24),

            headerTitleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            closeBtn.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            closeBtn.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            closeBtn.widthAnchor.constraint(equalToConstant: 26),
            closeBtn.heightAnchor.constraint(equalToConstant: 26),

            rule.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),

            mainContainer.topAnchor.constraint(equalTo: rule.bottomAnchor, constant: 6),
            mainContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            mainContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            mainContainer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

            exportContainer.topAnchor.constraint(equalTo: rule.bottomAnchor, constant: 6),
            exportContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            exportContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            exportContainer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    private func setupMainActions() {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.distribution = .fillEqually
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        mainContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: mainContainer.topAnchor),
            stack.leadingAnchor.constraint(equalTo: mainContainer.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: mainContainer.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: mainContainer.bottomAnchor)
        ])

        stack.addArrangedSubview(menuRow(title: "Notebooks Gallery", icon: "books.vertical.fill", action: .notebooksGallery))
        stack.addArrangedSubview(menuRow(title: "Rename Document", icon: "pencil", action: .renameDocument))
        stack.addArrangedSubview(menuRow(title: "Export & Share...", icon: "square.and.arrow.up", customAction: { [weak self] in
            self?.showExportMode()
        }))
        stack.addArrangedSubview(menuRow(title: "Import Photo...", icon: "photo.on.rectangle", action: .importPhoto))
        stack.addArrangedSubview(menuRow(title: "Drawing Settings...", icon: "gearshape.fill", action: .settings))
        stack.addArrangedSubview(menuRow(title: "Reset Canvas View", icon: "arrow.down.right.and.arrow.up.left", action: .resetView))
        stack.addArrangedSubview(menuRow(title: "Clear Document", icon: "trash.fill", isDestructive: true, action: .clearDocument))
    }

    private func setupExportActions() {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.distribution = .fillEqually
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        exportContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: exportContainer.topAnchor, constant: 6),
            stack.leadingAnchor.constraint(equalTo: exportContainer.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: exportContainer.trailingAnchor),
            stack.heightAnchor.constraint(equalToConstant: 160)
        ])

        stack.addArrangedSubview(menuRow(title: "Export Current Page (PNG)", icon: "photo", action: .exportPNG))
        stack.addArrangedSubview(menuRow(title: "Export All Pages (PDF)", icon: "doc.richtext", action: .exportPDF))
        stack.addArrangedSubview(menuRow(title: "Save Archive Copy (.drafttable)", icon: "archivebox", action: .saveArchive))
    }

    private func showExportMode() {
        headerTitleLabel.text = "Export & Share"
        headerLeadingWithoutBack?.isActive = false
        headerLeadingWithBack?.isActive = true
        backButton.isHidden = false
        UIView.transition(with: self, duration: 0.18, options: .transitionCrossDissolve) {
            self.mainContainer.isHidden = true
            self.exportContainer.isHidden = false
            self.layoutIfNeeded()
        }
    }

    private func showMainMenuMode() {
        headerTitleLabel.text = "Drafting Table"
        headerLeadingWithBack?.isActive = false
        headerLeadingWithoutBack?.isActive = true
        backButton.isHidden = true
        UIView.transition(with: self, duration: 0.18, options: .transitionCrossDissolve) {
            self.mainContainer.isHidden = false
            self.exportContainer.isHidden = true
            self.layoutIfNeeded()
        }
    }

    private func menuRow(title: String, icon: String, isDestructive: Bool = false, action: Action? = nil, customAction: (() -> Void)? = nil) -> UIButton {
        let button = UIButton(type: .system)
        var cfg = UIButton.Configuration.plain()
        cfg.image = UIImage(systemName: icon)
        var titleAttr = AttributedString(title)
        titleAttr.font = .systemFont(ofSize: 12.5, weight: .semibold)
        cfg.attributedTitle = titleAttr
        cfg.imagePadding = 8
        let primaryColor = isDestructive ? DraftingTheme.hot : DraftingTheme.ink
        cfg.baseForegroundColor = primaryColor
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10)
        button.configuration = cfg
        button.contentHorizontalAlignment = .leading
        button.backgroundColor = isDestructive ? DraftingTheme.hot.withAlphaComponent(0.08) : UIColor.white.withAlphaComponent(0.72)
        button.layer.cornerRadius = 8
        button.layer.borderWidth = 1
        button.layer.borderColor = isDestructive ? DraftingTheme.hot.withAlphaComponent(0.25).cgColor : DraftingTheme.rule.withAlphaComponent(0.6).cgColor

        button.addAction(UIAction { [weak self] _ in
            HapticFeedbackService.shared.toolSwitched()
            if let customAction {
                customAction()
            } else if let action {
                self?.dismiss(animated: true) {
                    self?.onAction?(action)
                }
            }
        }, for: .touchUpInside)

        return button
    }

    func present(in parentView: UIView, near anchor: CGPoint) {
        let safeMargin: CGFloat = 12.0
        let posX = min(max(anchor.x, safeMargin), parentView.bounds.width - windowWidth - safeMargin)
        let posY = min(max(anchor.y, safeMargin), parentView.bounds.height - windowHeight - safeMargin)
        frame = CGRect(x: posX, y: posY, width: windowWidth, height: windowHeight)

        let dismissOverlay = UIView(frame: parentView.bounds)
        dismissOverlay.backgroundColor = UIColor.black.withAlphaComponent(0.12)
        dismissOverlay.tag = 89912
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleOutsideTap))
        dismissOverlay.addGestureRecognizer(tap)
        parentView.addSubview(dismissOverlay)

        parentView.addSubview(self)
        transform = CGAffineTransform(scaleX: 0.90, y: 0.90)
        alpha = 0.0

        HapticFeedbackService.shared.toolSwitched()

        UIView.animate(withDuration: 0.22, delay: 0, usingSpringWithDamping: 0.82, initialSpringVelocity: 0.8, options: .curveEaseOut) {
            self.transform = .identity
            self.alpha = 1.0
            dismissOverlay.alpha = 1.0
        }
    }

    @objc private func handleOutsideTap() {
        dismiss(animated: true)
    }

    func dismiss(animated: Bool, completion: (() -> Void)? = nil) {
        let overlay = superview?.viewWithTag(89912)
        if animated {
            UIView.animate(withDuration: 0.16, delay: 0, options: .curveEaseIn, animations: {
                self.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
                self.alpha = 0.0
                overlay?.alpha = 0.0
            }) { _ in
                overlay?.removeFromSuperview()
                self.removeFromSuperview()
                completion?()
            }
        } else {
            overlay?.removeFromSuperview()
            self.removeFromSuperview()
            completion?()
        }
    }
}
