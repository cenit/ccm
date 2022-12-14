# Copyright Stefano Sinigardi

#.rst:
# FindATL
# --------
#
# Result Variables
# ^^^^^^^^^^^^^^^^
#
# This module will set the following variables in your project:
#
#  ``ATL_FOUND``
#    True if ATL is found on the local system
#
#  ``ATL_INCLUDE_DIRS``
#    Location of ATL header files.
#
#  ``ATL_LIBRARIES``
#    The ATL libraries
#

include(SelectLibraryConfigurations)
include(FindPackageHandleStandardArgs)

if(WIN32)
  find_path(ATL_INCLUDE_DIR atlbase.h)

  find_library(ATL_LIBRARY_RELEASE atls)
  find_library(ATL_LIBRARY_DEBUG atlsd)

  select_library_configurations(ATL)
endif()

set(ATL_INCLUDE_DIRS "${ATL_INCLUDE_DIR}")
set(ATL_LIBRARIES "${ATL_LIBRARY}")

find_package_handle_standard_args(ATL
      DEFAULT_MSG  ATL_LIBRARIES ATL_INCLUDE_DIRS
)
