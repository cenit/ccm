# Copyright Stefano Sinigardi

#.rst:
# FindQuartus
# -----------
#
# Result Variables
# ^^^^^^^^^^^^^^^^
#
# This module will set the following variables in your project:
#
#  ``QUARTUS_FOUND``
#    True if Intel Quartus Prime is found on the local system
#
#  ``add_fpga_project``
#    A function to add a Quartus FPGA project
#

include(FindPackageHandleStandardArgs)

set(QUARTUS_PATHS
  /opt/altera/quartus/bin
  /opt/altera/18.1/quartus/bin
  C:/intelFPGA_lite/18.1/quartus/bin64
  C:/intelFPGA/18.1/quartus/bin64
)

find_program(QUARTUS_SH NAMES quartus_sh PATHS ${QUARTUS_PATHS})
find_program(QUARTUS_MAP NAMES quartus_map PATHS ${QUARTUS_PATHS})
find_program(QUARTUS_FIT NAMES quartus_fit PATHS ${QUARTUS_PATHS})
find_program(QUARTUS_ASM NAMES quartus_asm PATHS ${QUARTUS_PATHS})
find_program(QUARTUS_STA NAMES quartus_sta PATHS ${QUARTUS_PATHS})
find_program(QUARTUS_PGM NAMES quartus_pgm PATHS ${QUARTUS_PATHS})

function(add_fpga_project)
  set(oneValueArgs PROJECT FAMILY PART)
  set(multiValueArgs SOURCES DEPENDS)
  cmake_parse_arguments(add_fpga_project "" "${oneValueArgs}" "${multiValueArgs}" ${ARGN})

  foreach(source ${add_fpga_project_SOURCES})
    list(APPEND SOURCE_ARGS --source=${source})
  endforeach(source)

  add_custom_command(OUTPUT ${add_fpga_project_PROJECT}.qpf
             COMMAND ${QUARTUS_SH} --prepare -f ${add_fpga_project_FAMILY} -t ${add_fpga_project_PROJECT} ${add_fpga_project_PROJECT}
             DEPENDS ${add_fpga_project_PROJECT}.qsf)
  add_custom_command(OUTPUT ${add_fpga_project_PROJECT}.map.rpt
             COMMAND ${QUARTUS_MAP} ${SOURCE_ARGS} --family ${add_fpga_project_FAMILY} --optimize=speed ${add_fpga_project_PROJECT}
             DEPENDS ${add_fpga_project_DEPENDS} ${add_fpga_project_SOURCES} ${add_fpga_project_PROJECT}.qpf ${add_fpga_project_PROJECT}.qsf)
  add_custom_command(OUTPUT ${add_fpga_project_PROJECT}.fit.rpt
             COMMAND ${QUARTUS_FIT} --part=${add_fpga_project_PART} --read_settings_file=on --set=SDC_FILE=${add_fpga_project_PROJECT}.sdc ${add_fpga_project_PROJECT}
             DEPENDS ${add_fpga_project_PROJECT}.map.rpt)
  add_custom_command(OUTPUT ${add_fpga_project_PROJECT}.asm.rpt
             COMMAND ${QUARTUS_ASM} ${add_fpga_project_PROJECT}
             DEPENDS ${add_fpga_project_PROJECT}.fit.rpt)
  add_custom_command(OUTPUT ${add_fpga_project_PROJECT}.sta.rpt ${add_fpga_project_PROJECT}.sof
             COMMAND ${QUARTUS_STA} ${add_fpga_project_PROJECT}
             DEPENDS ${add_fpga_project_PROJECT}.asm.rpt)
endfunction()


find_package_handle_standard_args(Quartus FOUND_VAR QUARTUS_FOUND
                  REQUIRED_VARS
                  QUARTUS_SH
                  QUARTUS_MAP
                  QUARTUS_FIT
                  QUARTUS_ASM
                  QUARTUS_STA
                  QUARTUS_PGM)
