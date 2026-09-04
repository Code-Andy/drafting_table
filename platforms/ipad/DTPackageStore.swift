import Foundation
import CryptoKit

// MARK: - Package model

/// The layer kind is persisted as metadata. Raster pixels are always stored in
/// immutable `.dtile` payloads; vector content is owned by the document engine
/// and is represented here only by its descriptor until the vector slice lands.
public enum DTPackageLayerKind: String, Codable, Hashable, Sendable {
    case raster
    case vector
    case group
}

public struct DTPackageLayerDescriptor: Codable, Hashable, Sendable {
    public let layerID: UInt64
    public var name: String
    public var kind: DTPackageLayerKind
    public var order: Int
    public var opacity: Float
    public var isVisible: Bool

    public init(layerID: UInt64,
                name: String,
                kind: DTPackageLayerKind = .raster,
                order: Int = 0,
                opacity: Float = 1,
                isVisible: Bool = true) {
        self.layerID = layerID
        self.name = name
        self.kind = kind
        self.order = order
        self.opacity = opacity
        self.isVisible = isVisible
    }
}

public struct DTPackagePageDescriptor: Codable, Hashable, Sendable {
    public let pageID: UInt64
    public var order: Int
    public var width: Int
    public var height: Int
    public var layers: [DTPackageLayerDescriptor]

    public init(pageID: UInt64,
                order: Int = 0,
                width: Int,
                height: Int,
                layers: [DTPackageLayerDescriptor] = []) {
        self.pageID = pageID
        self.order = order
        self.width = width
        self.height = height
        self.layers = layers
    }
}

public struct DTPackageDocumentDescriptor: Codable, Hashable, Sendable {
    public let documentID: UUID
    public var title: String
    public var pages: [DTPackagePageDescriptor]
    public var createdAt: Date
    public var modifiedAt: Date

    public init(documentID: UUID = UUID(),
                title: String = "Drafting Table",
                pages: [DTPackagePageDescriptor] = [],
                createdAt: Date = Date(),
                modifiedAt: Date = Date()) {
        self.documentID = documentID
        self.title = title
        self.pages = pages
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }
}

/// Stable identity of a tile independent of its version. Coordinates are in
/// document tile space and may be negative for a page origin outside (0, 0).
public struct DTTileAddress: Codable, Hashable, Sendable {
    public let pageID: UInt64
    public let layerID: UInt64
    public let x: Int32
    public let y: Int32

    public init(pageID: UInt64, layerID: UInt64, x: Int32, y: Int32) {
        self.pageID = pageID
        self.layerID = layerID
        self.x = x
        self.y = y
    }
}

/// A versioned immutable tile identity. `generation` is the document content
/// generation assigned by the serial document coordinator; `versionID` is the
/// nonzero UInt64 renderer version that produced the exact payload.
public struct DTTileKey: Codable, Hashable, Sendable {
    public let address: DTTileAddress
    public let generation: UInt64
    public let versionID: UInt64

    public init(address: DTTileAddress,
                generation: UInt64,
                versionID: UInt64) {
        self.address = address
        self.generation = generation
        self.versionID = versionID
    }

    public init(pageID: UInt64,
                layerID: UInt64,
                x: Int32,
                y: Int32,
                generation: UInt64,
                versionID: UInt64) {
        self.init(address: DTTileAddress(pageID: pageID, layerID: layerID, x: x, y: y),
                  generation: generation,
                  versionID: versionID)
    }
}

public enum DTTileGPUResidency: String, Codable, Hashable, Sendable {
    case notResident
    case residentClean
    case residentDirty
    case checkpointPending
}

/// Runtime bookkeeping contract shared by the document and renderer. The
/// package store only creates records with `.notResident`/`.none`; Metal is the
/// sole writable pixel owner while a tile is resident.
public enum DTTileWritableSource: String, Codable, Hashable, Sendable {
    case none
    case metal
}

public struct DTTileRecord: Codable, Hashable, Sendable {
    public let address: DTTileAddress
    public let versionID: UInt64
    public var contentGeneration: UInt64
    public var persistedGeneration: UInt64
    public var gpuResidency: DTTileGPUResidency
    public var writableSource: DTTileWritableSource
    public var payloadReference: String?

    public init(address: DTTileAddress,
                versionID: UInt64,
                contentGeneration: UInt64,
                persistedGeneration: UInt64,
                gpuResidency: DTTileGPUResidency = .notResident,
                writableSource: DTTileWritableSource = .none,
                payloadReference: String? = nil) {
        self.address = address
        self.versionID = versionID
        self.contentGeneration = contentGeneration
        self.persistedGeneration = persistedGeneration
        self.gpuResidency = gpuResidency
        self.writableSource = writableSource
        self.payloadReference = payloadReference
    }
}

