// Copyright 2026 Niantic Spatial.

import SwiftUI
import NSDK
import Combine

struct CaptureView: View {

    let arManager: ARManager

    // MARK: - State

    @State private var isCapturing = false
    @State private var isSaving = false
    @State private var statusText = ""
    @State private var exportProgress: Float = 0
    @State private var showProgress = false
    @State private var isHelpVisible = false
    @State private var shareFileURL: URL?
    @State private var scanningSession: NSDKScanningSession?
    @State private var viewModel: CaptureViewModel?
    @State private var exportTask: Task<Void, Never>?

    // MARK: - Constants

    private static let helpText =
        "Capture Sample Help\n\n" +
        "This sample creates and saves a recording that can later be used for NSDK Playback.\n\n" +
        "TO USE:\n" +
        "Press 'Start Capture' to start capturing. A simple visualization will indicate the parts " +
        "covered by the capture, with red stripes indicating the missed areas. After the capture " +
        "stops, the capture will automatically be exported to Niantic Spatial's recorder format " +
        "and you can use the result archive for NSDK Playback."

    // MARK: - Body

    var body: some View {
        ZStack {
            // Bottom layer: AR camera feed (full screen)
            NSDKViewRepresentable(arManager: arManager)
                .ignoresSafeArea()

            // Middle layer: scanning visualization (full screen)
            if let viewModel {
                TextureViewRepresentable(
                    viewModel: viewModel,
                    vertexShader: "scanningVertexShader",
                    fragmentShader: "scanningFragmentShader",
                    opacity: 1.0,
                    isVisible: isCapturing
                )
                .ignoresSafeArea()
            }

            // Top layer: SwiftUI controls
            VStack {
                ARStatusView(frameState: arManager.frameState)

                HelpOverlayView(
                    helpText: Self.helpText,
                    isVisible: $isHelpVisible
                )

                Spacer()

                // Bottom controls
                VStack(spacing: 0) {
                    // Status label
                    if !statusText.isEmpty {
                        Text(statusText)
                            .font(.system(size: 14))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 8)
                    }

                    // Progress bar
                    if showProgress {
                        ProgressView(value: exportProgress)
                            .progressViewStyle(.linear)
                            .tint(.white)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 16)
                    }

                    // Capture button
                    Button {
                        handleCaptureButtonTap()
                    } label: {
                        Text(captureButtonTitle)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 200, height: 44)
                            .background(Color.blue)
                            .cornerRadius(8)
                    }
                    .disabled(isSaving)
                    .padding(.bottom, 20)
                }
            }
        }
        .navigationTitle("Capture")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Help") {
                    isHelpVisible.toggle()
                }
            }
        }
        .sheet(item: $shareFileURL) { url in
            ActivityViewController(activityItems: [url])
        }
        .onAppear {
            guard scanningSession == nil else { return }

            // Scanning session: acquire and configure.
            // Not started until the user taps "Start Capture". Unlike depth/semantics, which
            // start immediately, scanning is an explicit user action.
            let session = arManager.nsdkSession.acquireScanningSession()
            var config = NSDKScanningSession.Configuration()
            config.enableRaycastVisualization = true
            config.enableVoxelVisualization = false
            config.generateDepthsIfLidarUnavailable = true
            do {
                try session.configure(with: config)
            } catch {
                print("[CaptureView] Failed to configure scanning session: \(error)")
            }

            // ViewModel subscribes to session.$latestRaycastBuffer internally.
            viewModel = CaptureViewModel(session: session)
            scanningSession = session

            arManager.startSession()
        }
        .onDisappear {
            exportTask?.cancel()
            exportTask = nil
            scanningSession?.stop()
            arManager.stopSession()
        }
    }

    // MARK: - Button Title

    private var captureButtonTitle: String {
        if isSaving { return "Saving..." }
        return isCapturing ? "Stop Capture" : "Start Capture"
    }

    // MARK: - Actions

    private func handleCaptureButtonTap() {
        if isCapturing {
            stopCapture()
        } else {
            startCapture()
        }
    }

    private func startCapture() {
        isCapturing = true
        statusText = ""
        scanningSession?.start()
    }

    private func stopCapture() {
        isCapturing = false
        isSaving = true

        guard let scanningSession else { return }
        let nsdkSession = arManager.nsdkSession

        // `saveCurrentScan` and `export` hand their work to the native layer and poll it between
        // suspensions, so this task can stay on the main actor and update the UI directly.
        exportTask = Task(priority: .userInitiated) {
            let saveInfo: NSDKScanningSession.SaveInfo
            do {
                saveInfo = try await scanningSession.saveCurrentScan(timeout: 20)
            } catch {
                guard !Task.isCancelled else { return }
                statusText = "Failed to save capture."
                finishCaptureFlow()
                return
            }

            guard !Task.isCancelled else { return }

            exportProgress = 0
            showProgress = true
            statusText = "Archiving capture..."
            let exporter = nsdkSession.acquireRecordingExporter()

            var archivePath: String?
            do {
                archivePath = try await exporter.export(
                    scanDirPath: saveInfo.path,
                    scanId: saveInfo.scanId,
                    exportAsVideo: false,
                    // The exporter polls off the main actor and reports progress from there, so
                    // hop back to update the UI.
                    progressCallback: { @Sendable progress in
                        DispatchQueue.main.async {
                            exportProgress = progress
                        }
                    }
                )
            } catch {
                if !Task.isCancelled {
                    print("[CaptureView] Archive failed: \(error)")
                }
            }

            guard !Task.isCancelled else { return }

            showProgress = false
            finishCaptureFlow()
            if let archivePath {
                statusText = "Capture saved and archived."
                if FileManager.default.fileExists(atPath: archivePath) {
                    shareFileURL = URL(fileURLWithPath: archivePath)
                }
            } else {
                statusText = "Failed to archive capture."
            }
        }
    }

    private func finishCaptureFlow() {
        scanningSession?.stop()
        isSaving = false
    }
}

// MARK: - Share Sheet

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

private struct ActivityViewController: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        if let popover = controller.popoverPresentationController {
            popover.permittedArrowDirections = []
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
