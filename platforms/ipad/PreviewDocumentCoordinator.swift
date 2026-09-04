import Foundation
import UIKit

/// Main-actor coordinator for the narrow v0.1 document slice.
///
/// UIKit submits input to `DTEngineBridge`; this type is the only app-facing
/// owner of the package store.  Renderer callbacks arrive on the main queue,
/// while the `saveTail` task serializes package commits in callback order.
/// Tile bytes are copied into value types before crossing into the
/// `DTPackageStore` actor.  A checkpoint is acknowledged by the bridge only
/// after the store has published its manifest and CURRENT pointer.
@MainActor
final class PreviewDocumentCoordinator {
    struct PackageLoad {
        let pageID: UInt64
        let generation: UInt64
        let width: CGFloat
        let height: CGFloat
        let layers: [DTPersistedLayerDescriptor]
        let tiles: [DTTileCheckpointPayload]
        let snapshot: DTPackageSnapshot?
    }

    var onCommit: ((UInt64) -> Void)?
    var onError: ((String) -> Void)?

    private(set) var packageURL: URL
    private(set) var packageStore: DTPackageStore
    private(set) var latestSnapshot: DTPackageSnapshot?

    private var securityScopedURL: URL?
    private var packageEpoch = UUID()
    private var saveTail: Task<Void, Never>?
    private var documentDescriptors: [UInt64: DTPackageDocumentDescriptor] = [:]
    private var pendingCheckpointGenerations = Set<UInt64>()
    private var metadataFallbackTasks: [UInt64: Task<Void, Never>] = [:]

    init(packageURL: URL = DTPackageStore.defaultPackageURL()) {
        self.packageURL = packageURL
        self.packageStore = DTPackageStore(packageURL: packageURL)
    }

    // MARK: Bridge callback wiring

    func bind(engineBridge: DTEngineBridge,
              pageSize: @escaping () -> CGSize) {
        engineBridge.documentCommitHandler = { [weak self, weak engineBridge] generation in
            guard let self, let engineBridge else { return }
            self.didCommit(generation: generation,
                           engineBridge: engineBridge,
                           pageSize: pageSize())
        }
        engineBridge.checkpointPayloadHandler = { [weak self, weak engineBridge] batch in
            guard let self, let engineBridge else { return }
            self.enqueueCheckpoint(batch,
                                   engineBridge: engineBridge,
                                   pageSize: pageSize())
        }
        engineBridge.rendererErrorHandler = { [weak self] message in
            self?.reportError(message)
        }
    }

    func unbind(engineBridge: DTEngineBridge) {
        engineBridge.documentCommitHandler = nil
        engineBridge.checkpointPayloadHandler = nil
        engineBridge.rendererErrorHandler = nil
    }

