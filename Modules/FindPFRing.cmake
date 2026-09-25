# Copyright Stefano Sinigardi

#.rst:
# FindPFRing
# --------
#
# Result Variables
# ^^^^^^^^^^^^^^^^
#
# This module will set the following variables in your project:
#
#  ``PFRing_FOUND``
#    True if pf_ring is found on the local system
#
#  ``PFRing_INCLUDE_DIRS``
#    Location of pf_ring header files
#
#  ``PFRing_LIBRARIES``
#    List of pf_ring libraries
#

include(FindPackageHandleStandardArgs)

find_path(PFRing_INCLUDE_DIR pfring.h)
find_library(PFRing_LIBRARY pfring)
find_library(PCAP_LIBRARY pcap)

set(PFRing_INCLUDE_DIRS ${PFRing_INCLUDE_DIR})
set(PFRing_LIBRARIES ${PFRing_LIBRARY} ${PCAP_LIBRARY})
mark_as_advanced(PFRing_INCLUDE_DIR)
mark_as_advanced(PFRing_LIBRARY)

find_package_handle_standard_args(PFRing
      REQUIRED_VARS  PFRing_INCLUDE_DIR PFRing_LIBRARY
)
