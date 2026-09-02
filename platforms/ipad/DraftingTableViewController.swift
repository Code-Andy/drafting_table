import UIKit

private final class InsetLabel: UILabel {
    var contentInsets = UIEdgeInsets.zero
    override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: contentInsets)) }
    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + contentInsets.left + contentInsets.right,
                      height: size.height + contentInsets.top + contentInsets.bottom)
    }
}

/// The iPad shell around the platform-neutral drawing engine. Pages and layers
/// remain visibly labelled placeholders until their document model is connected.
final class DraftingTableViewController: UIViewController {
    private static let selectedToolDefaultsKey = "draftingTable.selectedTool"
    private let canvas = CanvasView(frame: .zero)
    private let diagnostics = DiagnosticsOverlay(frame: .zero)
    private let emptyState = InsetLabel()
    private let pagesRail = PagesRailView(frame: .zero)
    private let layersRail = LayersRailView(frame: .zero)
    private let toolRail = UIView()
    private let persistence = StrokePersistenceStore()
    private var brushButton: UIButton!
    private var eraserButton: UIButton!
    private var undoButton: UIButton!
    private var redoButton: UIButton!
    private var clearButton: UIButton!
    private var settingsButton: UIButton!
    private var selectedTool: DTTool = .brush

    override func loadView() {
        let root = UIView()
        root.backgroundColor = UIColor(red: 0.965, green: 0.935, blue: 0.865, alpha: 1)
        view = root
        [canvas, diagnostics, emptyState, pagesRail, layersRail, toolRail].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview($0)
        }
        configureEmptyState(); configurePagesRail(); configureLayersRail(); configureToolRail()