public enum DTPackageStoreError: Error, LocalizedError, Sendable {
    case invalidTilePayload(expectedBytes: Int, actualBytes: Int)
    case invalidTileHeader
    case tileChecksumMismatch
    case tileNotFound
    case invalidManifest
    case invalidDocumentMetadata
    case nonPremultipliedTile
    case noCompleteManifest
    case manifestGenerationConflict(expected: UInt64, actual: UInt64)
    case tileGenerationConflict(address: DTTileAddress, previous: UInt64, incoming: UInt64)
    case versionCollision
    case packageURLIsNotDirectory
    case coordinatedAccessFailed(String)
    case legacyDTARWriteDisabled
    case legacyDTARReadRequiresExplicitImporter

    public var errorDescription: String? {
        switch self {
        case let .invalidTilePayload(expected, actual):
            return "A tile must contain exactly \(expected) bytes (received \(actual))."
        case .invalidTileHeader:
            return "The tile header is invalid or uses an unsupported format."
        case .tileChecksumMismatch:
            return "The tile checksum does not match its payload."
        case .tileNotFound:
            return "The requested tile is not referenced by the current manifest."
        case .invalidManifest:
            return "The package manifest is invalid or incomplete."
        case .invalidDocumentMetadata:
            return "Document metadata contains duplicate IDs, invalid dimensions, ordering, or opacity."
        case .nonPremultipliedTile:
            return "A premultiplied RGBA tile contains a color component greater than its alpha."
        case .noCompleteManifest:
            return "No complete Drafting Table package manifest could be recovered."
        case let .manifestGenerationConflict(expected, actual):
            return "The document changed (expected manifest generation \(expected), found \(actual))."
        case let .tileGenerationConflict(address, previous, incoming):
            return "Tile \(address.pageID)/\(address.layerID)/\(address.x)/\(address.y) regressed from generation \(previous) to \(incoming)."
        case .versionCollision:
            return "An immutable package object already exists with different contents."
        case .packageURLIsNotDirectory:
            return "A Drafting Table package URL must point to a directory."
        case let .coordinatedAccessFailed(message):
            return "Coordinated package access failed: \(message)"
        case .legacyDTARWriteDisabled:
            return "Flat DTAR writes are disabled; commit through DTPackageStore."
        case .legacyDTARReadRequiresExplicitImporter:
            return "Flat DTAR data must be loaded through the explicit legacy importer."
        }
    }
}

public struct DTTilePayload: Codable, Sendable, Hashable {
    public static let tileWidth = 256
    public static let tileHeight = 256
    public static let bytesPerPixel = 4
    public static let pixelByteCount = tileWidth * tileHeight * bytesPerPixel
    public static let tileFileByteCount = 96 + pixelByteCount

    public let key: DTTileKey
    /// Exact 8-bit premultiplied RGBA bytes in row-major order. No PNG or
    /// color-space conversion is performed by the package store.
    public let pixels: Data

    public init(key: DTTileKey, pixels: Data) throws {
        guard key.generation > 0, key.versionID > 0 else {
            throw DTPackageStoreError.invalidManifest
        }
        guard pixels.count == Self.pixelByteCount else {
            throw DTPackageStoreError.invalidTilePayload(expectedBytes: Self.pixelByteCount,
                                                          actualBytes: pixels.count)
        }
        // The package format is premultiplied RGBA8. Rejecting malformed input
        // here keeps Metal, undo snapshots, and persisted bytes in agreement.
        var offset = 0
        while offset < pixels.count {
            let alpha = pixels[offset + 3]
            if pixels[offset] > alpha || pixels[offset + 1] > alpha || pixels[offset + 2] > alpha {
                throw DTPackageStoreError.nonPremultipliedTile
            }
            offset += Self.bytesPerPixel
        }
        self.key = key
        self.pixels = pixels
    }

    public init(pageID: UInt64,
                layerID: UInt64,
                x: Int32,
                y: Int32,
                generation: UInt64,
                versionID: UInt64,
                pixels: Data) throws {
        try self.init(key: DTTileKey(pageID: pageID,
                                     layerID: layerID,
                                     x: x,
                                     y: y,
                                     generation: generation,
                                     versionID: versionID),
                      pixels: pixels)
    }

