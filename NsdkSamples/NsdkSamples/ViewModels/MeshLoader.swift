// Copyright 2026 Niantic Spatial.

import CoreLocation
import Foundation
import NSDK

/// Streams POI mesh chunks asynchronously using the asset-based portal mesh API.
final class MeshLoader {

    /// On-disk budget for downloaded meshes, so revisiting a site loads from the device instead of
    /// re-downloading. Least recently used meshes are evicted past this.
    private static let cacheMaxMb: UInt32 = 5000

    private var meshDownloader: NSDKMeshDownloader?
    private var meshDownloadTask: Task<Void, Never>?

    /// Starts streaming mesh chunks for the given asset ID.
    ///
    /// - Parameters:
    ///   - vpsMapAssetId: The VPS map asset ID returned by the Sites API. MeshDownloader resolves
    ///     the Mesh sibling in the same asset group.
    ///   - getCoordinate: Returns the device's current coordinate (used as a download hint). Called
    ///     on the main actor at download start.
    ///   - onChunk: Called on the main actor for each downloaded chunk.
    func start(
        vpsMapAssetId: String,
        nsdkSession: NSDKSession,
        retryHelper: AuthRetryHelper,
        getCoordinate: @MainActor @escaping () -> CLLocationCoordinate2D?,
        onChunk: @MainActor @escaping (MeshDownloaderChunk) -> Void
    ) {
        cancel()

        if meshDownloader == nil {
            let downloader = nsdkSession.acquireMeshDownloader()

            // Configured once, straight after acquire, so no download can be in flight when the
            // cache is set up. The cache only saves bandwidth, so failing to enable it must not
            // stop the download.
            do {
                try downloader.configure(
                    with: .init(cacheEnabled: true, cacheMaxMb: Self.cacheMaxMb))
            } catch {
                print("Mesh cache not enabled; meshes will be re-downloaded: \(error)")
            }
            meshDownloader = downloader
        }
        guard let downloader = meshDownloader else { return }

        meshDownloadTask = Task { [downloader] in
            do {
                // Auth preflight only: do not wrap the chunk stream in withRetry.
                // Mid-stream failures (or sizeLimitReached) must not restart the download, or
                // already-delivered chunks would be appended again as duplicates.
                try await retryHelper.withRetry { }

                let coord = await MainActor.run { getCoordinate() }
                let stream = downloader.requestLocationMeshByAsset(
                    vpsMapAssetId: vpsMapAssetId,
                    latitude: coord?.latitude ?? 0.0,
                    longitude: coord?.longitude ?? 0.0,
                    getTexture: true
                )
                do {
                    for try await chunk in stream {
                        try Task.checkCancellation()
                        await MainActor.run { onChunk(chunk) }
                    }
                } catch MeshDownloaderResults.Error.sizeLimitReached {
                    // Size cap hit: all available chunks already rendered; treat as success.
                }
            } catch is CancellationError {
            } catch {
                print("Failed to download mesh: \(error)")
            }
        }
    }

    func cancel() {
        meshDownloadTask?.cancel()
        meshDownloadTask = nil
    }

    /// Cancels the download and destroys the downloader, freeing every native request it holds.
    func release(from nsdkSession: NSDKSession) {
        cancel()
        if let meshDownloader {
            nsdkSession.destroy(meshDownloader)
        }
        meshDownloader = nil
    }
}
