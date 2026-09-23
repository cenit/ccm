# Copyright Stefano Sinigardi

#[=======================================================================[.rst:
FindGOSDK
---------

Finds the GOSDK by LMI3D

Result Variables
^^^^^^^^^^^^^^^^

This module will set the following variables in your project:

 ``GOSDK_FOUND``
   True if GOSDK is found on the local system
 ``GOSDK_INCLUDE_DIR``
   Location of GOSDK header files.
 ``KAPI_INCLUDE_DIR``
   Location of kApi header files.
 ``GOSDK_LIBRARY``
   The GOSDK libraries.
 ``KAPI_LIBRARY``
   The kApi libraries.

#]=======================================================================]

include(FindPackageHandleStandardArgs)
include(SelectLibraryConfigurations)

set(GOSDK_VERSION "5.3.22.22" CACHE STRING "")

if(APPLE)
  message(FATAL_ERROR "Unsupported architecture")
elseif(UNIX)
  if(CMAKE_SIZEOF_VOID_P EQUAL 8)
    set(GOSDK_ARCH "linux_x64")
  elseif(CMAKE_SIZEOF_VOID_P EQUAL 4)
    message(FATAL_ERROR "Unsupported architecture")
  endif()
elseif(MSVC)
  if(CMAKE_SIZEOF_VOID_P EQUAL 8)
    set(GOSDK_ARCH "win64")
  elseif(CMAKE_SIZEOF_VOID_P EQUAL 4)
    set(GOSDK_ARCH "win32")
  endif()
endif()

if(EXISTS "$ENV{GO_SDK_4}")
  set(GOSDK_PATH $ENV{GO_SDK_4})
else()
  message(FATAL_ERROR "Please create a GO_SDK_4 env variable pointing to the SDK folder")
endif()

find_path(
  GOSDK_INCLUDE_DIR
  NAMES GoSdk/GoSdk.h
  PATHS ${GOSDK_PATH}/Gocator/GoSdk
)

find_path(
  KAPI_INCLUDE_DIR
  NAMES kApi/kApi.h
  PATHS ${GOSDK_PATH}/Platform/kApi
)

message(STATUS "Gocator Headers found at ${GOSDK_INCLUDE_DIR}")
message(STATUS "kApi Headers found at ${KAPI_INCLUDE_DIR}")

message(STATUS "Looking for GOSDK libraries in ${GOSDK_PATH}/lib/${GOSDK_ARCH}d/ and ${GOSDK_PATH}/lib/${GOSDK_ARCH}/")
find_library(
  GOSDK_LIBRARY_DEBUG
  NAMES GoSdk
  PATHS ${GOSDK_PATH}/lib/${GOSDK_ARCH}d/
)
find_library(
  GOSDK_LIBRARY_RELEASE
  NAMES GoSdk
  PATHS ${GOSDK_PATH}/lib/${GOSDK_ARCH}/
)
select_library_configurations(GOSDK)
set(GOSDK_LIBRARY_GENEX "$<$<CONFIG:Debug>:${GOSDK_LIBRARY_DEBUG}>$<$<CONFIG:Release>:${GOSDK_LIBRARY_RELEASE}>" CACHE STRING "")

find_library(
  KAPI_LIBRARY_DEBUG
  NAMES kApi
  PATHS ${GOSDK_PATH}/lib/${GOSDK_ARCH}d/
)
find_library(
  KAPI_LIBRARY_RELEASE
  NAMES kApi
  PATHS ${GOSDK_PATH}/lib/${GOSDK_ARCH}/
)
select_library_configurations(KAPI)
set(KAPI_LIBRARY_GENEX "$<$<CONFIG:Debug>:${KAPI_LIBRARY_DEBUG}>$<$<CONFIG:Release>:${KAPI_LIBRARY_RELEASE}>" CACHE STRING "")

message(STATUS "Gocator Libraries found at ${GOSDK_LIBRARY}")
message(STATUS "kApi Libraries found at ${KAPI_LIBRARY}")

find_package_handle_standard_args(GOSDK
  REQUIRED_VARS  GOSDK_INCLUDE_DIR KAPI_INCLUDE_DIR GOSDK_LIBRARY KAPI_LIBRARY
  VERSION_VAR    GOSDK_VERSION
)

if( GOSDK_FOUND AND NOT TARGET GO::SDK )
  add_library( GO::SDK      UNKNOWN IMPORTED )
  set_target_properties( GO::SDK PROPERTIES
    IMPORTED_LOCATION_RELEASE         "${GOSDK_LIBRARY_RELEASE}"
    IMPORTED_LOCATION_DEBUG           "${GOSDK_LIBRARY_DEBUG}"
    INTERFACE_INCLUDE_DIRECTORIES     "${GOSDK_INCLUDE_DIR}"
    IMPORTED_LINK_INTERFACE_LANGUAGES "C" )
endif()

if( GOSDK_FOUND AND NOT TARGET GO::KAPI )
  add_library( GO::KAPI      UNKNOWN IMPORTED )
  set_target_properties( GO::KAPI PROPERTIES
    IMPORTED_LOCATION_RELEASE         "${KAPI_LIBRARY_RELEASE}"
    IMPORTED_LOCATION_DEBUG           "${KAPI_LIBRARY_DEBUG}"
    INTERFACE_INCLUDE_DIRECTORIES     "${KAPI_INCLUDE_DIR}"
    IMPORTED_LINK_INTERFACE_LANGUAGES "C" )
endif()

target_link_libraries(GO::SDK INTERFACE GO::KAPI)
