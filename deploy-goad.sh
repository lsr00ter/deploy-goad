#!/bin/bash
echo "Deploy GOAD v2 on Ubuntu 22.04"

# Ensure we're on the right OS and version
source /etc/os-release
if [ "$ID" = "ubuntu" ]; then
  IFS='.' read -r -a version_parts <<<"$VERSION_ID"
  major_version=${version_parts[0]}
  minor_version=${version_parts[1]}
  if [ "$major_version" -gt 22 ] || { [ "$major_version" -eq 22 ] && [ "$minor_version" -ge 4 ]; }; then
    echo "Ubuntu version is 22.04 or above."
  else
    echo "This script must be run on Ubuntu 22.04"
    exit 1
  fi
else
  echo "This script must be run on Ubuntu 22.04"
  exit 1
fi

# Ensure we're root
if [ "$(id -u)" != "0" ]; then
  echo "This script must be run as root" 1>&2
  exit 1
fi

# Add repositories
add-apt-repository -y multiverse

# Get list of latest packages
apt-get update

# Make sure we're running on latest versions of things installed
apt-get -y dist-upgrade

# Check if we're running inside VirtualBox
if [ $(dmidecode -s system-product-name) = "VirtualBox" ]; then
  # Install VirtualBox guest additions
  apt-get install -y virtualbox-guest-utils virtualbox-guest-x11
fi

# Install Virtualbox 7+
wget -O- https://www.virtualbox.org/download/oracle_vbox_2016.asc | gpg --dearmor --yes --output /usr/share/keyrings/oracle-virtualbox-2016.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/oracle-virtualbox-2016.gpg] https://download.virtualbox.org/virtualbox/debian jammy contrib" | tee /etc/apt/sources.list.d/virtualbox.list
apt update
apt install virtualbox-7.0 -y
apt install gcc-12 -y
wget https://download.virtualbox.org/virtualbox/7.0.14/Oracle_VM_VirtualBox_Extension_Pack-7.0.14.vbox-extpack
VBoxManage extpack install Oracle_VM_VirtualBox_Extension_Pack-7.0.14.vbox-extpack

# Install base packages needed
apt-get install -y git python3-pip pipx
pipx ensurepath && source /root/.bashrc

# Enable IP forwarding on Ubuntu
yes | apt-get install iptables-persistent
DEFAULT_ETH=$(ip route get 8.8.8.8 | sed -n 's/.*dev \([^\ ]*\).*/\1/p')
if [ "$(cat /proc/sys/net/ipv4/ip_forward)" != "1" ]; then
  # Implement in sysctl
  echo net.ipv4.ip_forward = 1 >>/etc/sysctl.conf
  sysctl -p
  iptables -A FORWARD -i $DEFAULT_ETH -o vboxnet0 -j ACCEPT
  iptables -A FORWARD -i vboxnet0 -o $DEFAULT_ETH -m state --state ESTABLISHED,RELATED -j ACCEPT
  iptables -t nat -A POSTROUTING -o vboxnet0 -j MASQUERADE
  iptables-save | tee /etc/iptables/rules.v4
fi

# Check if vagrant is installed
if ! dpkg -s vagrant &>/dev/null; then
  wget -O- https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/hashicorp.list
  apt update && yes | apt install vagrant
fi

# Set up prerequisites, not doing a venv but could be changed to that
# pip install --upgrade pip
pipx install ansible-core
pipx install pywinrm --include-deps

# Install stuff needed for Vagrant
vagrant plugin install winrm
vagrant plugin install winrm-elevated

# Download GOAD
if [ ! -d /opt/goad ]; then
  git clone --depth=1 https://github.com/Orange-Cyberdefense/GOAD /opt/goad
fi

# Install GOAD stuff needed for Ansible
ansible-galaxy install -r /opt/goad/ansible/requirements.yml

# Switch to GOAD folder and deploy VMs
cd /opt/goad
./goad.sh -t install -l GOAD -p virtualbox -m local

if [ $? -ne 0 ]; then
  echo "Deployment failed"
  exit 1
fi

# Load windows-update-disabler for next step
git clone --depth=1 https://github.com/tsgrgo/windows-update-disabler /opt/windows-update-disabler

echo "Deployment succeeded, your lab is now up and running on the 192.168.56.0/24 network"
echo "Upload '/opt/windows-update-disabler/' folder to each host, run 'disable updates.bat' to prevent windows update"
echo "Start VMs with: 'sudo su && cd /opt/goad/ad/GOAD/providers/virtualbox && vagrant up'"
