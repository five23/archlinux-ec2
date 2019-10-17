#!/bin/bash

set -x
set -e

# Install gdisk on the Debian system, so we can partition the extra disk (i.e.
# EBS volume), might already be installed on latest Debian AMIs.
sudo which sgdisk || DEBIAN_FRONTEND=noninteractive sudo apt-get install -y gdisk

# Partition the extra disk (EBS volume). The name is known because it is
# defined in the packer config.  We create a BIOS partition for GRUB (since GPT
# otherwise leaves no space for the MBR, but EC2 instances use legacy - i.e.
# non-EFI - boot) and one main partition for everything else.
sudo sgdisk -Zg -n1:0:4095 -t1:EF02 -c1:GRUB -n2:0:0 -t2:8300 -c2:ROOT /dev/xvdf
sync

# Create ext4 file system on the main partition - for EC2, it is advisable to
# use a file system that supports hot resizing, see growpart further down.
sudo mkfs.ext4 /dev/xvdf2

# Extract the Arch Linux base system to a temporary directory (on the Debian
# system, not the empty disk). The tarball has been placed here by the file
# provisioner in the packer config.
mkdir arch
cd arch && sudo tar xpzf /tmp/archbase.tar.gz
cd -

# Chroot preparations. Pacman requires the chroot root to be a mount point, so
# bind mount it. The rest is for devices and other kernel access (networking,
# disks, ...). Arch-chroot does this for you, but for regular chroot we need to
# take care of this. The last one mounts the newly formated partition inside
# the chroot.
sudo mount --bind arch arch
sudo mount --bind /proc arch/proc
sudo mount --bind /sys arch/sys
sudo mount --bind /dev arch/dev
sudo mount --bind /etc/resolv.conf arch/etc/resolv.conf
sudo mount /dev/xvdf2 arch/mnt

# By running `sudo chroot arch ...` we now have access to a fully funtional Arch system.
# Bootstrap a minimal system onto the empty partition.
sudo chroot arch pacstrap -c /mnt base grub lsb-release python2 sudo openssh net-tools binutils linux
sudo chroot arch genfstab -U /mnt | sudo tee arch/mnt/etc/fstab

# Set up a proper locale. Feel free to adjust to your liking. See the Arch
# install documentation For more details.
echo "en_US.UTF-8 UTF-8" | sudo tee -a arch/mnt/etc/locale.gen
echo "LANG=en_US.UTF-8"  | sudo tee -a arch/mnt/etc/locale.conf
sudo chroot arch arch-chroot /mnt locale-gen

# Set a default hostname. Will most likely be overwritten by cloud-init anyways.
echo "archec2" | sudo tee -a arch/mnt/etc/hostname

# Install the AUR packages on the new system.
sudo cp arch/*.pkg.tar.xz arch/mnt/
sudo chroot arch arch-chroot /mnt pacman -U --noconfirm /cloud-init.pkg.tar.xz
sudo chroot arch arch-chroot /mnt pacman -U --noconfirm /growpart.pkg.tar.xz
sudo rm arch/mnt/*.pkg.tar.xz

# Enable the growpart service. This will resize both the main partition as well
# as the file system it contains to use all available space. Without this, the
# main file system would always only be ~4GB, even if you start an instance
# with larger EBS volumes attached.
sudo chroot arch arch-chroot /mnt systemctl enable growpartfs@-

# Enable cloud-init services. This will set the hostname, but also do more
# advanced things like setting up the SSH key that you select for your
# instance, without which you would not be able to log in to the instance.
sudo chroot arch arch-chroot /mnt systemctl enable cloud-init
sudo chroot arch arch-chroot /mnt systemctl enable cloud-final

# Install GRUB
sudo chroot arch arch-chroot /mnt grub-install --target=i386-pc --recheck /dev/xvdf
sudo chroot arch arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg

#
# Network config - use only one of the netctl or systemd-networkd sections!
#

# The cloud-init Arch module uses netctl for network configuration. However, in
# it's current state, cloud-init on Arch does not actually handle the network
# config properly. In terms of functionality, the netctl setup is slightly less
# flexible - you need to know the exact interfaces you want to bring up in
# advance (as opposed to using wildcards, see systemd-networkd setup for
# comparison). Note that the network config will result in failure if you try
# to bring up a non-existing interface. This also currently makes the netctl
# approach incompatible with enhanced networking (ENA) instance types, as the
# driver will rename the interface to ensX.
#
# As such, use the netctl setup if you understand these limitations and know
# you can live with them. The plus side is better compatibility if you plan to
# use (near-)identical images in other cloud environments where the network is
# configured by cloud-init (like OpenStack).

# BEGIN Network config - netctl section
#sudo tee arch/mnt/etc/netctl/default <<EOF
#Interface=eth0
#Connection=ethernet
#IP=dhcp
#EOF
#sudo chroot arch arch-chroot /mnt netctl enable default
# END Network config - netctl section

# Using systemd-networkd allows for greater flexibility - you can use the same
# AMI for instances with different number of network interfaces, it will just
# work. If you use this, make sure not to mix it with netctl later on!

# BEGIN Network config - systemd-networkd section
sudo tee arch/mnt/etc/systemd/network/default.network <<EOF
[Match]
Name=e*

[Network]
DHCP=yes
EOF
sudo chroot arch arch-chroot /mnt systemctl enable systemd-networkd.service
sudo chroot arch arch-chroot /mnt systemctl enable systemd-resolved.service
sudo chroot arch ln -sf /run/systemd/resolve/stub-resolv.conf /mnt/etc/resolv.conf
# END Network config - systemd-networkd section

# Done. Clean up and exit.
sudo sync
sleep 3
sudo umount arch/etc/resolv.conf
sudo umount arch/mnt
sudo umount arch/proc
sudo umount arch/sys
sudo umount arch/dev
sudo umount arch
