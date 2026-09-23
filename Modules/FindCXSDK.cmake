# Copyright Stefano Sinigardi

#[=======================================================================[.rst:
FindCXSDK
---------

Finds the cxSDK by Automation Technology

Result Variables
^^^^^^^^^^^^^^^^

This module will set the following variables in your project:

``CXSDK_FOUND``
   True if cxSDK is found on the local system
 ``CXSDK_INCLUDE_DIRS``
   Location of cxSDK header files.
 ``CXSDK_LIBRARIES``
   The cxSDK libraries.

#]=======================================================================]

include(FindPackageHandleStandardArgs)

if("$ENV{PROCESSOR_ARCHITECTURE}" STREQUAL "AMD64")
  set(CXSDK_FOLDER_HINT "$ENV{CX_SDK_ROOT_64}" CACHE STRING "cxSDK Installation Folder")
elseif("$ENV{PROCESSOR_ARCHITECTURE}" STREQUAL "x86")
  set(CXSDK_FOLDER_HINT "$ENV{CX_SDK_ROOT_32}" CACHE STRING "cxSDK Installation Folder")
endif()

file(TO_CMAKE_PATH ${CXSDK_FOLDER_HINT} CXSDK_FOLDER_HINT)

if(CXSDK_FIND_REQUIRED)
  if(NOT EXISTS "${CXSDK_FOLDER_HINT}")
    message(FATAL_ERROR "cxSDK is not installed")
  endif()
  if(NOT EXISTS "${CXSDK_FOLDER_HINT}/cx3dLib")
    message(FATAL_ERROR "cx3dLib is not installed")
  endif()
  if(NOT EXISTS "${CXSDK_FOLDER_HINT}/cxBaseLib")
    message(FATAL_ERROR "cxBaseLib is not installed")
  endif()
  if(NOT EXISTS "${CXSDK_FOLDER_HINT}/cxCamLib")
    message(FATAL_ERROR "cxCamLib is not installed")
  endif()
endif()

if(NOT FORCE_USE_EXTERNAL_OPENCV)
  #set(OpenCV_DIR "${CXSDK_FOLDER_HINT}/ThirdParty/opencv-3.4.2/build_win_vc140_64_shared_vtk_static/")
  set(OpenCV_DIR "${CXSDK_FOLDER_HINT}/ThirdParty/opencv-3.4.2/build_win_vc140_64_shared_vtk_static/x64/vc14/lib/")
endif()
find_package(OpenCV REQUIRED)

include(${CXSDK_FOLDER_HINT}/cx3dLib/lib/cmake/Cx3dLibConfig.cmake)
include(${CXSDK_FOLDER_HINT}/cxBaseLib/lib/cmake/CxBaseLibConfig.cmake)
include(${CXSDK_FOLDER_HINT}/cxCamLib/lib/cmake/CxCamLibConfig.cmake)

if(TARGET AT::Cx3dLib)
  get_target_property(cx3dlib_include_dirs AT::Cx3dLib INTERFACE_INCLUDE_DIRECTORIES)
  get_target_property(cx3dlib_location_release AT::Cx3dLib IMPORTED_IMPLIB_RELEASE)
  list(APPEND CXSDK_INCLUDE_DIRS ${cx3dlib_include_dirs})
  list(APPEND CXSDK_LIBRARIES ${cx3dlib_location_release})
  message(STATUS "Found AT::Cx3dLib - INCLUDE_DIRECTORIES: ${cx3dlib_include_dirs}")
  message(STATUS "Found AT::Cx3dLib - LINK_LIBRARIES: ${cx3dlib_location_release}")
else()
  message(STATUS "Unable to find AT::Cx3dLib library")
endif()
if(TARGET AT::CxBaseLib)
  get_target_property(cxbaselib_include_dirs AT::CxBaseLib INTERFACE_INCLUDE_DIRECTORIES)
  get_target_property(cxbaselib_location_release AT::CxBaseLib IMPORTED_IMPLIB_RELEASE)
  list(APPEND CXSDK_INCLUDE_DIRS ${cxbaselib_include_dirs})
  list(APPEND CXSDK_LIBRARIES ${cxbaselib_location_release})
  message(STATUS "Found AT::CxBaseLib - INCLUDE_DIRECTORIES: ${cxbaselib_include_dirs}")
  message(STATUS "Found AT::CxBaseLib - LINK_LIBRARIES: ${cxbaselib_location_release}")
else()
  message(STATUS "Unable to find AT::CxBaseLib library")
endif()
if(TARGET AT::CxCamLib)
  get_target_property(cxcamlib_include_dirs AT::CxCamLib INTERFACE_INCLUDE_DIRECTORIES)
  get_target_property(cxcamlib_location_release AT::CxCamLib IMPORTED_IMPLIB_RELEASE)
  list(APPEND CXSDK_INCLUDE_DIRS ${cxcamlib_include_dirs})
  list(APPEND CXSDK_LIBRARIES ${cxcamlib_location_release})
  message(STATUS "Found AT::CxCamLib - INCLUDE_DIRECTORIES: ${cxcamlib_include_dirs}")
  message(STATUS "Found AT::CxCamLib - LINK_LIBRARIES: ${cxcamlib_location_release}")
else()
  message(STATUS "Unable to find AT::CxCamLib library")
endif()

list(REMOVE_DUPLICATES CXSDK_INCLUDE_DIRS)
list(REMOVE_DUPLICATES CXSDK_LIBRARIES)
set(CXSDK_VERSION "1.0.0" CACHE STRING "cxSDK Version")
set(CX_SDK_ROOT "${CXSDK_FOLDER_HINT}" CACHE STRING "cxSDK Installation Folder")

find_package_handle_standard_args(CXSDK
      REQUIRED_VARS  CXSDK_INCLUDE_DIRS CXSDK_LIBRARIES
      VERSION_VAR    CXSDK_VERSION
)
