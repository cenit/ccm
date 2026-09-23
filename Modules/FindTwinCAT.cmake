# Copyright Stefano Sinigardi

#.rst:
# FindTwinCAT
# --------
#
# Result Variables
# ^^^^^^^^^^^^^^^^
#
# This module will set the following variables in your project:
#
#  ``TwinCAT_FOUND``
#    True if TwinCAT SDK is found on the local system
#
#  ``TwinCAT_INCLUDE_DIRS``
#    Location of TwinCAT header files
#
#  ``TwinCAT_LIBRARIES``
#    List of TwinCAT libraries
#

include(FindPackageHandleStandardArgs)

file(TO_CMAKE_PATH "$ENV{TWINCATSDK}" ENV_TWINCATSDK)
find_path(TwinCAT_INCLUDE_DIR TcDef.h PATHS ${ENV_TWINCATSDK}/Include)
find_library(TwinCAT_FRAMEWORK TcFramework NAMES TcFramework TcFramework.v143 TcFramework.v142 TcFramework.v141 TcFramework.v140 PATHS "${ENV_TWINCATSDK}/Lib/TwinCAT RT (x64)")
find_library(TwinCAT_CHKSTK    TcChkStk    NAMES TcChkStk TcChkStk.v143 TcChkStk.v142 TcChkStk.v141 TcChkStk.v140                PATHS "${ENV_TWINCATSDK}/Lib/TwinCAT RT (x64)")
find_library(TwinCAT_CRT       TcCrt       NAMES TcCrt TcCrt.v143 TcCrt.v142 TcCrt.v141 TcCrt.v140                               PATHS "${ENV_TWINCATSDK}/Lib/TwinCAT RT (x64)")
find_library(TwinCAT_CRTCORE   TcCrtCore   NAMES TcCrtCore TcCrtCore.v143 TcCrtCore.v142 TcCrtCore.v141 TcCrtCore.v140           PATHS "${ENV_TWINCATSDK}/Lib/TwinCAT RT (x64)")
find_library(TwinCAT_DDKHAL    TcDdkHal    NAMES TcDdkHal TcDdkHal.v143 TcDdkHal.v142 TcDdkHal.v141 TcDdkHal.v140                PATHS "${ENV_TWINCATSDK}/Lib/TwinCAT RT (x64)")
find_library(TwinCAT_DDKKRNL   TcDdkKrnl   NAMES TcDdkKrnl TcDdkKrnl.v143 TcDdkKrnl.v142 TcDdkKrnl.v141 TcDdkKrnl.v140           PATHS "${ENV_TWINCATSDK}/Lib/TwinCAT RT (x64)")
find_library(TwinCAT_OMP       TcOmp       NAMES TcOmp TcOmp.v143 TcOmp.v142 TcOmp.v141 TcOmp.v140                               PATHS "${ENV_TWINCATSDK}/Lib/TwinCAT RT (x64)")

list(APPEND TwinCAT_LIBRARY ${TwinCAT_FRAMEWORK})
if(TwinCAT_CHKSTK)
  list(APPEND TwinCAT_LIBRARY ${TwinCAT_CHKSTK})
endif()
if(TwinCAT_CRT)
  list(APPEND TwinCAT_LIBRARY ${TwinCAT_CRT})
endif()
if(TwinCAT_CRTCORE)
  list(APPEND TwinCAT_LIBRARY ${TwinCAT_CRTCORE})
endif()
if(TwinCAT_DDKHAL)
  list(APPEND TwinCAT_LIBRARY ${TwinCAT_DDKHAL})
endif()
if(TwinCAT_DDKKRNL)
  list(APPEND TwinCAT_LIBRARY ${TwinCAT_DDKKRNL})
endif()
if(TwinCAT_OMP)
  list(APPEND TwinCAT_LIBRARY ${TwinCAT_OMP})
endif()

set(TwinCAT_INCLUDE_DIRS ${TwinCAT_INCLUDE_DIR})
set(TwinCAT_LIBRARIES ${TwinCAT_LIBRARY})
mark_as_advanced(TwinCAT_INCLUDE_DIR)
mark_as_advanced(TwinCAT_LIBRARY)

find_package_handle_standard_args(TwinCAT
      REQUIRED_VARS  TwinCAT_INCLUDE_DIR TwinCAT_LIBRARY
)
