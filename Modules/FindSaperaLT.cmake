# Copyright Stefano Sinigardi

#.rst:
# FindSaperaLT
# --------
#
# Result Variables
# ^^^^^^^^^^^^^^^^
#
# This module will set the following variables in your project:
#
#  ``SaperaLT_FOUND``
#    True if SaperaLT is found on the local system
#
#  ``SaperaLT_INCLUDE_DIRS``
#    Location of SaperaLT header files.
#
#  ``SaperaLT_LIBRARIES``
#    The SaperaLT libraries.
#

include(FindPackageHandleStandardArgs)

if("$ENV{PROCESSOR_ARCHITEW6432}" STREQUAL "")
  set(SAPERA_LT_FOLDER_HINT "$ENV{ProgramFiles}/Teledyne DALSA/Sapera" CACHE STRING "Sapera LT SDK Installation Folder")
  if("$ENV{PROCESSOR_ARCHITECTURE}" STREQUAL "x86")
    # "pure" 32-bit environment...
  else()
    # "pure" 64-bit environment...
  endif()
else()
  if("$ENV{PROCESSOR_ARCHITECTURE}" STREQUAL "x86")
    # 32-bit program running with an underlying 64-bit environment available
    set(SAPERA_LT_FOLDER_HINT "$ENV{ProgramW6432}/Teledyne DALSA/Sapera" CACHE STRING "Sapera LT SDK Installation Folder")
  else()
    # theoretically impossible case...
  endif()
endif()

if(NOT SaperaLT_CORE_INCLUDE_DIR)
  find_path(SaperaLT_CORE_INCLUDE_DIR SapVersion.h
    HINTS ${SAPERA_LT_FOLDER_HINT}
    PATH_SUFFIXES Include)
endif()

if(NOT SaperaLT_CLASS_INCLUDE_DIR)
  find_path(SaperaLT_CLASS_INCLUDE_DIR SapClassBasic.h
    HINTS ${SAPERA_LT_FOLDER_HINT}
    PATH_SUFFIXES Classes/Basic)
endif()

if(NOT SaperaLT_CLASSGUI_INCLUDE_DIR)
  find_path(SaperaLT_CLASSGUI_INCLUDE_DIR SapClassGui.h
    HINTS ${SAPERA_LT_FOLDER_HINT}
    PATH_SUFFIXES Classes/Gui)
endif()

if(MSVC)
  if(CMAKE_SIZEOF_VOID_P EQUAL 8)
    set(SAPERA_LT_ARCH "Win64")
  elseif(CMAKE_SIZEOF_VOID_P EQUAL 4)
    set(SAPERA_LT_ARCH "Win32")
  endif()
  if (MSVC_TOOLSET_VERSION EQUAL 120)
    set(SAPERA_LT_ARCH_VS_VER "${SAPERA_LT_ARCH}/VS2013")
  elseif(MSVC_TOOLSET_VERSION EQUAL 140)
    set(SAPERA_LT_ARCH_VS_VER "${SAPERA_LT_ARCH}/VS2015")
  elseif(MSVC_TOOLSET_VERSION EQUAL 141)
    set(SAPERA_LT_ARCH_VS_VER "${SAPERA_LT_ARCH}/VS2017")
  elseif(MSVC_TOOLSET_VERSION EQUAL 142 OR MSVC_TOOLSET_VERSION EQUAL 143 OR MSVC_TOOLSET_VERSION EQUAL 145)
    set(SAPERA_LT_ARCH_VS_VER "${SAPERA_LT_ARCH}/VS2019")
  else()
    set(SAPERA_LT_ARCH_VS_VER "${SAPERA_LT_ARCH}")
  endif()
endif()

if(NOT SaperaLT_CORE_LIBRARY)
  find_library(SaperaLT_CORE_LIBRARY corapi
    HINTS ${SAPERA_LT_FOLDER_HINT}
    PATH_SUFFIXES Lib/${SAPERA_LT_ARCH})
endif()

if(NOT SaperaLT_CLASS_LIBRARY)
  find_library(SaperaLT_CLASS_LIBRARY SapClassBasic
    HINTS ${SAPERA_LT_FOLDER_HINT}
    PATH_SUFFIXES Lib/${SAPERA_LT_ARCH})
endif()

if(NOT SaperaLT_CLASSGUI_LIBRARY)
  find_library(SaperaLT_CLASSGUI_LIBRARY SapClassGui
    HINTS ${SAPERA_LT_FOLDER_HINT}
    PATH_SUFFIXES Lib/${SAPERA_LT_ARCH} Lib/${SAPERA_LT_ARCH_VS_VER})
endif()

if(NOT SaperaLT_COREPP_LIBRARY)
  find_library(SaperaLT_COREPP_LIBRARY corppapi
    HINTS ${SAPERA_LT_FOLDER_HINT}
    PATH_SUFFIXES Lib/${SAPERA_LT_ARCH})
endif()

if(NOT SaperaLT_LIBRARY)
  list(APPEND SaperaLT_LIBRARY ${SaperaLT_CORE_LIBRARY} ${SaperaLT_CLASS_LIBRARY} ${SaperaLT_CLASSGUI_LIBRARY})
  if(SaperaLT_COREPP_LIBRARY)
    list(APPEND SaperaLT_LIBRARY ${SaperaLT_COREPP_LIBRARY})
  endif()
endif()

if(NOT SaperaLT_INCLUDE_DIR)
  list(APPEND SaperaLT_INCLUDE_DIR ${SaperaLT_CLASS_INCLUDE_DIR} ${SaperaLT_CLASSGUI_INCLUDE_DIR} ${SaperaLT_CORE_INCLUDE_DIR})
endif()

