#!/bin/sh

## Xilinx 2021.1 for Labview 2024Q1
wget https://download.ni.com/support/softlib/labview/labview_fpga/fpga_module/2024Q1/linux-tools/ni-vivado-2021.1-cg-full_24.1.0.zip
unzip ni-vivado-2021.1-cg-full_24.1.0.zip
sudo apt install ./ni-vivado-2021.1-cg_24.1.0.49363-0+f211-ubuntu2004_all.deb
sudo apt update
sudo apt install ni-vivado-2021.1-cg

## remember to open port 3389 (TCP) in your cloud firewall / network security group
