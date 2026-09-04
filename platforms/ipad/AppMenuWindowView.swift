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

    // Concept A's Android PopupWindow sizes itself to the menu content. Keep
    // a generous single-line width so the longest archive/export labels never
    // wrap, while the 9pt vertical row padding still keeps the menu compact.
    private let windowWidth: CGFloat = 336.0
    private let windowHeight: CGFloat = 430.0

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
        backgroundColor = DraftingTheme.paper
        layer.cornerRadius = 0
        layer.borderWidth = 1
        layer.borderColor = DraftingTheme.rule.cgColor
        layer.shadowOpacity = 0
        clipsToBounds = true

        // Header
        let header = UIView()
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)

        headerTitleLabel.text = "DRAFTING TABLE"
        headerTitleLabel.font = DraftingTheme.mono(size: 11, weight: .semibold)
        headerTitleLabel.adjustsFontSizeToFitWidth = true
        headerTitleLabel.minimumScaleFactor = 0.85
        headerTitleLabel.textColor = DraftingTheme.ink
        headerTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(headerTitleLabel)

        let closeBtn = UIButton(type: .system)
        closeBtn.setImage(DraftingIcon.image(named: "close", fallback: "xmark",
                                             configuration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)), for: .normal)
        closeBtn.tintColor = DraftingTheme.inkSoft
        closeBtn.translatesAutoresizingMaskIntoConstraints = false
        closeBtn.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)
        header.addSubview(closeBtn)

        backButton.setImage(DraftingIcon.image(named: "back", fallback: "chevron.backward",
                                               configuration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)), for: .normal)
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
            header.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            header.heightAnchor.constraint(equalToConstant: 24),

            backButton.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            backButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 24),
            backButton.heightAnchor.constraint(equalToConstant: 24),

            headerTitleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            closeBtn.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            closeBtn.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            closeBtn.widthAnchor.constraint(equalToConstant: 26),
            closeBtn.heightAnchor.constraint(equalToConstant: 26),

            rule.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),

            mainContainer.topAnchor.constraint(equalTo: rule.bottomAnchor),
            mainContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            mainContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            mainContainer.bottomAnchor.constraint(equalTo: bottomAnchor),

            exportContainer.topAnchor.constraint(equalTo: rule.bottomAnchor, constant: 6),
            exportContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            exportContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            exportContainer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    private func setupMainActions() {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.distribution = .fill
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        mainContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: mainContainer.topAnchor),
            stack.leadingAnchor.constraint(equalTo: mainContainer.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: mainContainer.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: mainContainer.bottomAnchor)
        ])

        // Keep this list in the same order as the upstream overflow menu. The
        // v0.1 renderer only implements open/rename/settings/reset; the other
        // rows remain visible as disabled ink so the preview makes its scope
        // explicit while still routing taps to the controller's toast contract.
        let items: [(String, String, Action, Bool)] = [
            ("Open .drafttable…", "docs", .notebooksGallery, true),
            ("Rename current…", "more", .renameDocument, true),
            ("Import image…", "color", .importPhoto, false),
            ("Export canvas as PNG…", "docs", .exportPNG, false),
            ("Export document as PDF…", "docs", .exportPDF, false),
            ("Backup all documents…", "docs", .saveArchive, false),
            ("Drawing settings…", "settings", .settings, true),
            ("Reset canvas view", "reset_view", .resetView, true),
            ("Clear entire document", "clear", .clearDocument, false)
        ]
        for (index, item) in items.enumerated() {
            stack.addArrangedSubview(menuRow(title: item.0, icon: item.1,
                                             action: item.2, enabled: item.3))
            if index < items.count - 1 {
                let divider = UIView()
                divider.backgroundColor = DraftingTheme.rule
                divider.translatesAutoresizingMaskIntoConstraints = false
                stack.addArrangedSubview(divider)
                divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
            }
        }
    }

    private func setupExportActions() {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.distribution = .fillEqually
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        exportContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: exportContainer.topAnchor),
            stack.leadingAnchor.constraint(equalTo: exportContainer.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: exportContainer.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: exportContainer.bottomAnchor)
        ])

        stack.addArrangedSubview(menuRow(title: "Export Current Page (PNG)", icon: "photo", action: .exportPNG))
        stack.addArrangedSubview(menuRow(title: "Export All Pages (PDF)", icon: "doc.richtext", action: .exportPDF))
        stack.addArrangedSubview(menuRow(title: "Save Archive Copy (.drafttable)", icon: "archivebox", action: .saveArchive))
    }

    private func showExportMode() {
        headerTitleLabel.text = "EXPORT"
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
        headerTitleLabel.text = "DRAFTING TABLE"
        headerLeadingWithBack?.isActive = false
        headerLeadingWithoutBack?.isActive = true
        backButton.isHidden = true
        UIView.transition(with: self, duration: 0.18, options: .transitionCrossDissolve) {
            self.mainContainer.isHidden = false
            self.exportContainer.isHidden = true
            self.layoutIfNeeded()
        }
    }

    private func menuRow(title: String, icon: String, isDestructive: Bool = false,
                         action: Action? = nil, enabled: Bool = true,
                         customAction: (() -> Void)? = nil) -> UIButton {
        let button = UIButton(type: .system)
        let primaryColor = isDestructive ? DraftingTheme.hot :
            (enabled ? DraftingTheme.ink : DraftingTheme.inkDisabled)
        button.setImage(DraftingIcon.image(named: icon), for: .normal)
        button.setTitle(title, for: .normal)
        button.setTitleColor(primaryColor, for: .normal)
        button.tintColor = primaryColor
        button.titleLabel?.font = DraftingTheme.mono(size: 13)
        button.titleLabel?.numberOfLines = 1
        button.titleLabel?.lineBreakMode = .byTruncatingTail
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.82
        button.imageView?.contentMode = .scaleAspectFit
        button.imageView?.tintColor = primaryColor
        button.semanticContentAttribute = .forceLeftToRight
        button.imageEdgeInsets = UIEdgeInsets(top: 0, left: 14, bottom: 0, right: 8)
        button.titleEdgeInsets = UIEdgeInsets(top: 0, left: 8, bottom: 0, right: 14)
        button.contentEdgeInsets = UIEdgeInsets(top: 9, left: 0, bottom: 9, right: 0)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 38).isActive = true
        button.contentHorizontalAlignment = .leading
        button.backgroundColor = enabled ? DraftingTheme.paper : DraftingTheme.paper.withAlphaComponent(0.82)
        button.accessibilityTraits = enabled ? [.button] : [.button, .notEnabled]
        button.accessibilityHint = enabled ? nil : "Unavailable in the v0.1 preview"

        button.addAction(UIAction { [weak self] _ in
            if enabled { HapticFeedbackService.shared.toolSwitched() }
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
        let fittedWidth = min(windowWidth, max(1, parentView.bounds.width - safeMargin * 2))
        let fittedHeight = min(windowHeight, max(1, parentView.bounds.height - safeMargin * 2))
        let posX = max(safeMargin, min(anchor.x, parentView.bounds.width - fittedWidth - safeMargin))
        let posY = max(safeMargin, min(anchor.y, parentView.bounds.height - fittedHeight - safeMargin))
        frame = CGRect(x: posX, y: posY, width: fittedWidth, height: fittedHeight)

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
