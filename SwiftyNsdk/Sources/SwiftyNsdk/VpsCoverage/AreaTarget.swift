import CArdk

/// Contains a ``CoverageArea`` and its associated ``LocalizationTarget``.
public struct AreaTarget: Sendable, CustomStringConvertible {
    /// The geographic area where the ``localizationTarget`` can be used
    /// for VPS operations.
    public let coverageArea: CoverageArea
    
    /// The localization target located within the ``coverageArea``
    public let localizationTarget: LocalizationTarget
    
    public init?(fromC cValue: ARDK_VPSCoverage_AreaTarget) {
        guard let coverageArea = CoverageArea(fromC: cValue.coverage_area) else {
            print("Error: Failed to create CoverageArea")
            return nil
        }
        self.coverageArea = coverageArea
        
        guard let localizationTarget = LocalizationTarget(fromC: cValue.localization_target) else {
            print("Error: Failed to create LocalizationTarget")
            return nil
        }
        self.localizationTarget = localizationTarget
    }
  
  public var description: String {
      var str = "Area Target\n"
      let targetLines = localizationTarget.description.components(separatedBy: .newlines)
      str += targetLines.map { indent + $0 }.joined(separator: "\n") + "\n"
      let areaLines = coverageArea.description.components(separatedBy: .newlines)
      str += areaLines.map { indent + $0 }.joined(separator: "\n") + "\n"
      return str
  }
}
