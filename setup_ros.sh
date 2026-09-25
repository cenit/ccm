#!/bin/sh

# Check if the script is run as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Please use sudo."
    exit 1
fi

# Check if the system is Ubuntu 22.04
if [ "$(lsb_release -rs)" != "22.04" ]; then
    echo "This script is intended for Ubuntu 22.04 only."
    exit 1
fi

apt-get update
apt-get -y full-upgrade
apt-get install -y software-properties-common curl
add-apt-repository -y universe
curl -sSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key -o /usr/share/keyrings/ros-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] http://packages.ros.org/ros2/ubuntu $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/ros2.list > /dev/null
apt-get update
apt-get install -y ros-humble-desktop python3-argcomplete ros-dev-tools ros-humble-orocos-kdl
