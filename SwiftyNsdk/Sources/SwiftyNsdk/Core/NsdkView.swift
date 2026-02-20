//
//  NsdkView.swift
//  SwiftyNsdk
//
// The NsdkView supports both live ARKit sessions and Nsdk recorder v2 playback Sessions
import ARKit
import RealityKit
import UIKit

public class NsdkView : ARView {
    public enum SessionMode {
        case live(ARSession)
        case playback(PlaybackSession)
    }
    
    public let sessionMode: SessionMode
    
    /// Returns whether depth data is available for this session
    public var hasDepth: Bool {
        switch sessionMode {
        case .playback(let playbackSession):
            return playbackSession.hasDepth()
        case .live:
            return ARUtils.isLidarAvailable()
        }
    }
    
    /// Initialize in live AR mode
    public init() {
        let liveSession = ARSession()
        sessionMode = .live(liveSession)
        super.init(frame: .zero)
        self.session = liveSession
    }
    
    /// Initialize in playback mode with a recorded dataset
    public init(dataset: PlaybackDataset) {
        let playbackSession = PlaybackSession(dataset: dataset)
        sessionMode = .playback(playbackSession)
        super.init(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        self.session = playbackSession
    }
    
    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @available(*, unavailable)
    required init(frame: CGRect) {
        fatalError("init(frame:) is not supported. Use init() or init(dataset:) instead.")
    }
    
    public func setup(in view: UIView) {
        // setup playback objects first so the background renderer renders behind everything
        if case .playback(let playbackSession) = sessionMode {
            playbackSession.playbackRenderer = PlaybackView(in: view, arView: self)
        }
        self.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(self)
        NSLayoutConstraint.activate([
            self.topAnchor.constraint(equalTo: view.topAnchor),
            self.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            self.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            self.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }
    
    public func setDelegate(nsdkSessionDelegate: NsdkSessionDelegate) {
        switch sessionMode {
        case .live(let liveSession):
            liveSession.delegate = nsdkSessionDelegate
        case .playback(let playbackSession):
            playbackSession.playbackDelegate = nsdkSessionDelegate
        }
    }
}
