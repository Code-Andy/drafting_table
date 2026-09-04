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
    /// Package-backed coordinator.  It is the only owner of persistence; the
    /// legacy flat archive facade is intentionally not used by the v0.1 UI.
    private let documentCoordinator = PreviewDocumentCoordinator()
    private var isRestoringDocument = false

    // Top chrome & Sub-tool UI
    private var mainMenuButton: UIButton!
    private var topToolBar: UIView!
    private var chipUndoButton: UIButton!
    private var chipRedoButton: UIButton!
    private var topActiveColorButton: UIButton!
    private var quickPaletteButtons: [UIButton] = []
    private var topBrushSizeSlider: UISlider!
    private var topBrushSizeLabel: UILabel!
    private var topBrushOpacitySlider: UISlider!
    private var topBrushOpacityLabel: UILabel!
    private var paperSizeButton: UIButton!
    private var bucketSubToolBar: UIView!
    private var gapSegment: UISegmentedControl!
    private var bleedSegment: UISegmentedControl!
    private var brushSubToolBar: UIView!
    private var brushSizeSlider: UISlider!
    private var brushSizeLabel: UILabel!
    private var brushOpacitySlider: UISlider!
    private var brushOpacityLabel: UILabel!
    private var brushHardnessSlider: UISlider!
    private var brushHardnessLabel: UILabel!

    private var topToolBarLeadingConstraint: NSLayoutConstraint?
    private var bucketSubToolBarLeadingConstraint: NSLayoutConstraint?
    private var brushSubToolBarLeadingConstraint: NSLayoutConstraint?
    private var layersRailLeadingConstraint: NSLayoutConstraint?
    private var pagesToggleButton: UIButton!
    private var layersToggleButton: UIButton!

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
    private var slotButtons: [UIButton] = []
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
        configureTopToolBar()
        configureBucketSubToolBar()
        configureBrushSubToolBar()
        configureSelectionActionBar()
        DTLaunchBreadcrumb("vc:create:rails:done")
        view = root
        [canvas, hoverOverlay, diagnostics, emptyState, pagesRail, layersRail, toolRail, statusBar, topToolBar, bucketSubToolBar, brushSubToolBar, selectionActionBar, toastLabel].forEach {
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

            // Page sidebar (compact 72pt width)
            pagesRail.leadingAnchor.constraint(equalTo: toolRail.trailingAnchor, constant: 8),
            pagesRail.topAnchor.constraint(equalTo: safe.topAnchor, constant: 6),
            pagesRail.bottomAnchor.constraint(equalTo: statusBar.topAnchor, constant: -6),
            pagesRail.widthAnchor.constraint(equalToConstant: 72),

            // Layer sidebar (compact 120pt width, stacked on left)
            layersRail.topAnchor.constraint(equalTo: safe.topAnchor, constant: 6),
            layersRail.bottomAnchor.constraint(equalTo: statusBar.topAnchor, constant: -6),
            layersRail.widthAnchor.constraint(equalToConstant: 120),

            // Top Bar (horizontal controls across canvas top)
            topToolBar.topAnchor.constraint(equalTo: safe.topAnchor, constant: 6),
            topToolBar.heightAnchor.constraint(equalToConstant: 44),
            topToolBar.trailingAnchor.constraint(lessThanOrEqualTo: safe.trailingAnchor, constant: -10),

            // Bucket Sub-Tool Menu (gap error margin & bleed)
            bucketSubToolBar.topAnchor.constraint(equalTo: topToolBar.bottomAnchor, constant: 8),
            bucketSubToolBar.widthAnchor.constraint(equalToConstant: 248),

            // Brush Sub-Tool Menu (size, opacity, hardness)
            brushSubToolBar.topAnchor.constraint(equalTo: topToolBar.bottomAnchor, constant: 8),
            brushSubToolBar.widthAnchor.constraint(equalToConstant: 220),

            // Keep bottom controls above the home-indicator safe area.
            statusBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: safe.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 40),

            selectionActionBar.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            selectionActionBar.bottomAnchor.constraint(equalTo: statusBar.topAnchor, constant: -14),
            toastLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            toastLabel.bottomAnchor.constraint(equalTo: statusBar.topAnchor, constant: -14),
            toastLabel.leadingAnchor.constraint(greaterThanOrEqualTo: safe.leadingAnchor, constant: 18),
            toastLabel.trailingAnchor.constraint(lessThanOrEqualTo: safe.trailingAnchor, constant: -18),
            emptyState.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: root.centerYAnchor, constant: -12),
            emptyState.leadingAnchor.constraint(greaterThanOrEqualTo: safe.leadingAnchor, constant: 18),
            emptyState.trailingAnchor.constraint(lessThanOrEqualTo: safe.trailingAnchor, constant: -18),
            diagnostics.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -12),
            diagnostics.topAnchor.constraint(equalTo: safe.topAnchor, constant: 10),
            diagnostics.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),
            diagnostics.widthAnchor.constraint(lessThanOrEqualToConstant: 240)
        ])
        updateSubToolPosition(animated: false)
        canvas.onDiagnostics = { [weak self] text in
            guard let self, !self.diagnostics.isHidden else { return }
            self.diagnostics.update(text: text)
        }
        canvas.onDrawingBegan = { [weak self] in self?.emptyState.isHidden = true }
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
        documentCoordinator.onCommit = { [weak self] _ in
            // This callback is delivered only after the renderer's command
            // buffer has completed.  It is the UI refresh boundary for undo,
            // layer state and the empty-canvas hint.
            self?.documentDidChange()
        }
        documentCoordinator.onError = { [weak self] message in
            self?.showToast("Drafting Table: \(message)")
        }
        documentCoordinator.bind(engineBridge: canvas.engineBridge) { [weak canvas] in
            canvas?.paperSize ?? CGSize(width: 1536, height: 2048)
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
        NSLog("DraftingTable launch: viewDidLoad, deferring package restore")
        applyStoredSettings()
        refreshRails(); updateToolSelection(); updateUndoRedoState(); refreshMySlotsRail(); refreshColorSwatch(); refreshBrushSubToolBar()
        updateLaunchBreadcrumb(stage: "viewDidLoad")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            NSLog("DraftingTable launch: deferred package restore begin")
            self.restoreDocument()
            self.refreshRails(); self.updateToolSelection(); self.updateUndoRedoState(); self.refreshMySlotsRail()
            self.refreshColorSwatch(); self.refreshBrushSubToolBar()
            self.canvas.setNeedsDisplay()
            self.updateLaunchBreadcrumb(stage: "restoreScheduled")
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
        // Tile checkpoints are committed by PreviewDocumentCoordinator after
        // the renderer completion callback.  There is deliberately no
        // synchronous archive snapshot here; keeping this method as a no-op
        // preserves the scene delegate hook while removing the old DTAR path.
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
        emptyState.isHidden = canvas.engineBridge.strokeCount > 0
        refreshRails()
        updateUndoRedoState(); canvas.setNeedsDisplay()
    }

    private func restoreDocument() {
        guard !isRestoringDocument else { return }
        isRestoringDocument = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isRestoringDocument = false }
            do {
                let load = try await self.documentCoordinator.recoverDefaultPackage(
                    engineBridge: self.canvas.engineBridge,
                    pageSize: self.canvas.paperSize)
                self.canvas.paperSize = CGSize(width: load.width, height: load.height)
                self.pageThumbnailCache.removeAll(keepingCapacity: true)
                self.thumbnailEpoch &+= 1
                self.emptyState.isHidden = self.canvas.engineBridge.strokeCount > 0
                self.refreshRails()
                self.updateUndoRedoState()
                self.canvas.setNeedsDisplay()
                self.fitPaperIfNeeded()
                self.updateLaunchBreadcrumb(stage: "restoredPackage")
            } catch {
                self.showToast("Could not recover Drafting Table package")
                self.updateLaunchBreadcrumb(stage: "restoreFailed")
            }
        }
    }

    /// Fits the sheet once when no view transform has been stored.  Subsequent
    /// launches preserve the user's pan/zoom/rotation exactly.
    private func fitPaperIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "draftingTable.canvasScale") == nil,
              defaults.object(forKey: "draftingTable.canvasTranslationX") == nil,
              defaults.object(forKey: "draftingTable.canvasTranslationY") == nil else { return }
        canvas.resetView()
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
        selectedTool = storedTool == Int(DTTool.eraser.rawValue) ? .eraser : .brush
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
        settings.onBrushSizeChanged = { [weak self] value in
            self?.canvas.engineBridge.brushSize = value
            self?.refreshBrushSubToolBar()
            self?.saveDocument()
        }
        settings.onBrushOpacityChanged = { [weak self] value in
            self?.canvas.engineBridge.brushOpacity = value
            self?.refreshBrushSubToolBar()
            self?.saveDocument()
        }
        settings.onBrushHardnessChanged = { [weak self] value in
            self?.canvas.engineBridge.brushHardness = value
            self?.refreshBrushSubToolBar()
            self?.saveDocument()
        }
        settings.onBrushColorChanged = { [weak self] value in
            self?.canvas.engineBridge.brushColorRGBA = value
            self?.refreshColorSwatch()
            self?.saveDocument()
        }
        settings.onGridChanged = { [weak self] value in self?.canvas.gridVisible = value; self?.updateStatusBar(); self?.saveDocument() }
        settings.onDiagnosticsChanged = { [weak self] value in self?.diagnostics.isHidden = !value }
        settings.onShapeCenterModeChanged = { [weak self] value in self?.canvas.shapeCenterMode = value; self?.updateStatusBar() }
        settings.onTransparentExportChanged = { [weak self] _ in self?.showToast("Transparent PNG export updated") }
        settings.onEyedropperToast = { [weak self] in self?.showToast("Eyedropper needs the tile sampler (M2)") }
        let navigation = UINavigationController(rootViewController: settings); navigation.modalPresentationStyle = .formSheet
        if let sheet = navigation.sheetPresentationController { sheet.detents = [.medium(), .large()]; sheet.prefersGrabberVisible = true }
        present(navigation, animated: true)
    }

    /// Color tool: opens the HSV picker directly from the rail swatch as a popover.
    @objc private func openColorPickerDirect() { presentColorPicker(sourceView: colorSwatchButton) }

    private func presentColorPicker(sourceView: UIView? = nil) {
        let picker = ColorPickerViewController()
        picker.initialColorRGBA = canvas.engineBridge.brushColorRGBA
        picker.onColorChanged = { [weak self] packed in
            self?.applyBrushColor(packed)
            self?.refreshMySlotsRail()
        }
        picker.onColorPicked = { [weak self] packed in
            self?.applyBrushColor(packed)
            self?.refreshMySlotsRail()
        }
        picker.onDismiss = { [weak self] in
            self?.refreshMySlotsRail()
        }
        picker.onEyedropperRequested = { [weak self] in
            self?.dismiss(animated: true)
            self?.showToast("Eyedropper needs the tile sampler (M2)")
        }
        let navigation = UINavigationController(rootViewController: picker)
        navigation.modalPresentationStyle = .popover
        let anchor = sourceView ?? colorSwatchButton ?? view
        if let popover = navigation.popoverPresentationController {
            popover.sourceView = anchor
            popover.sourceRect = anchor?.bounds ?? .zero
            popover.permittedArrowDirections = [.left, .up, .down]
        }
        navigation.preferredContentSize = CGSize(width: 360, height: 580)
        picker.preferredContentSize = CGSize(width: 360, height: 580)
        present(navigation, animated: true)
    }

    private func applyBrushColor(_ packed: UInt32) {
        canvas.engineBridge.brushColorRGBA = packed
        UserDefaults.standard.set(Int(packed), forKey: DrawingSettingsViewController.brushColorKey)
        saveDocument()
        refreshColorSwatch()
        refreshMySlotsRail()
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

        // Highlight matching quick color swatch
        let quickColors: [UInt32] = [
            0x000000FF, 0x2B2926FF, 0x5A3825FF, 0x7A7368FF, 0xD0C8B8FF,
            0xFFFFFFFF, 0xB5482EFF, 0x2A5D8FFF, 0x3D5E26FF, 0xC8A030FF
        ]
        for (idx, btn) in quickPaletteButtons.enumerated() {
            let isSelected = (idx < quickColors.count && quickColors[idx] == packed)
            btn.layer.borderWidth = isSelected ? 2.5 : 1.0
            btn.layer.borderColor = isSelected ? DraftingTheme.ink.cgColor : UIColor(white: 0.2, alpha: 0.3).cgColor
            btn.transform = isSelected ? CGAffineTransform(scaleX: 1.15, y: 1.15) : .identity
        }
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
                                      message: "The v0.1 preview keeps document history transactional. Use Undo to remove the latest stroke.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "OK", style: .default))
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
        let open = UIAction(title: "Open .drafttable…", image: UIImage(systemName: "folder")) { [weak self] _ in self?.openDocument() }
        let documents = UIMenu(title: "Documents", options: .displayInline, children: [renameDoc, open, clearDoc])
        let menu = UIMenu(title: "Document", children: [settings, grid, documents])
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
        // Thumbnails depend on the removed retained-stroke snapshot path and
        // remain intentionally absent in the narrow v0.1 slice.
        pagesRail.thumbnailForPage = nil
        pagesRail.onSelect = { [weak self] index in
            guard let self else { return }
            guard index == 0 else { return }
            self.canvas.engineBridge.setActivePageIndex(UInt(index))
            self.refreshRails()
        }
        // v0.1 deliberately exposes one package-backed page.  Creation,
        // deletion, duplication, reordering and retained-page actions remain
        // unavailable until the multi-page renderer slice lands.
        pagesRail.onAdd = nil
        pagesRail.onRename = nil
        pagesRail.onDelete = nil
        pagesRail.onDuplicate = nil
        pagesRail.onMove = nil
        pagesRail.onDocsMenu = { [weak self] in self?.openDocument() }
    }

    private func configureLayersRail() {
        layersRail.onSelect = { [weak self] index in
            guard let self else { return }
            guard (0..<2).contains(index) else { return }
            _ = self.canvas.engineBridge.setActiveLayerIndex(UInt(index))
            self.refreshRails()
        }
        layersRail.onAdd = nil
        layersRail.onAddVector = nil
        layersRail.onRename = nil
        layersRail.onDelete = nil
        layersRail.onDuplicate = nil
        layersRail.onMove = nil
        layersRail.onVisibility = { [weak self] visible, index in
            guard let self else { return }
            guard (0..<2).contains(index) else { return }
            _ = self.canvas.engineBridge.setLayerVisible(visible, at: UInt(index))
        }
        layersRail.onOpacity = { [weak self] opacity, index in
            guard let self else { return }
            guard (0..<2).contains(index) else { return }
            _ = self.canvas.engineBridge.setLayerOpacity(opacity, at: UInt(index))
            self.canvas.setNeedsDisplay()
        }
        layersRail.onOpacityCommit = { [weak self] opacity, index in
            guard let self else { return }
            guard (0..<2).contains(index) else { return }
            _ = self.canvas.engineBridge.setLayerOpacity(opacity, at: UInt(index))
        }
    }

    private func refreshRails() {
        pagesRail.pageInfos = canvas.engineBridge.pageInfos
        layersRail.layerInfos = canvas.engineBridge.layerInfos
        updateRailToggleButtons()
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
        let count = canvas.engineBridge.layerInfos.count + 1
        _ = canvas.engineBridge.addLayer(withName: "Raster \(count)")
        documentDidChange()
    }

    private func addVectorLayer() {
        let count = canvas.engineBridge.layerInfos.count + 1
        _ = canvas.engineBridge.addLayer(withName: "Vector \(count)")
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

    private func configureTopToolBar() {
        topToolBar = UIView()
        topToolBar.backgroundColor = DraftingTheme.paperDeep.withAlphaComponent(0.96)
        topToolBar.layer.cornerRadius = 10
        topToolBar.layer.borderWidth = 1
        topToolBar.layer.borderColor = DraftingTheme.rule.cgColor
        topToolBar.layer.shadowColor = UIColor.black.cgColor
        topToolBar.layer.shadowOpacity = 0.10
        topToolBar.layer.shadowRadius = 6
        topToolBar.layer.shadowOffset = CGSize(width: 0, height: 2)
        topToolBar.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = false
        topToolBar.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: topToolBar.leadingAnchor, constant: 6),
            scrollView.trailingAnchor.constraint(equalTo: topToolBar.trailingAnchor, constant: -6),
            scrollView.topAnchor.constraint(equalTo: topToolBar.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: topToolBar.bottomAnchor)
        ])

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        ])

        // 1. Undo & Redo buttons
        let undoCfg = UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        chipUndoButton = UIButton(type: .system)
        chipUndoButton.setImage(UIImage(systemName: "arrow.uturn.backward", withConfiguration: undoCfg), for: .normal)
        chipUndoButton.tintColor = DraftingTheme.ink
        chipUndoButton.widthAnchor.constraint(equalToConstant: 32).isActive = true
        chipUndoButton.heightAnchor.constraint(equalToConstant: 32).isActive = true
        chipUndoButton.addTarget(self, action: #selector(undoCanvas), for: .touchUpInside)
        chipUndoButton.accessibilityLabel = "Undo"
        stack.addArrangedSubview(chipUndoButton)

        chipRedoButton = UIButton(type: .system)
        chipRedoButton.setImage(UIImage(systemName: "arrow.uturn.forward", withConfiguration: undoCfg), for: .normal)
        chipRedoButton.tintColor = DraftingTheme.ink
        chipRedoButton.widthAnchor.constraint(equalToConstant: 32).isActive = true
        chipRedoButton.heightAnchor.constraint(equalToConstant: 32).isActive = true
        chipRedoButton.addTarget(self, action: #selector(redoCanvas), for: .touchUpInside)
        chipRedoButton.accessibilityLabel = "Redo"
        stack.addArrangedSubview(chipRedoButton)

        stack.addArrangedSubview(createTopDivider())

        // 2. Active Color Swatch Button (Tap opens full HSV Color Picker)
        topActiveColorButton = UIButton(type: .custom)
        topActiveColorButton.translatesAutoresizingMaskIntoConstraints = false
        topActiveColorButton.widthAnchor.constraint(equalToConstant: 28).isActive = true
        topActiveColorButton.heightAnchor.constraint(equalToConstant: 28).isActive = true
        topActiveColorButton.layer.cornerRadius = 14
        topActiveColorButton.layer.borderWidth = 2.0
        topActiveColorButton.layer.borderColor = DraftingTheme.ink.cgColor
        topActiveColorButton.layer.shadowColor = UIColor.black.cgColor
        topActiveColorButton.layer.shadowOpacity = 0.18
        topActiveColorButton.layer.shadowRadius = 2
        topActiveColorButton.layer.shadowOffset = CGSize(width: 0, height: 1)
        topActiveColorButton.accessibilityLabel = "Active brush color. Tap to open color picker."
        topActiveColorButton.addTarget(self, action: #selector(openColorPickerDirect), for: .touchUpInside)
        colorSwatchButton = topActiveColorButton
        stack.addArrangedSubview(topActiveColorButton)

        // 3. Quick 1-Tap Color Swatches (10 core drafting colors)
        let quickColors: [(UInt32, String)] = [
            (0x000000FF, "Black"),
            (0x2B2926FF, "Ink"),
            (0x5A3825FF, "Dark Brown"),
            (0x7A7368FF, "Charcoal"),
            (0xD0C8B8FF, "Warm Gray"),
            (0xFFFFFFFF, "White"),
            (0xB5482EFF, "Drafting Red"),
            (0x2A5D8FFF, "Drafting Blue"),
            (0x3D5E26FF, "Drafting Green"),
            (0xC8A030FF, "Drafting Amber")
        ]
        quickPaletteButtons.removeAll()
        for (rgba, name) in quickColors {
            let btn = UIButton(type: .custom)
            btn.translatesAutoresizingMaskIntoConstraints = false
            btn.widthAnchor.constraint(equalToConstant: 22).isActive = true
            btn.heightAnchor.constraint(equalToConstant: 22).isActive = true
            btn.layer.cornerRadius = 11
            btn.backgroundColor = UIColor(
                red: CGFloat((rgba >> 24) & 0xff) / 255.0,
                green: CGFloat((rgba >> 16) & 0xff) / 255.0,
                blue: CGFloat((rgba >> 8) & 0xff) / 255.0,
                alpha: 1.0
            )
            btn.layer.borderWidth = 1.0
            btn.layer.borderColor = UIColor(white: 0.2, alpha: 0.3).cgColor
            btn.accessibilityLabel = "1-Tap Color: \(name)"
            btn.addAction(UIAction { [weak self] _ in
                self?.applyQuickColor(rgba)
            }, for: .touchUpInside)
            quickPaletteButtons.append(btn)
            stack.addArrangedSubview(btn)
        }

        stack.addArrangedSubview(createTopDivider(height: 16))

        // 4. My Slots (4 customizable quick slots)
        slotButtons.removeAll()
        for index in 0..<4 {
            let btn = UIButton(type: .custom)
            btn.translatesAutoresizingMaskIntoConstraints = false
            btn.widthAnchor.constraint(equalToConstant: 22).isActive = true
            btn.heightAnchor.constraint(equalToConstant: 22).isActive = true
            btn.layer.cornerRadius = 11
            btn.tag = index
            btn.addAction(UIAction { [weak self] _ in self?.selectSlot(at: index) }, for: .touchUpInside)
            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleSlotLongPress(_:)))
            longPress.minimumPressDuration = 0.35
            btn.addGestureRecognizer(longPress)
            slotButtons.append(btn)
            stack.addArrangedSubview(btn)
        }
        refreshMySlotsRail()

        // 5. Full Color Picker Button
        let paletteCfg = UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        let pickerBtn = UIButton(type: .system)
        pickerBtn.setImage(UIImage(systemName: "paintpalette", withConfiguration: paletteCfg), for: .normal)
        pickerBtn.tintColor = DraftingTheme.ink
        pickerBtn.widthAnchor.constraint(equalToConstant: 28).isActive = true
        pickerBtn.heightAnchor.constraint(equalToConstant: 28).isActive = true
        pickerBtn.accessibilityLabel = "Custom Color Picker"
        pickerBtn.addTarget(self, action: #selector(openColorPickerDirect), for: .touchUpInside)
        stack.addArrangedSubview(pickerBtn)

        stack.addArrangedSubview(createTopDivider())

        // 6. Brush Size Quick Slider & Label
        let currentSize = canvas.engineBridge.brushSize
        topBrushSizeLabel = UILabel()
        topBrushSizeLabel.text = String(format: "%.1f pt", currentSize)
        topBrushSizeLabel.font = .systemFont(ofSize: 10, weight: .bold)
        topBrushSizeLabel.textColor = DraftingTheme.ink
        topBrushSizeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        stack.addArrangedSubview(topBrushSizeLabel)

        topBrushSizeSlider = UISlider()
        topBrushSizeSlider.minimumValue = 1.0
        topBrushSizeSlider.maximumValue = 40.0
        topBrushSizeSlider.value = Float(currentSize)
        topBrushSizeSlider.tintColor = DraftingTheme.ink
        topBrushSizeSlider.widthAnchor.constraint(equalToConstant: 80).isActive = true
        topBrushSizeSlider.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            let val = CGFloat(self.topBrushSizeSlider.value)
            self.canvas.engineBridge.brushSize = val
            UserDefaults.standard.set(Float(val), forKey: DrawingSettingsViewController.brushSizeKey)
            self.topBrushSizeLabel.text = String(format: "%.1f pt", val)
            self.brushSizeSlider?.value = Float(val)
            self.brushSizeLabel?.text = String(format: "SIZE: %.1f pt", val)
            self.saveDocument()
        }, for: .valueChanged)
        stack.addArrangedSubview(topBrushSizeSlider)

        // 7. Brush Opacity Quick Slider & Label
        let currentOpacity = canvas.engineBridge.brushOpacity
        topBrushOpacityLabel = UILabel()
        topBrushOpacityLabel.text = String(format: "%d%%", Int(currentOpacity * 100))
        topBrushOpacityLabel.font = .systemFont(ofSize: 10, weight: .bold)
        topBrushOpacityLabel.textColor = DraftingTheme.ink
        topBrushOpacityLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 34).isActive = true
        stack.addArrangedSubview(topBrushOpacityLabel)

        topBrushOpacitySlider = UISlider()
        topBrushOpacitySlider.minimumValue = 0.05
        topBrushOpacitySlider.maximumValue = 1.0
        topBrushOpacitySlider.value = Float(currentOpacity)
        topBrushOpacitySlider.tintColor = DraftingTheme.ink
        topBrushOpacitySlider.widthAnchor.constraint(equalToConstant: 65).isActive = true
        topBrushOpacitySlider.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            let val = CGFloat(self.topBrushOpacitySlider.value)
            self.canvas.engineBridge.brushOpacity = val
            UserDefaults.standard.set(Float(val * 100), forKey: DrawingSettingsViewController.brushOpacityKey)
            self.topBrushOpacityLabel.text = String(format: "%d%%", Int(val * 100))
            self.brushOpacitySlider?.value = Float(val)
            self.brushOpacityLabel?.text = String(format: "OPACITY: %d%%", Int(val * 100))
            self.saveDocument()
        }, for: .valueChanged)
        stack.addArrangedSubview(topBrushOpacitySlider)

        stack.addArrangedSubview(createTopDivider())

        // 8. Paper size is fixed by the package page in v0.1.  The old menu
        // changed only the immediate renderer and could desynchronise saved
        // metadata, so it is intentionally not exposed.
        paperSizeButton = UIButton(type: .system)
        var paperBtnConfig = UIButton.Configuration.plain()
        paperBtnConfig.image = UIImage(systemName: "doc.plaintext", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .medium))
        paperBtnConfig.title = "Paper"
        paperBtnConfig.imagePadding = 4
        paperBtnConfig.baseForegroundColor = DraftingTheme.ink
        paperSizeButton.configuration = paperBtnConfig
        paperSizeButton.showsMenuAsPrimaryAction = true
        paperSizeButton.menu = createPaperSizeMenu()
        paperSizeButton.isHidden = true

        // 9. Reset View Button
        let resetBtn = UIButton(type: .system)
        let resetCfg = UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        resetBtn.setImage(UIImage(systemName: "arrow.counterclockwise", withConfiguration: resetCfg), for: .normal)
        resetBtn.tintColor = DraftingTheme.ink
        resetBtn.widthAnchor.constraint(equalToConstant: 30).isActive = true
        resetBtn.heightAnchor.constraint(equalToConstant: 30).isActive = true
        resetBtn.accessibilityLabel = "Reset View & Center Paper"
        resetBtn.addTarget(self, action: #selector(resetCanvasView), for: .touchUpInside)
        stack.addArrangedSubview(resetBtn)
    }

    private func createTopDivider(height: CGFloat = 20) -> UIView {
        let div = UIView()
        div.backgroundColor = DraftingTheme.rule
        div.translatesAutoresizingMaskIntoConstraints = false
        div.widthAnchor.constraint(equalToConstant: 1).isActive = true
        div.heightAnchor.constraint(equalToConstant: height).isActive = true
        return div
    }

    private func createPaperSizeMenu() -> UIMenu {
        let sizes: [(String, CGSize)] = [
            ("iPad Native (1536 × 2048)", CGSize(width: 1536, height: 2048)),
            ("US Letter (1700 × 2200)", CGSize(width: 1700, height: 2200)),
            ("A4 Drafting (1754 × 2480)", CGSize(width: 1754, height: 2480)),
            ("Square (2048 × 2048)", CGSize(width: 2048, height: 2048)),
            ("Wide 16:9 (2560 × 1440)", CGSize(width: 2560, height: 1440))
        ]
        let current = canvas.paperSize
        let actions = sizes.map { name, size in
            let isCurrent = (abs(current.width - size.width) < 1.0 && abs(current.height - size.height) < 1.0)
            return UIAction(title: name, state: isCurrent ? .on : .off) { [weak self] _ in
                guard let self else { return }
                self.canvas.paperSize = size
                self.canvas.resetView()
                self.showToast("Paper: \(name)")
                self.paperSizeButton?.menu = self.createPaperSizeMenu()
                HapticFeedbackService.shared.toolSwitched()
            }
        }
        return UIMenu(title: "Paper Size", children: actions)
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

    private func configureBrushSubToolBar() {
        brushSubToolBar = UIView()
        brushSubToolBar.backgroundColor = DraftingTheme.paperDeep.withAlphaComponent(0.96)
        brushSubToolBar.layer.cornerRadius = 9
        brushSubToolBar.layer.borderWidth = 1
        brushSubToolBar.layer.borderColor = DraftingTheme.rule.cgColor
        brushSubToolBar.layer.shadowColor = UIColor.black.cgColor
        brushSubToolBar.layer.shadowOpacity = 0.10
        brushSubToolBar.layer.shadowRadius = 6
        brushSubToolBar.layer.shadowOffset = CGSize(width: 0, height: 2)
        brushSubToolBar.translatesAutoresizingMaskIntoConstraints = false
        brushSubToolBar.isHidden = true

        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        brushSubToolBar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: brushSubToolBar.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: brushSubToolBar.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: brushSubToolBar.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: brushSubToolBar.bottomAnchor, constant: -8)
        ])

        let titleLbl = UILabel()
        titleLbl.text = "BRUSH OPTIONS"
        titleLbl.font = .systemFont(ofSize: 10, weight: .bold)
        titleLbl.textColor = DraftingTheme.inkSoft
        titleLbl.textAlignment = .center
        stack.addArrangedSubview(titleLbl)

        let currentSize = canvas.engineBridge.brushSize
        brushSizeLabel = UILabel()
        brushSizeLabel.text = String(format: "SIZE: %.1f pt", currentSize)
        brushSizeLabel.font = .systemFont(ofSize: 9, weight: .semibold)
        brushSizeLabel.textColor = DraftingTheme.inkSoft
        stack.addArrangedSubview(brushSizeLabel)

        brushSizeSlider = UISlider()
        brushSizeSlider.minimumValue = 1.0
        brushSizeSlider.maximumValue = 40.0
        brushSizeSlider.value = Float(currentSize)
        brushSizeSlider.tintColor = DraftingTheme.ink
        brushSizeSlider.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            let val = CGFloat(self.brushSizeSlider.value)
            self.canvas.engineBridge.brushSize = val
            UserDefaults.standard.set(Float(val), forKey: DrawingSettingsViewController.brushSizeKey)
            self.brushSizeLabel.text = String(format: "SIZE: %.1f pt", val)
            self.saveDocument()
        }, for: .valueChanged)
        stack.addArrangedSubview(brushSizeSlider)

        let currentOpacity = canvas.engineBridge.brushOpacity
        brushOpacityLabel = UILabel()
        brushOpacityLabel.text = String(format: "OPACITY: %d%%", Int(currentOpacity * 100))
        brushOpacityLabel.font = .systemFont(ofSize: 9, weight: .semibold)
        brushOpacityLabel.textColor = DraftingTheme.inkSoft
        stack.addArrangedSubview(brushOpacityLabel)

        brushOpacitySlider = UISlider()
        brushOpacitySlider.minimumValue = 0.05
        brushOpacitySlider.maximumValue = 1.0
        brushOpacitySlider.value = Float(currentOpacity)
        brushOpacitySlider.tintColor = DraftingTheme.ink
        brushOpacitySlider.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            let val = CGFloat(self.brushOpacitySlider.value)
            self.canvas.engineBridge.brushOpacity = val
            UserDefaults.standard.set(Float(val * 100), forKey: DrawingSettingsViewController.brushOpacityKey)
            self.brushOpacityLabel.text = String(format: "OPACITY: %d%%", Int(val * 100))
            self.saveDocument()
        }, for: .valueChanged)
        stack.addArrangedSubview(brushOpacitySlider)

        let currentHardness = canvas.engineBridge.brushHardness
        brushHardnessLabel = UILabel()
        brushHardnessLabel.text = String(format: "HARDNESS: %d%%", Int(currentHardness * 100))
        brushHardnessLabel.font = .systemFont(ofSize: 9, weight: .semibold)
        brushHardnessLabel.textColor = DraftingTheme.inkSoft
        stack.addArrangedSubview(brushHardnessLabel)

        brushHardnessSlider = UISlider()
        brushHardnessSlider.minimumValue = 0.0
        brushHardnessSlider.maximumValue = 1.0
        brushHardnessSlider.value = Float(currentHardness)
        brushHardnessSlider.tintColor = DraftingTheme.ink
        brushHardnessSlider.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            let val = CGFloat(self.brushHardnessSlider.value)
            self.canvas.engineBridge.brushHardness = val
            UserDefaults.standard.set(Float(val * 100), forKey: DrawingSettingsViewController.brushHardnessKey)
            self.brushHardnessLabel.text = String(format: "HARDNESS: %d%%", Int(val * 100))
            self.saveDocument()
        }, for: .valueChanged)
        stack.addArrangedSubview(brushHardnessSlider)
    }

    private func updateSubToolPosition(animated: Bool = true) {
        layersRailLeadingConstraint?.isActive = false
        let layerAnchor = pagesRail.isHidden ? toolRail.trailingAnchor : pagesRail.trailingAnchor
        layersRailLeadingConstraint = layersRail.leadingAnchor.constraint(equalTo: layerAnchor, constant: 6)
        layersRailLeadingConstraint?.isActive = true

        let canvasLeftAnchor: NSLayoutXAxisAnchor
        if !layersRail.isHidden {
            canvasLeftAnchor = layersRail.trailingAnchor
        } else if !pagesRail.isHidden {
            canvasLeftAnchor = pagesRail.trailingAnchor
        } else {
            canvasLeftAnchor = toolRail.trailingAnchor
        }

        topToolBarLeadingConstraint?.isActive = false
        bucketSubToolBarLeadingConstraint?.isActive = false
        brushSubToolBarLeadingConstraint?.isActive = false

        topToolBarLeadingConstraint = topToolBar.leadingAnchor.constraint(equalTo: canvasLeftAnchor, constant: 10)
        topToolBarLeadingConstraint?.isActive = true

        bucketSubToolBarLeadingConstraint = bucketSubToolBar.leadingAnchor.constraint(equalTo: canvasLeftAnchor, constant: 12)
        bucketSubToolBarLeadingConstraint?.isActive = true

        brushSubToolBarLeadingConstraint = brushSubToolBar.leadingAnchor.constraint(equalTo: canvasLeftAnchor, constant: 12)
        brushSubToolBarLeadingConstraint?.isActive = true

        if animated {
            UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
                self.view.layoutIfNeeded()
            }
        } else {
            self.view.layoutIfNeeded()
        }
    }

    private func applyQuickColor(_ rgba: UInt32) {
        canvas.engineBridge.brushColorRGBA = rgba
        UserDefaults.standard.set(Int(rgba), forKey: DrawingSettingsViewController.brushColorKey)
        saveDocument()
        refreshColorSwatch()
        HapticFeedbackService.shared.toolSwitched()
    }

    @objc private func showMainMenu(_ sender: UIButton) {
        if let existing = view.subviews.first(where: { $0 is AppMenuWindowView }) as? AppMenuWindowView {
            existing.dismiss(animated: true)
            return
        }

        let menuWindow = AppMenuWindowView()
        menuWindow.onAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case .notebooksGallery:
                self.showToast("Notebook gallery is deferred in the v0.1 preview")
            case .renameDocument:
                self.promptRenameDocument()
            case .exportPNG:
                self.showToast("PNG export is deferred until tile readback is exposed")
            case .exportPDF:
                self.showToast("PDF export is deferred until tile readback is exposed")
            case .saveArchive:
                self.showToast("Use Files to share the .drafttable package")
            case .importPhoto:
                self.showToast("Image import is deferred in the v0.1 preview")
            case .settings:
                self.openSettings()
            case .resetView:
                self.resetCanvasView()
            case .clearDocument:
                self.showToast("Clear is unavailable in v0.1; use Undo")
            }
        }

        let safeTop = view.safeAreaInsets.top
        let anchorX = pagesRail.isHidden ? (toolRail.frame.maxX + 10) : (pagesRail.frame.maxX + 10)
        let anchorY = max(safeTop, 16.0) + 6.0
        menuWindow.present(in: view, near: CGPoint(x: anchorX, y: anchorY))
    }

    private func showExportMenu(sourceView: UIView? = nil) {
        _ = sourceView
        showToast("Export is deferred until tile readback is exposed")
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

        brushButton = railToolButton(systemName: "pencil.tip", label: "Brush", action: #selector(selectBrush))
        eraserButton = railToolButton(systemName: "eraser", label: "Eraser", action: #selector(selectEraser))

        pagesToggleButton = railToolButton(systemName: "doc.on.doc", label: "Pages", action: #selector(togglePagesRail))
        layersToggleButton = railToolButton(systemName: "square.3.layers.3d", label: "Layers", action: #selector(toggleLayersRail))
        let resetViewBtn = railToolButton(systemName: "arrow.down.right.and.arrow.up.left", label: "Reset", action: #selector(resetCanvasView))
        clearButton = railToolButton(systemName: "trash", label: "Clear", action: #selector(confirmClearDocument))

        stack.addArrangedSubview(railTitle("DRAW"))
        [brushButton, eraserButton].forEach(stack.addArrangedSubview)
        stack.addArrangedSubview(railRule())
        stack.addArrangedSubview(railTitle("PANELS"))
        [pagesToggleButton, layersToggleButton].forEach(stack.addArrangedSubview)
        stack.addArrangedSubview(railRule())
        stack.addArrangedSubview(resetViewBtn)

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
        updateRailToggleButtons()
    }

    private func loadSlots() -> [Int] {
        (UserDefaults.standard.array(forKey: ColorPickerViewController.slotsKey) as? [Int]) ?? []
    }

    private func refreshMySlotsRail() {
        let slots = loadSlots()
        for (index, btn) in slotButtons.enumerated() {
            let stored = index < slots.count ? slots[index] : -1
            if stored >= 0 {
                let color = ColorPickerViewController.uiColor(rgb: UInt32(stored))
                btn.backgroundColor = color
                btn.setTitle(nil, for: .normal)
                btn.layer.borderWidth = 1.0
                btn.layer.borderColor = UIColor(red: 0.35, green: 0.30, blue: 0.22, alpha: 0.45).cgColor
                btn.accessibilityLabel = "My slot \(index + 1): configured"
            } else {
                btn.backgroundColor = DraftingTheme.paper.withAlphaComponent(0.6)
                btn.setTitle("+", for: .normal)
                btn.setTitleColor(DraftingTheme.inkSoft.withAlphaComponent(0.6), for: .normal)
                btn.titleLabel?.font = .systemFont(ofSize: 10, weight: .bold)
                btn.layer.borderWidth = 1.0
                btn.layer.borderColor = DraftingTheme.rule.cgColor
                btn.accessibilityLabel = "My slot \(index + 1): empty"
            }
        }
    }

    private func selectSlot(at index: Int) {
        let slots = loadSlots()
        if index < slots.count && slots[index] >= 0 {
            let rgb = UInt32(slots[index])
            let packed = (rgb << 8) | 0xFF
            applyBrushColor(packed)
            showToast("Selected Slot \(index + 1)")
            HapticFeedbackService.shared.toolSwitched()
        } else {
            saveSlot(at: index)
        }
    }

    @objc private func handleSlotLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, let btn = gesture.view as? UIButton else { return }
        saveSlot(at: btn.tag)
    }

    private func saveSlot(at index: Int) {
        guard index >= 0 && index < 4 else { return }
        var slots = loadSlots()
        while slots.count < 4 { slots.append(-1) }
        let currentPacked = canvas.engineBridge.brushColorRGBA
        let rgb = Int((currentPacked >> 8) & 0xFFFFFF)
        slots[index] = rgb
        UserDefaults.standard.set(slots, forKey: ColorPickerViewController.slotsKey)
        refreshMySlotsRail()
        HapticFeedbackService.shared.success()
        showToast("Saved active color to Slot \(index + 1)")
    }

    @objc private func togglePagesRail() {
        pagesRail.isHidden.toggle()
        updateRailToggleButtons()
        updateSubToolPosition()
    }

    @objc private func toggleLayersRail() {
        layersRail.isHidden.toggle()
        updateRailToggleButtons()
        updateSubToolPosition()
    }

    private func updateRailToggleButtons() {
        let selectedColor = UIColor.systemBlue.withAlphaComponent(0.16)
        let normalColor = UIColor.white.withAlphaComponent(0.82)
        if let pagesToggleButton, let pagesRail {
            let active = !pagesRail.isHidden
            pagesToggleButton.isSelected = active
            pagesToggleButton.backgroundColor = active ? selectedColor : normalColor
            pagesToggleButton.layer.borderColor = (active ? UIColor.systemBlue : DraftingTheme.rule.withAlphaComponent(0.6)).cgColor
        }
        if let layersToggleButton, let layersRail {
            let active = !layersRail.isHidden
            layersToggleButton.isSelected = active
            layersToggleButton.backgroundColor = active ? selectedColor : normalColor
            layersToggleButton.layer.borderColor = (active ? UIColor.systemBlue : DraftingTheme.rule.withAlphaComponent(0.6)).cgColor
        }
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
                if tool == .brush || tool == .eraser {
                    self.selectTool(tool)
                } else {
                    self.showToast("That tool is deferred in the v0.1 preview")
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
        brushSubToolBar?.isHidden = (selectedTool != .brush)
        if selectedTool == .brush {
            refreshBrushSubToolBar()
        }
        refreshColorSwatch()
        updateStatusBar()
    }

    private func refreshBrushSubToolBar() {
        let size = canvas.engineBridge.brushSize
        let opacity = canvas.engineBridge.brushOpacity
        let hardness = canvas.engineBridge.brushHardness

        if let brushSizeSlider, let brushSizeLabel {
            brushSizeSlider.value = Float(size)
            brushSizeLabel.text = String(format: "SIZE: %.1f pt", size)
        }
        if let brushOpacitySlider, let brushOpacityLabel {
            brushOpacitySlider.value = Float(opacity)
            brushOpacityLabel.text = String(format: "OPACITY: %d%%", Int(opacity * 100))
        }
        if let brushHardnessSlider, let brushHardnessLabel {
            brushHardnessSlider.value = Float(hardness)
            brushHardnessLabel.text = String(format: "HARDNESS: %d%%", Int(hardness * 100))
        }

        if let topBrushSizeSlider, let topBrushSizeLabel {
            topBrushSizeSlider.value = Float(size)
            topBrushSizeLabel.text = String(format: "%.1f pt", size)
        }
        if let topBrushOpacitySlider, let topBrushOpacityLabel {
            topBrushOpacitySlider.value = Float(opacity)
            topBrushOpacityLabel.text = String(format: "%d%%", Int(opacity * 100))
        }
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
        let accepted: DTTool = tool == .eraser ? .eraser : .brush
        selectedTool = accepted
        canvas.currentTool = accepted
        UserDefaults.standard.set(Int(accepted.rawValue), forKey: Self.selectedToolDefaultsKey)
        HapticFeedbackService.shared.toolSwitched()
        updateToolSelection()
    }

    @objc private func undoCanvas() {
        guard canvas.engineBridge.canUndo else { return }
        guard canvas.engineBridge.undoLastStroke() else {
            showToast("Undo is waiting for the renderer")
            return
        }
        // UI refresh and persistence follow documentCommitHandler after the
        // restore command buffer completes; do not publish a stale snapshot.
        canvas.setNeedsDisplay()
    }

    @objc private func redoCanvas() {
        guard canvas.engineBridge.canRedo else { return }
        guard canvas.engineBridge.redoLastStroke() else {
            showToast("Redo is waiting for the renderer")
            return
        }
        canvas.setNeedsDisplay()
    }

    @objc private func clearCanvas() {
        showToast("Clear is unavailable in the v0.1 preview; use Undo")
    }
    @objc private func openSettings() { showSettings() }
    @objc private func resetCanvasView() { canvas.resetView() }

    private func exportCurrentPagePNG() {
        showToast("PNG export is deferred until tile readback is exposed")
    }

    @objc private func promptImportPhoto() {
        showToast("Image import is deferred in the v0.1 preview")
    }

    private func insertImportedImage(_ image: UIImage) {
        _ = image
        showToast("Image import is deferred in the v0.1 preview")
    }

    @objc private func openGallery() {
        openDocument()
    }

    private func openDocument() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.draftingTableDocument], asCopy: false)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        presentPickerSafely(picker)
    }

    private func saveDocumentCopy() {
        showToast("Use Files to share the current .drafttable package")
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
        pendingDocumentExportURL = nil
        guard let url = urls.first else { return }
        openPackage(at: url)
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

    /// Opens a package through a temporary coordinator and swaps the engine
    /// only after the candidate manifest, tile checksums and Metal upload all
    /// succeed.  The coordinator retains the security-scoped URL for the
    /// lifetime of the active package.
    func openPackage(at url: URL) {
        guard isViewLoaded else { return }
        guard !isRestoringDocument else {
            showToast("Document is still loading")
            return
        }
        isRestoringDocument = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isRestoringDocument = false }
            do {
                let load = try await self.documentCoordinator.switchToPackage(
                    at: url,
                    engineBridge: self.canvas.engineBridge,
                    pageSize: self.canvas.paperSize)
                self.canvas.paperSize = CGSize(width: load.width, height: load.height)
                self.pageThumbnailCache.removeAll(keepingCapacity: true)
                self.thumbnailEpoch &+= 1
                self.emptyState.isHidden = self.canvas.engineBridge.strokeCount > 0
                self.refreshRails()
                self.updateUndoRedoState()
                self.canvas.setNeedsDisplay()
                self.fitPaperIfNeeded()
                UserDefaults.standard.set(url.deletingPathExtension().lastPathComponent,
                                          forKey: Self.docTitleDefaultsKey)
                self.updateDocumentTitleLabel()
                self.showToast("Opened \(url.deletingPathExtension().lastPathComponent)")
            } catch {
                self.showDocumentError("Drafting Table could not open that package.")
            }
        }
    }

    private func exportAllPagesPDF() {
        showToast("PDF export is deferred until tile readback is exposed")
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
        // Page thumbnails are intentionally disabled with one fixed page and
        // no retained-stroke snapshot fallback.
        _ = index
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
        _ = gallery
        _ = name
        openPackage(at: url)
    }

    func documentGalleryDidCreateNewDocument(_ gallery: DocumentGalleryViewController, name: String, preset: String) {
        _ = gallery
        _ = name
        _ = preset
        showToast("Creating additional notebooks is deferred in the v0.1 preview")
    }
}
