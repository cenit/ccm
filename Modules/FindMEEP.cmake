# Copyright Stefano Sinigardi

#[=======================================================================[.rst:
FindMEEP
---------

Finds the MEEP library

Result Variables
^^^^^^^^^^^^^^^^

This module will set the following variables in your project:

``MEEP_FOUND``
   True if MEEP is found on the local system
 ``MEEP_INCLUDE_DIRS``
   Location of MEEP header files.
 ``MEEP_LIBRARIES``
   The MEEP libraries.

#]=======================================================================]

include(FindPackageHandleStandardArgs)
include(SelectLibraryConfigurations)
include(CMakeFindDependencyMacro)

if(NOT MEEP_INCLUDE_DIR)
  find_path(MEEP_INCLUDE_DIR meep.hpp)
endif()

if(NOT MEEP_LIBRARY)
  find_library(MEEP_LIBRARY meep)
  message(STATUS "Found MEEP_LIBRARY: ${MEEP_LIBRARY}")
endif()

if(NOT CTLGEOM_LIBRARY)
  find_library(CTLGEOM_LIBRARY ctlgeom)
  list(APPEND MEEP_LIBRARY ${CTLGEOM_LIBRARY})
  message(STATUS "Found CTLGEOM_LIBRARY: ${CTLGEOM_LIBRARY}")
endif()

find_dependency(LAPACK)
list(APPEND MEEP_LIBRARY ${LAPACK_LIBRARIES})
find_dependency(FFTW3)
list(APPEND MEEP_LIBRARY FFTW3::fftw3)

if(MINGW)
  find_library(GFORTRAN_LIBRARY gfortran)
  list(APPEND MEEP_LIBRARY ${GFORTRAN_LIBRARY})
  message(STATUS "Found GFORTRAN_LIBRARY: ${GFORTRAN_LIBRARY}")

  find_library(QUADMATH_LIBRARY quadmath)
  list(APPEND MEEP_LIBRARY ${QUADMATH_LIBRARY})
  message(STATUS "Found QUADMATH_LIBRARY: ${QUADMATH_LIBRARY}")
endif()

set(MEEP_INCLUDE_DIR ${MEEP_INCLUDE_DIR} CACHE STRING "")
set(MEEP_LIBRARY ${MEEP_LIBRARY} CACHE STRING "")
set(MEEP_INCLUDE_DIRS ${MEEP_INCLUDE_DIR} CACHE STRING "")
set(MEEP_LIBRARIES ${MEEP_LIBRARY} CACHE STRING "")

find_package_handle_standard_args(MEEP
      REQUIRED_VARS  MEEP_INCLUDE_DIRS MEEP_LIBRARIES
)