set(SaperaLT_INCLUDE_DIRS ${SaperaLT_INCLUDE_DIR})
set(SaperaLT_LIBRARIES ${SaperaLT_LIBRARY})
mark_as_advanced(SaperaLT_LIBRARY SaperaLT_INCLUDE_DIR)

if(EXISTS "${SaperaLT_CORE_INCLUDE_DIR}/SapVersion.h")
  file(READ ${SaperaLT_CORE_INCLUDE_DIR}/SapVersion.h SAPVERSION_HEADER_CONTENTS)
    string(REGEX MATCH "define SAPERA_LT_VERSION_MAJOR * +([0-9]+)"
                 SaperaLT_VERSION_MAJOR "${SAPVERSION_HEADER_CONTENTS}")
    string(REGEX REPLACE "define SAPERA_LT_VERSION_MAJOR * +([0-9]+)" "\\1"
                 SaperaLT_VERSION_MAJOR "${SaperaLT_VERSION_MAJOR}")

    string(REGEX MATCH "define SAPERA_LT_VERSION_MINOR * +([0-9]+)"
                 SaperaLT_VERSION_MINOR "${SAPVERSION_HEADER_CONTENTS}")
    string(REGEX REPLACE "define SAPERA_LT_VERSION_MINOR * +([0-9]+)" "\\1"
                 SaperaLT_VERSION_MINOR "${SaperaLT_VERSION_MINOR}")

    string(REGEX MATCH "define SAPERA_LT_REVISION_NUMBER * +([0-9]+)"
                 SaperaLT_VERSION_PATCH "${SAPVERSION_HEADER_CONTENTS}")
    string(REGEX REPLACE "define SAPERA_LT_REVISION_NUMBER * +([0-9]+)" "\\1"
                 SaperaLT_VERSION_PATCH "${SaperaLT_VERSION_PATCH}")

    string(REGEX MATCH "define SAPERA_LT_BUILD_NUMBER * +([0-9]+)"
                 SaperaLT_VERSION_TWEAK "${SAPVERSION_HEADER_CONTENTS}")
    string(REGEX REPLACE "define SAPERA_LT_BUILD_NUMBER * +([0-9]+)" "\\1"
                 SaperaLT_VERSION_TWEAK "${SaperaLT_VERSION_TWEAK}")

  if(NOT SaperaLT_VERSION_MAJOR)
    set(SaperaLT_VERSION "?")
  else()
    set(SaperaLT_VERSION "${SaperaLT_VERSION_MAJOR}.${SaperaLT_VERSION_MINOR}.${SaperaLT_VERSION_PATCH}.${SaperaLT_VERSION_TWEAK}")
  endif()
endif()

find_package_handle_standard_args(SaperaLT
      REQUIRED_VARS  SaperaLT_INCLUDE_DIR SaperaLT_LIBRARY
      VERSION_VAR    SaperaLT_VERSION
)

if(SaperaLT_FOUND)
  if (NOT TARGET SaperaLT::Core)
    add_library(SaperaLT::Core      UNKNOWN IMPORTED)
    set_target_properties(SaperaLT::Core PROPERTIES
      IMPORTED_LOCATION                 "${SaperaLT_CORE_LIBRARY}"
      INTERFACE_INCLUDE_DIRECTORIES     "${SaperaLT_CORE_INCLUDE_DIR}"
      IMPORTED_LINK_INTERFACE_LANGUAGES "C")
  endif()
  if (NOT TARGET SaperaLT::Class)
    add_library(SaperaLT::Class      UNKNOWN IMPORTED)
    set_target_properties(SaperaLT::Class PROPERTIES
      IMPORTED_LOCATION                 "${SaperaLT_CLASS_LIBRARY}"
      INTERFACE_INCLUDE_DIRECTORIES     "${SaperaLT_CLASS_INCLUDE_DIR}"
      IMPORTED_LINK_INTERFACE_LANGUAGES "C")
  endif()
  if (NOT TARGET SaperaLT::ClassGui)
    add_library(SaperaLT::ClassGui      UNKNOWN IMPORTED)
    set_target_properties(SaperaLT::ClassGui PROPERTIES
      IMPORTED_LOCATION                 "${SaperaLT_CLASSGUI_LIBRARY}"
      INTERFACE_INCLUDE_DIRECTORIES     "${SaperaLT_CLASSGUI_INCLUDE_DIR}"
      IMPORTED_LINK_INTERFACE_LANGUAGES "C")
  endif()
  if (SaperaLT_COREPP_LIBRARY AND NOT TARGET SaperaLT::CorePP)
    add_library(SaperaLT::CorePP      UNKNOWN IMPORTED)
    set_target_properties(SaperaLT::CorePP PROPERTIES
      IMPORTED_LOCATION                 "${SaperaLT_COREPP_LIBRARY}"
      INTERFACE_INCLUDE_DIRECTORIES     "${SaperaLT_CORE_INCLUDE_DIR}"
      IMPORTED_LINK_INTERFACE_LANGUAGES "C")
  endif()
  if (SaperaLT_COREPP_LIBRARY AND NOT TARGET SaperaLT::SaperaLT)
    add_library(SaperaLT::SaperaLT INTERFACE IMPORTED)
    set_property(TARGET SaperaLT::SaperaLT PROPERTY
      INTERFACE_LINK_LIBRARIES SaperaLT::Core SaperaLT::Class SaperaLT::ClassGui SaperaLT::CorePP
    )
  elseif (NOT TARGET SaperaLT::SaperaLT)
    add_library(SaperaLT::SaperaLT INTERFACE IMPORTED)
    set_property(TARGET SaperaLT::SaperaLT PROPERTY
      INTERFACE_LINK_LIBRARIES SaperaLT::Core SaperaLT::Class SaperaLT::ClassGui
    )
  endif()
endif()
