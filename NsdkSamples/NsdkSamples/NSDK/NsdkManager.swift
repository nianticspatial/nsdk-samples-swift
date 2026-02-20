import ARKit
import SwiftyNsdk


extension UnsafePointer where Pointee: Numeric {
    init(buffer: CVPixelBuffer) {
        // Check if it's a planar buffer
        let planeCount = CVPixelBufferGetPlaneCount(buffer)
        let ptr: UnsafeMutableRawPointer

        if planeCount > 0 {
            // Planar buffer (e.g., YUV)
            ptr = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!
        } else {
            // Non-planar buffer (e.g., depth)
            ptr = CVPixelBufferGetBaseAddress(buffer)!
        }

        self = UnsafePointer(ptr.bindMemory(to: Pointee.self, capacity: 4))
    }
}


class NsdkManager: NSObject, CLLocationManagerDelegate {
    var frameCount: UInt32

    var session: NsdkSession

    var locationManager: CLLocationManager?
    var lastUpdatedLocation: CLLocation?
    var lastUpdatedHeading: CLHeading?

    var croppedDepthBuffer: CVPixelBuffer?

    init(apiKey: String, useLidar: Bool) {
        self.frameCount = 0;

        // useLidar = true by default
        self.session = NsdkSession(apiKey: apiKey, useLidar: useLidar)
        print("Initialized NSDK with apiKey: \(apiKey), useLidar: \(useLidar)")

        super.init()
    }

    /// Alternative initializer that accepts access/refresh tokens instead of an API key.
    /// Tokens are sanitized and passed to native during NSDK creation.
    init(accessToken: String, refreshToken: String, useLidar: Bool) {
        self.frameCount = 0
        self.session = NsdkSession(accessToken: accessToken, refreshToken: refreshToken, useLidar: useLidar)
        print("Initialized NSDK with tokens (access_len=\(accessToken.count), refresh_len=\(refreshToken.count)), useLidar: \(useLidar)")
        super.init()
    }

