# Distributed under the OSI-approved BSD 3-Clause License.
# Copyright Stefano Sinigardi
#
#.rst:
# FindNuma
# --------
#
# Result Variables
# ^^^^^^^^^^^^^^^^
#
#   ``NUMA_FOUND``
#     True if Numa is found
#
#   ``NUMA_INCLUDE_DIR``
#     Location of Numa headers
#
#   ``NUMA_LIBRARY_DIR``
#     Location of Numa libraries
#
#   ``NUMA_LIBRARY``
#     List of Numa libraries found
#

include(FindPackageHandleStandardArgs)

find_path(NUMA_ROOT_DIR
  NAMES include/numa.h
  PATHS ENV NUMA_ROOT
  DOC "NUMA root directory")

find_path(NUMA_INCLUDE_DIR
  NAMES numa.h
  HINTS ${NUMA_ROOT_DIR}
  PATH_SUFFIXES include
  DOC "NUMA include directory")

find_library(NUMA_LIBRARY
  NAMES numa
  HINTS ${NUMA_ROOT_DIR}
  DOC "NUMA library")

if (NUMA_LIBRARY)
    get_filename_component(NUMA_LIBRARY_DIR ${NUMA_LIBRARY} PATH)
endif()

mark_as_advanced(NUMA_INCLUDE_DIR NUMA_LIBRARY_DIR NUMA_LIBRARY)

INCLUDE(FindPackageHandleStandardArgs)
find_package_handle_standard_args(NUMA REQUIRED_VARS NUMA_ROOT_DIR NUMA_INCLUDE_DIR NUMA_LIBRARY)