    private enum CodingKeys: String, CodingKey {
        case key
        case pixels
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(key: container.decode(DTTileKey.self, forKey: .key),
                      pixels: container.decode(Data.self, forKey: .pixels))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(pixels, forKey: .pixels)
    }
}

public struct DTTileManifestEntry: Codable, Hashable, Sendable {
    public let key: DTTileKey
    public let relativePath: String
    public let sha256: String
    public let byteCount: Int
    public let contentGeneration: UInt64
    public let persistedGeneration: UInt64

    public init(key: DTTileKey,
                relativePath: String,
                sha256: String,
                byteCount: Int,
                contentGeneration: UInt64,
                persistedGeneration: UInt64) {
        self.key = key
        self.relativePath = relativePath
        self.sha256 = sha256
        self.byteCount = byteCount
        self.contentGeneration = contentGeneration
        self.persistedGeneration = persistedGeneration
    }

    fileprivate func persisted() -> DTTileManifestEntry {
        DTTileManifestEntry(key: key,
                            relativePath: relativePath,
                            sha256: sha256,
                            byteCount: byteCount,
                            contentGeneration: contentGeneration,
                            persistedGeneration: contentGeneration)
    }

    public var record: DTTileRecord {
        DTTileRecord(address: key.address,
                     versionID: key.versionID,
                     contentGeneration: contentGeneration,
                     persistedGeneration: persistedGeneration,
                     payloadReference: relativePath)
    }
}

public struct DTPackageManifest: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let manifestGeneration: UInt64
    public let documentGeneration: UInt64
    public let document: DTPackageDocumentDescriptor
    public let tiles: [DTTileManifestEntry]
    public let committedAt: Date

    public init(schemaVersion: Int = DTPackageManifest.currentSchemaVersion,
                manifestGeneration: UInt64,
                documentGeneration: UInt64,
                document: DTPackageDocumentDescriptor,
                tiles: [DTTileManifestEntry],
                committedAt: Date = Date()) {
        self.schemaVersion = schemaVersion
        self.manifestGeneration = manifestGeneration
        self.documentGeneration = documentGeneration
        self.document = document
        self.tiles = tiles
        self.committedAt = committedAt
    }
}

public struct DTPackageSnapshot: Sendable, Hashable {
    public let manifest: DTPackageManifest

    public init(manifest: DTPackageManifest) {
        self.manifest = manifest
    }

    public var manifestGeneration: UInt64 { manifest.manifestGeneration }
    public var documentGeneration: UInt64 { manifest.documentGeneration }
    public var document: DTPackageDocumentDescriptor { manifest.document }
    public var tileRecords: [DTTileRecord] { manifest.tiles.map(\.record) }

    public func tileEntry(for address: DTTileAddress) -> DTTileManifestEntry? {
        manifest.tiles.first { $0.key.address == address }
    }
}

public struct DTPackageCommit: Sendable {
    public let document: DTPackageDocumentDescriptor
    public let documentGeneration: UInt64
    public let tiles: [DTTilePayload]
    public let removedTiles: Set<DTTileAddress>
    public let expectedManifestGeneration: UInt64?

    public init(document: DTPackageDocumentDescriptor,
                documentGeneration: UInt64 = 1,
                tiles: [DTTilePayload] = [],
                removedTiles: Set<DTTileAddress> = [],
                expectedManifestGeneration: UInt64? = nil) {
        self.document = document
        self.documentGeneration = documentGeneration
        self.tiles = tiles
        self.removedTiles = removedTiles
        self.expectedManifestGeneration = expectedManifestGeneration
    }
}

// MARK: - Package store

