// Copyright 2026 Niantic Spatial.

import SwiftUI
import UIKit
import NSDK
import Combine
import simd

struct DeviceMappingView: View {

    let arManager: ARManager

    // MARK: - SDK Sessions

    @State private var mappingSession: NSDKDeviceMappingSession?
    @State private var mapStorage: NSDKMapStorage?
    @State private var vps2Session: NSDKVps2Session?

    // MARK: - ViewModel & Renderer

    @State private var viewModel: DeviceMappingViewModel?
    @State private var pointCloudRenderer: PointCloudRenderer?

    // MARK: - UI State

    @State private var isMapping = false
    @State private var isVpsRunning = false
    @State private var statusText = ""
    @State private var statusColor: Color = .white
    @State private var showSaveButton = false
    @State private var showLoadButton = false
    @State private var showSaveDialog = false
    @State private var saveFileName = ""
    @State private var savedMaps: [String] = []
    @State private var showMapList = false
    @State private var isHelpVisible = false
    @State private var isSaving = false
    @State private var pendingMapBuffer: NSDKBuffer?

    // MARK: - Help

    private static let helpText =
        "Device Mapping Sample Help\n\n" +
        "This sample lets you anchor content to the world by scanning the local area and " +
        "saving a device map. These maps are saved to the device and can be shared with others.\n\n" +
        "TO USE:\n" +
        "Press \"Start Mapping\" to begin scanning the area around you. Once you're done, press " +
        "\"Stop Mapping\" to finalize the map. Then press \"Save Map\" to save the file.\n\n" +
        "To view existing maps, press \"Load Map\" to view the list of maps saved on the device " +
        "and select one to localize to."

    // MARK: - Body

