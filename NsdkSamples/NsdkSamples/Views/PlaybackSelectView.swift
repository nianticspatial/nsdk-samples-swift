// Copyright 2026 Niantic Spatial.

import Combine
import NSDK
import SwiftUI

/// Picks a validation scan to download and play in place of the camera.
struct PlaybackSelectView: View {
    @ObservedObject var library: PlaybackLibrary

    @StateObject private var model: PlaybackSelectModel
    @State private var isHelpVisible = false
    @State private var isConfirmingClear = false

    init(library: PlaybackLibrary) {
        self.library = library
        _model = StateObject(wrappedValue: PlaybackSelectModel(library: library))
    }

    private static let helpText =
        "Playback Select\n\n" +
        "Browse an organization's validation scans by site, or all at once. Tapping a scan " +
        "downloads it; several can download at once, and they keep going here and on the home " +
        "list. Opening a sample cancels any still running. " +
        "Tapping a downloaded scan plays it in place of the camera in every sample. The trash " +
        "button removes a downloaded scan from the cache, returning to the live camera first if " +
        "it is playing. Downloaded playbacks lists every scan in the cache, from any " +
        "organization; one whose details cannot be looked up shows its ID, and tapping an " +
        "incomplete one, left when the app stopped mid-download, downloads it again.\n\n" +
        "Listing scans needs a token that can read them; a token scoped to site-assets:read gets " +
        "HTTP_FORBIDDEN."

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                // Lazy, so a scan row looks up its recording only once it scrolls into view.
                LazyVStack(spacing: 8) {
                    content
                }
                .padding(20)
            }
            HelpOverlayView(helpText: Self.helpText, isVisible: $isHelpVisible)
        }
        .navigationTitle("Playback Select")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Help") { isHelpVisible.toggle() }
            }
        }
        .alert(clearPrompt, isPresented: $isConfirmingClear) {
            Button("Clear", role: .destructive) { library.clearCache() }
            Button("Cancel", role: .cancel) {}
        }
        .onAppear {
            library.isSelecting = true
            model.loadOrganizations()
            Task { _ = try? await library.loadCached() }
        }
        .onDisappear {
            library.isSelecting = false
            library.leaveSelection()
            model.cancel()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView()
        case .error(let message):
            Text(message).foregroundColor(.red)
            navButton("Retry") { model.loadOrganizations() }
        case .organizations(let orgs):
            title("Select an Organization")
            if !orgs.isEmpty {
                FilterField(text: $model.filterText, placeholder: "Filter organizations...")
            }
            ForEach(orgs.filter { model.matchesFilter($0.name) }, id: \.id) { org in
                navButton(org.name) { model.selectOrganization(org) }
            }
            cacheSettings
        case .sites(let org, let sites):
            navButton("← Organizations", color: Color(.systemGray)) { model.backToOrganizations() }
            modeToggle(allSelected: false, onBySite: {}, onAll: { model.selectAll(org) })
            title(org.name)
            if !sites.isEmpty {
                FilterField(text: $model.filterText, placeholder: "Filter sites...")
            }
            ForEach(sites.filter { model.matchesFilter($0.name) }, id: \.id) { site in
                navButton(site.name) { model.selectSite(site, of: org) }
            }
        case .scans(let org, let site, let entries, let progress):
            if site != nil {
                navButton("← Sites", color: Color(.systemGray)) { model.showSites(of: org) }
            } else {
                navButton("← Organizations", color: Color(.systemGray)) { model.backToOrganizations() }
            }
            modeToggle(allSelected: site == nil,
                       onBySite: { model.showSites(of: org) },
                       onAll: { if site != nil { model.selectAll(org) } })
            title(site?.name ?? "All playbacks in \(org.name)")
            if let progress {
                Text("Loaded \(progress.loaded) / \(progress.total) sites...")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if entries.isEmpty {
                Text("No validation scans").foregroundColor(.secondary)
            }
            if !entries.isEmpty {
                FilterField(text: $model.filterText, placeholder: "Filter playbacks...")
            }
            ForEach(entries.filter { model.matchesFilter($0.scan.displayName) }, id: \.scan.id) { entry in
                scanButton(entry, showSite: site == nil)
            }
        case .downloaded(let scans, let error):
            let listed = scans.filter { library.downloads[$0.id] != nil }
            navButton("← Organizations", color: Color(.systemGray)) { model.backToOrganizations() }
            title("Downloaded playbacks")
            if let error {
                Text(error).foregroundColor(.red)
            } else if listed.isEmpty {
                Text("No downloaded playbacks").foregroundColor(.secondary)
            }
            ForEach(listed) { scan in
                scanButton(ScanEntry(scan: scan, siteName: ""), showSite: false)
            }
        }
    }

    /// Opens the downloaded scans, and clears the whole playback cache when it holds anything.
    private var cacheSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Cache", systemImage: "gearshape")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.secondary)
            navButton("Downloaded playbacks") { model.showDownloaded() }
            if library.isClearing {
                Text("Clearing…")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            } else if library.hasCachedEntries {
                navButton("Clear all cache", color: Color(.systemRed)) {
                    if library.downloadingCount > 0 {
                        isConfirmingClear = true
                    } else {
                        library.clearCache()
                    }
                }
            }
            if let error = library.clearError {
                Text(error).font(.system(size: 12)).foregroundColor(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 24)
    }

    private var clearPrompt: String {
        PlaybackLibrary.cancelDownloadsPrompt(
            count: library.downloadingCount, question: "Clear the cache anyway?")
    }

    /// A scan button with its download progress as a fill and a delete button at its end.
    private func scanButton(_ entry: ScanEntry, showSite: Bool) -> some View {
        let scan = entry.scan
        let download = library.downloads[scan.id]
        let isActive = library.activeScan?.id == scan.id
        let progress: Double
        let status: String?
        var showsSpinner = false
        switch download {
        case .downloading(let value):
            progress = value
            status = "Downloading \(Int(value * 100))%"
            showsSpinner = value <= 0
        case .cached:
            progress = 1
            status = "Downloaded"
        case .opening:
            progress = 1
            status = "Opening…"
            showsSpinner = true
        case .incomplete:
            progress = 0
            status = "Incomplete"
        case .failed(let reason):
            progress = 0
            status = "Failed: \(reason)"
        case nil:
            progress = 0
            status = nil
        }
        let fileInfo = library.fileInfos[scan.id]
        let duration = (fileInfo.map(\.duration).flatMap { $0 > 0 ? $0 : nil } ?? scan.duration)
            .map { " (\(Duration.seconds($0).formatted(.time(pattern: .minuteSecond))))" } ?? ""
        let frames = fileInfo.flatMap { $0.frameCount > 0 ? "\($0.frameCount) frames" : nil }
        let subtitle = [showSite ? entry.siteName : nil, frames, isActive ? "Playing" : status]
            .compactMap { $0 }
            .joined(separator: " · ")

        return HStack {
            Button {
                library.select(scan)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(scan.displayName + duration)
                        .font(.system(size: 16, weight: .medium))
                        .lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.system(size: 12)).opacity(0.8)
                    }
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showsSpinner {
                ProgressView().tint(.white)
            }
            if library.canDelete(scan.id) {
                Button {
                    library.delete(scan.id)
                } label: {
                    Image(systemName: "trash").foregroundColor(.white)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete from cache")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(alignment: .leading) {
            GeometryReader { geometry in
                Color.blue.opacity(0.5).frame(width: geometry.size.width * progress)
            }
        }
        .background(isActive ? Color(.systemGreen) : Color(.darkGray))
        .cornerRadius(8)
        .onAppear { library.loadFileInfo(for: scan.id) }
    }

    private func modeToggle(allSelected: Bool, onBySite: @escaping () -> Void,
                            onAll: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            toggleButton("By site", selected: !allSelected, action: onBySite)
            toggleButton("All playbacks", selected: allSelected, action: onAll)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toggleButton(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(label, action: action)
            .buttonStyle(.borderedProminent)
            .tint(selected ? .blue : Color(.systemGray))
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 16, weight: .semibold))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func navButton(_ text: String, color: Color = .blue, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(color)
                .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
}

/// A playable scan and the site it belongs to.
private struct ScanEntry {
    let scan: PlaybackScan
    let siteName: String
}

/// Browses an organization's validation scans by site, or all of them at once, through the
/// library's `NSDKSession`.
@MainActor
private final class PlaybackSelectModel: ObservableObject {
    enum BrowseState {
        case loading
        case error(String)
        case organizations([OrganizationInfo])
        case sites(OrganizationInfo, [SiteInfo])

        /// `site` is nil for every site in the organization; `progress` counts the sites that have
        /// answered while those load, and is nil once loading ends.
        case scans(OrganizationInfo, SiteInfo?, [ScanEntry], progress: (loaded: Int, total: Int)?)

        /// Every cached scan, or `error` if the cache could not be listed.
        case downloaded([PlaybackScan], error: String?)
    }

    private static let maxConcurrentRequests = 6

    @Published private(set) var state = BrowseState.loading

    /// Case-insensitive name filter for the shown list, kept from a site's scans to All playbacks.
    @Published var filterText = ""

    private let sitesSession: NSDKSitesSession
    private let retryHelper: AuthRetryHelper
    private var task: Task<Void, Never>?
    private var orgs: [OrganizationInfo] = []
    private var sites: [SiteInfo] = []

    private let library: PlaybackLibrary

    init(library: PlaybackLibrary) {
        self.library = library
        let session = library.acquireSession()
        sitesSession = session.acquireSitesSession()
        retryHelper = AuthRetryHelper(session: session)
    }

    /// Lists the user's organizations.
    func loadOrganizations() {
        load { [self] in
            orgs = try await retryHelper.withRetry {
                try await sitesSession.requestSelfOrganizationInfo()
            }.organizations
            return .organizations(orgs)
        }
    }

    func selectOrganization(_ org: OrganizationInfo) {
        filterText = ""
        load { [self] in try await loadSites(org) }
    }

    func selectSite(_ site: SiteInfo, of org: OrganizationInfo) {
        filterText = ""
        load { [self] in
            let entries = try await scans(for: site)
            return .scans(org, site, entries, progress: nil)
        }
    }

    /// Lists the validation scans of every site in `org` newest first, adding each site's scans as
    /// its response arrives, with at most six requests in flight. Skips sites that fail, and fails
    /// only if every site fails.
    func selectAll(_ org: OrganizationInfo) {
        if case .sites = state {
            filterText = ""
        }
        let sites = sites
        load { [self] in
            var entries: [ScanEntry] = []
            var loaded = 0
            var succeeded = 0
            var firstFailure: Error?
            state = .scans(org, nil, [], progress: (0, sites.count))
            await withTaskGroup(of: Result<[ScanEntry], Error>.self) { group in
                var pending = sites[...]
                func addNext() {
                    guard !Task.isCancelled, let site = pending.popFirst() else { return }
                    group.addTask {
                        do {
                            return .success(try await self.scans(for: site))
                        } catch {
                            print("[PlaybackSelect] Failed to list scans for site \(site.name): \(error)")
                            return .failure(error)
                        }
                    }
                }
                for _ in 0..<Self.maxConcurrentRequests { addNext() }
                for await result in group {
                    addNext()
                    switch result {
                    case .success(let siteEntries):
                        succeeded += 1
                        entries = (entries + siteEntries).sorted {
                            ($0.scan.createdDate ?? .distantPast) > ($1.scan.createdDate ?? .distantPast)
                        }
                    case .failure(let error):
                        firstFailure = firstFailure ?? error
                    }
                    loaded += 1
                    guard !Task.isCancelled else { continue }
                    state = .scans(org, nil, entries, progress: (loaded, sites.count))
                }
            }
            try Task.checkCancellation()
            if succeeded == 0, let firstFailure {
                throw firstFailure
            }
            return .scans(org, nil, entries, progress: nil)
        }
    }

    /// Lists the cache, then fills in each scan's info; rows keep their places until every lookup
    /// ends, then sort.
    func showDownloaded() {
        load { [self] in
            let scanIds: [String]
            do {
                scanIds = try await library.loadCached().sorted()
            } catch {
                print("[PlaybackSelect] Failed to list the playback cache: \(error)")
                return .downloaded([], error: "Could not list the cache: \(error.localizedDescription)")
            }
            try Task.checkCancellation()
            var scans = scanIds.map { PlaybackScan(id: $0) }
            state = .downloaded(scans, error: nil)
            await withTaskGroup(of: PlaybackScan?.self) { group in
                var pending = scanIds[...]
                func addNext() {
                    guard !Task.isCancelled, let scanId = pending.popFirst() else { return }
                    group.addTask { await self.lookUp(scanId) }
                }
                for _ in 0..<Self.maxConcurrentRequests { addNext() }
                for await scan in group {
                    addNext()
                    guard let scan, let index = scans.firstIndex(where: { $0.id == scan.id }) else {
                        continue
                    }
                    scans[index] = scan
                    guard !Task.isCancelled else { continue }
                    state = .downloaded(scans, error: nil)
                }
            }
            try Task.checkCancellation()
            return .downloaded(scans.sorted(by: Self.isNewer), error: nil)
        }
    }

    func showSites(of org: OrganizationInfo) {
        task?.cancel()
        filterText = ""
        state = .sites(org, sites)
    }

    func backToOrganizations() {
        task?.cancel()
        filterText = ""
        state = .organizations(orgs)
    }

    func matchesFilter(_ name: String) -> Bool {
        filterText.isEmpty || name.localizedCaseInsensitiveContains(filterText)
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    private func loadSites(_ org: OrganizationInfo) async throws -> BrowseState {
        sites = try await retryHelper.withRetry {
            try await sitesSession.requestSitesForOrganization(orgId: org.id)
        }.sites
        return .sites(org, sites)
    }

    /// Lists `site`'s validation scans, marking the ones already in the cache as downloaded.
    private func scans(for site: SiteInfo) async throws -> [ScanEntry] {
        let scans = try await retryHelper.withRetry {
            try await sitesSession.requestScansForSite(siteId: site.id)
        }.scans.filter { $0.scanType == .validation }
        library.seedCached(scans.map(\.id))
        return scans.map { ScanEntry(scan: PlaybackScan($0), siteName: site.name) }
    }

    /// `scanId`'s scan info, or nil if Sites cannot return it.
    private func lookUp(_ scanId: String) async -> PlaybackScan? {
        do {
            return try await retryHelper.withRetry {
                try await sitesSession.requestScanInfo(scanId: scanId)
            }.scans.first.map { PlaybackScan($0) }
        } catch is CancellationError {
            return nil
        } catch {
            print("[PlaybackSelect] Failed to look up scan \(scanId): \(error)")
            return nil
        }
    }

    /// Orders newest first, scans with no created date last, then by ID.
    private static func isNewer(_ a: PlaybackScan, than b: PlaybackScan) -> Bool {
        switch (a.createdDate, b.createdDate) {
        case let (aDate?, bDate?) where aDate != bDate:
            return aDate > bDate
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return a.id < b.id
        }
    }

    private static func errorMessage(_ error: Error) -> String {
        if case .httpForbidden? = error as? SitesResult.Error {
            return "Error: HTTP_FORBIDDEN. Playback Select needs a token that can list scans; a " +
                "token scoped to site-assets:read cannot."
        }
        return "Error: \(error.localizedDescription)"
    }

    /// Runs `work` as the one in-flight load, replacing any earlier one, and shows its state.
    private func load(_ work: @escaping () async throws -> BrowseState) {
        task?.cancel()
        state = .loading
        task = Task { [weak self] in
            let next: BrowseState
            do {
                next = try await work()
            } catch is CancellationError {
                return
            } catch {
                next = .error(Self.errorMessage(error))
            }
            guard let self, !Task.isCancelled else { return }
            self.state = next
        }
    }
}