/// Actor-isolated, manifest-last storage for a `.drafttable` directory.
///
/// Ownership is intentionally one-way: the document queue submits value-type
/// commands and immutable tile payloads; Metal is the only writable owner of
/// resident pixels; this actor writes immutable generations; recovery reads the
/// last complete manifest. A package has no live DTAR fallback or dual-write
/// path.
public actor DTPackageStore {
    public static let currentFileName = "CURRENT"
    public static let manifestsDirectoryName = "manifests"
    public static let tilesDirectoryName = "tiles"
    public static let tileHeaderByteCount = 96

    private static let manifestPrefix = "manifest-"
    private static let manifestSuffix = ".json"
    private static let tileMagic = Data([0x44, 0x54, 0x49, 0x4C, 0x45, 0x00, 0x00, 0x00]) // DTILE\0\0\0
    private static let tileFormatVersion: UInt16 = 1
    private static let tilePixelFormatPremultipliedRGBA8: UInt8 = 1
    private static let tileHeaderSize = tileHeaderByteCount
    private static let maximumPageDimension = 65_536
    private static let maximumPagePixels: Int64 = 4_294_967_296

    private let packageURL: URL
    private let fileManager: FileManager
    private let usesSecurityScopedAccess: Bool

    public init(packageURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.packageURL = packageURL ?? Self.defaultPackageURL(fileManager: fileManager)
        self.usesSecurityScopedAccess = packageURL != nil
    }

    public static func defaultPackageURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("DraftingTable", isDirectory: true)
            .appendingPathComponent("Preview.drafttable", isDirectory: true)
    }

    public func url() -> URL { packageURL }

    /// Recover the newest complete manifest. Invalid/current-partial manifests
    /// are skipped and unreferenced files are ignored; this method does not
    /// mutate CURRENT while recovering.
    public func load() throws -> DTPackageSnapshot? {
        guard fileManager.fileExists(atPath: packageURL.path) else { return nil }
        return try coordinatedRead {
            guard isDirectory(packageURL) else { throw DTPackageStoreError.packageURLIsNotDirectory }
            guard let manifest = recoverManifest() else { return nil }
            return DTPackageSnapshot(manifest: manifest)
        }
    }

    public func commit(document: DTPackageDocumentDescriptor,
                       documentGeneration: UInt64 = 1,
                       tiles: [DTTilePayload] = [],
                       removedTiles: Set<DTTileAddress> = [],
                       expectedManifestGeneration: UInt64? = nil) throws -> DTPackageSnapshot {
        try commit(DTPackageCommit(document: document,
                                   documentGeneration: documentGeneration,
                                   tiles: tiles,
                                   removedTiles: removedTiles,
                                   expectedManifestGeneration: expectedManifestGeneration))
    }

    /// Commits tile objects, then a versioned manifest, and replaces CURRENT
    /// last. Existing objects remain immutable and are eligible for later GC.
    public func commit(_ transaction: DTPackageCommit) throws -> DTPackageSnapshot {
        try coordinatedWrite {
            try ensurePackageLayout()
            let previous = recoverManifest()
            let previousGeneration = previous?.manifestGeneration ?? 0
            let previousDocumentGeneration = previous?.documentGeneration ?? 0
            if let expected = transaction.expectedManifestGeneration,
               expected != previousGeneration {
                throw DTPackageStoreError.manifestGenerationConflict(expected: expected,
                                                                       actual: previousGeneration)
            }
            guard transaction.documentGeneration > 0,
                  transaction.documentGeneration > previousDocumentGeneration else {
                throw DTPackageStoreError.invalidDocumentMetadata
            }
            try validateDocument(transaction.document)
            for oldEntry in previous?.tiles ?? [] {
                guard oldEntry.contentGeneration <= transaction.documentGeneration,
                      isRasterTile(oldEntry.key.address, in: transaction.document) else {
                    throw DTPackageStoreError.invalidDocumentMetadata
                }
            }

            guard previousGeneration < UInt64.max else {
                throw DTPackageStoreError.invalidManifest
            }
            let nextManifestGeneration = previousGeneration + 1
            var entriesByAddress = Dictionary(uniqueKeysWithValues:
                (previous?.tiles ?? []).map { ($0.key.address, $0) })
            var incomingAddresses = Set<DTTileAddress>()

            for payload in transaction.tiles {
                guard payload.key.generation > 0, payload.key.versionID > 0 else {
                    throw DTPackageStoreError.invalidManifest
                }
                guard payload.key.generation <= transaction.documentGeneration else {
                    throw DTPackageStoreError.invalidManifest
                }
                guard isRasterTile(payload.key.address, in: transaction.document) else {
                    throw DTPackageStoreError.invalidDocumentMetadata
                }
                guard incomingAddresses.insert(payload.key.address).inserted else {
                    throw DTPackageStoreError.invalidManifest
                }
                guard !transaction.removedTiles.contains(payload.key.address) else {
                    throw DTPackageStoreError.invalidManifest
                }
                if let old = entriesByAddress[payload.key.address],
                   payload.key.generation <= old.contentGeneration {
                    throw DTPackageStoreError.tileGenerationConflict(address: payload.key.address,
                                                                       previous: old.contentGeneration,
                                                                       incoming: payload.key.generation)
                }

                let tileData = try encodeTileFile(payload)
                let relativePath = Self.tileRelativePath(for: payload.key)
                let destination = packageURL.appendingPathComponent(relativePath)
                try writeImmutableObject(tileData, to: destination)
                let entry = DTTileManifestEntry(key: payload.key,
                                                relativePath: relativePath,
                                                sha256: checksumHex(tileData),
                                                byteCount: tileData.count,
                                                contentGeneration: payload.key.generation,
                                                persistedGeneration: payload.key.generation)
                entriesByAddress[payload.key.address] = entry
            }

            for address in transaction.removedTiles {
                entriesByAddress.removeValue(forKey: address)
            }

            let entries = entriesByAddress.values
                .map { $0.persisted() }
                .sorted { lhs, rhs in
                    if lhs.key.address.pageID != rhs.key.address.pageID {
                        return lhs.key.address.pageID < rhs.key.address.pageID
                    }
                    if lhs.key.address.layerID != rhs.key.address.layerID {
                        return lhs.key.address.layerID < rhs.key.address.layerID
                    }
                    if lhs.key.address.y != rhs.key.address.y {
                        return lhs.key.address.y < rhs.key.address.y
                    }
                    return lhs.key.address.x < rhs.key.address.x
                }

            let manifest = DTPackageManifest(manifestGeneration: nextManifestGeneration,
                                             documentGeneration: transaction.documentGeneration,
                                             document: transaction.document,
                                             tiles: entries)
            let manifestData = try encodeManifestEnvelope(manifest)
            let manifestURL = packageURL
                .appendingPathComponent(Self.manifestsDirectoryName, isDirectory: true)
                .appendingPathComponent(Self.manifestFileName(nextManifestGeneration), isDirectory: false)
            try writeImmutableObject(manifestData, to: manifestURL)

            let currentData = Data(Self.manifestFileName(nextManifestGeneration).utf8)
            let currentURL = packageURL.appendingPathComponent(Self.currentFileName, isDirectory: false)
            try replaceObject(currentData, at: currentURL)
            return DTPackageSnapshot(manifest: manifest)
        }
    }

    /// Reads and validates one exact tile referenced by the recovered manifest.
    public func loadTile(_ key: DTTileKey) throws -> DTTilePayload {
        guard fileManager.fileExists(atPath: packageURL.path) else {
            throw DTPackageStoreError.noCompleteManifest
        }
        return try coordinatedRead {
            guard let manifest = recoverManifest(),
                  let entry = manifest.tiles.first(where: { $0.key == key }) else {
                throw DTPackageStoreError.tileNotFound
            }
            let url = packageURL.appendingPathComponent(entry.relativePath)
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard checksumHex(data) == entry.sha256, data.count == entry.byteCount else {
                throw DTPackageStoreError.tileChecksumMismatch
            }
            let payload = try decodeTileFile(data)
            guard payload.key == key else { throw DTPackageStoreError.invalidTileHeader }
            return payload
        }
    }

    /// The old flat archive is import-only. Callers must explicitly validate
    /// and translate its bytes into a package transaction; this helper never
    /// writes DTAR data and never updates a package manifest.
    public static func loadLegacyDTAR(from url: URL,
                                      fileManager: FileManager = .default) throws -> Data {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard fileManager.fileExists(atPath: url.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    // MARK: Coordinated I/O

    private func coordinatedRead<T>(_ body: () throws -> T) throws -> T {
        try withSecurityScope {
            let coordinator = NSFileCoordinator(filePresenter: nil)
            var coordinationError: NSError?
            var result: Result<T, Error>?
            coordinator.coordinate(readingItemAt: packageURL,
                                   options: [],
                                   error: &coordinationError) { _ in
                do {
                    result = .success(try body())
                } catch {
                    result = .failure(error)
                }
            }
            if let coordinationError {
                throw DTPackageStoreError.coordinatedAccessFailed(coordinationError.localizedDescription)
            }
            guard let result else { throw DTPackageStoreError.coordinatedAccessFailed("No accessor result") }
            return try result.get()
        }
    }

    private func coordinatedWrite<T>(_ body: () throws -> T) throws -> T {
        try withSecurityScope {
            try ensurePackageLayout()
            let coordinator = NSFileCoordinator(filePresenter: nil)
            var coordinationError: NSError?
            var result: Result<T, Error>?
            coordinator.coordinate(writingItemAt: packageURL,
                                   options: [],
                                   error: &coordinationError) { _ in
                do {
                    result = .success(try body())
                } catch {
                    result = .failure(error)
                }
            }
            if let coordinationError {
                throw DTPackageStoreError.coordinatedAccessFailed(coordinationError.localizedDescription)
            }
            guard let result else { throw DTPackageStoreError.coordinatedAccessFailed("No accessor result") }
            return try result.get()
        }
    }

    private func withSecurityScope<T>(_ body: () throws -> T) rethrows -> T {
        let accessed = usesSecurityScopedAccess && packageURL.startAccessingSecurityScopedResource()
        defer { if accessed { packageURL.stopAccessingSecurityScopedResource() } }
        return try body()
    }

    private func ensurePackageLayout() throws {
        if fileManager.fileExists(atPath: packageURL.path) && !isDirectory(packageURL) {
            throw DTPackageStoreError.packageURLIsNotDirectory
        }
        try fileManager.createDirectory(at: packageURL,
                                         withIntermediateDirectories: true,
                                         attributes: nil)
        try fileManager.createDirectory(at: packageURL.appendingPathComponent(Self.manifestsDirectoryName,
                                                                                isDirectory: true),
                                         withIntermediateDirectories: true,
                                         attributes: nil)
        try fileManager.createDirectory(at: packageURL.appendingPathComponent(Self.tilesDirectoryName,
                                                                                isDirectory: true),
                                         withIntermediateDirectories: true,
                                         attributes: nil)
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return false }
        return isDirectory.boolValue
    }

    // MARK: Recovery and object encoding

    private func validateDocument(_ document: DTPackageDocumentDescriptor) throws {
        guard document.createdAt.timeIntervalSinceReferenceDate.isFinite,
              document.modifiedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw DTPackageStoreError.invalidDocumentMetadata
        }
        var pageIDs = Set<UInt64>()
        var pageOrders = Set<Int>()
        var layerIDs = Set<UInt64>()
        for page in document.pages {
            guard page.pageID != 0,
                  pageIDs.insert(page.pageID).inserted,
                  pageOrders.insert(page.order).inserted,
                  page.width > 0,
                  page.height > 0,
                  page.width <= Self.maximumPageDimension,
                  page.height <= Self.maximumPageDimension,
                  Int64(page.width) * Int64(page.height) <= Self.maximumPagePixels else {
                throw DTPackageStoreError.invalidDocumentMetadata
            }
            var layerOrders = Set<Int>()
            for layer in page.layers {
                guard layer.layerID != 0,
                      layerIDs.insert(layer.layerID).inserted,
                      layerOrders.insert(layer.order).inserted,
                      layer.opacity.isFinite,
                      layer.opacity >= 0,
                      layer.opacity <= 1 else {
                    throw DTPackageStoreError.invalidDocumentMetadata
                }
            }
        }
    }

    private func isRasterTile(_ address: DTTileAddress,
                              in document: DTPackageDocumentDescriptor) -> Bool {
        document.pages.contains { page in
            page.pageID == address.pageID && page.layers.contains { layer in
                layer.layerID == address.layerID && layer.kind == .raster
            }
        }
    }

    private func recoverManifest() -> DTPackageManifest? {
        guard isDirectory(packageURL) else { return nil }
        var candidates: [URL] = []
        let currentURL = packageURL.appendingPathComponent(Self.currentFileName, isDirectory: false)
        if let currentText = try? String(contentsOf: currentURL, encoding: .utf8) {
            let currentName = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if let manifestURL = safeManifestURL(named: currentName) {
                candidates.append(manifestURL)
            }
        }

        let manifestsURL = packageURL.appendingPathComponent(Self.manifestsDirectoryName, isDirectory: true)
        let discovered = (try? fileManager.contentsOfDirectory(at: manifestsURL,
                                                                  includingPropertiesForKeys: nil,
                                                                  options: [.skipsHiddenFiles])) ?? []
        let sorted = discovered
            .filter { Self.manifestGeneration(from: $0.lastPathComponent) != nil }
            .sorted {
                (Self.manifestGeneration(from: $0.lastPathComponent) ?? 0)
                    > (Self.manifestGeneration(from: $1.lastPathComponent) ?? 0)
            }
        candidates.append(contentsOf: sorted)

        var visited = Set<URL>()
        for candidate in candidates where visited.insert(candidate).inserted {
            guard let manifest = try? readManifest(at: candidate) else { continue }
            return manifest
        }
        return nil
    }

    private func safeManifestURL(named name: String) -> URL? {
        guard let generation = Self.manifestGeneration(from: name) else { return nil }
        let url = packageURL
            .appendingPathComponent(Self.manifestsDirectoryName, isDirectory: true)
            .appendingPathComponent(Self.manifestFileName(generation), isDirectory: false)
        return url.lastPathComponent == name ? url : nil
    }

    private func readManifest(at url: URL) throws -> DTPackageManifest {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(ManifestEnvelope.self, from: data)
        guard envelope.manifest.schemaVersion == DTPackageManifest.currentSchemaVersion,
              envelope.manifest.manifestGeneration > 0,
              envelope.manifest.documentGeneration > 0,
              Self.manifestGeneration(from: url.lastPathComponent) == envelope.manifest.manifestGeneration,
              url.lastPathComponent == Self.manifestFileName(envelope.manifest.manifestGeneration),
              checksumHex(try encodeManifestPayload(envelope.manifest)) == envelope.manifestSHA256 else {
            throw DTPackageStoreError.invalidManifest
        }
        try validateDocument(envelope.manifest.document)

        var addresses = Set<DTTileAddress>()
        for entry in envelope.manifest.tiles {
            guard entry.contentGeneration == entry.key.generation,
                  entry.contentGeneration > 0,
                  entry.key.versionID > 0,
                  entry.contentGeneration <= envelope.manifest.documentGeneration,
                  entry.persistedGeneration == entry.contentGeneration,
                  entry.byteCount == Self.tileHeaderSize + DTTilePayload.pixelByteCount,
                  entry.relativePath == Self.tileRelativePath(for: entry.key),
                  addresses.insert(entry.key.address).inserted,
                  isRasterTile(entry.key.address, in: envelope.manifest.document) else {
                throw DTPackageStoreError.invalidManifest
            }
            let tileURL = packageURL.appendingPathComponent(entry.relativePath)
            let tileData = try Data(contentsOf: tileURL, options: [.mappedIfSafe])
            guard tileData.count == entry.byteCount,
                  checksumHex(tileData) == entry.sha256,
                  (try? decodeTileFile(tileData))?.key == entry.key else {
                throw DTPackageStoreError.invalidManifest
            }
        }
        return envelope.manifest
    }

    private func encodeManifestEnvelope(_ manifest: DTPackageManifest) throws -> Data {
        let envelope = ManifestEnvelope(manifest: manifest,
                                        manifestSHA256: checksumHex(try encodeManifestPayload(manifest)))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(envelope)
    }

    private func encodeManifestPayload(_ manifest: DTPackageManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(manifest)
    }

    private func writeImmutableObject(_ data: Data, to destination: URL) throws {
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true, attributes: nil)
        if fileManager.fileExists(atPath: destination.path) {
            guard let existing = try? Data(contentsOf: destination), existing == data else {
                throw DTPackageStoreError.versionCollision
            }
            return
        }
        let temp = parent.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).partial")
        defer { try? fileManager.removeItem(at: temp) }
        try writeDurably(data, to: temp)
        try fileManager.moveItem(at: temp, to: destination)
    }

    private func replaceObject(_ data: Data, at destination: URL) throws {
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true, attributes: nil)
        let temp = parent.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).partial")
        defer { try? fileManager.removeItem(at: temp) }
        try writeDurably(data, to: temp)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination,
                                              withItemAt: temp,
                                              backupItemName: nil,
                                              options: [.usingNewMetadataOnly])
        } else {
            try fileManager.moveItem(at: temp, to: destination)
        }
    }

    private func writeDurably(_ data: Data, to url: URL) throws {
        fileManager.createFile(atPath: url.path, contents: nil, attributes: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        handle.synchronizeFile()
    }

    private func checksumHex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: `.dtile` binary format

    private func encodeTileFile(_ payload: DTTilePayload) throws -> Data {
        let checksum = Data(SHA256.hash(data: payload.pixels))
        var header = Data(capacity: Self.tileHeaderSize)
        header.append(Self.tileMagic)
        appendUInt16(Self.tileFormatVersion, to: &header)
        appendUInt16(0, to: &header) // reserved
        appendUInt64(payload.key.address.pageID, to: &header)
        appendUInt64(payload.key.address.layerID, to: &header)
        appendUInt32(UInt32(bitPattern: payload.key.address.x), to: &header)
        appendUInt32(UInt32(bitPattern: payload.key.address.y), to: &header)
        appendUInt64(payload.key.generation, to: &header)
        appendUInt64(payload.key.versionID, to: &header)
        appendUInt16(UInt16(DTTilePayload.tileWidth), to: &header)
        appendUInt16(UInt16(DTTilePayload.tileHeight), to: &header)
        header.append(UInt8(DTTilePayload.bytesPerPixel))
        header.append(Self.tilePixelFormatPremultipliedRGBA8)
        appendUInt16(0, to: &header) // reserved
        appendUInt32(UInt32(DTTilePayload.pixelByteCount), to: &header)
        header.append(checksum)
        guard header.count == Self.tileHeaderSize else { throw DTPackageStoreError.invalidTileHeader }
        var result = header
        result.append(payload.pixels)
        return result
    }

    private func decodeTileFile(_ data: Data) throws -> DTTilePayload {
        guard data.count >= Self.tileHeaderSize,
              Data(data.prefix(Self.tileMagic.count)) == Self.tileMagic,
              readUInt16(data, at: 8) == Self.tileFormatVersion,
              readUInt16(data, at: 10) == 0,
              readUInt16(data, at: 52) == UInt16(DTTilePayload.tileWidth),
              readUInt16(data, at: 54) == UInt16(DTTilePayload.tileHeight),
              data[56] == UInt8(DTTilePayload.bytesPerPixel),
              data[57] == Self.tilePixelFormatPremultipliedRGBA8,
              readUInt16(data, at: 58) == 0,
              readUInt32(data, at: 60) == UInt32(DTTilePayload.pixelByteCount) else {
            throw DTPackageStoreError.invalidTileHeader
        }
        guard let payloadLength = readUInt32(data, at: 60),
              Int(payloadLength) == DTTilePayload.pixelByteCount,
              data.count == Self.tileHeaderSize + Int(payloadLength),
              let pageID = readUInt64(data, at: 12),
              let layerID = readUInt64(data, at: 20),
              let xBits = readUInt32(data, at: 28),
              let yBits = readUInt32(data, at: 32),
              let generation = readUInt64(data, at: 36),
              let versionID = readUInt64(data, at: 44) else {
            throw DTPackageStoreError.invalidTileHeader
        }
        let pixels = data.subdata(in: Self.tileHeaderSize..<data.count)
        let expectedChecksum = data.subdata(in: 64..<Self.tileHeaderSize)
        guard Data(SHA256.hash(data: pixels)) == expectedChecksum else {
            throw DTPackageStoreError.tileChecksumMismatch
        }
        return try DTTilePayload(key: DTTileKey(pageID: pageID,
                                                layerID: layerID,
                                                x: Int32(bitPattern: xBits),
                                                y: Int32(bitPattern: yBits),
                                                generation: generation,
                                                versionID: versionID),
                                 pixels: pixels)
    }

    private static func tileRelativePath(for key: DTTileKey) -> String {
        "\(tilesDirectoryName)/p\(key.address.pageID)/l\(key.address.layerID)/x\(key.address.x)y\(key.address.y)-g\(key.generation)-v\(key.versionID).dtile"
    }

    private static func manifestFileName(_ generation: UInt64) -> String {
        let value = String(generation)
        let padding = String(repeating: "0", count: max(0, 20 - value.count))
        return "\(manifestPrefix)\(padding)\(value)\(manifestSuffix)"
    }

    private static func manifestGeneration(from name: String) -> UInt64? {
        guard name.hasPrefix(manifestPrefix), name.hasSuffix(manifestSuffix) else { return nil }
        let start = name.index(name.startIndex, offsetBy: manifestPrefix.count)
        let end = name.index(name.endIndex, offsetBy: -manifestSuffix.count)
        guard start < end else { return nil }
        return UInt64(name[start..<end])
    }
}

