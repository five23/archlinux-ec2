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
sudo chroot arch pacstrap -c /mnt base grub lsb-release python2 sudo openssh net-tools binutils linux inetutils cloud-init
sudo chroot arch genfstab -U /mnt | sudo tee arch/mnt/etc/fstab

# Set up a proper locale. Feel free to adjust to your liking. See the Arch
# install documentation For more details.
echo "en_US.UTF-8 UTF-8" | sudo tee -a arch/mnt/etc/locale.gen
echo "LANG=en_US.UTF-8"  | sudo tee -a arch/mnt/etc/locale.conf
sudo chroot arch arch-chroot /mnt locale-gen

# Set a default hostname. Will most likely be overwritten by cloud-init anyways.
echo "archec2" | sudo tee -a arch/mnt/etc/hostname

# Install the AUR packages on the new system.
sudo cp arch/*.pkg.tar.zst arch/mnt/
sudo chroot arch arch-chroot /mnt pacman -U --noconfirm /growpart.pkg.tar.zst
sudo rm arch/mnt/*.pkg.tar.zst

# Enable cloud-init services. This will set the hostname, but also do more
# advanced things like setting up the SSH key that you select for your
# instance, without which you would not be able to log in to the instance.
sudo chroot arch arch-chroot /mnt systemctl enable cloud-init
sudo chroot arch arch-chroot /mnt systemctl enable cloud-final

# Install GRUB
sudo chroot arch arch-chroot /mnt grub-install --target=i386-pc --recheck /dev/xvdf
sudo chroot arch arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg

#
# Network config
#

# The cloud-init Arch module uses netctl for network configuration by default.
# However, in it's current state, it does not work very well. Because of that,
# starting with cloud-init 19.2, cloud-init will prefer using netplan to render
# the network config. Netplan renders a systemd-networkd config, and we
# explicitly installed it in this project, so we simply need to enable
# systemd-networkd. Cloud-init/netplan will handle all the rest.
sudo chroot arch arch-chroot /mnt systemctl enable systemd-networkd.service
sudo chroot arch arch-chroot /mnt systemctl enable systemd-resolved.service
sudo chroot arch ln -sf /run/systemd/resolve/stub-resolv.conf /mnt/etc/resolv.conf

# Done. Clean up and exit.
sudo sync
sleep 3
sudo umount arch/etc/resolv.conf
sudo umount arch/mnt
sudo umount arch/proc
sudo umount arch/sys
sudo umount arch/dev
sudo umount arch
