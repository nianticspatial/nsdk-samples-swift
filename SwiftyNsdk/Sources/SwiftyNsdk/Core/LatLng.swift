import CArdk

/// Struct representing a geographical coordinate with latitude and longitude in degrees.
public struct LatLng: CustomStringConvertible, Sendable {
    /// Latitude in degrees.
    public let latDegrees: Double
    
    /// Longitude in degrees.
    public let lngDegrees: Double
    
    public init(latDegrees: Double, lngDegrees: Double) {
        self.latDegrees = latDegrees
        self.lngDegrees = lngDegrees
    }
  
    init(fromC cValue: ARDK_VPSCoverage_LatLng) {
        self.latDegrees = cValue.lat_degrees
        self.lngDegrees = cValue.lng_degrees
    }

    func convertToC() -> ARDK_VPSCoverage_LatLng {
        return ARDK_VPSCoverage_LatLng(
            lat_degrees: self.latDegrees,
            lng_degrees: self.lngDegrees
        )
    }
    
    public var description: String {
        return "Lat: \(latDegrees), Lng: \(lngDegrees)"
    }
}
