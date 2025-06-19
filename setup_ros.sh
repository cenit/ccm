#!/bin/sh

# Check if the script is run as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Please use sudo."
    exit 1
fi

# Check if the system is Ubuntu 20.04
if [ "$(lsb_release -rs)" != "20.04" ]; then
    echo "This script is intended for Ubuntu 20.04 only."
    exit 1
fi

apt-get update
apt-get dist-upgrade
apt-get install ros-foxy-desktop python3-argcomplete ros-dev-tools
apt-get install software-properties-common
add-apt-repository universe
apt-get install curl -y
curl -sSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key -o /usr/share/keyrings/ros-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] http://packages.ros.org/ros2/ubuntu $(. /etc/os-release && echo $UBUNTU_CODENAME) main" | tee /etc/apt/sources.list.d/ros2.list > /dev/null
apt-get install ros-foxy-desktop python3-argcomplete ros-dev-tools
apt-get install ros-foxy-orocos-kdl
