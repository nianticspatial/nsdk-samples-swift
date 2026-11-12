// Copyright 2026 Niantic Spatial.

import Combine
import Foundation
import NSDK

/// A scan's download state in this app run.
enum ScanDownload {
    case downloading(Double)
    case cached
    case opening

    /// On disk without a complete recording, and not downloading; selecting it downloads again.
    case incomplete
    case failed(String)
}

/// App-wide scan downloads and playback source: downloads run concurrently, and a cached scan plays
/// in place of the camera in every sample once selected. Owns the `NSDKSession` that Playback Select
/// and the downloads run on, held while either is active so downloads outlive the screen.
@MainActor
final class PlaybackLibrary: ObservableObject {
    /// Download state by scan ID; absent for a scan not known to be cached or downloading.
    @Published private(set) var downloads: [String: ScanDownload] = [:]

    /// The scan playing in place of the camera, or nil in live mode.
    @Published private(set) var activeScan: PlaybackScan?

    /// The active scan's recording, passed to each sample's `ARManager`.
    private(set) var activeDataset: PlaybackDataset?

    /// Whether Playback Select is on screen, where the source may change.
    @Published var isSelecting = false

    /// Whether the whole cache is being cleared.
    @Published private(set) var isClearing = false

    /// Why the last cache clear failed, or nil.
    @Published private(set) var clearError: String?

    private var session: NSDKSession?
    private var authSubscription: AnyCancellable?
    private var cache: NSDKPlaybackCacheSession?

    @Published private var tasks: [String: Task<Void, Never>] = [:]

    /// The scan to play once its open finishes, or nil once dropped.
    private var pendingSourceId: String?

    /// Scans whose cache deletion is in flight.
    @Published private var deleting: Set<String> = []

    /// Whether a download, open or delete is running, which blocks clearing the cache.
    var isBusy: Bool { !tasks.isEmpty || !deleting.isEmpty }

    /// "N playback downloads will be cancelled." followed by `question`, singular for one.
    static func cancelDownloadsPrompt(count: Int, question: String) -> String {
        let downloads = count == 1 ? "1 playback download" : "\(count) playback downloads"
        return "\(downloads) will be cancelled. \(question)"
    }

    /// The recording each scan plays, as the portal lists it, for the scans looked up so far.
    @Published private(set) var fileInfos: [String: PlaybackFileInfo] = [:]

    /// Scans whose lookup is in flight or has failed this session; neither is looked up again.
    private var fileInfoRequested: Set<String> = []

    /// Looks up the recording `scanId` plays, once per session; a row calls it as it appears.
    /// Runs in its own task, so a row scrolling away keeps the result.
    func loadFileInfo(for scanId: String) {
        guard let cache, fileInfoRequested.insert(scanId).inserted else { return }
        Task {
            do {
                fileInfos[scanId] = try await cache.playbackFileInfo(scanId: scanId)
            } catch {
                print("[PlaybackLibrary] Failed to look up the recording of scan \(scanId): \(error)")
            }
        }
    }

    /// Whether any scan is in the cache or downloading into it.
    var hasCachedEntries: Bool {
        downloads.values.contains {
            if case .failed = $0 { return false }
            return true
        }
    }

    /// How many scans are downloading.
    var downloadingCount: Int {
        downloads.values.filter {
            if case .downloading = $0 { return true }
            return false
        }.count
    }

    private var isOpening: Bool {
        downloads.values.contains {
            if case .opening = $0 { return true }
            return false
        }
    }

    /// The library's `NSDKSession`, created on first use with its playback cache.
    func acquireSession() -> NSDKSession {
        if let session { return session }
        let session = NSDKSession(
            accessToken: AuthConstants.accessToken,
            useLidar: ARUtils.isLidarAvailable()
        )
        authSubscription = NSSampleSessionManager.setupSessionAccess(for: session)
        cache = session.acquirePlaybackCacheSession()
        self.session = session
        return session
    }

    /// Downloads `scan` if it is not cached or incomplete, or plays it in place of the camera if it
    /// is cached.
    func select(_ scan: PlaybackScan) {
        guard let cache, !deleting.contains(scan.id), !isClearing else { return }
        switch downloads[scan.id] {
        case nil, .failed, .incomplete:
            download(scan, cache: cache)
        case .cached:
            if !isOpening, activeScan?.id != scan.id { activate(scan, cache: cache) }
        case .downloading, .opening:
            break
        }
    }

    /// Keeps a scan still opening from becoming the source; downloads keep running.
    func leaveSelection() {
        pendingSourceId = nil
        releaseSessionIfIdle()
    }

    /// Cancels downloads and opens still running and releases the session, so a sample can create
    /// its own.
    func releaseForSample() {
        pendingSourceId = nil
        for (scanId, task) in tasks {
            task.cancel()
            if case .opening = downloads[scanId] {
                downloads[scanId] = .cached
            } else {
                downloads[scanId] = nil
            }
        }
        tasks = [:]
        cache = nil
        authSubscription = nil
        session = nil
    }

    /// Returns to the live camera, closing the playing scan and dropping one still opening.
    func useLiveCamera() {
        pendingSourceId = nil
        activeScan = nil
        activeDataset = nil
    }