    func startLocationService() {
        if #available(iOS 16.0, *) {
            locationManager = CLLocationManager()
            if let location = locationManager {
                print("Location auth status on init: \(location.authorizationStatus)")
                location.delegate = self
                location.headingFilter = kCLHeadingFilterNone

                location.startUpdatingLocation()
                location.startUpdatingHeading()

                location.requestWhenInUseAuthorization()
            }
        }
    }

    func sendFrame(_ frame: ARFrame) {
        if (frame.camera.trackingState == .notAvailable) {
          return
        }

        let requestedData = session.requestedDataInputs()
        if (requestedData.isEmpty) {
            return
        }

        var frameData = NsdkFrameData()
        frameData.frameId = frameCount

        if let orientation = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.windows.first?.windowScene?.interfaceOrientation {
            frameData.screenOrientation = orientation
        }

        frameData.trackingState = frame.camera.trackingState
        frameData.cameraTransform = frame.camera.transform
        frameData.cameraTimestampMs = UInt64(frame.timestamp * 1000)

        if requestedData.contains(.compass) {
            frameData.compassData = compassData()
        }

        if requestedData.contains(.gpsLocation) {
            frameData.gpsData = locationData()
        }

        if requestedData.contains(.cameraImage) {
            frameData.cameraImageWidth = UInt32(frame.camera.imageResolution.width)
            frameData.cameraImageHeight = UInt32(frame.camera.imageResolution.height)
            frameData.cameraImageFormat = .YUV420NV12
            frameData.cameraIntrinsics = NsdkFrameData.CameraIntrinsics(
                intrinsics: frame.camera.intrinsics,
                resolution: frame.camera.imageResolution
            )

            CVPixelBufferLockBaseAddress(frame.capturedImage, CVPixelBufferLockFlags.readOnly)
            let cameraPlanes = getCameraImagePlanes(image: frame.capturedImage)
            frameData.cameraPlane0 = cameraPlanes.y
            frameData.cameraPlane1 = cameraPlanes.cbcr
        }

        if requestedData.contains(.platformDepth), let sceneDepth = frame.sceneDepth {
            CVPixelBufferLockBaseAddress(sceneDepth.depthMap, CVPixelBufferLockFlags.readOnly)

            let depthWidth = CVPixelBufferGetWidth(sceneDepth.depthMap)
            let depthHeight = CVPixelBufferGetHeight(sceneDepth.depthMap)
            
            // No crop needed
            frameData.depthData = UnsafePointer(buffer: sceneDepth.depthMap)
            frameData.depthImageWidth = UInt32(depthWidth)
            frameData.depthImageHeight = UInt32(depthHeight)
            frameData.depthAndConfidenceImageDataLength = frameData.depthImageWidth * frameData.depthImageHeight

            frameData.depthCameraPose = frame.camera.transform
            frameData.depthCameraIntrinsics = NsdkFrameData.CameraIntrinsics(
                intrinsics: frame.camera.intrinsics,
                resolution: frame.camera.imageResolution
            )

            if let confidenceMap = sceneDepth.confidenceMap {
                CVPixelBufferLockBaseAddress(confidenceMap, CVPixelBufferLockFlags.readOnly)
                frameData.depthConfidenceData = UnsafePointer(buffer: confidenceMap)
            }
        }

        session.sendFrame(frameData)
        frameCount += 1

        if frameData.cameraPlane0 != nil {
            CVPixelBufferUnlockBaseAddress(frame.capturedImage, CVPixelBufferLockFlags.readOnly)
        }

        if frameData.depthData != nil, let sceneDepth = frame.sceneDepth {
            CVPixelBufferUnlockBaseAddress(sceneDepth.depthMap, CVPixelBufferLockFlags.readOnly)
            if let confidenceMap = sceneDepth.confidenceMap {
                CVPixelBufferUnlockBaseAddress(confidenceMap, CVPixelBufferLockFlags.readOnly)
            }

            // Unlock the cropped buffer if we created one
            if let croppedBuffer = croppedDepthBuffer {
                CVPixelBufferUnlockBaseAddress(croppedBuffer, [])
            }
        }
    }

    func cropDepthBuffer(_ depthMap: CVPixelBuffer, width: Int, height: Int, offsetY: Int) -> CVPixelBuffer? {
        // Get pointer to source depth data
        guard let srcPtr = CVPixelBufferGetBaseAddress(depthMap) else {
            return nil
        }

        let srcWidth = CVPixelBufferGetWidth(depthMap)
        let srcBytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        let pixelFormat = CVPixelBufferGetPixelFormatType(depthMap)

        // Create destination buffer
        var dstBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            pixelFormat,
            nil,
            &dstBuffer
        )

        guard status == kCVReturnSuccess, let dst = dstBuffer else {
            return nil
        }

        // Lock the destination buffer and keep it locked
        // It will be unlocked later when we're done with the frame
        CVPixelBufferLockBaseAddress(dst, [])

        guard let dstPtr = CVPixelBufferGetBaseAddress(dst) else {
            CVPixelBufferUnlockBaseAddress(dst, [])
            return nil
        }

        let dstBytesPerRow = CVPixelBufferGetBytesPerRow(dst)
        let bytesPerPixel = srcBytesPerRow / srcWidth
        let rowBytes = width * bytesPerPixel

        // Copy rows from source to destination
        for y in 0..<height {
            let srcOffset = (offsetY + y) * srcBytesPerRow
            let dstOffset = y * dstBytesPerRow
            memcpy(dstPtr + dstOffset, srcPtr + srcOffset, rowBytes)
        }

        return dst
    }

    func getCameraImagePlanes(image: CVPixelBuffer) -> (y: NsdkFrameData.CameraPlane, cbcr: NsdkFrameData.CameraPlane) {
        let yPtr = CVPixelBufferGetBaseAddressOfPlane(image, 0)
        let yWidth = CVPixelBufferGetWidthOfPlane(image, 0);
        let yHeight = CVPixelBufferGetHeightOfPlane(image, 0);
        let yRowStride = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
        let yPixelStride = yRowStride / yWidth

        let yPlane = NsdkFrameData.CameraPlane(
            dataPtr: UnsafePointer<UInt8>(yPtr!.assumingMemoryBound(to: UInt8.self)),
            dataSize: UInt32(yWidth * yHeight * yPixelStride),
            pixelStride: UInt32(yPixelStride),
            rowStride: UInt32(yRowStride)
        )

        let cbcrPtr = CVPixelBufferGetBaseAddressOfPlane(image, 1)
        let cbcrWidth = CVPixelBufferGetWidthOfPlane(image, 1);
        let cbcrHeight = CVPixelBufferGetHeightOfPlane(image, 1);
        let cbcrRowStride = CVPixelBufferGetBytesPerRowOfPlane(image, 1)
        let cbcrPixelStride = cbcrRowStride / cbcrWidth

        let cbcrPlane = NsdkFrameData.CameraPlane(
            dataPtr: UnsafePointer<UInt8>(cbcrPtr!.assumingMemoryBound(to: UInt8.self)),
            dataSize: UInt32(cbcrWidth * cbcrHeight * cbcrPixelStride),
            pixelStride: UInt32(cbcrPixelStride),
            rowStride: UInt32(cbcrRowStride)
        )

        return (y: yPlane, cbcr: cbcrPlane)
    }

    func locationData() -> NsdkFrameData.GpsData? {
        guard let location = lastUpdatedLocation else { return nil }

        return NsdkFrameData.GpsData(
            timestampMs: UInt64(location.timestamp.timeIntervalSince1970 * 1000),
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            altitude: location.ellipsoidalAltitude,
            verticalAccuracy: Float(location.verticalAccuracy),
            horizontalAccuracy: Float(location.horizontalAccuracy)
        )
    }

    func compassData() -> NsdkFrameData.CompassData? {
        guard let heading = lastUpdatedHeading else { return nil }

        return NsdkFrameData.CompassData(
            timestampMs: UInt64(heading.timestamp.timeIntervalSince1970 * 1000),
            headingAccuracy: Float(heading.headingAccuracy),
            trueHeading: Float(heading.trueHeading)
        )
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        lastUpdatedLocation = locations.last!
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading heading: CLHeading) {
        lastUpdatedHeading = heading
    }
}
