set(CMAKE_SYSTEM_NAME Generic)
set(CMAKE_SYSTEM_PROCESSOR arm)

set(CMAKE_FIND_LIBRARY_PREFIXES "")
set(CMAKE_FIND_LIBRARY_SUFFIXES ".a;.lib")
set(CMAKE_EXECUTABLE_SUFFIX ".out")
set(CMAKE_C_USE_RESPONSE_FILE_FOR_OBJECTS 0)

find_program(CMAKE_C_COMPILER "armcl" REQUIRED)
find_program(CMAKE_ASM_COMPILER "armcl" REQUIRED)
find_program(CMAKE_MAKE_PROGRAM "gmake" REQUIRED)

set(TI_CC_FLAGS " --endian=little -mv7A8 --abi=eabi --neon --float_support=VFPv3 -q -ms  --program_level_compile --gcc " CACHE INTERNAL "")
set(TI_CC_FLAGS_EXTRA " --code_state=32 -me --define=am335x --define=EXTERNAL_MEMORY --define=_INCLUDE_NIMU_CODE --define=idk_AM335x --define=sys_bios_ind_sdk --diag_warning=225 --display_error_number --preproc_with_compile " CACHE INTERNAL "")
set(TI_CC_RELEASE_FLAGS " --undefine=__DISABLE_WATCHDOG --symdebug:none --opt_level=3 ")
set(TI_CC_DEBUG_FLAGS " --define=__DISABLE_WATCHDOG -g --opt_level=off")

set(TI_EXE_FLAGS " -z --reread_libs --warn_sections --rom_model " CACHE INTERNAL "")
set(TI_EXE_RELEASE_FLAGS "")
set(TI_EXE_DEBUG_FLAGS "")


set(CMAKE_C_FLAGS_INIT "${TI_CC_FLAGS} ${TI_CC_FLAGS_EXTRA}")
set(CMAKE_C_FLAGS_DEBUG_INIT "${TI_CC_DEBUG_FLAGS}")
set(CMAKE_C_FLAGS_RELEASE_INIT "${TI_CC_RELEASE_FLAGS}")
set(CMAKE_ASM_FLAGS_INIT "${TI_CC_FLAGS} ${TI_CC_FLAGS_EXTRA}")
set(CMAKE_EXE_LINKER_FLAGS_INIT "${TI_EXE_FLAGS}")
set(CMAKE_EXE_LINKER_FLAGS_DEBUG_INIT "${TI_EXE_DEBUG_FLAGS}")
set(CMAKE_EXE_LINKER_FLAGS_RELEASE_INIT "${TI_EXE_RELEASE_FLAGS}")

SET(CMAKE_ASM_CREATE_STATIC_LIBRARY
      "<CMAKE_AR> qr <TARGET> <LINK_FLAGS> <OBJECTS> "
      "<CMAKE_RANLIB> <TARGET> ")

#bypass CMake compiler checks
set(CMAKE_C_COMPILER_WORKS           1)
set(CMAKE_CXX_COMPILER_WORKS         1)
set(CMAKE_DETERMINE_C_ABI_COMPILED   1)
set(CMAKE_DETERMINE_CXX_ABI_COMPILED 1)
set(CMAKE_DETERMINE_ASM_ABI_COMPILED 1)

# modify allowed search paths for CMake routines
#set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
#set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
#set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
#set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

# explicitly tell CMake that we are cross-compiling (executables are not loadable on host)
set(CMAKE_CROSSCOMPILING TRUE)