    /// Marks each of `scanIds` that has no state yet as downloaded if the cache holds it.
    func seedCached(_ scanIds: [String]) {
        guard let cache else { return }
        Task { [weak self] in
            let cached = await Task.detached {
                scanIds.filter { (try? cache.isCached(scanId: $0)) == true }
            }.value
            for scanId in cached where self?.downloads[scanId] == nil {
                self?.downloads[scanId] = .cached
            }
        }
    }

    /// Lists the scan IDs in the cache, marking each ready one downloaded and each incomplete one
    /// incomplete unless it already has a state.
    func loadCached() async throws -> [String] {
        guard let cache else { throw PlaybackOpenError.sessionEnded }
        let entries = try await Task.detached { try cache.cachedPlaybacks() }.value
        for entry in entries where downloads[entry.scanId] == nil {
            switch entry.state {
            case .ready: downloads[entry.scanId] = .cached
            case .incomplete: downloads[entry.scanId] = .incomplete
            case .downloading: break
            }
        }
        return entries.map(\.scanId)
    }

    /// Whether `scanId` can be deleted: it is downloaded or incomplete, and neither it nor the
    /// cache is being cleared.
    func canDelete(_ scanId: String) -> Bool {
        switch downloads[scanId] {
        case .cached, .incomplete: return !deleting.contains(scanId) && !isClearing
        default: return false
        }
    }

    /// Removes `scanId` from the cache, returning to the live camera first if it is playing; does
    /// nothing unless `canDelete`.
    func delete(_ scanId: String) {
        guard let cache, canDelete(scanId) else { return }
        if activeScan?.id == scanId { useLiveCamera() }
        deleting.insert(scanId)
        Task { [weak self] in
            do {
                try await Task.detached { try cache.deleteCached(scanId: scanId) }.value
                self?.deleting.remove(scanId)
                self?.downloads[scanId] = nil
                self?.releaseSessionIfIdle()
            } catch {
                print("[PlaybackLibrary] Failed to delete scan \(scanId): \(error)")
                let stillCached = await Task.detached { (try? cache.isCached(scanId: scanId)) == true }.value
                self?.deleting.remove(scanId)
                self?.downloads[scanId] = stillCached ? .cached : .incomplete
                self?.releaseSessionIfIdle()
            }
        }
    }

    /// Empties the cache, returning to the live camera first. Cancels downloads and opens still
    /// running and waits for them and any delete to finish, since the cache refuses to clear
    /// before then.
    func clearCache() {
        guard let cache, !isClearing else { return }
        useLiveCamera()
        isClearing = true
        clearError = nil
        let running = Array(tasks.values)
        running.forEach { $0.cancel() }
        Task { [weak self] in
            for task in running {
                await task.value
            }
            while self?.deleting.isEmpty == false {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            do {
                try await Task.detached { try cache.clearCache() }.value
                self?.downloads = [:]
            } catch {
                print("[PlaybackLibrary] Failed to clear the cache: \(error)")
                self?.clearError = "Could not clear the cache: \(error.localizedDescription)"
            }
            self?.isClearing = false
            self?.releaseSessionIfIdle()
        }
    }

    private func download(_ scan: PlaybackScan, cache: NSDKPlaybackCacheSession) {
        downloads[scan.id] = .downloading(0)
        tasks[scan.id] = Task { [weak self] in
            do {
                // The dataset closes when it goes out of scope; the recording stays cached.
                _ = try await cache.open(scanId: scan.id) { @Sendable progress in
                    Task { @MainActor in
                        guard let self, case .downloading = self.downloads[scan.id] else { return }
                        self.downloads[scan.id] = .downloading(progress)
                    }
                }
                guard self?.tasks.removeValue(forKey: scan.id) != nil else { return }
                self?.downloads[scan.id] = .cached
                self?.releaseSessionIfIdle()
            } catch {
                self?.fail(scan.id, error: error)
            }
        }
    }

    private func activate(_ scan: PlaybackScan, cache: NSDKPlaybackCacheSession) {
        downloads[scan.id] = .opening
        pendingSourceId = scan.id
        tasks[scan.id] = Task { [weak self] in
            do {
                let dataset = try await cache.open(scanId: scan.id)
                self?.finishOpening(scan, dataset: dataset)
            } catch {
                self?.fail(scan.id, error: error)
            }
        }
    }

    private func finishOpening(_ scan: PlaybackScan, dataset: PlaybackDataset) {
        guard tasks.removeValue(forKey: scan.id) != nil else { return }
        downloads[scan.id] = .cached
        releaseSessionIfIdle()

        // A dropped open closes its dataset as it goes out of scope.
        guard pendingSourceId == scan.id else { return }
        pendingSourceId = nil
        activeDataset = dataset
        activeScan = scan
    }

    private func fail(_ scanId: String, error: Error) {
        guard tasks.removeValue(forKey: scanId) != nil else { return }
        print("[PlaybackLibrary] Failed to open scan \(scanId): \(error)")
        downloads[scanId] = .failed((error as? PlaybackOpenError).map { "\($0)" } ?? error.localizedDescription)
        releaseSessionIfIdle()
    }

    /// Releases the session once Playback Select is gone and no download, open, delete or clear
    /// runs.
    private func releaseSessionIfIdle() {
        guard session != nil, !isSelecting, !isBusy, !isClearing else { return }
        cache = nil
        authSubscription = nil
        session = nil
    }
}
