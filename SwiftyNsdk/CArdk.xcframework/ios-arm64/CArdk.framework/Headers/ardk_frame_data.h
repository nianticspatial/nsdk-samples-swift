// Copyright 2022-2025 Niantic.
#pragma once

#include "ardk_compass_data.h"
#include "ardk_gps_data.h"
#include "ardk_image_format.h"
#include "ardk_orientation.h"
#include "ardk_transform.h"
#include "ardk_camera_plane.h"
#include "ardk_camera_intrinsics.h"
#include "ardk_tracking_state.h"

#ifdef __cplusplus

extern "C" {
#endif

/// @brief        Container for all the data possibly used by ARDK features.
typedef struct ARDK_FrameData {
  /// @brief      Heading data
  /// @note       The \c timestamp_ms field of this struct can be in either posix or monotonic
  ///             time, as long as that choice stays consistent across all frames in an ARDK
  ///             session.
  ARDK_CompassData compass_data;

  /// @brief      Location data
  ARDK_GpsData gps_data;

  /// @brief      The camera image timestamp in milliseconds since epoch.
  /// @details    This is equivalent to the camera pose timestamp.
  /// @internal   Note, this is not strictly the exact timestamp for all devices as
  ///             of May 2024 (e.g. Magic Leap)
  /// @internal   TODO(ardk): Revisit naming. camera_timestamp_ms is unclear because this is also
  ///             pose_timestamp_ms
  uint64_t camera_timestamp_ms;

  /// @brief      The first camera image plane.
  /// @details    When provided as input to \c ARDK_SendFrame, the camera image attributes must
  ///             match ARDK's expectations.
  ///               1. The image is undistorted.
  ///               2. The pixel in the top-left corner of the image is the very first pixel
  ///                  represented in the data buffer.
  ///               3. The image is in landscape orientation (sensor on the left); i.e. if
  ///                  the image was captured on a mobile device held in portrait orientation,
  ///                  it appears rotated 90 degrees counter-clockwise.
  /// @note       If the VPS feature is enabled, the camera image must have a resolution of at
  ///             least 720x540 pixels.
  ARDK_CameraPlane camera_image_plane0;

  /// @brief      The second camera image plane. Depending on the active device's camera
  ///             image format, this may not be used.
  ARDK_CameraPlane camera_image_plane1;

  /// @brief      The third camera image plane. Depending on the active device's camera
  ///             image format, this may not be used.
  ARDK_CameraPlane camera_image_plane2;

  /// @brief      Depth buffer
  /// @note       Currently, ARDK only supports depth images that come in synced with
  ///             a camera image; i.e. the timestamp of the depth image needs to be the same
  ///             as the camera image/pose timestamp.
  const float *depth_image_data;

  /// @brief      Depth confidence buffer. The number of pixels represented in this buffer
  ///             should equal the number of pixels in the depth image buffer.
  const uint8_t *depth_confidence_data;

  /// @brief      Intrinsics of the depth camera.
  ARDK_CameraIntrinsics depth_image_intrinsics;

  /// @brief      An unique identifier for a single frame across frames within the same
  ///             instance of ARDK.
  uint32_t frame_id;

  /// @brief      The camera pose in the OpenCV coordinate system.
  /// @remarks    The OpenCV coordinate system is right-handed with the positive x-axis
  ///             pointing right, the positive y-axis pointing down, and the positive
  ///             z-axis pointing forward.
  ARDK_Transform camera_pose;

  /// @brief      Pose of the depth camera/sensor.  Platforms without a dedicated depth
  ///             camera must copy the value of camera_pose into this field.  A zero (identity)
  ///             matrix indicates depth pose was requested but unavailable for this frame.
  ARDK_Transform depth_camera_pose;

  /// @brief      Intrinsics of the image camera.
  ARDK_CameraIntrinsics camera_instrinsics;

  /// @brief      Camera image width
  /// @note       If the VPS feature is enabled, this value must be at least 720 pixels.
  uint32_t camera_image_width;

  /// @brief      Camera image height
  /// @note       If the VPS feature is enabled, this value must be at least 540 pixels.
  uint32_t camera_image_height;

  /// @brief      Camera image format
  ARDK_ImageFormat camera_image_format;

  /// @brief      Total number of pixels represented in the depth buffer.
  uint32_t depth_and_confidence_image_data_length;

  /// @brief      Width of the image represented in the depth buffer.
  uint32_t depth_image_data_width;

  /// @brief      Height of the image represented in the depth buffer.
  uint32_t depth_image_data_height;

  /// @brief      Screen orientation.
  /// @details    When the screen is in landscape left orientation, ARDK assumes the camera images
  ///             are oriented correctly upright. When the screen is in portrait orientation, ARDK
  ///             assumes the camera images are rotated 90 degrees counter-clockwise from their
  ///             upright orientation.
  /// @note       Some features may take a little longer than usual to generate new outputs each
  ///             time the screen orientation changes, depending on the feature's configured target
  ///             framerate.
  ARDK_Orientation screen_orientation;

  /// @brief      AR tracking state
  ARDK_TrackingState tracking_state;
} ARDK_FrameData;

#ifdef __cplusplus
}
#endif