        let safe = root.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            canvas.leadingAnchor.constraint(equalTo: root.leadingAnchor), canvas.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: root.topAnchor), canvas.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            pagesRail.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 12), pagesRail.topAnchor.constraint(equalTo: safe.topAnchor, constant: 12),
            pagesRail.bottomAnchor.constraint(equalTo: toolRail.topAnchor, constant: -12), pagesRail.widthAnchor.constraint(equalToConstant: 84),
            layersRail.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -12), layersRail.topAnchor.constraint(equalTo: safe.topAnchor, constant: 12),
            layersRail.bottomAnchor.constraint(equalTo: toolRail.topAnchor, constant: -12), layersRail.widthAnchor.constraint(equalToConstant: 156),
            toolRail.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 16), toolRail.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -16),
            toolRail.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -10), toolRail.heightAnchor.constraint(equalToConstant: 74),
            emptyState.centerXAnchor.constraint(equalTo: root.centerXAnchor), emptyState.centerYAnchor.constraint(equalTo: root.centerYAnchor, constant: -12),
            emptyState.leadingAnchor.constraint(greaterThanOrEqualTo: pagesRail.trailingAnchor, constant: 18), emptyState.trailingAnchor.constraint(lessThanOrEqualTo: layersRail.leadingAnchor, constant: -18),
            diagnostics.leadingAnchor.constraint(equalTo: pagesRail.trailingAnchor, constant: 12), diagnostics.topAnchor.constraint(equalTo: safe.topAnchor, constant: 16),
            diagnostics.widthAnchor.constraint(greaterThanOrEqualToConstant: 150), diagnostics.widthAnchor.constraint(lessThanOrEqualToConstant: 240)
        ])
        canvas.onDiagnostics = { [weak self] text in self?.diagnostics.update(text: text) }
        canvas.onDrawingBegan = { [weak self] in self?.emptyState.isHidden = true }
        canvas.onDocumentChanged = { [weak self] in self?.documentDidChange() }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Drafting Table"; navigationItem.largeTitleDisplayMode = .never
        navigationController?.navigationBar.prefersLargeTitles = false
        let appearance = navigationAppearance()
        navigationController?.navigationBar.standardAppearance = appearance
        navigationController?.navigationBar.scrollEdgeAppearance = appearance
        navigationController?.navigationBar.compactAppearance = appearance
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Reset View",
            style: .plain,
            target: self,
            action: #selector(resetCanvasView)
        )
        restoreDocument(); applyStoredSettings(); refreshRails(); updateToolSelection(); updateUndoRedoState()
    }

    /// Called by the scene delegate before suspension as a final autosave.
    func saveDocument() {
        do { try persistence.save(canvas.engineBridge.archiveData()) } catch { /* retry on next mutation */ }
    }

    private func documentDidChange() {
        saveDocument(); emptyState.isHidden = canvas.engineBridge.strokeCount > 0
        refreshRails()
        updateUndoRedoState(); canvas.setNeedsDisplay()
    }

    private func restoreDocument() {
        guard let data = persistence.load() else { return }
        guard canvas.engineBridge.loadArchiveData(data) else {
            persistence.quarantineCorruptArchive()
            return
        }
        emptyState.isHidden = canvas.engineBridge.strokeCount > 0; canvas.setNeedsDisplay(); refreshRails()
    }

    private func applyStoredSettings() {
        let defaults = UserDefaults.standard
        let activation = min(max(storedFloat(defaults, key: DrawingSettingsViewController.activationKey, fallback: 3), 0), 20)
        let size = min(max(storedFloat(defaults, key: DrawingSettingsViewController.brushSizeKey, fallback: 8), 1), 40)
        let opacity = min(max(storedFloat(defaults, key: DrawingSettingsViewController.brushOpacityKey, fallback: 100), 5), 100)
        canvas.activationPressure = CGFloat(activation / 100)
        canvas.engineBridge.brushSize = CGFloat(size); canvas.engineBridge.brushOpacity = CGFloat(opacity / 100)
        selectedTool = defaults.integer(forKey: Self.selectedToolDefaultsKey) == Int(DTTool.eraser.rawValue)
            ? .eraser : .brush
        canvas.engineBridge.tool = selectedTool
    }

    private func storedFloat(_ defaults: UserDefaults, key: String, fallback: Float) -> Float {
        defaults.object(forKey: key) == nil ? fallback : defaults.float(forKey: key)
    }

    private func showSettings() {
        let settings = DrawingSettingsViewController()
        settings.onActivationChanged = { [weak self] value in self?.canvas.activationPressure = value }
        settings.onBrushSizeChanged = { [weak self] value in self?.canvas.engineBridge.brushSize = value; self?.saveDocument() }
        settings.onBrushOpacityChanged = { [weak self] value in self?.canvas.engineBridge.brushOpacity = value; self?.saveDocument() }
        let navigation = UINavigationController(rootViewController: settings); navigation.modalPresentationStyle = .formSheet
        if let sheet = navigation.sheetPresentationController { sheet.detents = [.medium(), .large()]; sheet.prefersGrabberVisible = true }
        present(navigation, animated: true)
    }

    private func navigationAppearance() -> UINavigationBarAppearance {
        let appearance = UINavigationBarAppearance(); appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(red: 0.985, green: 0.975, blue: 0.945, alpha: 1); appearance.shadowColor = UIColor.black.withAlphaComponent(0.12)
        appearance.titleTextAttributes = [.foregroundColor: UIColor(red: 0.16, green: 0.14, blue: 0.11, alpha: 1)]; return appearance
    }

    private func configureEmptyState() {
        emptyState.text = "Start drawing with Apple Pencil\nFinger drawing follows your Pencil setting"; emptyState.textAlignment = .center; emptyState.numberOfLines = 0
        emptyState.font = .systemFont(ofSize: 17, weight: .medium); emptyState.textColor = UIColor(red: 0.27, green: 0.23, blue: 0.18, alpha: 0.78)
        emptyState.backgroundColor = UIColor.white.withAlphaComponent(0.66); emptyState.layer.cornerRadius = 14; emptyState.layer.masksToBounds = true; emptyState.isUserInteractionEnabled = false
        emptyState.accessibilityLabel = "Empty canvas. Start drawing with Apple Pencil or touch the paper."; emptyState.setContentHuggingPriority(.required, for: .vertical); emptyState.setContentCompressionResistancePriority(.required, for: .vertical)
        emptyState.contentInsets = UIEdgeInsets(top: 14, left: 20, bottom: 14, right: 20)
    }

    private func configurePagesRail() {
        pagesRail.onSelect = { [weak self] index in
            guard let self else { return }
            self.canvas.engineBridge.setActivePageIndex(UInt(index))
            self.documentDidChange()
        }
        pagesRail.onAdd = { [weak self] in self?.addPage() }
        pagesRail.onRename = { [weak self] index in self?.renamePage(at: index) }
        pagesRail.onDelete = { [weak self] index in self?.deletePage(at: index) }
    }

    private func configureLayersRail() {
        layersRail.onSelect = { [weak self] index in
            guard let self else { return }
            self.canvas.engineBridge.setActiveLayerIndex(UInt(index))
            self.documentDidChange()
        }
        layersRail.onAdd = { [weak self] in self?.addLayer() }
        layersRail.onRename = { [weak self] index in self?.renameLayer(at: index) }
        layersRail.onDelete = { [weak self] index in self?.deleteLayer(at: index) }
        layersRail.onVisibility = { [weak self] visible, index in
            guard let self else { return }
            self.canvas.engineBridge.setLayerVisible(visible, at: UInt(index))
            self.documentDidChange()
        }
        layersRail.onOpacity = { [weak self] opacity, index in
            guard let self else { return }
            self.canvas.engineBridge.setLayerOpacity(opacity, at: UInt(index))
            self.canvas.setNeedsDisplay()
        }
        layersRail.onOpacityCommit = { [weak self] opacity, index in
            guard let self else { return }
            self.canvas.engineBridge.setLayerOpacity(opacity, at: UInt(index))
            self.documentDidChange()
        }
    }

    private func refreshRails() {
        pagesRail.pageInfos = canvas.engineBridge.pageInfos
        layersRail.layerInfos = canvas.engineBridge.layerInfos
    }

    private func addPage() {
        canvas.engineBridge.addPage()
        documentDidChange()
    }

    private func deletePage(at index: Int) {
        guard canvas.engineBridge.pageInfos.count > 1 else { return }
        canvas.engineBridge.deletePage(at: UInt(index))
        documentDidChange()
    }

    private func renamePage(at index: Int) {
        guard index >= 0, index < canvas.engineBridge.pageInfos.count else { return }
        let current = canvas.engineBridge.pageInfos[index].name
        let alert = UIAlertController(title: "Rename page", message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = current
            field.placeholder = "Page name"
            field.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Rename", style: .default) { [weak self, weak alert] _ in
            guard let self, let name = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return }
            self.canvas.engineBridge.renamePage(at: UInt(index), name: name)
            self.documentDidChange()
        })
        present(alert, animated: true)
    }

    private func addLayer() {
        canvas.engineBridge.addLayer()
        documentDidChange()
    }

    private func deleteLayer(at index: Int) {
        guard canvas.engineBridge.layerInfos.count > 1 else { return }
        canvas.engineBridge.deleteLayer(at: UInt(index))
        documentDidChange()
    }

    private func renameLayer(at index: Int) {
        guard index >= 0, index < canvas.engineBridge.layerInfos.count else { return }
        let current = canvas.engineBridge.layerInfos[index].name
        let alert = UIAlertController(title: "Rename layer", message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = current
            field.placeholder = "Layer name"
            field.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Rename", style: .default) { [weak self, weak alert] _ in
            guard let self, let name = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return }
            self.canvas.engineBridge.renameLayer(at: UInt(index), name: name)
            self.documentDidChange()
        })
        present(alert, animated: true)
    }

    private func configureToolRail() {
        styleRail(toolRail); let stack = UIStackView(); stack.axis = .horizontal; stack.alignment = .fill; stack.distribution = .fillEqually; stack.spacing = 7; stack.translatesAutoresizingMaskIntoConstraints = false
        brushButton = toolButton(title: "✎  Brush", action: #selector(selectBrush)); eraserButton = toolButton(title: "⌫  Eraser", action: #selector(selectEraser)); undoButton = toolButton(title: "↶  Undo", action: #selector(undoCanvas)); redoButton = toolButton(title: "↷  Redo", action: #selector(redoCanvas)); clearButton = toolButton(title: "⌫  Clear Layer", action: #selector(clearCanvas)); settingsButton = toolButton(title: "⚙  Settings", action: #selector(openSettings))
        [brushButton, eraserButton, undoButton, redoButton, clearButton, settingsButton].forEach { button in button.widthAnchor.constraint(greaterThanOrEqualToConstant: 78).isActive = true; stack.addArrangedSubview(button) }
        toolRail.addSubview(stack); NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: toolRail.leadingAnchor, constant: 9), stack.trailingAnchor.constraint(equalTo: toolRail.trailingAnchor, constant: -9), stack.topAnchor.constraint(equalTo: toolRail.topAnchor, constant: 8), stack.bottomAnchor.constraint(equalTo: toolRail.bottomAnchor, constant: -8)])
    }

    private func styleRail(_ rail: UIView) {
        rail.backgroundColor = UIColor(red: 0.99, green: 0.98, blue: 0.95, alpha: 0.94); rail.layer.cornerRadius = 12; rail.layer.borderWidth = 1; rail.layer.borderColor = UIColor(red: 0.35, green: 0.30, blue: 0.23, alpha: 0.14).cgColor; rail.layer.shadowColor = UIColor.black.cgColor; rail.layer.shadowOpacity = 0.08; rail.layer.shadowRadius = 8; rail.layer.shadowOffset = CGSize(width: 0, height: 2)
    }

    private func railTitle(_ title: String) -> UILabel { let label = UILabel(); label.text = title; label.font = .systemFont(ofSize: 10, weight: .bold); label.textColor = UIColor(red: 0.38, green: 0.33, blue: 0.27, alpha: 0.70); label.textAlignment = .center; return label }
    private func pageCard() -> UIView { let card = UIView(); card.backgroundColor = UIColor.white.withAlphaComponent(0.9); card.layer.cornerRadius = 7; card.layer.borderWidth = 2; card.layer.borderColor = UIColor.systemBlue.withAlphaComponent(0.75).cgColor; card.heightAnchor.constraint(equalToConstant: 82).isActive = true; let label = UILabel(); label.text = "1"; label.font = .systemFont(ofSize: 22, weight: .semibold); label.textColor = UIColor(red: 0.22, green: 0.19, blue: 0.15, alpha: 1); label.textAlignment = .center; label.translatesAutoresizingMaskIntoConstraints = false; card.addSubview(label); NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: card.centerXAnchor), label.centerYAnchor.constraint(equalTo: card.centerYAnchor)]); card.accessibilityLabel = "Page 1, selected"; return card }
    private func layerRow(_ icon: String, _ name: String, selected: Bool) -> UIView { let row = UIView(); row.backgroundColor = selected ? UIColor.systemBlue.withAlphaComponent(0.12) : .clear; row.layer.cornerRadius = 7; row.heightAnchor.constraint(equalToConstant: 34).isActive = true; let label = UILabel(); label.text = "\(icon)  \(name)"; label.font = .systemFont(ofSize: 13, weight: selected ? .semibold : .regular); label.textColor = UIColor(red: 0.22, green: 0.19, blue: 0.15, alpha: 1); label.translatesAutoresizingMaskIntoConstraints = false; row.addSubview(label); NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 7), label.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -4), label.centerYAnchor.constraint(equalTo: row.centerYAnchor)]); row.accessibilityLabel = "Layer \(name)"; return row }
    private func disabledPlaceholder(title: String) -> UILabel { let label = UILabel(); label.text = title; label.font = .systemFont(ofSize: 10, weight: .medium); label.textColor = .secondaryLabel; label.textAlignment = .center; label.heightAnchor.constraint(equalToConstant: 28).isActive = true; return label }
    private func toolButton(title: String, action: Selector) -> UIButton { let button = UIButton(type: .system); button.setTitle(title, for: .normal); button.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold); button.setTitleColor(UIColor(red: 0.16, green: 0.14, blue: 0.11, alpha: 1), for: .normal); button.backgroundColor = UIColor.white.withAlphaComponent(0.82); button.layer.cornerRadius = 9; button.layer.borderWidth = 1; button.layer.borderColor = UIColor.black.withAlphaComponent(0.08).cgColor; button.addTarget(self, action: action, for: .touchUpInside); button.accessibilityLabel = title; return button }

    private func updateToolSelection() {
        let selectedColor = UIColor.systemBlue.withAlphaComponent(0.16); let normalColor = UIColor.white.withAlphaComponent(0.82)
        brushButton.isSelected = selectedTool == .brush; eraserButton.isSelected = selectedTool == .eraser; brushButton.backgroundColor = brushButton.isSelected ? selectedColor : normalColor; eraserButton.backgroundColor = eraserButton.isSelected ? selectedColor : normalColor
        brushButton.layer.borderColor = (brushButton.isSelected ? UIColor.systemBlue : UIColor.black.withAlphaComponent(0.08)).cgColor; eraserButton.layer.borderColor = (eraserButton.isSelected ? UIColor.systemBlue : UIColor.black.withAlphaComponent(0.08)).cgColor
        brushButton.accessibilityValue = brushButton.isSelected ? "Selected" : "Not selected"; eraserButton.accessibilityValue = eraserButton.isSelected ? "Selected" : "Not selected"
    }

    private func updateUndoRedoState() {
        undoButton?.isEnabled = canvas.engineBridge.canUndo; redoButton?.isEnabled = canvas.engineBridge.canRedo; clearButton?.isEnabled = canvas.engineBridge.strokeCount > 0
        undoButton?.accessibilityValue = undoButton.isEnabled ? "Available" : "Unavailable"; redoButton?.accessibilityValue = redoButton.isEnabled ? "Available" : "Unavailable"
    }

    @objc private func selectBrush() {
        selectedTool = .brush
        canvas.engineBridge.tool = .brush
        UserDefaults.standard.set(Int(DTTool.brush.rawValue), forKey: Self.selectedToolDefaultsKey)
        updateToolSelection()
    }

    @objc private func selectEraser() {
        selectedTool = .eraser
        canvas.engineBridge.tool = .eraser
        UserDefaults.standard.set(Int(DTTool.eraser.rawValue), forKey: Self.selectedToolDefaultsKey)
        updateToolSelection()
    }
    @objc private func undoCanvas() { guard canvas.engineBridge.canUndo else { return }; _ = canvas.engineBridge.undoLastStroke(); documentDidChange() }
    @objc private func redoCanvas() { guard canvas.engineBridge.canRedo else { return }; _ = canvas.engineBridge.redoLastStroke(); documentDidChange() }
    @objc private func clearCanvas() { guard canvas.engineBridge.strokeCount > 0 else { return }; canvas.engineBridge.clearCanvas(); documentDidChange() }
    @objc private func openSettings() { showSettings() }
    @objc private func resetCanvasView() { canvas.resetView() }
}
