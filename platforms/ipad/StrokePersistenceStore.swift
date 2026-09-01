import Foundation

/// Small, recoverable document store for the development iPad shell.
///
/// Writes go to a sibling temporary file and are then atomically replaced so
/// an interrupted suspend or power loss cannot leave a partially written
/// archive behind. The store deliberately owns no engine state.
final class StrokePersistenceStore {
    private let fileURL: URL
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let base = fileManager.urls(for: .applicationSupportDirectory,
                                    in: .userDomainMask).first
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("DraftingTable", isDirectory: true)
        try? fileManager.createDirectory(at: directory,
                                         withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("document.archive", isDirectory: false)
    }

    func load() -> Data? {
        try? Data(contentsOf: fileURL)
    }

    func save(_ data: Data) throws {
        let temporaryURL = fileURL.appendingPathExtension("tmp")
        try data.write(to: temporaryURL, options: [.atomic])
        if fileManager.fileExists(atPath: fileURL.path) {
            _ = try fileManager.replaceItemAt(fileURL, withItemAt: temporaryURL,
                                              backupItemName: nil,
                                              options: [.usingNewMetadataOnly])
        } else {
            try fileManager.moveItem(at: temporaryURL, to: fileURL)
        }
    }

    func quarantineCorruptArchive() {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        let quarantine = fileURL.deletingPathExtension()
            .appendingPathExtension("corrupt-(Int(Date().timeIntervalSince1970)).archive")
        try? fileManager.moveItem(at: fileURL, to: quarantine)
    }
}
