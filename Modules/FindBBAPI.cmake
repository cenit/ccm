# Copyright Stefano Sinigardi

#.rst:
# FindBBAPI
# --------
#
# Result Variables
# ^^^^^^^^^^^^^^^^
#
# This module will set the following variables in your project:
#
#  ``BBAPI_FOUND``
#    True if BBAPI is found on the local system
#
#  ``BBAPI_INCLUDE_DIRS``
#    Location of BBAPI header files.
#

include(FindPackageHandleStandardArgs)

find_path(BBAPI_INCLUDE_DIR TcBaDevDef_gpl.h PATHS ${CMAKE_CURRENT_SOURCE_DIR}/BBAPI ${CMAKE_CURRENT_SOURCE_DIR}/../BBAPI)
if(NOT BBAPI_INCLUDE_DIR)
  find_path(BBAPI_INCLUDE_DIR TcBaDevDef.h PATHS ${CMAKE_CURRENT_SOURCE_DIR}/BBAPI ${CMAKE_CURRENT_SOURCE_DIR}/../BBAPI)
endif()

set(BBAPI_INCLUDE_DIRS ${BBAPI_INCLUDE_DIR})
mark_as_advanced(BBAPI_INCLUDE_DIR)

find_package_handle_standard_args(BBAPI
      REQUIRED_VARS  BBAPI_INCLUDE_DIR
)
