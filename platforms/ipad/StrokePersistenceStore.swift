import Foundation

/// App-facing façade for the package actor.
///
/// The old controller used synchronous `save(Data)`/`load()` calls for a flat
/// DTAR archive. Those entry points remain only as a source-compatible guard:
/// they deliberately do not read or write a live DTAR fallback. New code must
/// submit a value-type `DTPackageCommit` to `packageStore`.
final class StrokePersistenceStore {
    let packageStore: DTPackageStore

    init(packageURL: URL? = nil, fileManager: FileManager = .default) {
        packageStore = DTPackageStore(packageURL: packageURL, fileManager: fileManager)
    }

    /// Loads the newest complete package manifest. This is the integration API
    /// for the document coordinator and is intentionally asynchronous because
    /// it may coordinate Files/iCloud access and validate tile checksums.
    func loadPackage() async throws -> DTPackageSnapshot? {
        try await packageStore.load()
    }

    /// Commits immutable tile generations and metadata using the actor's
    /// tile -> manifest -> CURRENT protocol.
    @discardableResult
    func commit(_ transaction: DTPackageCommit) async throws -> DTPackageSnapshot {
        try await packageStore.commit(transaction)
    }

    @discardableResult
    func commit(document: DTPackageDocumentDescriptor,
                documentGeneration: UInt64 = 1,
                tiles: [DTTilePayload] = [],
                removedTiles: Set<DTTileAddress> = [],
                expectedManifestGeneration: UInt64? = nil) async throws -> DTPackageSnapshot {
        try await packageStore.commit(document: document,
                                       documentGeneration: documentGeneration,
                                       tiles: tiles,
                                       removedTiles: removedTiles,
                                       expectedManifestGeneration: expectedManifestGeneration)
    }

    func loadTile(_ key: DTTileKey) async throws -> DTTilePayload {
        try await packageStore.loadTile(key)
    }

    /// Explicit one-way DTAR import helper. The returned bytes must be decoded
    /// and translated into a package commit by the caller; this method never
    /// writes those bytes to the package store.
    static func loadLegacyDTAR(from url: URL,
                               fileManager: FileManager = .default) throws -> Data {
        try DTPackageStore.loadLegacyDTAR(from: url, fileManager: fileManager)
    }

    // MARK: Deprecated flat-archive compatibility

    /// Source-compatible shim for the pre-package controller. Keeping this
    /// method throwing prevents accidental dual writes while the controller is
    /// migrated to `commit(_:)`.
    @available(*, deprecated, message: "Use async commit(_:) on packageStore; flat DTAR writes are disabled")
    func save(_ data: Data) throws {
        _ = data
        throw DTPackageStoreError.legacyDTARWriteDisabled
    }

    /// Source-compatible shim for the pre-package controller. It returns nil
    /// rather than treating a flat DTAR as a live fallback. Use `loadPackage()`.
    @available(*, deprecated, message: "Use async loadPackage(); flat DTAR reads require explicit import")
    func load() -> Data? { nil }

    /// Retained only so old recovery call sites compile. Package recovery is
    /// non-destructive and ignores unreferenced partial files; there is no flat
    /// archive to quarantine here.
    @available(*, deprecated, message: "Package recovery supersedes flat archive quarantine")
    func quarantineCorruptArchive() {}
}
