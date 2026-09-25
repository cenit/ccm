# Copyright Stefano Sinigardi

#.rst:
# FindDalsa-GigEVision
# --------
#
# Result Variables
# ^^^^^^^^^^^^^^^^
#
# This module will set the following variables in your project:
#
#  ``Dalsa-GigEVision_FOUND``
#    True if GigEV is found on the local system
#
#  ``GigEV_INCLUDE_DIRS``
#    Location of GigEV header files.
#
#  ``GigEV_LIBRARIES``
#    The GigEV libraries.
#

include(FindPackageHandleStandardArgs)

# GigE-Vision installer puts some scripts in /etc/profile.d/ to setup useful environment variables after installation. We exploit them to find library
set(GigEV_FOLDER_HINT "$ENV{GIGEV_DIR}" CACHE STRING "TeleDyne Dalsa-GigEVision root folder")
set(GenICam_FOLDER_HINT "$ENV{GENICAM_ROOT_V3_0}" CACHE STRING "GenICam root folder")

if(NOT GigEV_CORE_INCLUDE_DIR)
  find_path(GigEV_CORE_INCLUDE_DIR cordef.h
    HINTS /usr/local/include /usr/local/include/GigeV ${GigEV_FOLDER_HINT}
    PATH_SUFFIXES include)
endif()

if(NOT GigEV_CORE_LIBRARY)
  find_library(GigEV_CORE_LIBRARY GevApi
    HINTS /usr/local/lib /usr/local/include/GigeV ${GigEV_FOLDER_HINT}
    PATH_SUFFIXES lib)
endif()

if(NOT GigEV_W32_LIBRARY)
  find_library(GigEV_W32_LIBRARY CorW32
    HINTS /usr/local /usr/local/include/GigeV ${GigEV_FOLDER_HINT}
    PATH_SUFFIXES lib)
endif()

if(NOT GenICam_CORE_INCLUDE_DIR)
  find_path(GenICam_CORE_INCLUDE_DIR GenICam.h
    HINTS /opt/genicam_v3_0 ${GenICam_FOLDER_HINT}
    PATH_SUFFIXES library/CPP/include)
endif()

if(NOT GenICam_CORE_LIBRARY)
  find_library(GenICam_CORE_LIBRARY GenApi_gcc421_v3_0
    HINTS /opt/genicam_v3_0 ${GenICam_FOLDER_HINT}
    PATH_SUFFIXES bin/Linux64_x64)
endif()

if(NOT GCBase_CORE_LIBRARY)
  find_library(GCBase_CORE_LIBRARY GCBase_gcc421_v3_0
    HINTS /opt/genicam_v3_0 ${GenICam_FOLDER_HINT}
    PATH_SUFFIXES bin/Linux64_x64)
endif()

if(NOT GigEV_LIBRARY)
  list(APPEND GigEV_LIBRARY ${GigEV_CORE_LIBRARY} ${GenICam_CORE_LIBRARY} ${GCBase_CORE_LIBRARY})
endif()

if(NOT GigEV_INCLUDE_DIR)
  list(APPEND GigEV_INCLUDE_DIR ${GigEV_CORE_INCLUDE_DIR} ${GenICam_CORE_INCLUDE_DIR})
endif()

set(GigEV_INCLUDE_DIRS ${GigEV_INCLUDE_DIR})
set(GigEV_LIBRARIES ${GigEV_LIBRARY})
mark_as_advanced(GigEV_LIBRARY GigEV_INCLUDE_DIR)

find_package_handle_standard_args(Dalsa-GigEVision
      REQUIRED_VARS  GigEV_INCLUDE_DIR GigEV_LIBRARY
      VERSION_VAR    GigEV_VERSION
)

if(Dalsa-GigEVision_FOUND)
  if (NOT TARGET GigEVision::Core)
    add_library(GigEVision::Core UNKNOWN IMPORTED)
    set_target_properties(GigEVision::Core PROPERTIES
      IMPORTED_LOCATION                 "${GigEV_CORE_LIBRARY}"
      INTERFACE_INCLUDE_DIRECTORIES     "${GigEV_CORE_INCLUDE_DIR}"
      INTERFACE_COMPILE_OPTIONS         "-DPOSIX_HOSTPC;-D_REENTRANT;-fno-for-scope;-Wall;-Wno-parentheses;-Wno-missing-braces;-Wno-unused-but-set-variable;-Wno-unknown-pragmas;-Wno-cast-qual;-Wno-unused-function;-Wno-unused-label"
      IMPORTED_LINK_INTERFACE_LANGUAGES "C"
    )
  endif()
  if (NOT TARGET GigEVision::W32)
    add_library(GigEVision::W32 UNKNOWN IMPORTED)
    set_target_properties(GigEVision::W32 PROPERTIES
      IMPORTED_LOCATION                 "${GigEV_W32_LIBRARY}"
      INTERFACE_INCLUDE_DIRECTORIES     "${GigEV_CORE_INCLUDE_DIR}"
      INTERFACE_COMPILE_OPTIONS         "-DPOSIX_HOSTPC;-D_REENTRANT;-fno-for-scope;-Wall;-Wno-parentheses;-Wno-missing-braces;-Wno-unused-but-set-variable;-Wno-unknown-pragmas;-Wno-cast-qual;-Wno-unused-function;-Wno-unused-label"
      IMPORTED_LINK_INTERFACE_LANGUAGES "C"
    )
  endif()

  if (NOT TARGET GenICam::GCBase)
    add_library(GenICam::GCBase UNKNOWN IMPORTED)
    set_target_properties(GenICam::GCBase PROPERTIES
      IMPORTED_LOCATION                 "${GCBase_CORE_LIBRARY}"
      INTERFACE_INCLUDE_DIRECTORIES     "${GenICam_CORE_INCLUDE_DIR}"
      INTERFACE_COMPILE_OPTIONS         "-Dx86_64;-D_REENTRANT"
      IMPORTED_LINK_INTERFACE_LANGUAGES "C"
    )
  endif()

  if (NOT TARGET GenICam::Core)
    add_library(GenICam::Core UNKNOWN IMPORTED)
    set_target_properties(GenICam::Core PROPERTIES
      IMPORTED_LOCATION                 "${GenICam_CORE_LIBRARY}"
      INTERFACE_INCLUDE_DIRECTORIES     "${GenICam_CORE_INCLUDE_DIR}"
      INTERFACE_COMPILE_OPTIONS         "-Dx86_64;-D_REENTRANT"
      IMPORTED_LINK_INTERFACE_LANGUAGES "C"
    )
  endif()

  if (NOT TARGET Dalsa::GigEVision)
    add_library(Dalsa::GigEVision INTERFACE IMPORTED)
    set_property(TARGET Dalsa::GigEVision PROPERTY
      INTERFACE_LINK_LIBRARIES GigEVision::Core GigEVision::W32 GenICam::Core GenICam::GCBase
    )
  endif()
endif()
