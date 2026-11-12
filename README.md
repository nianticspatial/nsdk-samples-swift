# NSDK Swift Samples

A SwiftUI app demonstrating the Niantic Spatial SDK (NSDK) — depth, occlusion, meshing,
semantic segmentation, device mapping, capture, and VPS2 localization.

## Quick Links
* [Documentation](https://www.nianticspatial.com/docs/nsdk/?platform=swift)
* [NSDK API Reference](https://www.nianticspatial.com/docs/api/swift/)
* [Sample project walkthroughs](https://www.nianticspatial.com/docs/nsdk/sample_projects/?platform=swift)
* [NSDK Swift package](https://github.com/nianticspatial/nsdk-library-xcframework)

## Requirements

* Xcode 26 or later
* [Git LFS](https://git-lfs.com) — required to check out any LFS-tracked assets
* An ARKit-capable device running iOS 18.0 or later — the samples use live camera and
  sensor data and do not run in the Simulator
* A Niantic Spatial access token, for the samples that use VPS2 or Sites

## Getting Started

1. Clone this repository.
2. Fetch any LFS-tracked assets:

   ```sh
   git lfs install
   git lfs pull
   ```

3. Open `NsdkSamples/NsdkSamples.xcodeproj`. Xcode resolves the NSDK Swift package on
   first open.
4. Set your access token in `NsdkSamples/NsdkSamples/Auth/AuthConstants.swift`:

   ```swift
   static let accessToken: String = "YOUR_TOKEN_HERE"
   ```

   To create a token, sign in to [Scaniverse Web](https://scaniverse.nianticspatial.com),
   open **Developer tokens** for your organization, and select **New developer token**.
   Copy it before closing the dialog — it is shown only once — and note that it expires on
   the date you choose. See the
   [setup guide](https://www.nianticspatial.com/docs/nsdk/setup/?platform=swift) for more.
   Playback Select lists your organization's scans, which a token scoped only to
   `site-assets:read` cannot do; the request fails with `httpForbidden`.
5. Select your device and run.

The app opens on a list of samples; each entry launches one feature.

### Switching between versions

Xcode caches compiled modules per project. If a build fails with unexpected NSDK errors
after changing version, clean the build folder: **Product → Clean Build Folder** (⇧⌘K).

## What's included

| Sample | What it shows |
|---|---|
| Auth | Authenticating the SDK with an access token |
| Depth | Per-frame depth estimation |
| Occlusion | Occluding virtual content with estimated depth |
| Meshing | Real-time mesh reconstruction of the environment |
| Scene segmentation | Semantic segmentation of the camera feed |
| Device mapping | Building and saving a device map |
| VPS2 | Visual Positioning System localization |
| VPS Debugger | Diagnostics for VPS2 localization |
| Sites | Discovering and loading nearby sites |
| Capture | Recording sessions for playback |

## License

See [LICENSE](LICENSE).
