import UIKit

final class DraftingTableViewController: UIViewController {
    private let canvas = CanvasView(frame: .zero)
    private let diagnostics = DiagnosticsOverlay(frame: .zero)

    override func loadView() {
        view = UIView()
        view.backgroundColor = .black
        canvas.translatesAutoresizingMaskIntoConstraints = false
        diagnostics.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(canvas)
        view.addSubview(diagnostics)

        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            canvas.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: view.topAnchor),
            canvas.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            diagnostics.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 14),
            diagnostics.topAnchor.constraint(equalTo: safe.topAnchor, constant: 14),
            diagnostics.widthAnchor.constraint(greaterThanOrEqualToConstant: 174)
        ])
        canvas.onDiagnostics = { [weak self] text in
            self?.diagnostics.update(text: text)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Drafting Table"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Clear",
            style: .plain,
            target: self,
            action: #selector(clearCanvas)
        )
    }

    @objc private func clearCanvas() {
        canvas.engineBridge.clearCanvas()
        canvas.setNeedsDisplay()
    }
}
