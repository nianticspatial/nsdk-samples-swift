import CArdk
import ARKit

/// A type alias for the native NSDK handle used to interface with the underlying C API.
public typealias NsdkHandle = ARDK_Handle

/// The main entry point for the NSDK (Native SDK) framework.
///
/// `NsdkSession` provides the core functionality for AR applications, managing the lifecycle
/// of NSDK features and serving as a factory for specialized sessions like VPS, WPS, scanning, and mapping.
/// This class handles frame data processing, configuration management, and resource cleanup.
///
/// ## Overview
///
/// Use `NsdkSession` to:
/// - Initialize the NSDK with your API key and configuration
/// - Send camera frame data for processing
/// - Create specialized feature sessions (VPS, WPS, Scanning, Mapping)
/// - Query required input data formats
/// - Manage the lifecycle of NSDK resources
///
/// ## Example Usage
///
/// ```swift
/// // Initialize with API key
/// let session = NsdkSession(apiKey: "your-api-key")
///
/// // Create a VPS session for localization
/// let vpsSession = session.createVpsSession()
///
/// // Send frame data during AR session
/// let status = session.sendFrame(frameData)
/// ```
public final class NsdkSession {
    // TODO this should be a singleton
    
    /// The native handle to the underlying NSDK C API instance.
    ///
    /// This handle is used internally to communicate with the native NSDK library
    /// and should not be modified directly by application code.
    public let nativeHandle: NsdkHandle
    private let api: NsdkApi
    
    
    public private(set) var currentFrame: NsdkFrameData?
    
    /**
     A delegate for receiving ARSession updates.
     */
    public var delegate: (any NsdkSessionDelegate)?
    
    internal protocol IDisposable {
        func destroy()
    }
    
    internal var disposables: [ObjectIdentifier: IDisposable] = [:]

    /// Creates a new NSDK session with the specified API key and configuration.
    ///
    /// This is the recommended way to initialize NSDK for most use cases. The session will
    /// automatically configure itself with default settings appropriate for AR applications.
    ///
    /// - Parameters:
    ///   - apiKey: Your NSDK API key obtained from the developer portal
    ///   - useLidar: Whether to use LiDAR depth data when available (default: true)
    ///   - pathConfig: Optional path configuration for custom file locations
    ///   - logCallback: Optional callback to receive NSDK log messages
    ///
    /// ## Example
    ///
    /// ```swift
    /// let session = NsdkSession(apiKey: "your-api-key")
    /// let sessionWithoutLidar = NsdkSession(apiKey: "your-api-key", useLidar: false)
    /// ```
    public convenience init(apiKey: String, useLidar: Bool = true, pathConfig: NsdkPathConfig? = nil, logCallback: NsdkLogCallback? = nil) {
        self.init(api: CArdkApi(), apiKey: apiKey, useLidar: useLidar, pathConfig: pathConfig, logCallback: logCallback)
    }
    
    /// Creates a new NSDK session from a JSON configuration file.
    ///
    /// Use this initializer for fine-grained control over NSDK configuration
    /// or when loading settings from a configuration file.
    ///
    /// - Parameters:
    ///   - configFilePath: Path to the JSON configuration file
    ///   - logCallback: Optional callback to receive NSDK log messages
    /// - Returns: A new NSDK session, or `nil` if configuration loading fails
    ///
    /// ## Example
    ///
    /// ```swift
    /// if let session = NsdkSession(withJson: "/path/to/config.json") {
    ///     // Session created successfully
    /// } else {
    ///     // Failed to load configuration
    /// }
    /// ```
    public convenience init?(withJson configFilePath: String, logCallback: NsdkLogCallback? = nil) {
        self.init(api: CArdkApi(), withJson: configFilePath, logCallback: logCallback)
    }
    
    /// Creates a new NSDK session with a Configuration object.
    ///
    /// Use this initializer for fine-grained control over NSDK configuration
    ///
    /// - Parameter config: The configuration object with defined settings
    /// - Returns: A new NSDK session, or `nil` if configuration is invalid
    ///
    /// ## Example
    ///
    /// ```swift
    /// let config = Configuration()
    /// // Configure settings...
    /// if let session = NsdkSession(withConfig: config) {
    ///     // Session created successfully
    /// }
    /// ```
    public convenience init?(withConfig config: Configuration) {
        self.init(api: CArdkApi(), withConfig: config)
    }
    
