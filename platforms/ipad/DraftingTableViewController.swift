import UIKit

private final class InsetLabel: UILabel {
    var contentInsets = UIEdgeInsets.zero

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: contentInsets))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + contentInsets.left + contentInsets.right,
                      height: size.height + contentInsets.top + contentInsets.bottom)
    }
}

/// The first usable iPad shell around the platform-neutral drawing engine.
/// Rails are deliberately lightweight placeholders until the document/page
/// model is connected; they make the canvas orientation and interaction model
/// clear in an unsigned development build.
final class DraftingTableViewController: UIViewController {
    private let canvas = CanvasView(frame: .zero)
    private let diagnostics = DiagnosticsOverlay(frame: .zero)
    private let emptyState = InsetLabel()
    private let pagesRail = UIView()
    private let layersRail = UIView()
    private let toolRail = UIView()

    override func loadView() {
        let root = UIView()
        root.backgroundColor = UIColor(red: 0.965, green: 0.935, blue: 0.865, alpha: 1)
        view = root

        canvas.translatesAutoresizingMaskIntoConstraints = false
        diagnostics.translatesAutoresizingMaskIntoConstraints = false
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        pagesRail.translatesAutoresizingMaskIntoConstraints = false
        layersRail.translatesAutoresizingMaskIntoConstraints = false
        toolRail.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(canvas)
        root.addSubview(pagesRail)
        root.addSubview(layersRail)
        root.addSubview(toolRail)
        root.addSubview(emptyState)
        root.addSubview(diagnostics)

        configureEmptyState()
        configurePagesRail()
        configureLayersRail()
        configureToolRail()

        let safe = root.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            canvas.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: root.topAnchor),
            canvas.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            pagesRail.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 12),
            pagesRail.topAnchor.constraint(equalTo: safe.topAnchor, constant: 12),
            pagesRail.bottomAnchor.constraint(equalTo: toolRail.topAnchor, constant: -12),
            pagesRail.widthAnchor.constraint(equalToConstant: 84),

            layersRail.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -12),
            layersRail.topAnchor.constraint(equalTo: safe.topAnchor, constant: 12),
            layersRail.bottomAnchor.constraint(equalTo: toolRail.topAnchor, constant: -12),
            layersRail.widthAnchor.constraint(equalToConstant: 104),

            toolRail.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 16),
            toolRail.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -16),
            toolRail.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -10),
            toolRail.heightAnchor.constraint(equalToConstant: 62),

            emptyState.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: root.centerYAnchor, constant: -12),
            emptyState.leadingAnchor.constraint(greaterThanOrEqualTo: pagesRail.trailingAnchor, constant: 18),
            emptyState.trailingAnchor.constraint(lessThanOrEqualTo: layersRail.leadingAnchor, constant: -18),

            diagnostics.leadingAnchor.constraint(equalTo: pagesRail.trailingAnchor, constant: 12),
            diagnostics.topAnchor.constraint(equalTo: safe.topAnchor, constant: 16),
            diagnostics.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),
            diagnostics.widthAnchor.constraint(lessThanOrEqualToConstant: 240)
        ])

        canvas.onDiagnostics = { [weak self] text in
            self?.diagnostics.update(text: text)
        }
        canvas.onDrawingBegan = { [weak self] in
            self?.emptyState.isHidden = true
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Drafting Table"
        navigationItem.largeTitleDisplayMode = .never
        navigationController?.navigationBar.prefersLargeTitles = false
        let appearance = navigationAppearance()
        navigationController?.navigationBar.standardAppearance = appearance
        navigationController?.navigationBar.scrollEdgeAppearance = appearance
        navigationController?.navigationBar.compactAppearance = appearance
    }

    private func navigationAppearance() -> UINavigationBarAppearance {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(red: 0.985, green: 0.975, blue: 0.945, alpha: 1)
        appearance.shadowColor = UIColor.black.withAlphaComponent(0.12)
        appearance.titleTextAttributes = [.foregroundColor: UIColor(red: 0.16, green: 0.14, blue: 0.11, alpha: 1)]
        return appearance
    }

    private func configureEmptyState() {
        emptyState.text = "Start drawing with Apple Pencil\nFinger drawing follows your Pencil setting"
        emptyState.textAlignment = .center
        emptyState.numberOfLines = 0
        emptyState.font = .systemFont(ofSize: 17, weight: .medium)
        emptyState.textColor = UIColor(red: 0.27, green: 0.23, blue: 0.18, alpha: 0.78)
        emptyState.backgroundColor = UIColor.white.withAlphaComponent(0.66)
        emptyState.layer.cornerRadius = 14
        emptyState.layer.masksToBounds = true
        emptyState.isUserInteractionEnabled = false
        emptyState.accessibilityLabel = "Empty canvas. Start drawing with Apple Pencil or touch the paper."
        emptyState.setContentHuggingPriority(.required, for: .vertical)
        emptyState.setContentCompressionResistancePriority(.required, for: .vertical)
        emptyState.contentInsets = UIEdgeInsets(top: 14, left: 20, bottom: 14, right: 20)
    }

    private func configurePagesRail() {
        styleRail(pagesRail)
        let stack = UIStackView(arrangedSubviews: [railTitle("PAGES"), pageCard(), disabledPlaceholder(title: "New page · soon")])
        stack.axis = .vertical
        stack.spacing = 10
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        pagesRail.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: pagesRail.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: pagesRail.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: pagesRail.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: pagesRail.bottomAnchor, constant: -10)
        ])
    }

    private func configureLayersRail() {
        styleRail(layersRail)
        let stack = UIStackView(arrangedSubviews: [railTitle("LAYERS"), layerRow("✎", "Ink", selected: true), layerRow("□", "Paper", selected: false), disabledPlaceholder(title: "New layer · soon")])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        layersRail.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: layersRail.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: layersRail.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: layersRail.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: layersRail.bottomAnchor, constant: -10)
        ])
    }

    private func configureToolRail() {
        styleRail(toolRail)
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(toolButton(title: "✎  Brush", action: nil))
        stack.addArrangedSubview(toolButton(title: "↶  Undo", action: #selector(undoCanvas)))
        stack.addArrangedSubview(toolButton(title: "⌫  Clear", action: #selector(clearCanvas)))
        toolRail.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: toolRail.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: toolRail.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: toolRail.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: toolRail.bottomAnchor, constant: -8)
        ])
    }

    private func styleRail(_ rail: UIView) {
        rail.backgroundColor = UIColor(red: 0.99, green: 0.98, blue: 0.95, alpha: 0.94)
        rail.layer.cornerRadius = 12
        rail.layer.borderWidth = 1
        rail.layer.borderColor = UIColor(red: 0.35, green: 0.30, blue: 0.23, alpha: 0.14).cgColor
        rail.layer.shadowColor = UIColor.black.cgColor
        rail.layer.shadowOpacity = 0.08
        rail.layer.shadowRadius = 8
        rail.layer.shadowOffset = CGSize(width: 0, height: 2)
    }

    private func railTitle(_ title: String) -> UILabel {
        let label = UILabel()
        label.text = title
        label.font = .systemFont(ofSize: 10, weight: .bold)
        label.textColor = UIColor(red: 0.38, green: 0.33, blue: 0.27, alpha: 0.70)
        label.textAlignment = .center
        return label
    }

    private func pageCard() -> UIView {
        let card = UIView()
        card.backgroundColor = UIColor.white.withAlphaComponent(0.9)
        card.layer.cornerRadius = 7
        card.layer.borderWidth = 2
        card.layer.borderColor = UIColor.systemBlue.withAlphaComponent(0.75).cgColor
        card.heightAnchor.constraint(equalToConstant: 82).isActive = true
        let label = UILabel()
        label.text = "1"
        label.font = .systemFont(ofSize: 22, weight: .semibold)
        label.textColor = UIColor(red: 0.22, green: 0.19, blue: 0.15, alpha: 1)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: card.centerYAnchor)
        ])
        card.accessibilityLabel = "Page 1, selected"
        return card
    }

    private func layerRow(_ icon: String, _ name: String, selected: Bool) -> UIView {
        let row = UIView()
        row.backgroundColor = selected ? UIColor.systemBlue.withAlphaComponent(0.12) : .clear
        row.layer.cornerRadius = 7
        row.heightAnchor.constraint(equalToConstant: 34).isActive = true
        let label = UILabel()
        label.text = "\(icon)  \(name)"
        label.font = .systemFont(ofSize: 13, weight: selected ? .semibold : .regular)
        label.textColor = UIColor(red: 0.22, green: 0.19, blue: 0.15, alpha: 1)
        label.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        row.accessibilityLabel = "Layer \(name)"
        return row
    }

    private func disabledPlaceholder(title: String) -> UILabel {
        let label = UILabel()
        label.text = title
        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return label
    }

    private func toolButton(title: String, action: Selector?) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        button.setTitleColor(UIColor(red: 0.16, green: 0.14, blue: 0.11, alpha: 1), for: .normal)
        button.backgroundColor = UIColor.white.withAlphaComponent(0.82)
        button.layer.cornerRadius = 9
        button.layer.borderWidth = 1
        button.layer.borderColor = UIColor.black.withAlphaComponent(0.08).cgColor
        if let action { button.addTarget(self, action: action, for: .touchUpInside) }
        button.accessibilityLabel = title
        return button
    }

    @objc private func undoCanvas() {
        _ = canvas.engineBridge.undoLastStroke()
        emptyState.isHidden = canvas.engineBridge.strokeCount != 0
    }

    @objc private func clearCanvas() {
        canvas.engineBridge.clearCanvas()
        canvas.setNeedsDisplay()
        emptyState.isHidden = false
    }
}
