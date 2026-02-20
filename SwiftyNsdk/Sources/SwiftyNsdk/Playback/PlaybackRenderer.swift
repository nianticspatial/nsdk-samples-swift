import CoreGraphics

@MainActor
public protocol PlaybackRenderer
{
    func renderFrame(_ frame: NsdkPlaybackFrame)
}
