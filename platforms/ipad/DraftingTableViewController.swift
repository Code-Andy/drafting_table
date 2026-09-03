import UIKit

enum DraftingTheme {
    static let paper = UIColor(red: 0.961, green: 0.941, blue: 0.902, alpha: 1.0)        // #F5F0E6
    static let paperDeep = UIColor(red: 0.929, green: 0.898, blue: 0.824, alpha: 1.0)    // #EDE5D2
    static let ink = UIColor(red: 0.165, green: 0.149, blue: 0.125, alpha: 1.0)          // #2A2620
    static let inkSoft = UIColor(red: 0.420, green: 0.388, blue: 0.341, alpha: 1.0)      // #6B6357
    static let rule = UIColor(red: 0.851, green: 0.812, blue: 0.722, alpha: 1.0)         // #D9CFB8
    static let hot = UIColor(red: 0.710, green: 0.282, blue: 0.180, alpha: 1.0)          // #B5482E
}

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
    private static let snapDefaultsKey = "draftingTable.snapEnabled"
    private static let pixelGridDefaultsKey = "draftingTable.pixelGridEnabled"
    private static let angleSnapDefaultsKey = "draftingTable.angleSnapEnabled"
    private static let brushPreviewDefaultsKey = "draftingTable.brushPreviewEnabled"
    private static let predictionDefaultsKey = "draftingTable.predictionEnabled"
    private static let docTitleDefaultsKey = "draftingTable.documentTitle"
    private static let showDiagnosticsDefaultsKey = DrawingSettingsViewController.showDiagnosticsKey
    private static let shapeCenterModeDefaultsKey = DrawingSettingsViewController.shapeCenterModeKey

    private var canvas: CanvasView!
    private var hoverOverlay: HoverOverlayView!
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
    private var statusCenterChip: UIButton!
    private var statusPreviewChip: UIButton!
    private var statusPredictChip: UIButton!
    private var statusPageLabel: UILabel!
    private var toastLabel: InsetLabel!
    private var selectionActionBar: UIView!
    private var selectionCountLabel: UILabel!
    private let persistence = StrokePersistenceStore()

    // Top-left chrome & Sub-tool UI
    private var mainMenuButton: UIButton!
    private var undoRedoChip: UIView!
    private var chipUndoButton: UIButton!
    private var chipRedoButton: UIButton!
    private var bucketSubToolBar: UIView!
    private var gapSegment: UISegmentedControl!
    private var bleedSegment: UISegmentedControl!

    // Tool rail buttons
    private var brushButton: UIButton!
    private var eraserButton: UIButton!
    private var bucketButton: UIButton!
    private var shadeButton: UIButton!
    private var lineButton: UIButton!
    private var rectangleButton: UIButton!
    private var ellipseButton: UIButton!
    private var circleButton: UIButton!
    private var selectButton: UIButton!
    private var lassoButton: UIButton!
    private var colorSwatchButton: UIButton!
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
        root.backgroundColor = DraftingTheme.paper
        DTLaunchBreadcrumb("vc:create:canvas:start")
        canvas = CanvasView(frame: .zero)
        DTLaunchBreadcrumb("vc:create:canvas:done")
        hoverOverlay = HoverOverlayView(frame: .zero)
        canvas.hoverOverlay = hoverOverlay
        diagnostics = DiagnosticsOverlay(frame: .zero)
        diagnostics.isHidden = !UserDefaults.standard.bool(forKey: Self.showDiagnosticsDefaultsKey)
        DTLaunchBreadcrumb("vc:create:diagnostics:done")
        emptyState = InsetLabel()
        pagesRail = PagesRailView(frame: .zero)
        layersRail = LayersRailView(frame: .zero)
        toolRail = UIView()
        statusBar = UIView()
        toastLabel = InsetLabel()
        configureUndoRedoChip()
        configureBucketSubToolBar()
        configureSelectionActionBar()
        DTLaunchBreadcrumb("vc:create:rails:done")
        view = root
        [canvas, hoverOverlay, diagnostics, emptyState, pagesRail, layersRail, toolRail, statusBar, undoRedoChip, bucketSubToolBar, selectionActionBar, toastLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview($0)
        }
        configureEmptyState(); configurePagesRail(); configureLayersRail(); configureToolRail(); configureStatusBar(); configureToast()
        DTLaunchBreadcrumb("vc:loadView:done")

        let safe = root.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            // Canvas covers full screen to true paper edges, zero top bar overhead
            canvas.leadingAnchor.constraint(equalTo: root.leadingAnchor), canvas.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: root.topAnchor), canvas.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            hoverOverlay.leadingAnchor.constraint(equalTo: canvas.leadingAnchor), hoverOverlay.trailingAnchor.constraint(equalTo: canvas.trailingAnchor),
            hoverOverlay.topAnchor.constraint(equalTo: canvas.topAnchor), hoverOverlay.bottomAnchor.constraint(equalTo: canvas.bottomAnchor),

            // Left vertical tool rail (compact 54pt width, starts at top of screen)
            toolRail.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 8),
            toolRail.topAnchor.constraint(equalTo: safe.topAnchor, constant: 6),
            toolRail.bottomAnchor.constraint(equalTo: statusBar.topAnchor, constant: -6),
            toolRail.widthAnchor.constraint(equalToConstant: 54),

            // Page sidebar
            pagesRail.leadingAnchor.constraint(equalTo: toolRail.trailingAnchor, constant: 8),
            pagesRail.topAnchor.constraint(equalTo: safe.topAnchor, constant: 6),
            pagesRail.bottomAnchor.constraint(equalTo: statusBar.topAnchor, constant: -6),
            pagesRail.widthAnchor.constraint(equalToConstant: 80),

            // Layer sidebar
            layersRail.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -8),
            layersRail.topAnchor.constraint(equalTo: safe.topAnchor, constant: 6),
            layersRail.bottomAnchor.constraint(equalTo: statusBar.topAnchor, constant: -6),
            layersRail.widthAnchor.constraint(equalToConstant: 156),

            // Floating Undo / Redo chip over top-left canvas
            undoRedoChip.leadingAnchor.constraint(equalTo: toolRail.trailingAnchor, constant: 12),
            undoRedoChip.topAnchor.constraint(equalTo: safe.topAnchor, constant: 8),
            undoRedoChip.heightAnchor.constraint(equalToConstant: 34),

            // Bucket Sub-Tool Menu (gap error margin & bleed)
            bucketSubToolBar.leadingAnchor.constraint(equalTo: toolRail.trailingAnchor, constant: 12),
            bucketSubToolBar.topAnchor.constraint(equalTo: undoRedoChip.bottomAnchor, constant: 8),
            bucketSubToolBar.widthAnchor.constraint(equalToConstant: 248),

            // Status bar touching true bottom edge
            statusBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 34),

            selectionActionBar.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            selectionActionBar.bottomAnchor.constraint(equalTo: statusBar.topAnchor, constant: -14),
            toastLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            toastLabel.bottomAnchor.constraint(equalTo: statusBar.topAnchor, constant: -14),
            toastLabel.leadingAnchor.constraint(greaterThanOrEqualTo: pagesRail.trailingAnchor, constant: 18),
            toastLabel.trailingAnchor.constraint(lessThanOrEqualTo: layersRail.leadingAnchor, constant: -18),
            emptyState.centerXAnchor.constraint(equalTo: root.centerXAnchor), emptyState.centerYAnchor.constraint(equalTo: root.centerYAnchor, constant: -12),
            emptyState.leadingAnchor.constraint(greaterThanOrEqualTo: pagesRail.trailingAnchor, constant: 18), emptyState.trailingAnchor.constraint(lessThanOrEqualTo: layersRail.leadingAnchor, constant: -18),
            diagnostics.leadingAnchor.constraint(equalTo: pagesRail.trailingAnchor, constant: 12), diagnostics.topAnchor.constraint(equalTo: safe.topAnchor, constant: 10),
            diagnostics.widthAnchor.constraint(greaterThanOrEqualToConstant: 150), diagnostics.widthAnchor.constraint(lessThanOrEqualToConstant: 240)
        ])
        canvas.onDiagnostics = { [weak self] text in
            guard let self, !self.diagnostics.isHidden else { return }
            self.diagnostics.update(text: text)
        }
        canvas.onDrawingBegan = { [weak self] in self?.emptyState.isHidden = true }
        canvas.onDocumentChanged = { [weak self] in self?.documentDidChange() }
        canvas.onSqueeze = { [weak self] in self?.handlePencilSqueeze() }
        canvas.onCenterModeChanged = { [weak self] _ in self?.updateStatusBar() }
        canvas.onSelectionChanged = { [weak self] indices, _ in
            guard let self else { return }
            if indices.isEmpty {
                self.selectionActionBar.isHidden = true
            } else {
                self.selectionCountLabel.text = "\(indices.count) selected"
                self.selectionActionBar.isHidden = false
            }
        }
        canvas.onToolChanged = { [weak self] in
            guard let self else { return }
            let tool = self.canvas.currentTool
            self.selectedTool = tool
            UserDefaults.standard.set(Int(tool.rawValue), forKey: Self.selectedToolDefaultsKey)
            self.updateToolSelection()
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationController?.setNavigationBarHidden(true, animated: false)
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

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
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
        // Any in-flight background renders belong to the previous document
        // state; bumping the epoch orphans them so stale art can never land.
        thumbnailEpoch &+= 1
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
        thumbnailEpoch &+= 1
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
        canvas.snapToGrid = defaults.bool(forKey: Self.snapDefaultsKey)
        canvas.pixelGridVisible = defaults.bool(forKey: Self.pixelGridDefaultsKey)
        canvas.angleSnapEnabled = defaults.bool(forKey: Self.angleSnapDefaultsKey)
        canvas.brushPreviewEnabled = defaults.bool(forKey: Self.brushPreviewDefaultsKey)
        canvas.shapeCenterMode = defaults.bool(forKey: Self.shapeCenterModeDefaultsKey)
        diagnostics.isHidden = !defaults.bool(forKey: Self.showDiagnosticsDefaultsKey)
        let storedTool = defaults.integer(forKey: Self.selectedToolDefaultsKey)
        selectedTool = (0...Int(DTTool.lasso.rawValue)).contains(storedTool)
            ? (DTTool(rawValue: UInt8(storedTool)) ?? .brush)
            : .brush
        canvas.currentTool = selectedTool
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
        settings.onGridChanged = { [weak self] value in self?.canvas.gridVisible = value; self?.updateStatusBar(); self?.saveDocument() }
        settings.onDiagnosticsChanged = { [weak self] value in self?.diagnostics.isHidden = !value }
        settings.onShapeCenterModeChanged = { [weak self] value in self?.canvas.shapeCenterMode = value; self?.updateStatusBar() }
        settings.onTransparentExportChanged = { [weak self] _ in self?.showToast("Transparent PNG export updated") }
        settings.onEyedropperToast = { [weak self] in self?.showToast("Eyedropper needs the tile sampler (M2)") }
        let navigation = UINavigationController(rootViewController: settings); navigation.modalPresentationStyle = .formSheet
        if let sheet = navigation.sheetPresentationController { sheet.detents = [.medium(), .large()]; sheet.prefersGrabberVisible = true }
        present(navigation, animated: true)
    }

    /// Color tool: opens the HSV picker directly from the rail swatch.
    @objc private func openColorPickerDirect() { presentColorPicker() }

    private func presentColorPicker() {
        let picker = ColorPickerViewController()
        picker.initialColorRGBA = canvas.engineBridge.brushColorRGBA
        picker.onColorChanged = { [weak self] packed in self?.applyBrushColor(packed) }
        picker.onColorPicked = { [weak self] packed in self?.applyBrushColor(packed) }
        picker.onEyedropperRequested = { [weak self] in
            self?.dismiss(animated: true)
            self?.showToast("Eyedropper needs the tile sampler (M2)")
        }
        let navigation = UINavigationController(rootViewController: picker)
        navigation.modalPresentationStyle = .formSheet
        if let sheet = navigation.sheetPresentationController { sheet.detents = [.medium(), .large()]; sheet.prefersGrabberVisible = true }
        present(navigation, animated: true)
    }

    private func applyBrushColor(_ packed: UInt32) {
        canvas.engineBridge.brushColorRGBA = packed
        UserDefaults.standard.set(Int(packed), forKey: DrawingSettingsViewController.brushColorKey)
        saveDocument()
        refreshColorSwatch()
    }

    private func refreshColorSwatch() {
        guard let colorSwatchButton else { return }
        let packed = isViewLoaded ? canvas.engineBridge.brushColorRGBA : DrawingSettingsViewController.defaultBrushColorRGBA
        colorSwatchButton.backgroundColor = DrawingSettingsViewController.uiColor(from: packed)
        let r = CGFloat((packed >> 24) & 0xff) / 255
        let g = CGFloat((packed >> 16) & 0xff) / 255
        let b = CGFloat((packed >> 8) & 0xff) / 255
        let ink: UIColor = (0.299 * r + 0.587 * g + 0.114 * b) > 0.5
            ? UIColor(red: 0.16, green: 0.14, blue: 0.11, alpha: 1) : .white
        colorSwatchButton.setTitleColor(ink, for: .normal)
    }

    private func updateDocumentTitleLabel() {
        let title = UserDefaults.standard.string(forKey: Self.docTitleDefaultsKey) ?? "DraftingTable"
        statusDocLabel?.text = "doc · \(title)"
        self.title = title
    }

    @objc private func promptRenameDocument() {
        let currentTitle = UserDefaults.standard.string(forKey: Self.docTitleDefaultsKey) ?? "DraftingTable"
        let alert = UIAlertController(title: "Document Title",
                                      message: "Enter a title for this notebook document:",
                                      preferredStyle: .alert)
        alert.addTextField { tf in
            tf.text = currentTitle
            tf.placeholder = "Document Title"
            tf.autocapitalizationType = .words
            tf.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self, weak alert] _ in
            guard let self, let name = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return }
            UserDefaults.standard.set(name, forKey: Self.docTitleDefaultsKey)
            self.updateDocumentTitleLabel()
            HapticFeedbackService.shared.success()
        })
        present(alert, animated: true)
    }

    @objc private func confirmClearDocument() {
        let alert = UIAlertController(title: "Clear Entire Document",
                                      message: "Are you sure you want to clear all pages and strokes? This cannot be undone.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Clear All", style: .destructive) { [weak self] _ in
            guard let self else { return }
            self.canvas.engineBridge.clearCanvas()
            self.documentDidChange(invalidateAllThumbnails: true)
            HapticFeedbackService.shared.undoRedo()
        })
        present(alert, animated: true)
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
        let renameDoc = UIAction(title: "Rename Document…", image: UIImage(systemName: "pencil")) { [weak self] _ in self?.promptRenameDocument() }
        let clearDoc = UIAction(title: "Clear Entire Document", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in self?.confirmClearDocument() }
        let exportPage = UIAction(title: "Export Current Page (PNG)", image: UIImage(systemName: "photo")) { [weak self] _ in self?.exportCurrentPagePNG() }
        let exportPDF = UIAction(title: "Export All Pages (PDF)", image: UIImage(systemName: "doc.richtext")) { [weak self] _ in self?.exportAllPagesPDF() }
        let open = UIAction(title: "Open .drafttable…", image: UIImage(systemName: "folder")) { [weak self] _ in self?.openDocument() }
        let saveCopy = UIAction(title: "Save Copy…", image: UIImage(systemName: "square.and.arrow.down")) { [weak self] _ in self?.saveDocumentCopy() }
        let documents = UIMenu(title: "Documents", options: .displayInline, children: [renameDoc, open, saveCopy, clearDoc])
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
        // v0.9.0: thumbnails are back through the background cache. The rail
        // callback stays synchronous and cheap; raster work happens off-main
        // and refreshes the rail when ready.
        pagesRail.thumbnailForPage = { [weak self] index in self?.thumbnail(forPageAt: index) }
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
        pagesRail.onDocsMenu = { [weak self] in self?.openGallery() }
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

    private func configureUndoRedoChip() {
        undoRedoChip = UIView()
        undoRedoChip.backgroundColor = DraftingTheme.paperDeep.withAlphaComponent(0.95)
        undoRedoChip.layer.cornerRadius = 8
        undoRedoChip.layer.borderWidth = 1
        undoRedoChip.layer.borderColor = DraftingTheme.rule.cgColor
        undoRedoChip.layer.shadowColor = UIColor.black.cgColor
        undoRedoChip.layer.shadowOpacity = 0.08
        undoRedoChip.layer.shadowRadius = 4
        undoRedoChip.layer.shadowOffset = CGSize(width: 0, height: 1.5)
        undoRedoChip.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        undoRedoChip.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: undoRedoChip.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: undoRedoChip.trailingAnchor, constant: -4),
            stack.topAnchor.constraint(equalTo: undoRedoChip.topAnchor),
            stack.bottomAnchor.constraint(equalTo: undoRedoChip.bottomAnchor)
        ])

        chipUndoButton = UIButton(type: .system)
        let undoCfg = UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        chipUndoButton.setImage(UIImage(systemName: "arrow.uturn.backward", withConfiguration: undoCfg), for: .normal)
        chipUndoButton.tintColor = DraftingTheme.ink
        chipUndoButton.widthAnchor.constraint(equalToConstant: 34).isActive = true
        chipUndoButton.heightAnchor.constraint(equalToConstant: 32).isActive = true
        chipUndoButton.addTarget(self, action: #selector(undoCanvas), for: .touchUpInside)
        chipUndoButton.accessibilityLabel = "Undo"

        let div = UIView()
        div.backgroundColor = DraftingTheme.rule
        div.widthAnchor.constraint(equalToConstant: 1).isActive = true
        div.heightAnchor.constraint(equalToConstant: 18).isActive = true

        chipRedoButton = UIButton(type: .system)
        let redoCfg = UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        chipRedoButton.setImage(UIImage(systemName: "arrow.uturn.forward", withConfiguration: redoCfg), for: .normal)
        chipRedoButton.tintColor = DraftingTheme.ink
        chipRedoButton.widthAnchor.constraint(equalToConstant: 34).isActive = true
        chipRedoButton.heightAnchor.constraint(equalToConstant: 32).isActive = true
        chipRedoButton.addTarget(self, action: #selector(redoCanvas), for: .touchUpInside)
        chipRedoButton.accessibilityLabel = "Redo"

        [chipUndoButton, div, chipRedoButton].forEach(stack.addArrangedSubview)
    }

    private func configureBucketSubToolBar() {
        bucketSubToolBar = UIView()
        bucketSubToolBar.backgroundColor = DraftingTheme.paperDeep.withAlphaComponent(0.96)
        bucketSubToolBar.layer.cornerRadius = 9
        bucketSubToolBar.layer.borderWidth = 1
        bucketSubToolBar.layer.borderColor = DraftingTheme.rule.cgColor
        bucketSubToolBar.layer.shadowColor = UIColor.black.cgColor
        bucketSubToolBar.layer.shadowOpacity = 0.10
        bucketSubToolBar.layer.shadowRadius = 6
        bucketSubToolBar.layer.shadowOffset = CGSize(width: 0, height: 2)
        bucketSubToolBar.translatesAutoresizingMaskIntoConstraints = false
        bucketSubToolBar.isHidden = true

        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        bucketSubToolBar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bucketSubToolBar.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: bucketSubToolBar.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: bucketSubToolBar.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bucketSubToolBar.bottomAnchor, constant: -8)
        ])

        let titleLbl = UILabel()
        titleLbl.text = "BUCKET FILL OPTIONS"
        titleLbl.font = .systemFont(ofSize: 10, weight: .bold)
        titleLbl.textColor = DraftingTheme.inkSoft
        stack.addArrangedSubview(titleLbl)

        let gapLabel = UILabel()
        gapLabel.text = "GAP ERROR MARGIN"
        gapLabel.font = .systemFont(ofSize: 9, weight: .semibold)
        gapLabel.textColor = DraftingTheme.inkSoft
        stack.addArrangedSubview(gapLabel)

        let gapValues = [0, 2, 4, 8, 12, 16]
        let gapTitles = ["0px", "2px", "4px", "8px", "12px", "16px"]
        gapSegment = UISegmentedControl(items: gapTitles)
        let currentGap = canvas.bucketGapSize
        if let idx = gapValues.firstIndex(of: currentGap) {
            gapSegment.selectedSegmentIndex = idx
        } else {
            gapSegment.selectedSegmentIndex = 2
        }
        gapSegment.selectedSegmentTintColor = DraftingTheme.paper
        gapSegment.backgroundColor = DraftingTheme.paper.withAlphaComponent(0.6)
        gapSegment.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            let idx = self.gapSegment.selectedSegmentIndex
            if idx >= 0 && idx < gapValues.count {
                self.canvas.bucketGapSize = gapValues[idx]
                self.showToast("Bucket Gap Margin: \(gapTitles[idx])")
            }
        }, for: .valueChanged)
        stack.addArrangedSubview(gapSegment)

        let bleedLabel = UILabel()
        bleedLabel.text = "BLEED / EXPANSION"
        bleedLabel.font = .systemFont(ofSize: 9, weight: .semibold)
        bleedLabel.textColor = DraftingTheme.inkSoft
        stack.addArrangedSubview(bleedLabel)

        let bleedValues = [0, 1, 2, 4]
        let bleedTitles = ["0px", "1px", "2px", "4px"]
        bleedSegment = UISegmentedControl(items: bleedTitles)
        let currentBleed = canvas.bucketBleed
        if let idx = bleedValues.firstIndex(of: currentBleed) {
            bleedSegment.selectedSegmentIndex = idx
        } else {
            bleedSegment.selectedSegmentIndex = 2
        }
        bleedSegment.selectedSegmentTintColor = DraftingTheme.paper
        bleedSegment.backgroundColor = DraftingTheme.paper.withAlphaComponent(0.6)
        bleedSegment.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            let idx = self.bleedSegment.selectedSegmentIndex
            if idx >= 0 && idx < bleedValues.count {
                self.canvas.bucketBleed = bleedValues[idx]
                self.showToast("Bucket Bleed: \(bleedTitles[idx])")
            }
        }, for: .valueChanged)
        stack.addArrangedSubview(bleedSegment)
    }

    private func applyQuickColor(_ rgba: UInt32) {
        canvas.engineBridge.brushColorRGBA = rgba
        UserDefaults.standard.set(Int64(rgba), forKey: DrawingSettingsViewController.brushColorDefaultsKey)
        refreshColorSwatch()
        HapticFeedbackService.shared.toolSwitched()
    }

    @objc private func showMainMenu(_ sender: UIButton) {
        let alert = UIAlertController(title: "Drafting Table", message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "Notebooks Gallery", style: .default) { [weak self] _ in
            self?.openGallery()
        })
        alert.addAction(UIAlertAction(title: "Rename Document", style: .default) { [weak self] _ in
            self?.promptRenameDocument()
        })
        alert.addAction(UIAlertAction(title: "Export & Share...", style: .default) { [weak self] _ in
            self?.showExportMenu(sourceView: sender)
        })
        alert.addAction(UIAlertAction(title: "Import Photo...", style: .default) { [weak self] _ in
            self?.promptImportPhoto()
        })
        alert.addAction(UIAlertAction(title: "Settings...", style: .default) { [weak self] _ in
            self?.openSettings()
        })
        alert.addAction(UIAlertAction(title: "Reset Canvas View", style: .default) { [weak self] _ in
            self?.resetCanvasView()
        })
        alert.addAction(UIAlertAction(title: "Clear Document", style: .destructive) { [weak self] _ in
            self?.confirmClearDocument()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.sourceView = sender
            popover.sourceRect = sender.bounds
        }
        present(alert, animated: true)
    }

    @objc private func showExportMenu(sourceView: UIView? = nil) {
        let alert = UIAlertController(title: "Export & Share", message: nil, preferredStyle: .actionSheet)
        let anchor = sourceView ?? mainMenuButton ?? view
        alert.popoverPresentationController?.sourceView = anchor
        alert.popoverPresentationController?.sourceRect = anchor?.bounds ?? .zero

        alert.addAction(UIAlertAction(title: "Export Current Page (PNG)", style: .default) { [weak self] _ in
            self?.exportCurrentPagePNG()
        })
        alert.addAction(UIAlertAction(title: "Export All Pages (PDF)", style: .default) { [weak self] _ in
            self?.exportAllPagesPDF()
        })
        alert.addAction(UIAlertAction(title: "Save Archive Copy (.drafttable)", style: .default) { [weak self] _ in
            self?.saveDocumentCopy()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    private func configureToolRail() {
        styleRail(toolRail)
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.showsVerticalScrollIndicator = false
        let stack = UIStackView()
        stack.axis = .vertical; stack.alignment = .fill; stack.spacing = 4; stack.translatesAutoresizingMaskIntoConstraints = false

        mainMenuButton = railToolButton(systemName: "line.3.horizontal", label: "Menu", action: #selector(showMainMenu(_:)))
        stack.addArrangedSubview(mainMenuButton)
        stack.addArrangedSubview(railRule())

        // Primitive Color Selector & Pen Colors
        colorSwatchButton = railToolButton(systemName: "circle.fill", label: "Color", action: #selector(openColorPickerDirect))
        refreshColorSwatch()
        stack.addArrangedSubview(colorSwatchButton)

        let paletteGrid = UIStackView()
        paletteGrid.axis = .vertical
        paletteGrid.spacing = 3
        paletteGrid.alignment = .center

        let quickColors: [(UInt32, String)] = [
            (0x000000FF, "Black"), (0x2B2926FF, "Ink"),
            (0xB5482EFF, "Red"),   (0x2A5D8FFF, "Blue"),
            (0x3D5E26FF, "Green"), (0xC8A030FF, "Amber"),
            (0x7A7368FF, "Gray"),  (0xFFFFFFFF, "White")
        ]
        for r in 0..<4 {
            let rowStack = UIStackView()
            rowStack.axis = .horizontal
            rowStack.spacing = 4
            rowStack.alignment = .center
            for c in 0..<2 {
                let idx = r * 2 + c
                let (rgba, name) = quickColors[idx]
                let btn = UIButton(type: .custom)
                btn.translatesAutoresizingMaskIntoConstraints = false
                btn.widthAnchor.constraint(equalToConstant: 18).isActive = true
                btn.heightAnchor.constraint(equalToConstant: 18).isActive = true
                btn.layer.cornerRadius = 9
                btn.backgroundColor = UIColor(
                    red: CGFloat((rgba >> 24) & 0xff) / 255.0,
                    green: CGFloat((rgba >> 16) & 0xff) / 255.0,
                    blue: CGFloat((rgba >> 8) & 0xff) / 255.0,
                    alpha: 1.0
                )
                btn.layer.borderWidth = 1.0
                btn.layer.borderColor = UIColor(red: 0.35, green: 0.30, blue: 0.22, alpha: 0.35).cgColor
                btn.accessibilityLabel = name
                btn.addAction(UIAction { [weak self] _ in
                    self?.applyQuickColor(rgba)
                }, for: .touchUpInside)
                rowStack.addArrangedSubview(btn)
            }
            paletteGrid.addArrangedSubview(rowStack)
        }
        stack.addArrangedSubview(paletteGrid)
        stack.addArrangedSubview(railRule())

        brushButton = railToolButton(systemName: "pencil.tip", label: "Brush", action: #selector(selectBrush))
        eraserButton = railToolButton(systemName: "eraser", label: "Eraser", action: #selector(selectEraser))
        bucketButton = railToolButton(systemName: "drop.fill", label: "Bucket", action: #selector(selectBucket))
        shadeButton = railToolButton(systemName: "skew", label: "Shade", action: #selector(selectShade))
        lineButton = railToolButton(systemName: "line.diagonal", label: "Line", action: #selector(selectLine))
        rectangleButton = railToolButton(systemName: "rectangle", label: "Rect", action: #selector(selectRectangle))
        circleButton = railToolButton(systemName: "circle", label: "Circle", action: #selector(selectCircle))
        ellipseButton = railToolButton(systemName: "oval", label: "Ellipse", action: #selector(selectEllipse))
        selectButton = railToolButton(systemName: "rectangle.dashed", label: "Select", action: #selector(selectMarquee))
        lassoButton = railToolButton(systemName: "lasso", label: "Lasso", action: #selector(selectLasso))

        let pagesToggle = railToolButton(systemName: "doc.plaintext", label: "Pages", action: #selector(togglePagesRail))
        let layersToggle = railToolButton(systemName: "square.3.layers.3d", label: "Layers", action: #selector(toggleLayersRail))
        let resetViewBtn = railToolButton(systemName: "arrow.down.right.and.arrow.up.left", label: "Reset", action: #selector(resetCanvasView))
        clearButton = railToolButton(systemName: "trash", label: "Clear", action: #selector(confirmClearDocument))

        stack.addArrangedSubview(railTitle("DRAW"))
        [brushButton, eraserButton, bucketButton, shadeButton].forEach(stack.addArrangedSubview)
        stack.addArrangedSubview(railRule())
        stack.addArrangedSubview(railTitle("VECTOR"))
        [lineButton, rectangleButton, circleButton, ellipseButton].forEach(stack.addArrangedSubview)
        stack.addArrangedSubview(railRule())
        stack.addArrangedSubview(railTitle("SELECT"))
        [selectButton, lassoButton].forEach(stack.addArrangedSubview)
        stack.addArrangedSubview(railRule())
        stack.addArrangedSubview(railTitle("PANELS"))
        [pagesToggle, layersToggle].forEach(stack.addArrangedSubview)
        stack.addArrangedSubview(railRule())
        [resetViewBtn, clearButton].forEach(stack.addArrangedSubview)

        scroll.addSubview(stack); toolRail.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: toolRail.leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: toolRail.trailingAnchor, constant: -4),
            scroll.topAnchor.constraint(equalTo: toolRail.topAnchor, constant: 6),
            scroll.bottomAnchor.constraint(equalTo: toolRail.bottomAnchor, constant: -6),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor)
        ])
    }

    @objc private func togglePagesRail() {
        pagesRail.isHidden.toggle()
    }

    @objc private func toggleLayersRail() {
        layersRail.isHidden.toggle()
    }

    private func styleRail(_ rail: UIView) {
        rail.backgroundColor = DraftingTheme.paperDeep
        rail.layer.cornerRadius = 10
        rail.layer.borderWidth = 1
        rail.layer.borderColor = DraftingTheme.rule.cgColor
        rail.layer.shadowColor = UIColor.black.cgColor
        rail.layer.shadowOpacity = 0.06
        rail.layer.shadowRadius = 6
        rail.layer.shadowOffset = CGSize(width: 0, height: 2)
    }

    private func railTitle(_ title: String) -> UILabel {
        let label = UILabel()
        label.text = title
        label.font = .systemFont(ofSize: 9, weight: .bold)
        label.textColor = DraftingTheme.inkSoft
        label.textAlignment = .center
        return label
    }

    private func railRule() -> UIView {
        let rule = UIView()
        rule.backgroundColor = DraftingTheme.rule
        rule.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return rule
    }

    private func railToolButton(systemName: String, label: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        var config = UIButton.Configuration.plain()
        let symConfig = UIImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        config.image = UIImage(systemName: systemName, withConfiguration: symConfig)
        config.imagePlacement = .top
        config.imagePadding = 2
        config.title = label
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .systemFont(ofSize: 9, weight: .medium)
            return outgoing
        }
        config.baseForegroundColor = DraftingTheme.ink
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 2, bottom: 4, trailing: 2)
        button.configuration = config
        button.backgroundColor = UIColor.white.withAlphaComponent(0.82)
        button.layer.cornerRadius = 7
        button.layer.borderWidth = 1
        button.layer.borderColor = DraftingTheme.rule.withAlphaComponent(0.6).cgColor
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        button.addTarget(self, action: action, for: .touchUpInside)
        button.accessibilityLabel = label
        return button
    }

    // MARK: - Status bar (mirrors the original app's bottom bar)

    private func configureStatusBar() {
        statusBar.backgroundColor = DraftingTheme.paperDeep
        let hairline = UIView()
        hairline.backgroundColor = DraftingTheme.rule
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
        // Shift items inward to ensure iPad display corner radii don't cut off buttons
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 48),
            stack.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor, constant: -48),
            stack.topAnchor.constraint(equalTo: statusBar.topAnchor),
            stack.bottomAnchor.constraint(equalTo: statusBar.bottomAnchor)
        ])
        statusDocLabel = statusLabel(text: "doc · DraftingTable")
        statusDocLabel.isUserInteractionEnabled = true
        let docTap = UITapGestureRecognizer(target: self, action: #selector(promptRenameDocument))
        statusDocLabel.addGestureRecognizer(docTap)
        statusToolLabel = statusLabel(text: "◇ brush")
        statusGridChip = statusChip(action: #selector(toggleGridChip))
        statusPixelChip = statusChip(action: #selector(togglePixelChip))
        statusSnapChip = statusChip(action: #selector(toggleSnapChip))
        statusAngleChip = statusChip(action: #selector(toggleAngleChip))
        statusCenterChip = statusChip(action: #selector(toggleCenterChip))
        statusPreviewChip = statusChip(action: #selector(togglePreviewChip))
        statusPredictChip = statusChip(action: #selector(togglePredictChip))
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusPageLabel = statusLabel(text: "page 01 / 01")

        [statusDocLabel, statusToolLabel,
         statusGridChip, statusPixelChip, statusSnapChip,
         statusAngleChip, statusCenterChip, statusPreviewChip, statusPredictChip,
         spacer, statusPageLabel].forEach(stack.addArrangedSubview)
        updateStatusBar()
    }

    private func statusLabel(text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = DraftingTheme.inkSoft
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
        let color: UIColor = on ? DraftingTheme.hot : DraftingTheme.inkSoft
        chip.setTitleColor(color, for: .normal)
        chip.accessibilityValue = on ? "On" : "Off"
    }

    private func updateStatusBar() {
        guard isViewLoaded, let statusToolLabel else { return }
        updateDocumentTitleLabel()
        statusToolLabel.text = "◇ \(canvas.activeToolDisplayName)"
        paintChip(statusGridChip, title: canvas.gridVisible ? "grid: on" : "grid: off", on: canvas.gridVisible)
        paintChip(statusPixelChip, title: canvas.pixelGridVisible ? "px: on" : "px: off", on: canvas.pixelGridVisible)
        paintChip(statusSnapChip, title: canvas.snapToGrid ? "snap: on" : "snap: off", on: canvas.snapToGrid)
        paintChip(statusAngleChip, title: canvas.angleSnapEnabled ? "angle: on" : "angle: off", on: canvas.angleSnapEnabled)
        paintChip(statusCenterChip, title: canvas.shapeCenterMode ? "center: on" : "center: off", on: canvas.shapeCenterMode)
        paintChip(statusPreviewChip, title: canvas.brushPreviewEnabled ? "preview: on" : "preview: off", on: canvas.brushPreviewEnabled)
        paintChip(statusPredictChip, title: canvas.predictionEnabled ? "predict: on" : "predict: off", on: canvas.predictionEnabled)

        let pages = canvas.engineBridge.pageInfos
        let current = (pages.first(where: { $0.selected })?.index ?? 0) + 1
        statusPageLabel?.text = String(format: "page %02d / %02d", current, max(1, pages.count))
    }

    @objc private func toggleCenterChip() {
        canvas.shapeCenterMode.toggle()
        UserDefaults.standard.set(canvas.shapeCenterMode, forKey: Self.shapeCenterModeDefaultsKey)
        HapticFeedbackService.shared.snapLock()
        updateStatusBar()
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
        canvas.snapToGrid = next
        updateStatusBar()
    }

    @objc private func togglePixelChip() {
        let next = !canvas.pixelGridVisible
        UserDefaults.standard.set(next, forKey: Self.pixelGridDefaultsKey)
        canvas.pixelGridVisible = next
        updateStatusBar()
        HapticFeedbackService.shared.snapLock()
    }

    @objc private func toggleAngleChip() {
        let next = !canvas.angleSnapEnabled
        UserDefaults.standard.set(next, forKey: Self.angleSnapDefaultsKey)
        canvas.angleSnapEnabled = next
        updateStatusBar()
        HapticFeedbackService.shared.snapLock()
    }

    @objc private func togglePreviewChip() {
        let next = !canvas.brushPreviewEnabled
        UserDefaults.standard.set(next, forKey: Self.brushPreviewDefaultsKey)
        canvas.brushPreviewEnabled = next
        updateStatusBar()
    }

    @objc private func togglePredictChip() {
        canvas.predictionEnabled.toggle()
        UserDefaults.standard.set(canvas.predictionEnabled, forKey: Self.predictionDefaultsKey)
        updateStatusBar()
    }

    private func configureSelectionActionBar() {
        selectionActionBar = UIView()
        selectionActionBar.translatesAutoresizingMaskIntoConstraints = false
        selectionActionBar.backgroundColor = UIColor(red: 0.99, green: 0.98, blue: 0.95, alpha: 0.96)
        selectionActionBar.layer.cornerRadius = 14
        selectionActionBar.layer.borderWidth = 1.5
        selectionActionBar.layer.borderColor = UIColor.systemBlue.withAlphaComponent(0.4).cgColor
        selectionActionBar.layer.shadowColor = UIColor.black.cgColor
        selectionActionBar.layer.shadowOpacity = 0.12
        selectionActionBar.layer.shadowRadius = 8
        selectionActionBar.layer.shadowOffset = CGSize(width: 0, height: 3)
        selectionActionBar.isHidden = true

        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = 10
        stack.alignment = .center

        selectionCountLabel = UILabel()
        selectionCountLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        selectionCountLabel.textColor = UIColor(red: 0.20, green: 0.18, blue: 0.15, alpha: 1)
        selectionCountLabel.text = "0 selected"

        let dupBtn = UIButton(type: .system)
        dupBtn.setTitle("Duplicate", for: .normal)
        dupBtn.titleLabel?.font = .systemFont(ofSize: 12, weight: .semibold)
        dupBtn.addTarget(self, action: #selector(duplicateSelectionAction), for: .touchUpInside)

        let delBtn = UIButton(type: .system)
        delBtn.setTitle("Delete", for: .normal)
        delBtn.setTitleColor(.systemRed, for: .normal)
        delBtn.titleLabel?.font = .systemFont(ofSize: 12, weight: .semibold)
        delBtn.addTarget(self, action: #selector(deleteSelectionAction), for: .touchUpInside)

        let clearBtn = UIButton(type: .system)
        clearBtn.setTitle("Done", for: .normal)
        clearBtn.titleLabel?.font = .systemFont(ofSize: 12, weight: .semibold)
        clearBtn.addTarget(self, action: #selector(clearSelectionAction), for: .touchUpInside)

        stack.addArrangedSubview(selectionCountLabel)
        stack.addArrangedSubview(dupBtn)
        stack.addArrangedSubview(delBtn)
        stack.addArrangedSubview(clearBtn)
        selectionActionBar.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: selectionActionBar.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: selectionActionBar.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: selectionActionBar.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: selectionActionBar.bottomAnchor, constant: -6)
        ])
    }

    @objc private func duplicateSelectionAction() {
        canvas.duplicateSelection()
    }

    @objc private func deleteSelectionAction() {
        canvas.deleteSelection()
    }

    @objc private func clearSelectionAction() {
        canvas.clearSelection()
        selectionActionBar.isHidden = true
    }

    private func handlePencilSqueeze() {
        let hoverPt = hoverOverlay?.hoverPoint ?? canvas.lastTouchPoint
        let targetPt = (hoverPt == .zero) ? CGPoint(x: view.bounds.midX, y: view.bounds.midY) : hoverPt
        let current = canvas.engineBridge.brushColorRGBA
        let currentUIColor = UIColor(
            red: CGFloat((current >> 24) & 0xff) / 255.0,
            green: CGFloat((current >> 16) & 0xff) / 255.0,
            blue: CGFloat((current >> 8) & 0xff) / 255.0,
            alpha: CGFloat(current & 0xff) / 255.0
        )
        let radial = CircularRadialMenuView(activeTool: canvas.currentTool, activeColor: currentUIColor)
        radial.onAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case .selectTool(let tool):
                if tool == .bucket {
                    self.selectBucket()
                } else {
                    self.selectTool(tool)
                }
            case .openColorPicker:
                self.openColorPickerDirect()
            case .undo:
                self.undoCanvas()
            }
        }
        radial.present(in: view, around: targetPt)
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

    private func updateToolSelection() {
        let selectedColor = UIColor.systemBlue.withAlphaComponent(0.16)
        let normalColor = UIColor.white.withAlphaComponent(0.82)
        let entries: [(UIButton?, DTTool)] = [
            (brushButton, .brush),
            (eraserButton, .eraser),
            (bucketButton, .bucket),
            (shadeButton, .shade),
            (lineButton, .line),
            (rectangleButton, .rectangle),
            (ellipseButton, .ellipse),
            (circleButton, .circle),
            (selectButton, .select),
            (lassoButton, .lasso)
        ]
        entries.forEach { button, tool in
            guard let button else { return }
            button.isSelected = selectedTool == tool
            button.backgroundColor = button.isSelected ? selectedColor : normalColor
            button.layer.borderColor = (button.isSelected ? UIColor.systemBlue : DraftingTheme.rule.withAlphaComponent(0.6)).cgColor
            button.accessibilityValue = button.isSelected ? "Selected" : "Not selected"
        }
        bucketSubToolBar?.isHidden = (selectedTool != .bucket)
        refreshColorSwatch()
        updateStatusBar()
    }

    private func updateUndoRedoState() {
        let canUndo = canvas.engineBridge.canUndo
        let canRedo = canvas.engineBridge.canRedo
        undoButton?.isEnabled = canUndo
        redoButton?.isEnabled = canRedo
        chipUndoButton?.isEnabled = canUndo
        chipUndoButton?.alpha = canUndo ? 1.0 : 0.35
        chipRedoButton?.isEnabled = canRedo
        chipRedoButton?.alpha = canRedo ? 1.0 : 0.35
        clearButton?.isEnabled = canvas.engineBridge.strokeCount > 0
    }

    @objc private func selectEraser() { selectTool(.eraser) }
    @objc private func selectBrush() { selectTool(.brush) }
    @objc private func selectBucket() { selectTool(.bucket); showToast("Bucket Fill Tool Active") }
    @objc private func selectShade() { selectTool(.shade) }
    @objc private func selectLine() { selectTool(.line) }
    @objc private func selectRectangle() { selectTool(.rectangle) }
    @objc private func selectEllipse() { selectTool(.ellipse) }
    @objc private func selectCircle() { selectTool(.circle) }
    @objc private func selectMarquee() { selectTool(.select) }
    @objc private func selectLasso() { selectTool(.lasso) }

    private func selectTool(_ tool: DTTool) {
        selectedTool = tool
        canvas.currentTool = tool
        UserDefaults.standard.set(Int(tool.rawValue), forKey: Self.selectedToolDefaultsKey)
        HapticFeedbackService.shared.toolSwitched()
        updateToolSelection()
    }

    @objc private func undoCanvas() { guard canvas.engineBridge.canUndo else { return }; _ = canvas.engineBridge.undoLastStroke(); documentDidChange() }
    @objc private func redoCanvas() { guard canvas.engineBridge.canRedo else { return }; _ = canvas.engineBridge.redoLastStroke(); documentDidChange() }
    @objc private func clearCanvas() { guard canvas.engineBridge.strokeCount > 0 else { return }; canvas.engineBridge.clearCanvas(); documentDidChange() }
    @objc private func openSettings() { showSettings() }
    @objc private func resetCanvasView() { canvas.resetView() }

    private func exportCurrentPagePNG() {
        guard let page = canvas.engineBridge.pageInfos.first(where: { $0.selected }) else { return }
        let transparent = UserDefaults.standard.bool(forKey: "draftingTable.transparentExport")
        guard let data = DocumentExportService.pngData(
            strokes: canvas.engineBridge.renderableStrokes(forPageAt: page.index),
            canvasSize: canvas.bounds.size,
            transparentBackground: transparent
        ) else { return }
        shareTemporary(data: data, extension: "png", activityItem: "Drafting Table Page")
    }

    @objc private func promptImportPhoto() {
        let picker = UIImagePickerController()
        picker.sourceType = .photoLibrary
        picker.delegate = self
        picker.modalPresentationStyle = .formSheet
        present(picker, animated: true)
    }

    private func insertImportedImage(_ image: UIImage) {
        let center = canvas.documentPoint(for: CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY))
        let maxDim: CGFloat = 360.0
        let aspect = image.size.width > 0 ? image.size.height / image.size.width : 1.0
        let w = min(image.size.width, maxDim)
        let h = w * aspect
        let minX = center.x - w * 0.5
        let minY = center.y - h * 0.5
        let maxX = center.x + w * 0.5
        let maxY = center.y + h * 0.5

        var p0 = DTRenderPoint(x: Float(minX), y: Float(minY), pressure: 1.0, predicted: 0)
        var p1 = DTRenderPoint(x: Float(maxX), y: Float(maxY), pressure: 1.0, predicted: 0)
        let val0 = NSValue(bytes: &p0, objCType: "{DTRenderPoint=ffff}")
        let val1 = NSValue(bytes: &p1, objCType: "{DTRenderPoint=ffff}")

        _ = canvas.engineBridge.insertStroke(points: [val0, val1],
                                             tool: .rectangle,
                                             brushSize: 2.0,
                                             brushOpacity: 1.0,
                                             brushColorRGBA: canvas.engineBridge.brushColorRGBA,
                                             brushHardness: 1.0)
        documentDidChange()
        showToast("Image imported (\(Int(w)) × \(Int(h)))")
    }

    @objc private func openGallery() {
        saveDocument()
        let currentTitle = UserDefaults.standard.string(forKey: Self.docTitleDefaultsKey) ?? "DraftingTable"
        let gallery = DocumentGalleryViewController(currentDocumentName: currentTitle)
        gallery.delegate = self
        let nav = UINavigationController(rootViewController: gallery)
        nav.modalPresentationStyle = .formSheet
        present(nav, animated: true)
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
        requestThumbnail(forPageAt: index)
        return nil
    }

    private let thumbnailQueue = DispatchQueue(label: "draftingTable.thumbnails", qos: .utility)
    private var thumbnailsInFlight: Set<UInt> = []
    private var thumbnailEpoch: UInt64 = 0

    private func requestThumbnail(forPageAt index: UInt) {
        guard !thumbnailsInFlight.contains(index) else { return }
        let canvasSize = canvas.bounds.size
        guard canvasSize.width >= 1, canvasSize.height >= 1 else { return }
        thumbnailsInFlight.insert(index)
        let epoch = thumbnailEpoch
        let bridge = canvas.engineBridge
        thumbnailQueue.async { [weak self] in
            let strokes = bridge.renderableStrokes(forPageAt: index)
            let image = DocumentExportService.thumbnail(
                strokes: strokes,
                canvasSize: canvasSize,
                targetSize: CGSize(width: 96, height: 60))
            DispatchQueue.main.async {
                guard let self else { return }
                self.thumbnailsInFlight.remove(index)
                guard epoch == self.thumbnailEpoch,
                      let image,
                      self.pageThumbnailCache[index] == nil else { return }
                self.pageThumbnailCache[index] = image
                self.refreshRails()
            }
        }
    }
}

extension DraftingTableViewController: UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
        picker.dismiss(animated: true)
        guard let image = info[.originalImage] as? UIImage else { return }
        insertImportedImage(image)
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
    }
}

extension DraftingTableViewController: DocumentGalleryDelegate {
    func documentGallery(_ gallery: DocumentGalleryViewController, didSelectDocumentAt url: URL, name: String) {
        do {
            let data = try Data(contentsOf: url)
            guard canvas.engineBridge.loadArchiveData(data) else {
                showDocumentError("Invalid Drafting Table document.")
                return
            }
            UserDefaults.standard.set(name, forKey: Self.docTitleDefaultsKey)
            documentDidChange(invalidateAllThumbnails: true)
            updateDocumentTitleLabel()
            showToast("Opened: \(name)")
        } catch {
            showDocumentError("Could not load document.")
        }
    }

    func documentGalleryDidCreateNewDocument(_ gallery: DocumentGalleryViewController, name: String, preset: String) {
        saveDocument()
        canvas.engineBridge.clearCanvas()
        UserDefaults.standard.set(name, forKey: Self.docTitleDefaultsKey)
        documentDidChange(invalidateAllThumbnails: true)
        updateDocumentTitleLabel()
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let url = dir.appendingPathComponent("\(name).drafttable")
        try? canvas.engineBridge.archiveData().write(to: url, options: .atomic)
        showToast("Created notebook: \(name)")
    }
}