    /// Convenience initializer that accepts access and refresh tokens instead of an API key.
    /// Tokens are sanitized and passed to native AuthManagerApi immediately via creation call.
    public convenience init(accessToken: String, refreshToken: String, useLidar: Bool = true, pathConfig: NsdkPathConfig? = nil, logCallback: NsdkLogCallback? = nil) {
        self.init(api: CArdkApi(), accessToken: accessToken, refreshToken: refreshToken, useLidar: useLidar, pathConfig: pathConfig, logCallback: logCallback)
    }

    // Hold onto the log callback and callback bridge to ensure they persists for the lifetime of the session
    private var logCallback: NsdkLogCallback?
    private var logCallbackBridge: NsdkLogCallbackBridge?
    
    /// Internal initializer that accepts an API key and sets it immediately during creation.
    internal init(api: NsdkApi, apiKey: String, useLidar: Bool = true, pathConfig: NsdkPathConfig? = nil, logCallback: NsdkLogCallback? = nil) {
        self.api = api
        
        // Store the callback and create callback bridge if callback is provided
        self.logCallback = logCallback
        let callbackBridge = logCallback.map { NsdkLogCallbackBridge(callback: $0) }
        self.logCallbackBridge = callbackBridge
        let sinkCallback = callbackBridge?.makeCFunctionPointer()
        
        nativeHandle = NsdkSession.createHandle(api: api,
                                                apiKey: apiKey,
                                                accessToken: "",
                                                refreshToken: "",
                                                useLidar: useLidar,
                                                pathConfig: pathConfig,
                                                sinkCallback: sinkCallback)
    }
    
    /// Internal initializer that accepts auth tokens and sets them immediately during creation.
    internal init(api: NsdkApi, accessToken: String, refreshToken: String, useLidar: Bool = true, pathConfig: NsdkPathConfig? = nil, logCallback: NsdkLogCallback? = nil) {
        self.api = api
        
        // Store the callback and create callback bridge if callback is provided
        self.logCallback = logCallback
        let callbackBridge = logCallback.map { NsdkLogCallbackBridge(callback: $0) }
        self.logCallbackBridge = callbackBridge
        let sinkCallback = callbackBridge?.makeCFunctionPointer()
        
        nativeHandle = NsdkSession.createHandle(api: api,
                                                apiKey: "",
                                                accessToken: accessToken,
                                                refreshToken: refreshToken,
                                                useLidar: useLidar,
                                                pathConfig: pathConfig,
                                                sinkCallback: sinkCallback)
    }

