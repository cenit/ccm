# Copyright Stefano Sinigardi

#.rst:
# FindTcADS
# --------
#
# Result Variables
# ^^^^^^^^^^^^^^^^
#
# This module will set the following variables in your project:
#
#  ``TcADS_FOUND``
#    True if TwinCAT ADS is found on the local system
#
#  ``TcADS_INCLUDE_DIRS``
#    Location of TwinCAT ADS header files
#
#  ``TcADS_LIBRARIES``
#    List of TwinCAT ADS libraries
#

include(FindPackageHandleStandardArgs)

if (DEFINED ENV{TWINCATDIR})
  file(TO_CMAKE_PATH "$ENV{TWINCATDIR}" ENV_TWINCATDIR)
  list(APPEND PATHS_TO_SEARCH "${ENV_TWINCATDIR}")
endif()
if (DEFINED ENV{TWINCAT3DIR})
  file(TO_CMAKE_PATH "$ENV{TWINCAT3DIR}" ENV_TWINCAT3DIR)
  list(APPEND PATHS_TO_SEARCH "${ENV_TWINCAT3DIR}/..")
endif()
find_path(TwinCAT_ADS_INCLUDE_DIR TcAdsDef.h TcAdsAPI.h PATHS ${PATHS_TO_SEARCH} PATH_SUFFIXES "AdsApi/TcAdsDll/Include")

if (CMAKE_SIZEOF_VOID_P EQUAL 4)
  message(STATUS "Looking for TcADS 32 bit library")
  find_library(TwinCAT_ADS_LIBRARY TcAdsDll PATHS ${PATHS_TO_SEARCH} PATH_SUFFIXES "AdsApi/TcAdsDll/Lib")
endif()

if (CMAKE_SIZEOF_VOID_P EQUAL 8)
  message(STATUS "Looking for TcADS 64 bit library")
  find_library(TwinCAT_ADS_LIBRARY TcAdsDll PATHS ${PATHS_TO_SEARCH} PATH_SUFFIXES "AdsApi/TcAdsDll/x64/lib" "AdsApi/TcAdsDll/Lib/x64")
endif()


mark_as_advanced(TwinCAT_ADS_INCLUDE_DIR)
mark_as_advanced(TwinCAT_ADS_LIBRARY)

find_package_handle_standard_args(TcADS
      REQUIRED_VARS  TwinCAT_ADS_INCLUDE_DIR TwinCAT_ADS_LIBRARY
)

if(TcADS_FOUND)
  set(TcADS_INCLUDE_DIRS ${TwinCAT_ADS_INCLUDE_DIR})
  set(TcADS_LIBRARIES ${TwinCAT_ADS_LIBRARY})
  # kept for consumers of the old (misspelt, previously always empty) name
  set(TwinCAT_ADS_INCLUDE_DIRS ${TwinCAT_ADS_INCLUDE_DIR})
endif()

if( TcADS_FOUND AND NOT TARGET TwinCAT::ADS )
  add_library( TwinCAT::ADS      UNKNOWN IMPORTED )
  set_target_properties( TwinCAT::ADS PROPERTIES
    IMPORTED_LOCATION                 "${TwinCAT_ADS_LIBRARY}"
    INTERFACE_INCLUDE_DIRECTORIES     "${TwinCAT_ADS_INCLUDE_DIR}"
    IMPORTED_LINK_INTERFACE_LANGUAGES "C" )
endif()
