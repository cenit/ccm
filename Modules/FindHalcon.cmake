# Copyright Stefano Sinigardi

#.rst:
# FindHalcon
# --------
#
# Result Variables
# ^^^^^^^^^^^^^^^^
#
# This module will set the following variables in your project:
#
#  ``Halcon_FOUND``
#    True if Halcon is found on the local system
#
#  ``Halcon_INCLUDE_DIR``
#    Location of Halcon header files.
#
#  ``Halcon_LIBRARY``
#    The Halcon libraries.
#

include(FindPackageHandleStandardArgs)

# GigE-Vision installer puts some scripts in /etc/profile.d/ to setup useful environment variables after installation. We exploit them to find library
set(Halcon_FOLDER_HINT "$ENV{HALCONROOT}" CACHE STRING "Halcon root folder")
set(Halcon_ARCH_HINT "$ENV{HALCONARCH}" CACHE STRING "Halcon architecture")

if(NOT Halcon_BASE_INCLUDE_DIR)
  find_path(Halcon_BASE_INCLUDE_DIR Halcon.h
    HINTS "${Halcon_FOLDER_HINT}"
    PATH_SUFFIXES include)
endif()

if(NOT Halcon_C_INCLUDE_DIR)
  find_path(Halcon_C_INCLUDE_DIR Hdevthread.h
    HINTS "${Halcon_FOLDER_HINT}/include/halconc")
endif()

if(NOT Halcon_CPP_INCLUDE_DIR)
  find_path(Halcon_CPP_INCLUDE_DIR HalconCpp.h
    HINTS "${Halcon_FOLDER_HINT}/include/halconcpp")
endif()

if(NOT Halcon_BASE_LIBRARY)
  find_library(Halcon_BASE_LIBRARY halcon
    HINTS "${Halcon_FOLDER_HINT}/lib/${Halcon_ARCH_HINT}")
endif()

if(NOT Halcon_C_LIBRARY)
  find_library(Halcon_C_LIBRARY halconc
    HINTS "${Halcon_FOLDER_HINT}/lib/${Halcon_ARCH_HINT}")
endif()

if(NOT Halcon_CPP_LIBRARY)
  find_library(Halcon_CPP_LIBRARY halconcpp
    HINTS "${Halcon_FOLDER_HINT}/lib/${Halcon_ARCH_HINT}")
endif()

if(NOT Halcon_LIBRARY)
  list(APPEND Halcon_LIBRARY "${Halcon_BASE_LIBRARY}" "${Halcon_C_LIBRARY}" "${Halcon_CPP_LIBRARY}")
endif()

if(NOT Halcon_INCLUDE_DIR)
  list(APPEND Halcon_INCLUDE_DIR "${Halcon_BASE_INCLUDE_DIR}" "${Halcon_C_INCLUDE_DIR}" "${Halcon_CPP_INCLUDE_DIR}")
endif()

set(Halcon_INCLUDE_DIRS "${Halcon_INCLUDE_DIR}")
set(Halcon_LIBRARIES "${Halcon_LIBRARY}")
mark_as_advanced(Halcon_LIBRARY Halcon_INCLUDE_DIR)

find_package_handle_standard_args(Halcon
      REQUIRED_VARS  Halcon_INCLUDE_DIR Halcon_LIBRARY
)

if(Halcon_FOUND)
  if (NOT TARGET Halcon::BASE)
    add_library(Halcon::BASE UNKNOWN IMPORTED)
    set_target_properties(Halcon::BASE PROPERTIES
      IMPORTED_LOCATION                 "${Halcon_BASE_LIBRARY}"
      INTERFACE_INCLUDE_DIRECTORIES     "${Halcon_BASE_INCLUDE_DIR}"
      IMPORTED_LINK_INTERFACE_LANGUAGES "C"
    )
  endif()
  if (NOT TARGET Halcon::C)
    add_library(Halcon::C UNKNOWN IMPORTED)
    set_target_properties(Halcon::C PROPERTIES
      IMPORTED_LOCATION                 "${Halcon_C_LIBRARY}"
      INTERFACE_INCLUDE_DIRECTORIES     "${Halcon_C_INCLUDE_DIR}"
      IMPORTED_LINK_INTERFACE_LANGUAGES "C"
    )
  endif()
  if (NOT TARGET Halcon::CPP)
    add_library(Halcon::CPP UNKNOWN IMPORTED)
    set_target_properties(Halcon::CPP PROPERTIES
      IMPORTED_LOCATION                 "${Halcon_CPP_LIBRARY}"
      INTERFACE_INCLUDE_DIRECTORIES     "${Halcon_CPP_INCLUDE_DIR}"
      IMPORTED_LINK_INTERFACE_LANGUAGES "C"
    )
  endif()
  if (NOT TARGET Halcon::Halcon)
    add_library(Halcon::Halcon INTERFACE IMPORTED)
    set_property(TARGET Halcon::Halcon PROPERTY
      INTERFACE_LINK_LIBRARIES Halcon::BASE Halcon::C Halcon::CPP
    )
  endif()
endif()
