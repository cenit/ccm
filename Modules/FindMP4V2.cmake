# Copyright Stefano Sinigardi

#.rst:
# FindMP4V2
# --------
#
# Result Variables
# ^^^^^^^^^^^^^^^^
#
# This module will set the following variables in your project:
#
#  ``MP4V2_FOUND``
#    True if MP4V2 is found on the local system
#
#  ``MP4V2_INCLUDE_DIRS``
#    Location of MP4V2 header files.
#
#  ``MP4V2_LIBRARIES``
#    The MP4V2 libraries.
#

include(FindPackageHandleStandardArgs)

find_package(PkgConfig QUIET)
pkg_check_modules(PC_MP4V2 QUIET mp4v2)

find_path(MP4V2_INCLUDE_DIR NAMES mp4v2/mp4v2.h
  PATH_SUFFIXES include
  HINTS ${MP4V2_ROOT} ${PC_MP4V2_INCLUDE_DIRS}
)

find_path(MP4V2_PRIVATE_INCLUDE_DIR NAMES impl.h
  PATH_SUFFIXES include/mp4v2/private
  HINTS ${MP4V2_ROOT} ${PC_MP4V2_INCLUDE_DIRS} ${MP4V2_INCLUDE_DIR}
)

find_library(MP4V2_LIBRARY
  NAMES mp4v2
  PATH_SUFFIXES lib
  HINTS ${MP4V2_ROOT} ${PC_MP4V2_LIBRARY_DIRS}
)

find_package_handle_standard_args(MP4V2
      REQUIRED_VARS  MP4V2_INCLUDE_DIR MP4V2_LIBRARY
)

set(MP4V2_LIBRARIES "${MP4V2_LIBRARY}")
mark_as_advanced(MP4V2_INCLUDE_DIR MP4V2_LIBRARY)

if(MP4V2_FOUND AND NOT TARGET mp4v2::mp4v2)
  add_library(mp4v2::mp4v2 UNKNOWN IMPORTED)
  set_target_properties(mp4v2::mp4v2 PROPERTIES
    IMPORTED_LOCATION                 "${MP4V2_LIBRARY}"
    INTERFACE_INCLUDE_DIRECTORIES     "${MP4V2_INCLUDE_DIR}"
    IMPORTED_LINK_INTERFACE_LANGUAGES "C" )
endif()

if(MP4V2_FOUND AND MP4V2_PRIVATE_INCLUDE_DIR AND NOT TARGET mp4v2::mp4v2_with_private_includes)
  add_library(mp4v2::mp4v2_with_private_includes UNKNOWN IMPORTED)
  set_target_properties(mp4v2::mp4v2_with_private_includes PROPERTIES
    IMPORTED_LOCATION                 "${MP4V2_LIBRARY}"
    INTERFACE_INCLUDE_DIRECTORIES     "${MP4V2_INCLUDE_DIR};${MP4V2_PRIVATE_INCLUDE_DIR}"
    IMPORTED_LINK_INTERFACE_LANGUAGES "C" )
endif()
