// Copyright 2022-2025 Niantic.

#pragma once

#ifdef __cplusplus

#include <cstdint>

extern "C" {
#else
#include <stdint.h>
#endif

/// @brief        Configuration for VPS2
/// @note         Struct fields left zeroed-out will be internally converted to default
///               values.
typedef struct ARDK_VPS2_Config {
  /// @brief      If true, universal localization is enabled.
  /// @details    Universal localization provides geographic positioning that works anywhere
  ///             without requiring pre-scanning.
  bool universal_localization_enabled;

  /// @brief      Number of requests per second to send the cloud for universal localization.
  /// @details    This is 4.0f in the default configuration.
  float universal_localization_requests_per_second;

  /// @brief      If true, localization on VPS maps is enabled.
  /// @details    VPS maps only exist in pre-scanned areas. Your device must be localized on
  ///             a VPS map in order for VPS anchors to be placed with high accuracy.
  bool vps_map_localization_enabled;

  /// @brief      Number of VPS localization requests per second to send the server prior to
  ///             the first successful localization on a VPS map.
  /// @details    This is 1.0f in the default configuration.
  float initial_vps_requests_per_second;

  /// @brief      Number of VPS localization requests per second to send the server while
  ///             successfully localized on a VPS map.
  /// @details    This is 0.2f in the default configuration.
  float continuous_vps_requests_per_second;

  /// @brief      If true, geolocation smoothing is enabled.
  /// @details    This is true in the default configuration.
  bool geolocation_smoothing_enabled;
} ARDK_VPS2_Config;

#ifdef __cplusplus
}
#endif
