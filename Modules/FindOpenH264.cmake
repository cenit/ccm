# Copyright Stefano Sinigardi

#.rst:
# FindOpenH264
# --------
#
# Result Variables
# ^^^^^^^^^^^^^^^^
#
# This module will set the following variables in your project:
#
#  ``OpenH264_FOUND``
#    True if OpenH264 is found on the local system
#
#  ``OpenH264_INCLUDE_DIRS``
#    Location of OpenH264 header files.
#
#  ``OpenH264_LIBRARIES``
#    The OpenH264 libraries.
#

include(FindPackageHandleStandardArgs)

find_package(PkgConfig QUIET)
pkg_check_modules(PC_OpenH264 QUIET openh264)

find_path(OpenH264_INCLUDE_DIR NAMES wels/codec_api.h wels/codec_app_def.h wels/codec_def.h
  PATH_SUFFIXES include
  HINTS ${OpenH264_ROOT} ${PC_OpenH264_INCLUDE_DIRS}
)

find_library(OpenH264_LIBRARY
  NAMES openh264_dll openh264 welsdec
  PATH_SUFFIXES lib
  HINTS ${OpenH264_ROOT} ${PC_OpenH264_LIBRARY_DIRS}
)

find_package_handle_standard_args(OpenH264
      REQUIRED_VARS  OpenH264_INCLUDE_DIR OpenH264_LIBRARY
)

set(OpenH264_LIBRARIES ${OpenH264_LIBRARY})
mark_as_advanced(OpenH264_INCLUDE_DIR OpenH264_LIBRARY)

if(OpenH264_FOUND AND NOT TARGET OpenH264::openh264)
  add_library(OpenH264::openh264 UNKNOWN IMPORTED)
  set_target_properties(OpenH264::openh264 PROPERTIES
    IMPORTED_LOCATION                 "${OpenH264_LIBRARY}"
    INTERFACE_INCLUDE_DIRECTORIES     "${OpenH264_INCLUDE_DIR}"
    IMPORTED_LINK_INTERFACE_LANGUAGES "C" )
endif()
