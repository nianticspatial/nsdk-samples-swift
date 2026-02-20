import Foundation

extension Data {
    /// Creates a Data instance from an NsdkBuffer
    /// - Parameter nsdkBuffer: The NsdkBuffer to convert to Data
    init(from nsdkBuffer: NsdkBuffer) {
        self.init(bytes: nsdkBuffer.data, count: Int(nsdkBuffer.dataSize))
    }
}