    private func didCommit(generation: UInt64,
                           engineBridge: DTEngineBridge,
                           pageSize: CGSize) {
        guard generation > 0 else { return }
        documentDescriptors[generation] = makeDocumentDescriptor(engineBridge: engineBridge,
                                                                 pageSize: pageSize)
        pendingCheckpointGenerations.insert(generation)
        onCommit?(generation)

        // Metadata-only transactions (opacity, visibility, undo of an empty
        // tile) do not necessarily produce a payload batch.  Give the paired
        // checkpoint callback a chance to arrive, then publish metadata alone
        // if no payload was delivered for this generation.
        metadataFallbackTasks[generation]?.cancel()
        metadataFallbackTasks[generation] = Task { @MainActor [weak self, weak engineBridge] in
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
            } catch {
                return
            }
            guard let self,
                  let engineBridge,
                  self.pendingCheckpointGenerations.remove(generation) != nil else { return }
            self.metadataFallbackTasks[generation] = nil
            self.enqueueMetadataCommit(generation: generation,
                                       descriptor: self.documentDescriptors[generation],
                                       engineBridge: engineBridge,
                                       epoch: self.packageEpoch)
        }
    }

    private func enqueueCheckpoint(_ batch: DTCheckpointPayloadBatch,
                                   engineBridge: DTEngineBridge,
                                   pageSize: CGSize) {
        let generation = batch.generation
        guard generation > 0 else {
            reportError("Renderer returned an invalid checkpoint generation.")
            return
        }
        pendingCheckpointGenerations.remove(generation)
        metadataFallbackTasks[generation]?.cancel()
        metadataFallbackTasks[generation] = nil

        if documentDescriptors[generation] == nil {
            documentDescriptors[generation] = makeDocumentDescriptor(engineBridge: engineBridge,
                                                                     pageSize: pageSize)
        }
        let descriptor = documentDescriptors[generation]
        let epoch = packageEpoch
        let previous = saveTail
        saveTail = Task { @MainActor [weak self, weak engineBridge] in
            _ = await previous?.value
            guard let self, let engineBridge, self.packageEpoch == epoch else { return }
            do {
                try await self.persistCheckpoint(batch,
                                                 descriptor: descriptor,
                                                 engineBridge: engineBridge,
                                                 epoch: epoch)
            } catch {
                self.reportError(error.localizedDescription)
            }
        }
    }

    private func enqueueMetadataCommit(generation: UInt64,
                                       descriptor: DTPackageDocumentDescriptor?,
                                       engineBridge: DTEngineBridge,
                                       epoch: UUID) {
        let previous = saveTail
        saveTail = Task { @MainActor [weak self, weak engineBridge] in
            _ = await previous?.value
            guard let self, let engineBridge,
                  self.packageEpoch == epoch else { return }
            do {
                let document = descriptor ?? self.makeDocumentDescriptor(engineBridge: engineBridge,
                                                                          pageSize: .zero)
                let snapshot = try await self.packageStore.commit(
                    document: document,
                    documentGeneration: generation,
                    tiles: [],
                    removedTiles: [],
                    expectedManifestGeneration: self.latestSnapshot?.manifestGeneration)
                self.latestSnapshot = snapshot
            } catch {
                self.reportError(error.localizedDescription)
            }
        }
    }

    private func persistCheckpoint(_ batch: DTCheckpointPayloadBatch,
                                   descriptor: DTPackageDocumentDescriptor?,
                                   engineBridge: DTEngineBridge,
                                   epoch: UUID) async throws {
        guard packageEpoch == epoch else { return }
        let document = descriptor ?? makeDocumentDescriptor(engineBridge: engineBridge, pageSize: .zero)
        var payloads: [DTTilePayload] = []
        var removedTiles = Set<DTTileAddress>()
        var acknowledgements: [DTPersistedTileAcknowledgement] = []
        payloads.reserveCapacity(batch.tiles.count)
        removedTiles.reserveCapacity(batch.tiles.count)

        for checkpoint in batch.tiles {
            let address = DTTileAddress(pageID: checkpoint.pageID,
                                        layerID: checkpoint.layerID,
                                        x: checkpoint.tileX,
                                        y: checkpoint.tileY)
            guard checkpoint.generation > 0,
                  checkpoint.generation <= batch.generation,
                  checkpoint.pageID == document.pages.first?.pageID,
                  document.pages.first?.layers.contains(where: {
                      $0.layerID == checkpoint.layerID && $0.kind == .raster
                  }) == true else {
                throw DTPackageStoreError.invalidManifest
            }

            if checkpoint.exists {
                let key = DTTileKey(address: address,
                                    generation: checkpoint.generation,
                                    versionID: checkpoint.versionID)
                let payload = try DTTilePayload(key: key,
                                                pixels: checkpoint.premultipliedRGBA8 as Data)
                payloads.append(payload)
            } else {
                // Undo-to-empty is a tombstone.  It must remove the address
                // from the next manifest and must never be forced through the
                // 256x256 payload validator.
                let tombstoneBytes = checkpoint.premultipliedRGBA8 as Data
                guard checkpoint.versionID == 0,
                      tombstoneBytes.isEmpty else {
                    throw DTPackageStoreError.invalidManifest
                }
                removedTiles.insert(address)
            }
        }

        let snapshot = try await packageStore.commit(
            document: document,
            documentGeneration: batch.generation,
            tiles: payloads,
            removedTiles: removedTiles,
            expectedManifestGeneration: latestSnapshot?.manifestGeneration)
        guard packageEpoch == epoch else { return }
        latestSnapshot = snapshot

        for payload in payloads {
            guard let entry = snapshot.tileEntry(for: payload.key.address) else {
                throw DTPackageStoreError.invalidManifest
            }
            acknowledgements.append(DTPersistedTileAcknowledgement(
                pageID: payload.key.address.pageID,
                layerID: payload.key.address.layerID,
                tileX: payload.key.address.x,
                tileY: payload.key.address.y,
                versionID: payload.key.versionID,
                payloadID: entry.relativePath))
        }

        // Empty acknowledgement arrays are intentional for an all-tombstone
        // transaction; the bridge accepts them as the durable removal marker.
        guard engineBridge.acknowledgePersistedOperationID(batch.operationID,
                                                            generation: batch.generation,
                                                            tiles: acknowledgements) else {
            throw DTPackageStoreError.invalidManifest
        }
    }

    // MARK: Package recovery and switching

    func recoverDefaultPackage(engineBridge: DTEngineBridge,
                               pageSize: CGSize) async throws -> PackageLoad {
        try await recover(packageURL: DTPackageStore.defaultPackageURL(),
                          engineBridge: engineBridge,
                          pageSize: pageSize,
                          retainSecurityScope: false)
    }

    func switchToPackage(at url: URL,
                         engineBridge: DTEngineBridge,
                         pageSize: CGSize) async throws -> PackageLoad {
        try await recover(packageURL: url,
                          engineBridge: engineBridge,
                          pageSize: pageSize,
                          retainSecurityScope: true)
    }

    private func recover(packageURL url: URL,
                         engineBridge: DTEngineBridge,
                         pageSize: CGSize,
                         retainSecurityScope: Bool) async throws -> PackageLoad {
        let standardized = url.standardizedFileURL
        guard standardized.pathExtension.lowercased() == "drafttable" else {
            throw DTPackageStoreError.packageURLIsNotDirectory
        }
        let accessed = retainSecurityScope && standardized.startAccessingSecurityScopedResource()
        let candidate = DTPackageStore(packageURL: standardized)
        do {
            let snapshot = try await candidate.load()
            let load = try await makePackageLoad(snapshot: snapshot,
                                                  candidateURL: standardized,
                                                  engineBridge: engineBridge,
                                                  pageSize: pageSize)
            let success = await install(load, on: engineBridge)
            guard success else {
                if accessed { standardized.stopAccessingSecurityScopedResource() }
                throw DTPackageStoreError.invalidManifest
            }

            securityScopedURL?.stopAccessingSecurityScopedResource()
            securityScopedURL = retainSecurityScope && accessed ? standardized : nil
            packageURL = standardized
            packageStore = candidate
            latestSnapshot = snapshot
            packageEpoch = UUID()
            documentDescriptors.removeAll(keepingCapacity: true)
            pendingCheckpointGenerations.removeAll(keepingCapacity: true)
            metadataFallbackTasks.values.forEach { $0.cancel() }
            metadataFallbackTasks.removeAll(keepingCapacity: true)
            return load
        } catch {
            if accessed { standardized.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    private func makePackageLoad(snapshot: DTPackageSnapshot?,
                                 candidateURL: URL,
                                 engineBridge: DTEngineBridge,
                                 pageSize: CGSize) async throws -> PackageLoad {
        guard let snapshot else {
            let page = engineBridge.pageInfos.first
            let layers = engineBridge.layerInfos
            guard let page, layers.count == 2,
                  layers.allSatisfy({ $0.kind == .raster }) else {
                throw DTPackageStoreError.invalidDocumentMetadata
            }
            let descriptorLayers = layers.map {
                DTPersistedLayerDescriptor(layerID: $0.layerID,
                                            name: $0.name,
                                            visible: $0.visible,
                                            opacity: $0.opacity)
            }
            return PackageLoad(pageID: page.pageID,
                               generation: max(UInt64(1), engineBridge.revision),
                               width: max(1, pageSize.width),
                               height: max(1, pageSize.height),
                               layers: descriptorLayers,
                               tiles: [],
                               snapshot: nil)
        }

        guard snapshot.document.pages.count == 1,
              let page = snapshot.document.pages.first,
              page.layers.count == 2,
              page.layers.allSatisfy({ $0.kind == .raster }),
              page.width > 0,
              page.height > 0 else {
            throw DTPackageStoreError.invalidDocumentMetadata
        }
        let layers = page.layers.sorted { $0.order < $1.order }.map {
            DTPersistedLayerDescriptor(layerID: $0.layerID,
                                        name: $0.name,
                                        visible: $0.isVisible,
                                        opacity: CGFloat($0.opacity))
        }
        var tiles: [DTTileCheckpointPayload] = []
        tiles.reserveCapacity(snapshot.manifest.tiles.count)
        for entry in snapshot.manifest.tiles {
            let payload = try await DTPackageStore(packageURL: candidateURL).loadTile(entry.key)
            tiles.append(DTTileCheckpointPayload(pageID: payload.key.address.pageID,
                                                 layerID: payload.key.address.layerID,
                                                 tileX: payload.key.address.x,
                                                 tileY: payload.key.address.y,
                                                 exists: true,
                                                 versionID: payload.key.versionID,
                                                 generation: payload.key.generation,
                                                 premultipliedRGBA8: payload.pixels as NSData))
        }
        return PackageLoad(pageID: page.pageID,
                           generation: snapshot.documentGeneration,
                           width: CGFloat(page.width),
                           height: CGFloat(page.height),
                           layers: layers,
                           tiles: tiles,
                           snapshot: snapshot)
    }

    private func install(_ load: PackageLoad,
                         on engineBridge: DTEngineBridge) async -> Bool {
        await withCheckedContinuation { continuation in
            engineBridge.loadPackagePage(withID: load.pageID,
                                         generation: load.generation,
                                         width: load.width,
                                         height: load.height,
                                         layers: load.layers,
                                         tiles: load.tiles) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }

    // MARK: Descriptor and errors

    private func makeDocumentDescriptor(engineBridge: DTEngineBridge,
                                        pageSize: CGSize) -> DTPackageDocumentDescriptor {
        let pageInfo = engineBridge.pageInfos.first
        let layers = engineBridge.layerInfos.prefix(2).map {
            DTPackageLayerDescriptor(layerID: $0.layerID,
                                     name: $0.name,
                                     kind: .raster,
                                     order: Int($0.index),
                                     opacity: Float(max(0, min(1, $0.opacity))),
                                     isVisible: $0.visible)
        }
        let page = DTPackagePageDescriptor(pageID: pageInfo?.pageID ?? 1,
                                           order: 0,
                                           width: max(1, Int(pageSize.width.rounded())),
                                           height: max(1, Int(pageSize.height.rounded())),
                                           layers: Array(layers))
        return DTPackageDocumentDescriptor(title: pageInfo?.name ?? "Drafting Table",
                                            pages: [page])
    }

    private func reportError(_ message: String) {
        guard !message.isEmpty else { return }
        onError?(message)
    }
}
