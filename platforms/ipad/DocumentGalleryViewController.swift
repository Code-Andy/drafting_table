import UIKit

protocol DocumentGalleryDelegate: AnyObject {
    func documentGallery(_ gallery: DocumentGalleryViewController, didSelectDocumentAt url: URL, name: String)
    func documentGalleryDidCreateNewDocument(_ gallery: DocumentGalleryViewController, name: String, preset: String)
}

final class DocumentGalleryViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    weak var delegate: DocumentGalleryDelegate?

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private var documentURLs: [URL] = []
    private var currentDocumentName: String = "DraftingTable"

    init(currentDocumentName: String = "DraftingTable") {
        self.currentDocumentName = currentDocumentName
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Notebooks"
        view.backgroundColor = UIColor(red: 0.961, green: 0.941, blue: 0.902, alpha: 1.0)

        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Close", style: .plain, target: self, action: #selector(closeGallery))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "＋ New", style: .done, target: self, action: #selector(promptNewDocument))

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = .clear
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "NotebookCell")
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        reloadDocuments()
    }

    private func documentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    func reloadDocuments() {
        let dir = documentsDirectory()
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
        documentURLs = urls.filter { $0.pathExtension.lowercased() == "drafttable" }
            .sorted { (u1, u2) -> Bool in
                let d1 = (try? u1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                let d2 = (try? u2.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                return d1 > d2
            }
        tableView.reloadData()
    }

    @objc private func closeGallery() {
        dismiss(animated: true)
    }

    @objc private func promptNewDocument() {
        let alert = UIAlertController(title: "New Notebook", message: "Choose a page preset:", preferredStyle: .actionSheet)
        alert.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem

        let presets = [
            ("Infinite Canvas (Default)", "infinite"),
            ("A4 (210 × 297 mm)", "a4"),
            ("US Letter (8.5 × 11 in)", "letter"),
            ("16:9 Screen (1920 × 1080)", "16:9")
        ]

        for (label, presetId) in presets {
            alert.addAction(UIAlertAction(title: label, style: .default) { [weak self] _ in
                self?.promptNotebookName(preset: presetId)
            })
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    private func promptNotebookName(preset: String) {
        let alert = UIAlertController(title: "Notebook Name", message: "Enter a title for this notebook:", preferredStyle: .alert)
        alert.addTextField { tf in
            tf.text = "Notebook \(self.documentURLs.count + 1)"
            tf.placeholder = "Notebook title"
            tf.autocapitalizationType = .words
            tf.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Create", style: .default) { [weak self, weak alert] _ in
            guard let self, let name = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return }
            self.delegate?.documentGalleryDidCreateNewDocument(self, name: name, preset: preset)
            self.dismiss(animated: true)
        })
        present(alert, animated: true)
    }

    // MARK: - UITableViewDataSource & Delegate

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        documentURLs.isEmpty ? 1 : documentURLs.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: "NotebookCell")
        cell.backgroundColor = UIColor(red: 0.929, green: 0.898, blue: 0.824, alpha: 0.8)
        cell.textLabel?.textColor = UIColor(red: 0.165, green: 0.149, blue: 0.125, alpha: 1.0)
        cell.textLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        cell.detailTextLabel?.textColor = UIColor(red: 0.420, green: 0.388, blue: 0.341, alpha: 1.0)
        cell.detailTextLabel?.font = .systemFont(ofSize: 12)

        if documentURLs.isEmpty {
            cell.textLabel?.text = currentDocumentName
            cell.detailTextLabel?.text = "Active Notebook · In Memory"
            cell.imageView?.image = UIImage(systemName: "doc.text.fill")
            cell.imageView?.tintColor = UIColor(red: 0.710, green: 0.282, blue: 0.180, alpha: 1.0)
            cell.accessoryType = .checkmark
            return cell
        }

        let url = documentURLs[indexPath.row]
        let name = url.deletingPathExtension().lastPathComponent
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let date = values?.contentModificationDate ?? Date()
        let size = values?.fileSize ?? 0
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        cell.textLabel?.text = name
        cell.detailTextLabel?.text = "Modified: \(formatter.string(from: date)) · \(size / 1024) KB"
        cell.imageView?.image = UIImage(systemName: "book.closed")
        cell.imageView?.tintColor = UIColor(red: 0.420, green: 0.388, blue: 0.341, alpha: 1.0)

        if name == currentDocumentName {
            cell.accessoryType = .checkmark
            cell.imageView?.tintColor = UIColor(red: 0.710, green: 0.282, blue: 0.180, alpha: 1.0)
        } else {
            cell.accessoryType = .disclosureIndicator
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !documentURLs.isEmpty else {
            dismiss(animated: true)
            return
        }
        let url = documentURLs[indexPath.row]
        let name = url.deletingPathExtension().lastPathComponent
        delegate?.documentGallery(self, didSelectDocumentAt: url, name: name)
        dismiss(animated: true)
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard !documentURLs.isEmpty else { return nil }
        let url = documentURLs[indexPath.row]
        let name = url.deletingPathExtension().lastPathComponent

        let delete = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, completion in
            try? FileManager.default.removeItem(at: url)
            self?.reloadDocuments()
            completion(true)
        }
        delete.image = UIImage(systemName: "trash")

        let duplicate = UIContextualAction(style: .normal, title: "Duplicate") { [weak self] _, _, completion in
            guard let self else { return }
            let copyURL = self.documentsDirectory().appendingPathComponent("\(name) Copy.drafttable")
            try? FileManager.default.copyItem(at: url, to: copyURL)
            self.reloadDocuments()
            completion(true)
        }
        duplicate.backgroundColor = UIColor.systemBlue
        duplicate.image = UIImage(systemName: "plus.square.on.square")

        return UISwipeActionsConfiguration(actions: [delete, duplicate])
    }
}
