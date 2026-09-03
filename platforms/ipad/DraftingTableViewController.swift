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
/// are retained by the bridge and exposed through the dynamic side rails.
final class DraftingTableViewController: UIViewController, UIDocumentPickerDelegate {
    private static let selectedToolDefaultsKey = "draftingTable.selectedTool"
    private static let gridDefaultsKey = DrawingSettingsViewController.gridKey
    // Status-bar toggle prefs mirror the original app's bottom bar. Grid is
    // live; prediction gates Pencil predicted samples; snap/px/angle/preview
    // persist here until their engine surfaces land.
    private static let snapDefaultsKey = "draftingTable.snapEnabled"
    private static let pixelGridDefaultsKey = "draftingTable.pixelGridEnabled"
    private static let angleSnapDefaultsKey = "draftingTable.angleSnapEnabled"
    private static let brushPreviewDefaultsKey = "draftingTable.brushPreviewEnabled"
    private static let predictionDefaultsKey = "draftingTable.predictionEnabled"
    // v0.7.2: views are created in loadView (with per-step breadcrumbs), not
    // as eager property initializers. CI forensics showed the process dying
    // inside UIViewController init before any view code ran; staging creation
    // after the window/scene exists isolates which surface aborts and keeps
    // Metal init off the scene-connection path.
    private var canvas: CanvasView!
    private var diagnostics: DiagnosticsOverlay!
    private var emptyState: InsetLabel!
    private var pagesRail: PagesRailView!
    private var layersRail: LayersRailView!
    private var toolRail: UIView!
    private var statusBar: UIView!
    private var statusDocLabel: UILabel!
    private var statusToolLabel: UILabel!
    private var statusGridChip: UIButton!
    private var statusPixelChip: UIButton!
    private var statusSnapChip: UIButton!
    private var statusAngleChip: UIButton!
    private var statusPreviewChip: UIButton!
    private var statusPredictChip: UIButton!
    private var toastLabel: InsetLabel!
    private let persistence = StrokePersistenceStore()
    private var brushButton: UIButton!
    private var eraserButton: UIButton!
    private var lineButton: UIButton!
    private var rectangleButton: UIButton!
    private var ellipseButton: UIButton!
    private var circleButton: UIButton!
    private var undoButton: UIButton!
    private var redoButton: UIButton!
    private var clearButton: UIButton!
    private var settingsButton: UIButton!
    private var selectedTool: DTTool = .brush
    private var pendingDocumentExportURL: URL?
    private var pageThumbnailCache: [UInt: UIImage] = [:]

