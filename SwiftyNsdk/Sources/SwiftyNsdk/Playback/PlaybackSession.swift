import Foundation
import UIKit
import simd
import CoreGraphics
import CoreVideo
import ARKit
/// A session that plays back frame metadata and images from a loaded dataset.
/// 
/// Playback runs on a background queue and continuously loops through frames at the
/// framerate specified in the dataset. The session notifies its delegate of each frame update.
public class PlaybackSession : ARSession, @unchecked Sendable {
    private var currentFrameIndex: Int = 0
    private let playbackQueue = DispatchQueue(label: "com.ardk.playback", qos: .userInitiated)
    private var isPlaying: Bool = false
    private let playbackDataset: PlaybackDataset
    
    /// Delegate that receives frame updates during playback
    open var playbackDelegate: (any PlaybackSessionDelegate)?
    open var playbackRenderer: (any PlaybackRenderer)?

    /// Initializes a new playback session with an existing dataset.
    /// 
    /// - Parameter dataset: The playback dataset to use
    public init(dataset: PlaybackDataset) {
        self.playbackDataset = dataset
    }
    
    /// Infinite loop that retrieves and processes the next frame.
    /// 
    /// Runs on the playback queue and continuously cycles through frames, sleeping
    /// for the frame interval between updates. Automatically loops back to frame 0
    /// after reaching the end of the dataset.
    private func playbackLoop() {
        while isPlaying {
            do {
                let metadata = try playbackDataset.getFrameDataAtIndex(index: currentFrameIndex)
                let image = try playbackDataset.getFrameImageAtIndex(index: currentFrameIndex)
                let depthData = try playbackDataset.getDepthDataAtIndex(index: currentFrameIndex)
                let depthConfidence = try playbackDataset.getDepthConfidenceAtIndex(index: currentFrameIndex)
                
                let frame = NsdkPlaybackFrame(
                    metadata: metadata,
                    image: image,
                    depthData: depthData,
                    depthConfidence: depthConfidence
                )
                
                // Capture delegate and renderer references before dispatching
                let delegate = self.playbackDelegate
                let renderer = self.playbackRenderer

                DispatchQueue.main.async {
                    delegate?.playbackSession(self, didUpdate: frame)
                    renderer?.renderFrame(frame)
                }

                // Move to next frame, looping back to start if needed
                currentFrameIndex = (currentFrameIndex + 1) % playbackDataset.frameCount
                Thread.sleep(forTimeInterval: playbackDataset.frameInterval)
            } catch {
                print("PlaybackSession: Error retrieving frame at index \(currentFrameIndex): \(error.localizedDescription)")
                // Skip to next frame on error
                currentFrameIndex = (currentFrameIndex + 1) % playbackDataset.frameCount
                Thread.sleep(forTimeInterval: playbackDataset.frameInterval)
            }
        }
    }
    
    /// Starts playback of the dataset.
    /// 
    /// Playback runs asynchronously on a background queue. Call `pause()` to stop playback.
    public override func run(_ configuration: ARConfiguration, options: ARSession.RunOptions = []) {
        isPlaying = true
        playbackQueue.async { [weak self] in
            self?.playbackLoop()
        }
    }

    /// Pauses playback.
    /// 
    /// The playback loop will exit on the next iteration after this is called.
    /// The current frame index is preserved, so calling `run()` again will resume
    /// from the same position.
    public override func pause() {
        isPlaying = false
    }
    
    /// Checks if the playback dataset has depth data from a LiDAR source.
    /// 
    /// - Returns: `true` if `depthSource` exists and equals "lidar", `false` otherwise
    public func hasDepth() -> Bool {
        return playbackDataset.hasDepth()
    }
    
    deinit {
        isPlaying = false
    }
}

/// Delegate protocol for receiving frame updates during playback.
public protocol PlaybackSessionDelegate: Sendable {
    /// Called each time a new frame is ready during playback.
    /// 
    /// This method is called on the playback queue, so any UI updates should be
    /// dispatched to the main queue.
    /// 
    /// - Parameters:
    ///   - session: The playback session that generated the update
    ///   - frame: The frame data including metadata, image, and depth buffers
    func playbackSession(_ session: PlaybackSession, didUpdate frame: NsdkPlaybackFrame)
}