    private static func createHandle(api: NsdkApi,
                                     apiKey: String,
                                     accessToken: String?,
                                     refreshToken: String?,
                                     useLidar: Bool,
                                     pathConfig: NsdkPathConfig?,
                                     sinkCallback: ARDK_SinkCallbackFunctionPtr?) -> NsdkHandle {
        let sanitizedAccess = (accessToken ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitizedRefresh = (refreshToken ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let isLidarProvided = useLidar && ARUtils.isLidarAvailable()
        return apiKey.withCString { keyC in
            return sanitizedAccess.withCString { accessC in
                return sanitizedRefresh.withCString { refreshC in
                    let keyStr = ARDK_String(data: keyC, data_size: UInt32(strlen(keyC)))
                    let atStr = ARDK_String(data: accessC, data_size: UInt32(strlen(accessC)))
                    let rtStr = ARDK_String(data: refreshC, data_size: UInt32(strlen(refreshC)))
                    if (pathConfig == nil) {
                        return api.createWithDefaults(apiKey: keyStr,
                                                      accessToken: atStr,
                                                      refreshToken: rtStr,
                                                      usePlatformDepths: isLidarProvided,
                                                      sinkCallback: sinkCallback,
                                                      pathConfig: nil)
                    }
                    return pathConfig!.withCStruct { configPtr in
                        return api.createWithDefaults(apiKey: keyStr,
                                                      accessToken: atStr,
                                                      refreshToken: rtStr,
                                                      usePlatformDepths: isLidarProvided,
                                                      sinkCallback: sinkCallback,
                                                      pathConfig: configPtr)
                    }
                }
            }
        }
    }

    private static func toARDKString(_ s: String) -> ARDK_String {
        return s.withCString { c in ARDK_String(data: c, data_size: UInt32(strlen(c))) }
    }
    
    internal init?(api: NsdkApi, withJson configFilePath: String, logCallback: NsdkLogCallback? = nil) {
        self.api = api
        
        // Store the callback and create callback bridge if callback is provided
        self.logCallback = logCallback
        let callbackBridge = logCallback.map { NsdkLogCallbackBridge(callback: $0) }
        self.logCallbackBridge = callbackBridge
        let sinkCallback = callbackBridge?.makeCFunctionPointer()
        
        let handle = configFilePath.withCString { cstr in
            let nsdkStr = ARDK_String(data: cstr, data_size: UInt32(strlen(cstr)))
            return api.createFromFile(configFilePath: nsdkStr, sinkCallback: sinkCallback)
        }
        
        if (handle != nil) {
            self.nativeHandle = handle!
        } else {
            return nil
        }
    }
    
    internal init?(api: NsdkApi, withConfig config: Configuration) {
        self.api = api
        
        // Store the callback to ensure it persists for the lifetime of the session
        self.logCallback = config.logCallback
        
        // withCStruct creates the callback bridge from config.logCallback and returns it
        let (handle, callbackBridge) = config.withCStruct { configPtr in
            return api.create(config: configPtr)
        }
        
        // Store the callback bridge to keep it alive
        self.logCallbackBridge = callbackBridge
        
        if (handle != nil) {
            self.nativeHandle = handle!
        } else {
            return nil
        }
    }
    
    deinit {
        for (_, item) in disposables {
            item.destroy()
        }
        
        // Release the callback bridge if it exists
        logCallbackBridge?.release()
        
        _ = api.destroy(handle: nativeHandle)
    }
    
    /// Sends a frame of data to NSDK for processing.
    ///
    /// Call this method for each frame captured from an AR session. This will push
    /// the captured frame data into NSDK's native components for processing by active features.
    ///
    /// - Parameter frameData: The frame data captured from the AR session
    public func sendFrame(_ frameData: NsdkFrameData) {
        let cFrame = frameData.convertToC()
        let cStatus = withUnsafePointer(to: cFrame) { ptr in
            api.sendFrame(handle: nativeHandle, frameData: ptr)
        }
        
        currentFrame = frameData
        delegate?.nsdkSession(self, didUpdate: frameData)
        
        if cStatus.isError {
            unexpectedNsdkStatus(cStatus)
        }
    }
    
    /// Get the current set of input data types that are required by NSDK's native
    /// components.
    ///
    /// Use this method to determine what data should be included in frames sent to `sendFrame(_:)`.
    /// The required data formats may change based on currently active features and their states.
    ///
    /// - Returns: Flags indicating which data types are currently required
    ///
    /// ## Example
    ///
    /// ```swift
    /// let requiredInputs = session.requestedDataInputs()
    /// if requiredInputs.contains(.camera) {
    ///     // Include camera data in frame
    /// }
    /// if requiredInputs.contains(.depth) {
    ///     // Include depth data in frame
    /// }
    /// ```
    public func requestedDataInputs() -> NsdkInputDataFlags {
        var flags = ARDK_InputData_None
        _ = withUnsafeMutablePointer(to: &flags) { ptr in
            api.getRequestedDataFormats(handle: nativeHandle, dataFormatsOut: ptr)
        }
        
        return NsdkInputDataFlags(rawValue: flags.rawValue)
    }
    
    /// Returns true if a valid, non-expired access token is available.
    ///
    /// Use this to check if features requiring authentication can be used.
    /// If a feature returns an auth error, poll this property until it returns true
    /// before retrying.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // After receiving an auth error from a feature:
    /// while !session.isAuthorized {
    ///     try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
    /// }
    /// // Retry the feature call
    /// ```
    public var isAuthorized: Bool {
        var isAuthorizedOut: Bool = false
        let cStatus = api.isAuthorized(handle: nativeHandle, isAuthorizedOut: &isAuthorizedOut)
        if cStatus.isError {
            unexpectedNsdkStatus(cStatus)
        }
        return isAuthorizedOut
    }

    /// Sets the log level for standard output logging.
    ///
    /// - Parameter logLevel: The desired log level for standard output
    public func setStdoutLogLevel(logLevel: NsdkLogLevel) {
        LoggingApi.setStdoutLogLevel(nsdkHandle: nativeHandle, logLevel: logLevel)
    }

    /// Sets the log level for file logging.
    ///
    /// - Parameter logLevel: The desired log level for file logging
    public func setFileLogLevel(logLevel: NsdkLogLevel) {
        LoggingApi.setFileLogLevel(nsdkHandle: nativeHandle, logLevel: logLevel)
    }

    /// Sets the log level for callback logging.
    ///
    /// - Parameter logLevel: The desired log level for callback logging
    public func setCallbackLogLevel(logLevel: NsdkLogLevel){
        LoggingApi.setCallbackLogLevel(nsdkHandle: nativeHandle, logLevel: logLevel)
    }

    /// Retrieves the NSDK version string.
    public static func version() -> String {
        return CArdkApi().getVersion()
    }

    /// Sets the access token on native (routed through AuthManagerApi via C-ABI).
    /// Empty or whitespace-only tokens are ignored by native.
    public func setAccessToken(_ token: String) {
        let sanitized = token.trimmingCharacters(in: .whitespacesAndNewlines)
        sanitized.withCString { c in
            let s = ARDK_String(data: c, data_size: UInt32(strlen(c)))
            api.setAccessToken(handle: nativeHandle, token: s)
        }
    }

    /// Sets the refresh token on native (routed through AuthManagerApi via C-ABI).
    /// Empty or whitespace-only tokens are ignored by native.
    public func setRefreshToken(_ token: String) {
        let sanitized = token.trimmingCharacters(in: .whitespacesAndNewlines)
        sanitized.withCString { c in
            let s = ARDK_String(data: c, data_size: UInt32(strlen(c)))
            api.setRefreshToken(handle: nativeHandle, token: s)
        }
    }
    
    /// Sets the age level for the NSDK session.
    ///
    /// This method sets the age classification for the user
    ///
    /// - Parameter ageLevel: The age level to set (unknown, minor, teen, or adult)
    ///
    /// ## Example
    ///
    /// ```swift
    /// session.setAgeLevel(.adult)
    /// ```
    public func setAgeLevel(_ ageLevel: AgeLevel) {
        let cAgeLevel = ageLevel.cValue
        let cStatus = api.setAgeLevel(handle: nativeHandle, ageLevel: cAgeLevel)
        if cStatus.isError {
            unexpectedNsdkStatus(cStatus)
        }
    }

    /// Gets access token authentication information.
    /// Returns authentication information containing information about the current access token.
    /// - Returns: AuthInfo containing access token claims, or nil if the operation fails
    public func getAccessAuthInfo() -> AuthInfo? {
        var cAuthInfo = ARDK_AuthManager_AuthInfo()
        let cStatus = api.getAccessAuthInfo(handle: nativeHandle, authInfoOut: &cAuthInfo)
        
        guard cStatus == ARDK_Status_OK else {
            return nil
        }
        
        defer {
            api.releaseResource(handle: cAuthInfo.handle)
        }
        
        return AuthInfo(fromC: cAuthInfo)
    }
    
    /// Gets refresh token authentication information.
    /// Returns authentication information containing information about the current refresh token.
    /// - Returns: AuthInfo containing refresh token claims, or nil if the operation fails
    public func getRefreshAuthInfo() -> AuthInfo? {
        var cAuthInfo = ARDK_AuthManager_AuthInfo()
        let cStatus = api.getRefreshAuthInfo(handle: nativeHandle, authInfoOut: &cAuthInfo)
        
        guard cStatus == ARDK_Status_OK else {
            return nil
        }
        
        defer {
            api.releaseResource(handle: cAuthInfo.handle)
        }
        
        return AuthInfo(fromC: cAuthInfo)
    }
}

public protocol NsdkSessionDelegate : ARSessionDelegate, PlaybackSessionDelegate
{
    /**
     This is called when a new frame has been sent to the underlying nsdk
     
     @param session The nsdk session being run.
     @param frame The nsdk frame that was just sent to the underlying native NSDK subsystems
     */
    func nsdkSession(_ : NsdkSession, didUpdate nsdkFrame: NsdkFrameData)
}
