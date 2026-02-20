import CArdk
import Foundation

/// Protocol for receiving log messages from NSDK.
///
/// Implement this protocol to receive NSDK log messages in your application.
/// The callback will be invoked on background threads, so ensure your implementation
/// is thread-safe.
///
/// ## Example Usage
///
/// ```swift
/// class MyLogCallback: NsdkLogCallback {
///     func onLog(level: NsdkLogLevel, message: String, fileName: String?, fileLine: Int, funcName: String?) {
///         let levelStr = level.description
///         let location = fileName.map { "\($0):\(fileLine)" } ?? ""
///         let funcInfo = funcName.map { " \($0)" } ?? ""
///         print("[NSDK-\(levelStr)] \(location)\(funcInfo): \(message)")
///     }
/// }
///
/// let callback = MyLogCallback()
/// let session = NsdkSession(apiKey: "your-key", logCallback: callback)
/// ```
public protocol NsdkLogCallback: AnyObject {
    /// Called when NSDK generates a log message.
    ///
    /// - Parameters:
    ///   - level: The severity level of the log message
    ///   - message: The log message content
    ///   - fileName: Optional source file name where the log was generated
    ///   - fileLine: Line number in the source file
    ///   - funcName: Optional function name where the log was generated
    func onLog(level: NsdkLogLevel, message: String, fileName: String?, fileLine: Int, funcName: String?)
}

/// Global registry to store active callback bridges.
///
/// ## Why a Singleton/Registry Pattern?
///
/// This implementation uses a singleton/registry pattern due to fundamental constraints
/// of C function pointers and the NSDK C API:
///
/// 1. **C Function Pointers Cannot Capture Context**: The native NSDK library expects
///    a C function pointer (`ARDK_SinkCallbackFunctionPtr`) for logging callbacks. C function
///    pointers are just memory addresses - they cannot capture Swift closures, objects, or
///    any other context. This means we cannot directly pass a Swift callback instance.
///
/// 2. . **Static C Function Requirement**: To create a C function pointer, we must use a
///    static function (marked with `@_cdecl`). This static function cannot capture any
///    Swift context, so it needs a way to look up which callback bridge to use.
///
/// ## Solution: Global Registry
///
/// The registry pattern solves this by:
/// - Storing a single active `NsdkLogCallbackBridge` instance in a global registry
/// - The static C function (`nsdkLogSinkCallbackSwift`) looks up the active bridge from
///   the registry when called
/// - Each `NsdkSession` registers its bridge when created and unregisters it when destroyed
///
/// ## Limitations
///
/// This pattern supports one active NSDK instance with a callback at a time. This matches
/// typical usage patterns where an application has a single NSDK session. If multiple
/// sessions are needed, only the most recently created session's callback will receive logs.
///
/// ## Thread Safety
///
/// The registry uses `NSLock` to ensure thread-safe access, as callbacks may be invoked
/// from background threads by the native NSDK library.
private class NsdkLogCallbackRegistry {
    // Use nonisolated(unsafe) to suppress concurrency warning since we use a lock for thread safety
    nonisolated(unsafe) private static var _activeBridge: NsdkLogCallbackBridge?
    private static let lock = NSLock()
    
    static func setActive(_ bridge: NsdkLogCallbackBridge?) {
        lock.lock()
        defer { lock.unlock() }
        _activeBridge = bridge
    }
    
    static func getActive() -> NsdkLogCallbackBridge? {
        lock.lock()
        defer { lock.unlock() }
        return _activeBridge
    }
}

/// Static C function that can be used as a function pointer.
/// This function looks up the active bridge from the global registry.
/// Note: This uses @convention(c) to ensure it can be used as a C function pointer.
@_cdecl("nsdkLogSinkCallbackSwift")
private func nsdkLogSinkCallbackSwift(
    level: ARDK_LogLevel,
    message: UnsafePointer<CChar>?,
    fileName: UnsafePointer<CChar>?,
    fileLine: Int32,
    funcName: UnsafePointer<CChar>?
) {
    guard let bridge = NsdkLogCallbackRegistry.getActive() else {
        return
    }
    
    // Get the callback (it may have been deallocated)
    guard let callback = bridge.getCallback() else {
        return
    }
    
    // Convert C strings to Swift strings
    let messageStr = message.map { String(cString: $0) } ?? ""
    let fileNameStr = fileName.map { String(cString: $0) }
    let funcNameStr = funcName.map { String(cString: $0) }
    
    // Convert C log level to Swift log level
    let swiftLevel = NsdkLogLevel(fromC: level)
    
    // Call the Swift callback on the specified queue
    bridge.callCallbackOnQueue(level: swiftLevel, message: messageStr, fileName: fileNameStr, fileLine: Int(fileLine), funcName: funcNameStr)
}

// Global variable to hold the function pointer
// This allows us to get a pointer to the function without capturing context
private let nsdkLogSinkCallbackPtr: ARDK_SinkCallbackFunctionPtr = nsdkLogSinkCallbackSwift

/// Internal class to bridge Swift callbacks to C function pointers.
internal class NsdkLogCallbackBridge {
    private weak var callback: NsdkLogCallback?
    private let callbackQueue: DispatchQueue
    
    init(callback: NsdkLogCallback?, queue: DispatchQueue = .main) {
        self.callback = callback
        self.callbackQueue = queue
        
        // Register as active bridge if callback is provided
        if callback != nil {
            NsdkLogCallbackRegistry.setActive(self)
        }
    }
    
    /// Gets the callback (internal access for the static C function)
    internal func getCallback() -> NsdkLogCallback? {
        return callback
    }
    
    /// Calls the callback on the specified queue (internal access for the static C function)
    internal func callCallbackOnQueue(level: NsdkLogLevel, message: String, fileName: String?, fileLine: Int, funcName: String?) {
        guard let callback = callback else {
            return
        }
        callbackQueue.async {
            callback.onLog(level: level, message: message, fileName: fileName, fileLine: fileLine, funcName: funcName)
        }
    }
    
    /// Creates a C function pointer that can be passed to NSDK C API.
    /// The function pointer will call the Swift callback on the specified queue.
    /// Note: The bridge must be kept alive for the lifetime of the NSDK handle.
    func makeCFunctionPointer() -> ARDK_SinkCallbackFunctionPtr? {
        guard callback != nil else {
            return nil
        }
        
        // Return the global function pointer
        // This doesn't capture any context, so it can be used as a C function pointer
        return nsdkLogSinkCallbackPtr
    }
    
    /// Releases the bridge from the registry when the NSDK handle is destroyed.
    /// This should be called from the NsdkSession deinit.
    func release() {
        // Only clear if we're the active bridge
        if NsdkLogCallbackRegistry.getActive() === self {
            NsdkLogCallbackRegistry.setActive(nil)
        }
    }
    
    deinit {
        release()
    }
}

