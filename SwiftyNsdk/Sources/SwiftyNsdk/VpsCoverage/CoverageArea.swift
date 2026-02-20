import CArdk

/// Represents a geographic area where VPS localization is possible
public struct CoverageArea: Sendable, CustomStringConvertible {
    /// Points describing a polygon outline of the area.
    public let shape: [LatLng]
    
    /// Centroid of the polygon described in ``shape``.
    public let centroid: LatLng
    
    /// Identifiers of all the localization targets within the coverage area.
    public let localizationTargetIdentifiers: [String]
    
    /// Quality of VPS coverage in the area.
    public let localizability: Localizability

    public init?(fromC cValue: ARDK_VPSCoverage_CoverageArea) {
        guard let shapePtr = cValue.shape else {
            print("Error: CoverageArea shape is nil")
            return nil
        }
      
        let shapeBuffer = UnsafeBufferPointer(start: shapePtr, count: Int(cValue.shape_size))
        shape = shapeBuffer.map { cLatLng in LatLng(fromC: cLatLng) }
      
        centroid = LatLng(fromC: cValue.centroid)
      
        guard let targetsPtr = cValue.localization_targets else {
            print("Error: Localization targets pointer is nil")
            return nil
        }
        
        var targets: [String] = []
        for i in 0..<Int(cValue.localization_targets_size) {
            let cTarget = targetsPtr[i]
            guard let dataPtr = cTarget.data else {
                print("Error: Localization target data pointer is nil at index \(i)")
                return nil
            }
          
            guard let id = String(ptr: dataPtr, len: cTarget.data_size) else {
                print("Error: Failed to read localization target identifier at index \(i)")
                return nil
            }
          
            targets.append(id)
        }
        localizationTargetIdentifiers = targets
      
        self.localizability = Localizability(fromC: cValue.localizability)
    }
  
    public var description: String {
        let points = shape.enumerated().map { (index, point) in
          return "\t[\(index)] \(point)"
        }.joined(separator: "\n")
        
        return
"""
Coverage Area
- Centroid: \(centroid)
- Localizability: \(localizability)
- Localization Targets: \(localizationTargetIdentifiers)
- Shape Points:
\(points)
"""
    }
}

