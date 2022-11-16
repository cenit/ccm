# To use this function, you should add something like the following snippet to the main CMakeLists.txt
#
# add_custom_command(
#   TARGET ${TARGET_NAME}
#   PRE_BUILD
#   COMMAND ${CMAKE_COMMAND} -D "PATH=\"${CMAKE_BINARY_DIR}/ZERO_CHECK.vcxproj\"" -P "${CMAKE_CURRENT_SOURCE_DIR}/cmake/Functions/FixDriverProj.cmake"
# )
#
# In order to enable a target to be built as a Kernel mode driver, you should add also this line to the main CMakeLists.txt
#
# set_target_properties(${TARGET_NAME} PROPERTIES VS_PLATFORM_TOOLSET "WindowsKernelModeDriver10.0")
#
# Remember also to build using msbuild and not ninja (pass -DoNotUseNinja if you use the build.ps1 script)
#

file(READ "${PATH}" contents)

STRING(REGEX REPLACE ";" "#SEMICOLON#" contents "${contents}")
STRING(REGEX REPLACE "\n" ";" contents "${contents}")

LIST(GET contents 2 line_2)
LIST(GET contents 3 line_3)

set(miss_1 "  <Target Name=\"GetDriverProjectAttributes\" Returns=\"@(DriverProjectAttributes)\"/>")
set(miss_2 "  <Target Name=\"GetPackageFiles\" Returns=\"@(FullyQualifiedFilesToPackage)\"/>")

if ((NOT ${line_2} STREQUAL ${miss_1}) OR (NOT ${line_3} STREQUAL ${miss_2}))
  LIST(INSERT contents 2 ${miss_1} ${miss_2})

  STRING(REGEX REPLACE ";" "\n" contents "${contents}")
  STRING(REGEX REPLACE "#SEMICOLON#" ";" contents "${contents}")

  file(WRITE "${PATH}" "${contents}")
  message("Fixed Project-File: ${PATH}")
endif()
