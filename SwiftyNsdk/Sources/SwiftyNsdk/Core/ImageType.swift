import CArdk

/// Enum representing various image types supported by NSDK.
public enum ImageType {
  case unspecified
  case JPEG
  case PNG
  case RGB
  case BGR
  case RGBX
  case BGRX
  case Gray
  case NV12
  case NV21
  case I420
  case depthRawFloat
  case depthConfidence
  case semanticsConfidence
  case semanticsBoolMask
  case raycastNormals
  case raycastPositionAndConfidence
  
  init(fromC cValue: ARDK_ImageType) {
      switch cValue {
      case ARDK_ImageType_Unspecified:
          self = .unspecified
      case ARDK_ImageType_JPEG:
          self = .JPEG
      case ARDK_ImageType_PNG:
          self = .PNG
      case ARDK_ImageType_RGB:
          self = .RGB
      case ARDK_ImageType_BGR:
          self = .BGR
      case ARDK_ImageType_RGBX:
          self = .RGBX
      case ARDK_ImageType_BGRX:
          self = .BGRX
      case ARDK_ImageType_Gray:
          self = .Gray
      case ARDK_ImageType_YUV_NV12:
          self = .NV12
      case ARDK_ImageType_YUV_NV21:
          self = .NV21
      case ARDK_ImageType_YUV_I420:
          self = .I420
      case ARDK_ImageType_DepthRawFloat:
          self = .depthRawFloat
      case ARDK_ImageType_DepthConfidence:
          self = .depthConfidence
      case ARDK_ImageType_SemanticsConfidence:
          self = .semanticsConfidence
      case ARDK_ImageType_SemanticsBoolMask:
          self = .semanticsBoolMask
      case ARDK_ImageType_RaycastNormals:
          self = .raycastNormals
      case ARDK_ImageType_RaycastPositionAndConfidence:
          self = .raycastPositionAndConfidence
      default:
          self = .unspecified
      }
  }
}
