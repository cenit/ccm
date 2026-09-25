# Copyright Stefano Sinigardi

#.rst:
# FindVCG
# --------
#
# Result Variables
# ^^^^^^^^^^^^^^^^
#
# This module will set the following variables in your project:
#
#  ``VCG_FOUND``
#    True if VCG is found on the local system
#
#  ``VCG_INCLUDE_DIRS``
#    Location of VCG header files
#

include(FindPackageHandleStandardArgs)

find_path(VCG_INCLUDE_DIR "vcg/complex/complex.h" HINTS "${VCG_ROOT}" "$ENV{VCG_ROOT}" PATH_SUFFIXES "vcg" "include")

set(VCG_INCLUDE_DIRS ${VCG_INCLUDE_DIR})
mark_as_advanced(VCG_INCLUDE_DIR)

find_package_handle_standard_args(VCG
      REQUIRED_VARS  VCG_INCLUDE_DIR
)