    var body: some View {
        ZStack {
            NSDKViewRepresentable(arManager: arManager)
                .ignoresSafeArea()

            // Subscribe to the ViewModel. Color.clear is just a transparent, non-interactive
            // host for the onReceive modifiers (viewModel is optional, so we gate with `if let`)
            // and must not obscure or block the views below.
            if let viewModel {
                Color.clear
                    .allowsHitTesting(false)

                    // Root anchor became available → start VPS tracking.
                    .onReceive(viewModel.$rootAnchorPayload) { payload in
                        guard let payload else { return }
                        _ = try? vps2Session?.trackAnchor(payload: payload)
                    }

                    // Rebuild point cloud whenever the VM delivers new points.
                    .onReceive(viewModel.$points) { points in
                        guard let transform = viewModel.anchorTransform, !points.isEmpty else { return }
                        pointCloudRenderer?.visualize(points: points, anchorTransform: transform)
                        statusText = "Localized — \(points.count) points"
                        statusColor = .green
                        showSaveButton = !isMapping
                    }

                    // Reposition the existing anchor entity each frame. No geometry rebuild.
                    .onReceive(viewModel.$anchorTransform) { transform in
                        guard let transform else { return }
                        pointCloudRenderer?.updateAnchorTransform(transform)
                    }
            }

            VStack(spacing: 0) {
                ARStatusView(frameState: arManager.frameState)

                HelpOverlayView(helpText: Self.helpText, isVisible: $isHelpVisible)

                if showMapList {
                    savedMapsList
                }

                Spacer()

                if !statusText.isEmpty {
                    Text(statusText)
                        .font(.system(size: 14))
                        .foregroundStyle(statusColor)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                }

                bottomControls
            }
        }
        .navigationTitle("Device Mapping")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Help") {
                    isHelpVisible.toggle()
                }
            }
        }
        .onAppear { setup() }
        .onDisappear { teardown() }
        .alert("Save Map", isPresented: $showSaveDialog) {
            TextField("Filename", text: $saveFileName)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("Cancel", role: .cancel) { }
            Button("Save") { performSave() }
        } message: {
            Text("Enter a filename.")
        }
    }

    // MARK: - Saved Maps List

    private var savedMapsList: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(savedMaps, id: \.self) { name in
                    mapCard(fileName: name)
                }
            }
            .padding(20)
        }
    }

    private func mapCard(fileName: String) -> some View {
        Button {
            loadMap(fileName: fileName)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Text(fileName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.leading)

                Spacer()

                Group {
                    if let image = loadThumbnail(fileName: fileName) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                    } else {
                        Color(.systemGray5)
                    }
                }
                .frame(width: 40, height: 80)
                .cornerRadius(8)
                .clipped()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.systemBackground))
            .cornerRadius(12)
            .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Bottom Controls

    private var bottomControls: some View {
        HStack {
            // Save and Load occupy the same slot: only one is ever visible at a time.
            if showSaveButton {
                actionButton("Save Map", color: .green, action: handleSave)
            } else if showLoadButton {
                actionButton("Load Map", color: .purple, action: handleLoad)
            }

            Spacer()

            actionButton(isMapping ? "Stop Mapping" : "Start Mapping", color: .blue) {
                if isMapping { stopMapping() } else { startMapping() }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
    }

    private func actionButton(_ title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 120, height: 44)
                .background(color)
                .cornerRadius(8)
        }
    }

    // MARK: - Screen Lifecycle

    private func setup() {
        guard viewModel == nil else { return }

        let nsdkSession = arManager.nsdkSession
        let mapping = nsdkSession.acquireDeviceMappingSession()
        let storage = nsdkSession.acquireMapStorage()
        let vps = nsdkSession.acquireVps2Session()

        var vpsConfig = NSDKVps2Session.Configuration()
        vpsConfig.deviceMapLocalizationEnabled = true
        vpsConfig.universalLocalizationEnabled = false
        vpsConfig.vpsMapLocalizationEnabled = false
        try? vps.configure(with: vpsConfig)

        mappingSession = mapping
        mapStorage = storage
        vps2Session = vps

        pointCloudRenderer = PointCloudRenderer(nsdkView: arManager.nsdkView)
        viewModel = DeviceMappingViewModel(
            mappingSession: mapping,
            mapStorage: storage,
            vps2Session: vps
        )

        savedMaps = listSavedMaps()
        showLoadButton = !savedMaps.isEmpty

        arManager.startSession()
    }

    private func teardown() {
        stopAllSessions()
        pointCloudRenderer?.clear()
        arManager.stopSession()
    }

    // MARK: - Mapping Lifecycle

    private func startMapping() {
        viewModel?.reset()
        if isVpsRunning {
            vps2Session?.stop()
            isVpsRunning = false
        }

        mappingSession?.start()
        mappingSession?.startMapping()
        vps2Session?.start()
        isVpsRunning = true
        isMapping = true
        showLoadButton = false
        showSaveButton = false
        statusText = "Running Device Mapping"
        statusColor = .white
        pointCloudRenderer?.clear()
    }

    private func stopMapping() {
        mappingSession?.stopMapping()
        mappingSession?.stop()
        vps2Session?.stop()
        isVpsRunning = false
        isMapping = false
        showSaveButton = !(viewModel?.points.isEmpty ?? true)
        statusText = ""
    }

    private func stopAllSessions() {
        if isMapping {
            stopMapping()
        } else if isVpsRunning {
            vps2Session?.stop()
            isVpsRunning = false
        }
    }

    // MARK: - Save

    private func handleSave() {
        guard !isSaving, let storage = mapStorage else { return }
        isSaving = true
        statusText = "Preparing map…"
        statusColor = .white

        // mapStorage.mapData() serializes the native map, so run it off the main thread
        // to avoid blocking the AR session and dropping tracking.
        DispatchQueue.global(qos: .userInitiated).async {
            let buffer = storage.mapData()
            DispatchQueue.main.async {
                isSaving = false
                statusText = ""
                guard let buffer else {
                    print("[DeviceMappingView] No map data available to save")
                    return
                }
                pendingMapBuffer = buffer
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyyMMdd-HHmm"
                saveFileName = "Map-\(formatter.string(from: Date()))"
                showSaveDialog = true
            }
        }
    }

    private func performSave() {
        let name = saveFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let buffer = pendingMapBuffer else { return }
        saveMapToDisk(buffer: buffer, fileName: name)
        pendingMapBuffer = nil
    }

    private func saveMapToDisk(buffer: NSDKBuffer, fileName: String) {
        let mapData = Data(bytes: buffer.data, count: Int(buffer.dataSize))
        let finalName = fileName.hasSuffix(".map") ? fileName : "\(fileName).map"

        // Capture the screenshot on the main thread before dispatching I/O.
        let screenshotData = captureScreenshotData()

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let dir = try appSupportDirectory()
                try mapData.write(to: dir.appendingPathComponent(finalName))
                if let pngData = screenshotData {
                    try? pngData.write(to: dir.appendingPathComponent("\(fileName).png"))
                }
                DispatchQueue.main.async {
                    showSaveButton = false
                    showLoadButton = true
                    savedMaps = listSavedMaps()
                    statusText = "Map saved"
                    statusColor = .green
                }
            } catch {
                print("[DeviceMappingView] Save failed: \(error)")
            }
        }
    }

    private func captureScreenshotData() -> Data? {
        let view = arManager.nsdkView
        let maxHeight: CGFloat = 320
        var size = view.bounds.size
        guard size.width > 0, size.height > 0 else { return nil }
        if size.height > maxHeight {
            let scale = maxHeight / size.height
            size = CGSize(width: size.width * scale, height: maxHeight)
        }
        return UIGraphicsImageRenderer(size: size).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }.pngData()
    }

    // MARK: - Load

    private func handleLoad() {
        savedMaps = listSavedMaps()
        showMapList = true
        statusText = "Found \(savedMaps.count) map(s)"
        statusColor = .white
    }

    private func loadMap(fileName: String) {
        showMapList = false

        // Stop VPS before touching map storage: clear() must not be called while VPS
        // is running, and calling start() on an already-running session causes a
        // double-registration assertion crash in the native map data store module.
        if isVpsRunning {
            vps2Session?.stop()
            isVpsRunning = false
        }
        mapStorage?.clear()

        do {
            let finalName = fileName.hasSuffix(".map") ? fileName : "\(fileName).map"
            let data = try Data(contentsOf: try appSupportDirectory().appendingPathComponent(finalName))
            try mapStorage?.addMap(map: NSDKBuffer(data: data))

            vps2Session?.start()
            isVpsRunning = true

            // Clear stale state, then load the root anchor from the freshly added map. The
            // resulting rootAnchorPayload change reaches the live subscription, which registers
            // the anchor with VPS. Done after start() so tracking registers against a running session.
            viewModel?.reset()
            viewModel?.loadRootAnchorFromStorage()

            showLoadButton = false
            statusText = "Tracking anchor for localization…"
            statusColor = .orange
        } catch {
            print("[DeviceMappingView] Failed to load map: \(error)")
        }
    }

    private func loadThumbnail(fileName: String) -> UIImage? {
        let baseName = fileName.hasSuffix(".map") ? String(fileName.dropLast(4)) : fileName
        guard let dir = try? appSupportDirectory() else { return nil }
        let url = dir.appendingPathComponent("\(baseName).png")
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let image = UIImage(data: data) else { return nil }
        return image
    }

    // MARK: - Disk Helpers

    nonisolated private func appSupportDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let dir = base.appendingPathComponent(
            Bundle.main.bundleIdentifier ?? "com.nianticspatial.nsdk-swift"
        )
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private func listSavedMaps() -> [String] {
        guard let dir = try? appSupportDirectory() else { return [] }
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        )) ?? []
        return urls.filter { $0.pathExtension == "map" }.map { $0.lastPathComponent }
    }
}
