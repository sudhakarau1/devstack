#!/bin/bash

# set release branch to retrieve from git
RELEASE_BRANCH=${1:-master}
MTU=${2:-1500}

echo ""
echo ""
echo "###############################################################################"
echo "## Installing OpenStack (Devstack)                                           ##"
echo "## using RELEASE_BRANCH=\"${RELEASE_BRANCH}\"                                ##"
echo "###############################################################################"
echo ""
echo ""

# Disable interactive options when installing with apt-get
export DEBIAN_FRONTEND=noninteractive

echo export LC_ALL=en_US.UTF-8 >> ~/.bash_profile
echo export LANG=en_US.UTF-8 >> ~/.bash_profile

echo Updating...
sudo apt-get -y update
sudo apt-get install -y zfsutils-linux git

echo Creating ZFS for lxd
sudo zpool create -m /lxd -f lxd sdb
sudo apt-get install -y lxd
sudo lxd init --auto --storage-backend zfs --storage-pool lxd

sudo apt-get install -y python-pip
sudo pip install -U os-testr
sudo pip install -U pbr
sudo apt-get install python-setuptools
sudo easy_install pip

echo configuring swap...
# We need swap space to do any sort of scale testing with the Vagrant config.
# Without this, we quickly run out of RAM and the kernel starts whacking things.
sudo rm -f /swapfile
sudo fallocate -l 4G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
sudo echo "vm.swappiness = 10" | sudo tee --append /etc/sysctl.conf > /dev/null
sudo echo "vm.vfs_cache_pressure = 50" | sudo tee --append /etc/sysctl.conf > /dev/null
sudo echo "/swapfile   none    swap    sw    0   0" | sudo tee --append /etc/fstab > /dev/null

# Disable firewall (this is not production)
sudo ufw disable

echo Configuring networking....
# To permit IP packets pass through different networks,
# the network card should be configured with routing capability.
sudo echo "net.ipv4.ip_forward = 1" | sudo tee --append /etc/sysctl.conf > /dev/null
sudo echo "net.ipv4.conf.all.rp_filter=0" | sudo tee --append /etc/sysctl.conf > /dev/null
sudo echo "net.ipv4.conf.default.rp_filter=0" | sudo tee --append /etc/sysctl.conf > /dev/null
sudo echo "net.ipv6.conf.all.disable_ipv6 = 1" | sudo tee --append /etc/sysctl.conf > /dev/null
sudo echo "net.ipv6.conf.default.disable_ipv6 = 1" | sudo tee --append /etc/sysctl.conf > /dev/null
sudo echo "net.ipv6.conf.lo.disable_ipv6 = 1" | sudo tee --append /etc/sysctl.conf > /dev/null
sudo sysctl -p

# allow OpenStack nodes to route packets out through NATed network on HOST (this is the vagrant managed nic)
sudo iptables -t nat -A POSTROUTING -o enp0s3 -j MASQUERADE

# Update host configuration
sudo bash -c "echo 'openstack' > /etc/hostname"
#export eth1=`ifconfig eth1 | sed -En 's/127.0.0.1//;s/.*inet (addr:)?(([0-9]*\.){3}[0-9]*).*/\2/p'`
sudo bash -c 'cat > /etc/hosts' <<EOF
127.0.0.1         localhost
192.168.27.100    openstack.stackinabox.io openstack
EOF

sudo hostname openstack

# speed up DNS resolution
sudo bash -c 'cat > /etc/dhcp/dhclient.conf' <<EOF
timeout 30;
retry 10;
reboot 0;
select-timeout 0;
initial-interval 1;
backoff-cutoff 2;
interface "enp0s3"
{
  prepend domain-name-servers 192.168.27.1, 8.8.8.8, 8.8.4.4;
  request subnet-mask,
          broadcast-address,
          time-offset,
          routers,
          domain-name,
          domain-name-servers,
          host-name,
          netbios-name-servers,
          netbios-scope;
}
EOF

echo enable cgroup memory limits
sudo sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="cgroup_enable=memory swapaccount=1 /g' /etc/default/grub
sudo sed -i 's/GRUB_CMDLINE_LINUX="/GRUB_CMDLINE_LINUX="cgroup_enable=memory swapaccount=1 /g' /etc/default/grub
sudo update-grub

# Clone devstack repo
echo "Cloning DevStack repo from branch \"${RELEASE_BRANCH}\""
sudo mkdir -p /opt/stack
sudo chown -R vagrant:vagrant /opt/stack
git clone https://git.openstack.org/openstack-dev/devstack.git /opt/stack/devstack -b "${RELEASE_BRANCH}"
#need to do below to stop devstack failing on test-requirements for lxd
echo "Cloning nova-lxd repo from branch \"${RELEASE_BRANCH}\""
git clone https://github.com/openstack/nova-lxd /opt/stack/nova-lxd -b "${RELEASE_BRANCH}"
rm -f /opt/stack/nova-lxd/test-requirements.txt
# add local.conf to /opt/devstack folder
cp /vagrant/scripts/stackinabox/local.conf /opt/stack/devstack/

# update RELEASE_BRANCH variable in local.conf to match existing
# (use '@' as delim in sed b/c $RELEASE_BRANCH may contain '/')
sed -i "s@RELEASE_BRANCH=@RELEASE_BRANCH=$RELEASE_BRANCH@" /opt/stack/devstack/local.conf

# don't assign IP to eth2 yet
sudo ifconfig enp0s9 0.0.0.0
sudo ifconfig enp0s9 promisc
sudo ip link set dev enp0s9 up
# gentelmen start your engines
echo "Installing DevStack"
cd /opt/stack/devstack
./stack.sh
if [ $? -eq 0 ]
then
 echo "Finished installing DevStack"
else
  echo "Error installing DevStack"
  exit $?
fi

# bridge eth2 to ovs for our public network
sudo ovs-vsctl add-port br-ex enp0s9
sudo ifconfig br-ex promisc up

# assign ip from public network to bridge (br-ex)
sudo bash -c 'cat >> /etc/network/interfaces' <<'EOF'
auto enp0s9
iface enp0s9 inet manual
    address 0.0.0.0
    up ifconfig $IFACE 0.0.0.0 up
    up ip link set $IFACE promisc on
    down ip link set $IFACE promisc off
    down ifconfig $IFACE down

    auto br-ex
    iface br-ex inet static
        address 172.24.4.2
        netmask 255.255.255.0
        up ip link set $IFACE promisc on
        down ip link set $IFACE promisc off
EOF

sudo ip link set dev enp0s3 mtu $MTU
sudo ip link set dev enp0s8 mtu $MTU

cp /vagrant/scripts/stackinabox/stack-noscreenrc /opt/stack/devstack/stack-noscreenrc
chmod 755 /opt/stack/devstack/stack-noscreenrc
sudo cp /vagrant/scripts/stackinabox/devstack2 /etc/init.d/devstack
sudo chmod +x /etc/init.d/devstack
sudo update-rc.d devstack start 98 2 3 4 5 . stop 02 0 1 6 .

cp /vagrant/scripts/stackinabox/admin-openrc.sh /home/vagrant
cp /vagrant/scripts/stackinabox/demo-openrc.sh /home/vagrant
exit 0
