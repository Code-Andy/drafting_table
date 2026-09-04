import UniformTypeIdentifiers

extension UTType {
    static let draftingTableDocument = UTType(exportedAs: "com.local.draftingtable.document",
                                               conformingTo: .data)
}

/// Package-backed document façade for the document coordinator.
///
/// This type intentionally does not subclass UIDocument yet. UIDocument's
/// synchronous contents hook would either block the main actor or create a
/// second flat-DTAR persistence path. Package commits must go through the
/// async `DTPackageStore` actor, which coordinates versioned tiles, a manifest,
/// and CURRENT.
final class DraftingTableDocument {
    let packageStore: DTPackageStore
    let fileURL: URL
    private(set) var latestSnapshot: DTPackageSnapshot?

    init(fileURL url: URL) {
        fileURL = url
        packageStore = DTPackageStore(packageURL: url)
    }

    convenience init() {
        self.init(fileURL: DTPackageStore.defaultPackageURL())
    }

    @discardableResult
    func loadPackage() async throws -> DTPackageSnapshot? {
        let snapshot = try await packageStore.load()
        latestSnapshot = snapshot
        return snapshot
    }

    @discardableResult
    func commit(_ transaction: DTPackageCommit) async throws -> DTPackageSnapshot {
        let snapshot = try await packageStore.commit(transaction)
        latestSnapshot = snapshot
        return snapshot
    }

    @discardableResult
    func commit(document: DTPackageDocumentDescriptor,
                documentGeneration: UInt64 = 1,
                tiles: [DTTilePayload] = [],
                removedTiles: Set<DTTileAddress> = [],
                expectedManifestGeneration: UInt64? = nil) async throws -> DTPackageSnapshot {
        let snapshot = try await packageStore.commit(document: document,
                                                      documentGeneration: documentGeneration,
                                                      tiles: tiles,
                                                      removedTiles: removedTiles,
                                                      expectedManifestGeneration: expectedManifestGeneration)
        latestSnapshot = snapshot
        return snapshot
    }

    /// Explicit one-way importer for old flat DTAR bytes. The caller owns
    /// validation/translation into a package transaction; no package state is
    /// changed by this helper.
    static func importLegacyDTAR(from contents: Any) throws -> Data {
        if let data = contents as? Data {
            guard !data.isEmpty else { throw DTPackageStoreError.invalidManifest }
            return data
        }
        if let wrapper = contents as? FileWrapper,
           wrapper.isRegularFile,
           let data = wrapper.regularFileContents,
           !data.isEmpty {
            return data
        }
        throw DTPackageStoreError.legacyDTARReadRequiresExplicitImporter
    }

    static func importLegacyDTAR(from url: URL,
                                 fileManager: FileManager = .default) throws -> Data {
        try DTPackageStore.loadLegacyDTAR(from: url, fileManager: fileManager)
    }
}