    override func loadView() {
        DTLaunchBreadcrumb("vc:loadView:start")
        let root = UIView()
        root.backgroundColor = UIColor(red: 0.965, green: 0.935, blue: 0.865, alpha: 1)
        DTLaunchBreadcrumb("vc:create:canvas:start")
        canvas = CanvasView(frame: .zero)
        DTLaunchBreadcrumb("vc:create:canvas:done")
        diagnostics = DiagnosticsOverlay(frame: .zero)
        DTLaunchBreadcrumb("vc:create:diagnostics:done")
        emptyState = InsetLabel()
        pagesRail = PagesRailView(frame: .zero)
        layersRail = LayersRailView(frame: .zero)
        toolRail = UIView()
        statusBar = UIView()
        toastLabel = InsetLabel()
        DTLaunchBreadcrumb("vc:create:rails:done")
        view = root
        [canvas, diagnostics, emptyState, pagesRail, layersRail, toolRail, statusBar, toastLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview($0)
        }
        configureEmptyState(); configurePagesRail(); configureLayersRail(); configureToolRail(); configureStatusBar(); configureToast()
        DTLaunchBreadcrumb("vc:loadView:done")

        let safe = root.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            canvas.leadingAnchor.constraint(equalTo: root.leadingAnchor), canvas.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: root.topAnchor), canvas.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            // Left vertical tool rail mirrors the original app's rail; the
            // page sidebar sits beside it and the layer column stays right.
            toolRail.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 10), toolRail.topAnchor.constraint(equalTo: safe.topAnchor, constant: 12),
            toolRail.bottomAnchor.constraint(equalTo: statusBar.topAnchor, constant: -10), toolRail.widthAnchor.constraint(equalToConstant: 64),
            pagesRail.leadingAnchor.constraint(equalTo: toolRail.trailingAnchor, constant: 10), pagesRail.topAnchor.constraint(equalTo: safe.topAnchor, constant: 12),
            pagesRail.bottomAnchor.constraint(equalTo: statusBar.topAnchor, constant: -10), pagesRail.widthAnchor.constraint(equalToConstant: 84),
            layersRail.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -12), layersRail.topAnchor.constraint(equalTo: safe.topAnchor, constant: 12),
            layersRail.bottomAnchor.constraint(equalTo: statusBar.topAnchor, constant: -10), layersRail.widthAnchor.constraint(equalToConstant: 156),
            statusBar.leadingAnchor.constraint(equalTo: root.leadingAnchor), statusBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: safe.bottomAnchor), statusBar.heightAnchor.constraint(equalToConstant: 32),
            toastLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            toastLabel.bottomAnchor.constraint(equalTo: statusBar.topAnchor, constant: -14),
            toastLabel.leadingAnchor.constraint(greaterThanOrEqualTo: pagesRail.trailingAnchor, constant: 18),
            toastLabel.trailingAnchor.constraint(lessThanOrEqualTo: layersRail.leadingAnchor, constant: -18),
            emptyState.centerXAnchor.constraint(equalTo: root.centerXAnchor), emptyState.centerYAnchor.constraint(equalTo: root.centerYAnchor, constant: -12),
            emptyState.leadingAnchor.constraint(greaterThanOrEqualTo: pagesRail.trailingAnchor, constant: 18), emptyState.trailingAnchor.constraint(lessThanOrEqualTo: layersRail.leadingAnchor, constant: -18),
            diagnostics.leadingAnchor.constraint(equalTo: pagesRail.trailingAnchor, constant: 12), diagnostics.topAnchor.constraint(equalTo: safe.topAnchor, constant: 16),
            diagnostics.widthAnchor.constraint(greaterThanOrEqualToConstant: 150), diagnostics.widthAnchor.constraint(lessThanOrEqualToConstant: 240)
        ])
        canvas.onDiagnostics = { [weak self] text in self?.diagnostics.update(text: text) }
        canvas.onDrawingBegan = { [weak self] in self?.emptyState.isHidden = true }
        canvas.onDocumentChanged = { [weak self] in self?.documentDidChange() }
        canvas.onToolChanged = { [weak self] in
            guard let self else { return }
            let tool = self.canvas.engineBridge.tool
            self.selectedTool = tool
            UserDefaults.standard.set(Int(tool.rawValue), forKey: Self.selectedToolDefaultsKey)
            self.updateToolSelection()
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Drafting Table"; navigationItem.largeTitleDisplayMode = .never
        navigationController?.navigationBar.prefersLargeTitles = false
        let appearance = navigationAppearance()
        navigationController?.navigationBar.standardAppearance = appearance
        navigationController?.navigationBar.scrollEdgeAppearance = appearance
        navigationController?.navigationBar.compactAppearance = appearance
        let reset = UIBarButtonItem(
            title: "Reset View",
            style: .plain,
            target: self,
            action: #selector(resetCanvasView)
        )
        navigationItem.rightBarButtonItems = [reset, commandMenuButton()]
        // v0.7.2: keep scene connection instant. Restoring the autosaved
        // archive, reading UserDefaults, and laying out the rails now happens
        // after the window is visible so the watchdog never kills us between
        // the beige launch screen and the first committed frame.
        NSLog("DraftingTable launch: viewDidLoad, deferring restore")
        applyStoredSettings()
        refreshRails(); updateToolSelection(); updateUndoRedoState()
        updateLaunchBreadcrumb(stage: "viewDidLoad")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            NSLog("DraftingTable launch: deferred restore begin")
            self.restoreDocument()
            self.refreshRails(); self.updateToolSelection(); self.updateUndoRedoState()
            self.canvas.setNeedsDisplay()
            NSLog("DraftingTable launch: deferred restore done strokes=%lu",
                  UInt(self.canvas.engineBridge.strokeCount))
            self.updateLaunchBreadcrumb(stage: "restored")
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // On-demand renderer needs one explicit kick once layout has a real size.
        canvas.setNeedsDisplay()
        updateLaunchBreadcrumb(stage: "appeared")
    }

    /// Called by the scene delegate before suspension as a final autosave.
    func saveDocument() {
        guard isViewLoaded, let canvas else { return }
        do { try persistence.save(canvas.engineBridge.archiveData()) } catch { /* retry on next mutation */ }
    }

    /// Tiny launch breadcrumb for the next crash report. If the app ever dies
    /// between the beige launch screen and first draw again, this file tells
    /// us exactly which stage completed on the previous attempt.
    private func updateLaunchBreadcrumb(stage: String) {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("DraftingTable-last-launch.txt", isDirectory: false)
        guard let url else { return }
        let entry = "\(Date().timeIntervalSince1970) \(stage)\n"
        try? entry.write(to: url, atomically: true, encoding: .utf8)
    }

    private func documentDidChange(invalidateAllThumbnails: Bool = false) {
        if invalidateAllThumbnails {
            pageThumbnailCache.removeAll(keepingCapacity: true)
        } else if let active = canvas.engineBridge.pageInfos.first(where: { $0.selected }) {
            pageThumbnailCache.removeValue(forKey: active.index)
        }
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
        pageThumbnailCache.removeAll(keepingCapacity: true)
        emptyState.isHidden = canvas.engineBridge.strokeCount > 0; canvas.setNeedsDisplay(); refreshRails()
    }

    private func applyStoredSettings() {
        let defaults = UserDefaults.standard
        let activation = min(max(storedFloat(defaults, key: DrawingSettingsViewController.activationKey, fallback: 3), 0), 20)
        let size = min(max(storedFloat(defaults, key: DrawingSettingsViewController.brushSizeKey, fallback: 8), 1), 40)
        let opacity = min(max(storedFloat(defaults, key: DrawingSettingsViewController.brushOpacityKey, fallback: 100), 5), 100)
        let hardness = min(max(storedFloat(defaults, key: DrawingSettingsViewController.brushHardnessKey, fallback: 80), 0), 100)
        let color = storedUInt32(defaults,
                                 key: DrawingSettingsViewController.brushColorKey,
                                 fallback: DrawingSettingsViewController.defaultBrushColorRGBA)
        canvas.activationPressure = CGFloat(activation / 100)
        canvas.engineBridge.brushSize = CGFloat(size)
        canvas.engineBridge.brushOpacity = CGFloat(opacity / 100)
        canvas.engineBridge.brushHardness = CGFloat(hardness / 100)
        canvas.engineBridge.brushColorRGBA = color
        canvas.gridVisible = defaults.bool(forKey: Self.gridDefaultsKey)
        canvas.predictionEnabled = defaults.object(forKey: Self.predictionDefaultsKey) == nil
            ? true : defaults.bool(forKey: Self.predictionDefaultsKey)
        let storedTool = defaults.integer(forKey: Self.selectedToolDefaultsKey)
        selectedTool = (0...Int(DTTool.circle.rawValue)).contains(storedTool)
            ? (DTTool(rawValue: UInt8(storedTool)) ?? .brush)
            : .brush
        canvas.engineBridge.tool = selectedTool
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

    private func showSettings() {
        let settings = DrawingSettingsViewController()
        settings.onActivationChanged = { [weak self] value in self?.canvas.activationPressure = value }
        settings.onBrushSizeChanged = { [weak self] value in self?.canvas.engineBridge.brushSize = value; self?.saveDocument() }
        settings.onBrushOpacityChanged = { [weak self] value in self?.canvas.engineBridge.brushOpacity = value; self?.saveDocument() }
        settings.onBrushHardnessChanged = { [weak self] value in self?.canvas.engineBridge.brushHardness = value; self?.saveDocument() }
        settings.onBrushColorChanged = { [weak self] value in self?.canvas.engineBridge.brushColorRGBA = value; self?.saveDocument() }
        settings.onGridChanged = { [weak self] value in self?.canvas.gridVisible = value; self?.saveDocument() }
        let navigation = UINavigationController(rootViewController: settings); navigation.modalPresentationStyle = .formSheet
        if let sheet = navigation.sheetPresentationController { sheet.detents = [.medium(), .large()]; sheet.prefersGrabberVisible = true }
        present(navigation, animated: true)
    }

    private func commandMenuButton() -> UIBarButtonItem {
        let grid = UIAction(title: "Show Grid", image: UIImage(systemName: "grid"), state: canvas.gridVisible ? .on : .off) { [weak self] _ in
            guard let self else { return }
            self.canvas.gridVisible.toggle()
            UserDefaults.standard.set(self.canvas.gridVisible, forKey: Self.gridDefaultsKey)
            self.canvas.setNeedsDisplay()
            self.updateStatusBar()
        }
        let settings = UIAction(title: "Settings", image: UIImage(systemName: "slider.horizontal.3")) { [weak self] _ in self?.showSettings() }
        let exportPage = UIAction(title: "Export Current Page (PNG)", image: UIImage(systemName: "photo")) { [weak self] _ in self?.exportCurrentPagePNG() }
        let exportPDF = UIAction(title: "Export All Pages (PDF)", image: UIImage(systemName: "doc.richtext")) { [weak self] _ in self?.exportAllPagesPDF() }
        let open = UIAction(title: "Open .drafttable…", image: UIImage(systemName: "folder")) { [weak self] _ in self?.openDocument() }
        let saveCopy = UIAction(title: "Save Copy…", image: UIImage(systemName: "square.and.arrow.down")) { [weak self] _ in self?.saveDocumentCopy() }
        let documents = UIMenu(title: "Documents", options: .displayInline, children: [open, saveCopy])
        let menu = UIMenu(title: "Document", children: [settings, grid, documents, UIMenu(title: "Export", options: .displayInline, children: [exportPage, exportPDF])])
        return UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: menu)
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
        // Thumbnail generation is disabled for the v0.7.1 launch hotfix. It
        // previously ran synchronously from layout and is being moved to an
        // isolated background cache before re-enabling.
        pagesRail.thumbnailForPage = nil
        pagesRail.onSelect = { [weak self] index in
            guard let self else { return }
            self.canvas.engineBridge.setActivePageIndex(UInt(index))
            self.documentDidChange()
        }
        pagesRail.onAdd = { [weak self] in self?.addPage() }
        pagesRail.onRename = { [weak self] index in self?.renamePage(at: index) }
        pagesRail.onDelete = { [weak self] index in self?.deletePage(at: index) }
        pagesRail.onDuplicate = { [weak self] index in self?.duplicatePage(at: index) }
        pagesRail.onMove = { [weak self] from, to in self?.movePage(from: from, to: to) }
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
        layersRail.onDuplicate = { [weak self] index in self?.duplicateLayer(at: index) }
        layersRail.onMove = { [weak self] from, to in self?.moveLayer(from: from, to: to) }
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
        documentDidChange(invalidateAllThumbnails: true)
    }

    private func deletePage(at index: Int) {
        guard canvas.engineBridge.pageInfos.count > 1 else { return }
        canvas.engineBridge.deletePage(at: UInt(index))
        documentDidChange(invalidateAllThumbnails: true)
    }

    private func duplicatePage(at index: Int) {
        guard index >= 0, index < canvas.engineBridge.pageInfos.count else { return }
        _ = canvas.engineBridge.duplicatePage(at: UInt(index))
        documentDidChange(invalidateAllThumbnails: true)
    }

    private func movePage(from index: Int, to destination: Int) {
        guard index >= 0, destination >= 0, index < canvas.engineBridge.pageInfos.count,
              destination < canvas.engineBridge.pageInfos.count else { return }
        _ = canvas.engineBridge.movePage(from: UInt(index), to: UInt(destination))
        documentDidChange(invalidateAllThumbnails: true)
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

    private func duplicateLayer(at index: Int) {
        guard index >= 0, index < canvas.engineBridge.layerInfos.count else { return }
        _ = canvas.engineBridge.duplicateLayer(at: UInt(index))
        documentDidChange()
    }

    private func moveLayer(from index: Int, to destination: Int) {
        guard index >= 0, destination >= 0, index < canvas.engineBridge.layerInfos.count,
              destination < canvas.engineBridge.layerInfos.count else { return }
        _ = canvas.engineBridge.moveLayer(from: UInt(index), to: UInt(destination))
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
        styleRail(toolRail)
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.showsVerticalScrollIndicator = false
        let stack = UIStackView()
        stack.axis = .vertical; stack.alignment = .fill; stack.spacing = 5; stack.translatesAutoresizingMaskIntoConstraints = false
        // Section order mirrors the original app's left rail: DRAW, VECTOR,
        // SELECT, history, then settings. Glyphs match the original's icon
        // set (pen, eraser, bucket, shade, line, rect, circle, ellipse,
        // select, lasso). Bucket, shade, and selection tools have no engine
        // yet; they announce their milestone instead of silently doing
        // nothing.
        brushButton = railToolButton(glyph: "✎", label: "Brush", action: #selector(selectBrush))
        eraserButton = railToolButton(glyph: "⌫", label: "Eraser", action: #selector(selectEraser))
        let bucketButton = railToolButton(glyph: "🪣", label: "Bucket", action: #selector(announceBucket))
        let shadeButton = railToolButton(glyph: "◧", label: "Shade", action: #selector(announceShade))
        lineButton = railToolButton(glyph: "╱", label: "Line", action: #selector(selectLine))
        rectangleButton = railToolButton(glyph: "□", label: "Rect", action: #selector(selectRectangle))
        circleButton = railToolButton(glyph: "◦", label: "Circle", action: #selector(selectCircle))
        ellipseButton = railToolButton(glyph: "○", label: "Ellipse", action: #selector(selectEllipse))
        let selectButton = railToolButton(glyph: "⬚", label: "Select", action: #selector(announceSelect))
        let lassoButton = railToolButton(glyph: "⚪", label: "Lasso", action: #selector(announceLasso))
        undoButton = railToolButton(glyph: "↶", label: "Undo", action: #selector(undoCanvas))
        redoButton = railToolButton(glyph: "↷", label: "Redo", action: #selector(redoCanvas))
        clearButton = railToolButton(glyph: "🗑", label: "Clear", action: #selector(clearCanvas))
        settingsButton = railToolButton(glyph: "⚙", label: "Tune", action: #selector(openSettings))
        stack.addArrangedSubview(railSectionLabel("DRAW"))
        [brushButton, eraserButton, bucketButton, shadeButton].forEach(stack.addArrangedSubview)
        stack.addArrangedSubview(railRule())
        stack.addArrangedSubview(railSectionLabel("SHAPE"))
        [lineButton, rectangleButton, circleButton, ellipseButton].forEach(stack.addArrangedSubview)
        stack.addArrangedSubview(railRule())
        stack.addArrangedSubview(railSectionLabel("SELECT"))
        [selectButton, lassoButton].forEach(stack.addArrangedSubview)
        stack.addArrangedSubview(railRule())
        [undoButton, redoButton, clearButton, settingsButton].forEach(stack.addArrangedSubview)
        scroll.addSubview(stack); toolRail.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: toolRail.leadingAnchor, constant: 6), scroll.trailingAnchor.constraint(equalTo: toolRail.trailingAnchor, constant: -6),
            scroll.topAnchor.constraint(equalTo: toolRail.topAnchor, constant: 8), scroll.bottomAnchor.constraint(equalTo: toolRail.bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor), stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor), stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor)
        ])
    }

    private func styleRail(_ rail: UIView) {
        rail.backgroundColor = UIColor(red: 0.99, green: 0.98, blue: 0.95, alpha: 0.94); rail.layer.cornerRadius = 12; rail.layer.borderWidth = 1; rail.layer.borderColor = UIColor(red: 0.35, green: 0.30, blue: 0.23, alpha: 0.14).cgColor; rail.layer.shadowColor = UIColor.black.cgColor; rail.layer.shadowOpacity = 0.08; rail.layer.shadowRadius = 8; rail.layer.shadowOffset = CGSize(width: 0, height: 2)
    }

    private func railTitle(_ title: String) -> UILabel { let label = UILabel(); label.text = title; label.font = .systemFont(ofSize: 10, weight: .bold); label.textColor = UIColor(red: 0.38, green: 0.33, blue: 0.27, alpha: 0.70); label.textAlignment = .center; return label }
    private func railRule() -> UIView { let rule = UIView(); rule.backgroundColor = UIColor(red: 0.35, green: 0.30, blue: 0.23, alpha: 0.18); rule.heightAnchor.constraint(equalToConstant: 1).isActive = true; return rule }
    private func railToolButton(glyph: String, label: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle("\(glyph)\n\(label)", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 10, weight: .semibold)
        button.titleLabel?.numberOfLines = 2
        button.titleLabel?.textAlignment = .center
        button.setTitleColor(UIColor(red: 0.16, green: 0.14, blue: 0.11, alpha: 1), for: .normal)
        button.backgroundColor = UIColor.white.withAlphaComponent(0.82)
        button.layer.cornerRadius = 9; button.layer.borderWidth = 1
        button.layer.borderColor = UIColor.black.withAlphaComponent(0.08).cgColor
        button.heightAnchor.constraint(equalToConstant: 46).isActive = true
        button.addTarget(self, action: action, for: .touchUpInside)
        button.accessibilityLabel = label
        return button
    }

    // MARK: - Status bar (mirrors the original app's bottom bar)

    private func configureStatusBar() {
        statusBar.backgroundColor = UIColor(red: 0.93, green: 0.895, blue: 0.815, alpha: 1)
        let hairline = UIView()
        hairline.backgroundColor = UIColor(red: 0.35, green: 0.30, blue: 0.23, alpha: 0.18)
        hairline.translatesAutoresizingMaskIntoConstraints = false
        statusBar.addSubview(hairline)
        NSLayoutConstraint.activate([
            hairline.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor),
            hairline.topAnchor.constraint(equalTo: statusBar.topAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 1)
        ])
        let stack = UIStackView()
        stack.axis = .horizontal; stack.alignment = .center; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        statusBar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: statusBar.topAnchor),
            stack.bottomAnchor.constraint(equalTo: statusBar.bottomAnchor)
        ])
        statusDocLabel = statusLabel(text: "doc · DraftingTable")
        statusToolLabel = statusLabel(text: "◇ brush")
        statusGridChip = statusChip(action: #selector(toggleGridChip))
        statusPixelChip = statusChip(action: #selector(togglePixelChip))
        statusSnapChip = statusChip(action: #selector(toggleSnapChip))
        statusAngleChip = statusChip(action: #selector(toggleAngleChip))
        statusPreviewChip = statusChip(action: #selector(togglePreviewChip))
        statusPredictChip = statusChip(action: #selector(togglePredictChip))
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        [statusDocLabel, statusToolLabel, spacer,
         statusGridChip, statusPixelChip, statusSnapChip,
         statusAngleChip, statusPreviewChip, statusPredictChip].forEach(stack.addArrangedSubview)
        updateStatusBar()
    }

    private func statusLabel(text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = UIColor(red: 0.38, green: 0.33, blue: 0.27, alpha: 1)
        label.setContentHuggingPriority(.required, for: .horizontal)
        return label
    }

    private func statusChip(action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.titleLabel?.font = .systemFont(ofSize: 11, weight: .semibold)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    private func paintChip(_ chip: UIButton, title: String, on: Bool) {
        chip.setTitle(title, for: .normal)
        let color: UIColor = on ? .systemBlue : .secondaryLabel
        chip.setTitleColor(color, for: .normal)
        chip.accessibilityValue = on ? "On" : "Off"
    }

    private func updateStatusBar() {
        guard isViewLoaded, let statusToolLabel else { return }
        let defaults = UserDefaults.standard
        statusToolLabel.text = "◇ \(canvas.activeToolDisplayName)"
        paintChip(statusGridChip, title: canvas.gridVisible ? "grid: on" : "grid: off", on: canvas.gridVisible)
        let pixel = defaults.bool(forKey: Self.pixelGridDefaultsKey)
        paintChip(statusPixelChip, title: pixel ? "px: on" : "px: off", on: pixel)
        let snap = defaults.bool(forKey: Self.snapDefaultsKey)
        paintChip(statusSnapChip, title: snap ? "snap: on" : "snap: off", on: snap)
        let angle = defaults.bool(forKey: Self.angleSnapDefaultsKey)
        paintChip(statusAngleChip, title: angle ? "angle: on" : "angle: off", on: angle)
        let preview = defaults.bool(forKey: Self.brushPreviewDefaultsKey)
        paintChip(statusPreviewChip, title: preview ? "preview: on" : "preview: off", on: preview)
        paintChip(statusPredictChip, title: canvas.predictionEnabled ? "predict: on" : "predict: off", on: canvas.predictionEnabled)
    }

    @objc private func toggleGridChip() {
        canvas.gridVisible.toggle()
        UserDefaults.standard.set(canvas.gridVisible, forKey: Self.gridDefaultsKey)
        canvas.setNeedsDisplay()
        updateStatusBar()
    }

    @objc private func toggleSnapChip() {
        let next = !UserDefaults.standard.bool(forKey: Self.snapDefaultsKey)
        UserDefaults.standard.set(next, forKey: Self.snapDefaultsKey)
        if next { showToast("Snap arms with vector snapping (M5)") }
        updateStatusBar()
    }

    @objc private func togglePixelChip() {
        let next = !UserDefaults.standard.bool(forKey: Self.pixelGridDefaultsKey)
        UserDefaults.standard.set(next, forKey: Self.pixelGridDefaultsKey)
        if next { showToast("Pixel grid renders with the tile compositor (M11)") }
        updateStatusBar()
    }

    @objc private func toggleAngleChip() {
        let next = !UserDefaults.standard.bool(forKey: Self.angleSnapDefaultsKey)
        UserDefaults.standard.set(next, forKey: Self.angleSnapDefaultsKey)
        if next { showToast("Angle snap arms with vector snapping (M5)") }
        updateStatusBar()
    }

    @objc private func togglePreviewChip() {
        let next = !UserDefaults.standard.bool(forKey: Self.brushPreviewDefaultsKey)
        UserDefaults.standard.set(next, forKey: Self.brushPreviewDefaultsKey)
        updateStatusBar()
    }

    @objc private func togglePredictChip() {
        canvas.predictionEnabled.toggle()
        UserDefaults.standard.set(canvas.predictionEnabled, forKey: Self.predictionDefaultsKey)
        updateStatusBar()
    }

    private func configureToast() {
        toastLabel.textAlignment = .center
        toastLabel.numberOfLines = 0
        toastLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        toastLabel.textColor = .white
        toastLabel.backgroundColor = UIColor.black.withAlphaComponent(0.72)
        toastLabel.layer.cornerRadius = 12
        toastLabel.layer.masksToBounds = true
        toastLabel.contentInsets = UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
        toastLabel.isHidden = true
    }

    private var toastHideWorkItem: DispatchWorkItem?

    private func showToast(_ message: String) {
        guard isViewLoaded, let toastLabel else { return }
        toastHideWorkItem?.cancel()
        toastLabel.text = message
        toastLabel.isHidden = false
        toastLabel.alpha = 1
        let work = DispatchWorkItem { [weak self] in
            UIView.animate(withDuration: 0.3, animations: {
                self?.toastLabel.alpha = 0
            }, completion: { _ in
                self?.toastLabel.isHidden = true
            })
        }
        toastHideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }
    private func pageCard() -> UIView { let card = UIView(); card.backgroundColor = UIColor.white.withAlphaComponent(0.9); card.layer.cornerRadius = 7; card.layer.borderWidth = 2; card.layer.borderColor = UIColor.systemBlue.withAlphaComponent(0.75).cgColor; card.heightAnchor.constraint(equalToConstant: 82).isActive = true; let label = UILabel(); label.text = "1"; label.font = .systemFont(ofSize: 22, weight: .semibold); label.textColor = UIColor(red: 0.22, green: 0.19, blue: 0.15, alpha: 1); label.textAlignment = .center; label.translatesAutoresizingMaskIntoConstraints = false; card.addSubview(label); NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: card.centerXAnchor), label.centerYAnchor.constraint(equalTo: card.centerYAnchor)]); card.accessibilityLabel = "Page 1, selected"; return card }
    private func layerRow(_ icon: String, _ name: String, selected: Bool) -> UIView { let row = UIView(); row.backgroundColor = selected ? UIColor.systemBlue.withAlphaComponent(0.12) : .clear; row.layer.cornerRadius = 7; row.heightAnchor.constraint(equalToConstant: 34).isActive = true; let label = UILabel(); label.text = "\(icon)  \(name)"; label.font = .systemFont(ofSize: 13, weight: selected ? .semibold : .regular); label.textColor = UIColor(red: 0.22, green: 0.19, blue: 0.15, alpha: 1); label.translatesAutoresizingMaskIntoConstraints = false; row.addSubview(label); NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 7), label.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -4), label.centerYAnchor.constraint(equalTo: row.centerYAnchor)]); row.accessibilityLabel = "Layer \(name)"; return row }
    private func disabledPlaceholder(title: String) -> UILabel { let label = UILabel(); label.text = title; label.font = .systemFont(ofSize: 10, weight: .medium); label.textColor = .secondaryLabel; label.textAlignment = .center; label.heightAnchor.constraint(equalToConstant: 28).isActive = true; return label }
    private func toolButton(title: String, action: Selector) -> UIButton { let button = UIButton(type: .system); button.setTitle(title, for: .normal); button.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold); button.setTitleColor(UIColor(red: 0.16, green: 0.14, blue: 0.11, alpha: 1), for: .normal); button.backgroundColor = UIColor.white.withAlphaComponent(0.82); button.layer.cornerRadius = 9; button.layer.borderWidth = 1; button.layer.borderColor = UIColor.black.withAlphaComponent(0.08).cgColor; button.addTarget(self, action: action, for: .touchUpInside); button.accessibilityLabel = title; return button }

    private func updateToolSelection() {
        let selectedColor = UIColor.systemBlue.withAlphaComponent(0.16); let normalColor = UIColor.white.withAlphaComponent(0.82)
        let entries: [(UIButton, DTTool)] = [(brushButton, .brush), (eraserButton, .eraser), (lineButton, .line), (rectangleButton, .rectangle), (ellipseButton, .ellipse), (circleButton, .circle)]
        entries.forEach { button, tool in
            button.isSelected = selectedTool == tool
            button.backgroundColor = button.isSelected ? selectedColor : normalColor
            button.layer.borderColor = (button.isSelected ? UIColor.systemBlue : UIColor.black.withAlphaComponent(0.08)).cgColor
            button.accessibilityValue = button.isSelected ? "Selected" : "Not selected"
        }
        updateStatusBar()
    }

    private func updateUndoRedoState() {
        undoButton?.isEnabled = canvas.engineBridge.canUndo; redoButton?.isEnabled = canvas.engineBridge.canRedo; clearButton?.isEnabled = canvas.engineBridge.strokeCount > 0
        undoButton?.accessibilityValue = undoButton.isEnabled ? "Available" : "Unavailable"; redoButton?.accessibilityValue = redoButton.isEnabled ? "Available" : "Unavailable"
    }

    @objc private func selectEraser() { selectTool(.eraser) }
    @objc private func selectBrush() { selectTool(.brush) }
    @objc private func selectLine() { selectTool(.line) }
    @objc private func selectRectangle() { selectTool(.rectangle) }
    @objc private func selectEllipse() { selectTool(.ellipse) }
    @objc private func selectCircle() { selectTool(.circle) }
    @objc private func announceBucket() { showToast("Bucket fill arrives with the tile renderer (M2)") }
    @objc private func announceShade() { showToast("Shade fill arrives with the tile renderer (M2)") }
    @objc private func announceSelect() { showToast("Selection + transform handles land in M6") }
    @objc private func announceLasso() { showToast("Lasso selection lands in M6") }
    private func selectTool(_ tool: DTTool) {
        selectedTool = tool; canvas.engineBridge.tool = tool
        UserDefaults.standard.set(Int(tool.rawValue), forKey: Self.selectedToolDefaultsKey)
        updateToolSelection()
    }
    @objc private func undoCanvas() { guard canvas.engineBridge.canUndo else { return }; _ = canvas.engineBridge.undoLastStroke(); documentDidChange() }
    @objc private func redoCanvas() { guard canvas.engineBridge.canRedo else { return }; _ = canvas.engineBridge.redoLastStroke(); documentDidChange() }
    @objc private func clearCanvas() { guard canvas.engineBridge.strokeCount > 0 else { return }; canvas.engineBridge.clearCanvas(); documentDidChange() }
    @objc private func openSettings() { showSettings() }
    @objc private func resetCanvasView() { canvas.resetView() }

    private func exportCurrentPagePNG() {
        guard let page = canvas.engineBridge.pageInfos.first(where: { $0.selected }),
              let data = DocumentExportService.pngData(strokes: canvas.engineBridge.renderableStrokes(forPageAt: page.index), canvasSize: canvas.bounds.size) else { return }
        shareTemporary(data: data, extension: "png", activityItem: "Drafting Table Page")
    }

    private func openDocument() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.draftingTableDocument, .data], asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        presentPickerSafely(picker)
    }

    private func saveDocumentCopy() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DraftingTable-\(UUID().uuidString).drafttable")
        do {
            try canvas.engineBridge.archiveData().write(to: url, options: .atomic)
            pendingDocumentExportURL = url
            let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
            picker.delegate = self
            presentPickerSafely(picker)
        } catch {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func presentPickerSafely(_ picker: UIDocumentPickerViewController) {
        if let popover = picker.popoverPresentationController {
            popover.barButtonItem = navigationItem.rightBarButtonItems?.last
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        }
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let wasExporting = pendingDocumentExportURL != nil
        defer {
            if let pendingDocumentExportURL {
                try? FileManager.default.removeItem(at: pendingDocumentExportURL)
                self.pendingDocumentExportURL = nil
            }
        }
        guard !wasExporting, let url = urls.first else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            guard canvas.engineBridge.loadArchiveData(data) else {
                showDocumentError("This file is not a valid Drafting Table document.")
                return
            }
            documentDidChange(invalidateAllThumbnails: true)
        } catch {
            showDocumentError("Drafting Table could not read that file.")
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        if let pendingDocumentExportURL {
            try? FileManager.default.removeItem(at: pendingDocumentExportURL)
            self.pendingDocumentExportURL = nil
        }
    }

    private func showDocumentError(_ message: String) {
        let alert = UIAlertController(title: "Document Error", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func exportAllPagesPDF() {
        let pages = canvas.engineBridge.pageInfos.map { canvas.engineBridge.renderableStrokes(forPageAt: $0.index) }
        guard let data = DocumentExportService.pdfData(pages: pages, canvasSize: canvas.bounds.size) else { return }
        shareTemporary(data: data, extension: "pdf", activityItem: "Drafting Table Document")
    }

    private func shareTemporary(data: Data, extension fileExtension: String, activityItem: String) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DraftingTable-\(UUID().uuidString).\(fileExtension)")
        do { try data.write(to: url, options: .atomic) } catch { return }
        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        activity.completionWithItemsHandler = { _, _, _, _ in
            try? FileManager.default.removeItem(at: url)
        }
        if let popover = activity.popoverPresentationController {
            popover.barButtonItem = navigationItem.rightBarButtonItems?.last
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        }
        present(activity, animated: true)
    }

    private func thumbnail(forPageAt index: UInt) -> UIImage? {
        if let cached = pageThumbnailCache[index] { return cached }
        let target = CGSize(width: 68, height: 42)
        guard let thumbnail = DocumentExportService.thumbnail(
            strokes: canvas.engineBridge.renderableStrokes(forPageAt: index),
            canvasSize: canvas.bounds.size,
            targetSize: target
        ) else { return nil }
        pageThumbnailCache[index] = thumbnail
        return thumbnail
    }
}
