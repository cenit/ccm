#!/bin/sh

#sudo yum -y --exclude=kernel\* update
#sudo yum install -y yum-plugin-versionlock
#sudo yum versionlock kernel*
#sudo yum install -y epel-release
sudo yum install -y libpng12 compat-libtiff3
sudo yum install -y giflib libXrender cairo libexif fontconfig
sudo yum install -y libX11 libXau libXext libXi libXrandr libXtst libxcb ncurses-libs
sudo yum install -y glibc.i686 libstdc++.i686 ncurses-libs.i686 libX11.i686 libXau.i686 libXi.i686 libXrender.i686 libxcb.i686 nss-softokn-freebl.i686 libXext.i686 libXrandr.i686 libXtst.i686
#sudo DEBIAN_FRONTEND=noninteractive yum groupinstall "Xfce" -y
#sudo yum install -y xrdp
sudo yum groupinstall "Server with GUI" -y
#sudo yum install -y Xvfb mono-core
sudo yum clean all

exit

## installation went on manually. These might be some automated steps, but I never really debugged them start-to-end

sudo mkdir /mnt/resource
sudo mkdir /mnt/vivadoiso
sudo mkdir /mnt/resource/niInst
sudo mkdir /mnt/resource/tmp

## XILINX 2021
#wget https://download.ni.com/support/softlib/labview/labview_fpga/fpga_module/2020/Linux%20Tools/NI-LVFPGA2020-LinuxVivado.iso
#sudo mv NI-LVFPGA2020-LinuxVivado.iso /mnt/resource/
#sudo mount /mnt/resource/NI-LVFPGA2020-LinuxVivado.iso /mnt/vivadoiso
#sudo cp /mnt/vivadoiso/nifpgacompileworker-20.0.0f1.tar.gz /mnt/resource/niInst/

# XILINX 2019
wget https://download.ni.com/support/softlib/labview/labview_fpga/fpga_module/2019/Linux%20Tools/NI-LVFPGA-2019-LinuxVivado.iso
sudo mv NI-LVFPGA-2019-LinuxVivado.iso /mnt/resource/
sudo mount /mnt/resource/NI-LVFPGA-2019-LinuxVivado.iso /mnt/vivadoiso
sudo cp /mnt/vivadoiso/nifpgacompileworker-19.0.0f0.tar.gz /mnt/resource/niInst/

# COMMON
sudo cp /mnt/vivadoiso/INSTALL /mnt/resource/niInst/


#####
# the next sed command should change the line
#   kTmpInstallSrcPath="/tmp/$kProductName-$kProductVersion.install"
# to make it read
#   kTmpInstallSrcPath="/mnt/resource/tmp/$kProductName-$kProductVersion.install"
# untested for now - separator is @ and not the default / to avoid clash with slash in the replaced string itself
#####
sed -i 's@kTmpInstallSrcPath="/tmp/$kProductName-$kProductVersion.install"@kTmpInstallSrcPath="/mnt/resource/tmp/$kProductName-$kProductVersion.install"@' /mnt/resource/niInst/INSTALL

sudo sh /mnt/resource/niInst/INSTALL
sudo systemctl enable xrdp
sudo systemctl set-default graphical.target
sudo systemctl isolate graphical.target
echo "xfce4-session" > ~/.Xclients
chmod a+x ~/.Xclients

cat << EOF > nifpgaworker.service
[Unit]
Description=NI FPGA Compile Worker Wrapper
[Service]
ExecStart=/usr/local/natinst/nifpgacompileworker/start_nifpgacompileworker.sh
ExecStop=
StandardOutput=syslog
StandardError=syslog
Restart=on-failure
RestartSec=5s
[Install]
WantedBy=default.target
EOF
sudo mv nifpgaworker.service /etc/systemd/system/nifpgaworker.service
sudo chown root:root /etc/systemd/system/nifpgaworker.service
sudo chmod 664 /etc/systemd/system/nifpgaworker.service

cat << EOF > start_nifpgacompileworker.sh
#!/bin/bash
CW_PATH=/usr/local/natinst/nifpgacompileworker
export LD_LIBRARY_PATH=\$DIR:/usr/local/natinst/mono/lib64:\$LD_LIBRARY_PATH
export PATH=/usr/local/natinst/mono/bin/:\$PATH
# This line is a workaround for Mono 4.0.4. Mono 4.2.1 has fixed the issue. See CAR #550029.
export MONO_XMLSERIALIZER_THS=no
# set screen to virtual framebuffer
# no worries, this will only apply to the contents of the shell file
if which Xvfb
then
               Xvfb :1 -screen 0 1024x768x16 &
               export DISPLAY=:1
fi
cd \$CW_PATH
mono \$CW_PATH/CompileWorker.exe
EOF
sudo mv start_nifpgacompileworker.sh /usr/local/natinst/nifpgacompileworker/start_nifpgacompileworker.sh
sudo chown root:root /usr/local/natinst/nifpgacompileworker/start_nifpgacompileworker.sh
sudo chmod 774 /usr/local/natinst/nifpgacompileworker/start_nifpgacompileworker.sh

cd /usr/local/natinst/nifpgacompileworker
sh cw_wrapper.sh mono CompileWorker.exe

sudo systemctl daemon-reload
sudo systemctl enable nifpgaworker.service
sudo systemctl start nifpgaworker.service

## remember to open port 3389 (TCP) in your cloud firewall / network security group