private struct ManifestEnvelope: Codable, Sendable {
    let manifest: DTPackageManifest
    let manifestSHA256: String
}

// MARK: - Binary helpers

private func appendUInt16(_ value: UInt16, to data: inout Data) {
    data.append(UInt8(truncatingIfNeeded: value))
    data.append(UInt8(truncatingIfNeeded: value >> 8))
}

private func appendUInt32(_ value: UInt32, to data: inout Data) {
    appendUInt16(UInt16(truncatingIfNeeded: value), to: &data)
    appendUInt16(UInt16(truncatingIfNeeded: value >> 16), to: &data)
}

private func appendUInt64(_ value: UInt64, to data: inout Data) {
    appendUInt32(UInt32(truncatingIfNeeded: value), to: &data)
    appendUInt32(UInt32(truncatingIfNeeded: value >> 32), to: &data)
}

private func readUInt16(_ data: Data, at offset: Int) -> UInt16? {
    guard offset >= 0, offset + 2 <= data.count else { return nil }
    return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
}

private func readUInt32(_ data: Data, at offset: Int) -> UInt32? {
    guard let low = readUInt16(data, at: offset),
          let high = readUInt16(data, at: offset + 2) else { return nil }
    return UInt32(low) | (UInt32(high) << 16)
}

private func readUInt64(_ data: Data, at offset: Int) -> UInt64? {
    guard let low = readUInt32(data, at: offset),
          let high = readUInt32(data, at: offset + 4) else { return nil }
    return UInt64(low) | (UInt64(high) << 32)
}
