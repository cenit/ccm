# Distributed under the OSI-approved BSD 3-Clause License.
# Copyright Stefano Sinigardi

#.rst:
# FindPThreads
# ------------
#
# Find the PThreads includes and library.
#
# Result Variables
# ^^^^^^^^^^^^^^^^
#
# This module defines the following variables:
#
# ``PTHREADS_FOUND``
#   True if PThreads library found
#
# ``PTHREADS_INCLUDE_DIRS``
#   Location of PThreads headers
#
# ``PTHREADS_LIBRARIES``
#   List of libraries to link with when using PThreads
#

include(${CMAKE_ROOT}/Modules/FindPackageHandleStandardArgs.cmake)
include(${CMAKE_ROOT}/Modules/SelectLibraryConfigurations.cmake)

find_path(PTHREADS_INCLUDE_DIR NAMES pthread.h)

# Allow libraries to be set manually
if(NOT PTHREADS_LIBRARY)
  find_library(PTHREADS_LIBRARY_RELEASE NAMES pthread pthreads pthreadsVC2)
  find_library(PTHREADS_LIBRARY_DEBUG NAMES pthreadd pthreadsd pthreadsVC2d)
  select_library_configurations(PTHREADS)
endif()

find_package_handle_standard_args(PTHREADS DEFAULT_MSG PTHREADS_LIBRARY PTHREADS_INCLUDE_DIR)
mark_as_advanced(PTHREADS_INCLUDE_DIR PTHREADS_LIBRARY)

if(PTHREADS_FOUND)
	SET(PTHREADS_LIBRARIES    ${PTHREADS_LIBRARY})
	SET(PTHREADS_INCLUDE_DIRS ${PTHREADS_INCLUDE_DIR})
else()
	SET(PTHREADS_LIBRARIES)
	SET(PTHREADS_INCLUDE_DIRS)
endif()
