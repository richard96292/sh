#!/usr/bin/env bash
set -xe
timedatectl set-ntp true

pacman -Syy
pacman -S dialog archlinux-keyring --noconfirm
# ----------------------------- inputs -----------------------------
parts=()
while read -r disk data; do
    parts+=("$disk" "$data")
done < <(lsblk --nodeps -lno name,model,type,size | grep -v -e loop -e sr)
exec 3>&1
diskname="/dev/$(dialog --menu "Choose one:" 0 0 0 "${parts[@]}" 2>&1 1>&3)"
exec 3>&-
clear
# not sure if mmcblk works
if [[ $diskname =~ nvme|mmcblk ]]; then
    literallyLetterP="p"
fi

exec 3>&1
hostname=$(dialog --inputbox "Enter the hostname for this computer:" 0 0 2>&1 1>&3)
exec 3>&-
clear

exec 3>&1
password=$(dialog --inputbox "Enter the password for the root user:" 0 0 2>&1 1>&3)
exec 3>&-
clear

exec 3>&1
passwordLuks=$(dialog --inputbox "Enter the password to encrypt the drive:" 0 0 2>&1 1>&3)
exec 3>&-
clear

optionsManufacturer=(
    amd "AMD"
    intel "Intel"
)
exec 3>&1
choiceCPU=$(dialog --menu "Select your CPU manufacturer:" 0 0 0 "${optionsManufacturer[@]}" 2>&1 1>&3)
exec 3>&-
clear
# ----------------------------- inputs -----------------------------

# destroying the drive (i am trying really hard)
wipefs -af ${diskname}
mkfs.ext4 ${diskname}
dd if=/dev/zero of=${diskname} bs=1M count=32

UEFIBIOS=1
ls /sys/firmware/efi &>/dev/null || UEFIBIOS=0
echo $UEFIBIOS

if [ ${UEFIBIOS} == 1 ]; then
    # UEFI
    sgdisk -n 0:0:+512MiB -t 0:ef00 -c 0:efi ${diskname}
    sgdisk -n 0:0:0 -t 0:8300 -c 0:luks ${diskname}
    sgdisk -p ${diskname}

    bootPartition=${diskname}${literallyLetterP}1
    rootPartition=${diskname}${literallyLetterP}2

    # format boot
    mkfs.vfat ${bootPartition}
    # encrypt second partition
    echo "${passwordLuks}" | cryptsetup -q luksFormat --type luks1 --iter-time 1000 ${rootPartition}
    echo "${passwordLuks}" | cryptsetup open ${rootPartition} luks
    # format partition
    mkfs.btrfs /dev/mapper/luks -f
    # create subvolumes
    mount /dev/mapper/luks /mnt
    btrfs sub create /mnt/@
    btrfs sub create /mnt/@home
    btrfs sub create /mnt/@log
    btrfs sub create /mnt/@pkg
    btrfs sub create /mnt/@.snapshots
    umount -R /mnt
    # mount subvolumes
    mount -o noatime,nodiratime,compress=zstd,subvol=@ /dev/mapper/luks /mnt
    mkdir -pv /mnt/{efi,home,var/log,var/cache/pacman/pkg,.snapshots}
    mount -o noatime,nodiratime,compress=zstd,subvol=@home /dev/mapper/luks /mnt/home
    mount -o noatime,nodiratime,compress=zstd,subvol=@log /dev/mapper/luks /mnt/var/log
    mount -o noatime,nodiratime,compress=zstd,subvol=@pkg /dev/mapper/luks /mnt/var/cache/pacman/pkg
    mount -o noatime,nodiratime,compress=zstd,subvol=@.snapshots /dev/mapper/luks /mnt/.snapshots

    mount ${bootPartition} /mnt/efi
else
    # BIOS
    sfdisk --label dos ${diskname} <<EOF
;
EOF
    rootPartition=${diskname}${literallyLetterP}1

    # specify type as luks1 as grub currently does not support luks2
    echo "${passwordLuks}" | cryptsetup -q luksFormat --type luks1 --iter-time 1000 ${rootPartition}
    echo "${passwordLuks}" | cryptsetup open ${rootPartition} luks
    # format partition
    mkfs.btrfs /dev/mapper/luks -L root -f
    # create subvolumes
    mount /dev/mapper/luks /mnt
    btrfs sub create /mnt/@
    btrfs sub create /mnt/@home
    btrfs sub create /mnt/@log
    btrfs sub create /mnt/@pkg
    btrfs sub create /mnt/@.snapshots
    umount -R /mnt
    # mount subvolumes
    mount -o noatime,nodiratime,compress=zstd,subvol=@ /dev/mapper/luks /mnt
    mkdir -pv /mnt/{home,var/log,var/cache/pacman/pkg,.snapshots}
    mount -o noatime,nodiratime,compress=zstd,subvol=@home /dev/mapper/luks /mnt/home
    mount -o noatime,nodiratime,compress=zstd,subvol=@log /dev/mapper/luks /mnt/var/log
    mount -o noatime,nodiratime,compress=zstd,subvol=@pkg /dev/mapper/luks /mnt/var/cache/pacman/pkg
    mount -o noatime,nodiratime,compress=zstd,subvol=@.snapshots /dev/mapper/luks /mnt/.snapshots
fi

# install necessary packages
pacstrap /mnt base base-devel linux linux-headers linux-firmware git vim dialog btrfs-progs ${choiceCPU}-ucode
# generate fstab
genfstab -U /mnt >>/mnt/etc/fstab

curl --output /mnt/root/post-archinstall.sh https://raw.githubusercontent.com/richard96292/ALIS/master/scripts/post-archinstall.sh
curl --output /mnt/root/2-archinstall.sh https://raw.githubusercontent.com/richard96292/ALIS/master/scripts/2-archinstall.sh
sed -i "/set -xe/a hostname='${hostname}'" /mnt/root/2-archinstall.sh
sed -i "/set -xe/a password='${password}'" /mnt/root/2-archinstall.sh
sed -i "/set -xe/a diskname='${diskname}'" /mnt/root/2-archinstall.sh
sed -i "/set -xe/a rootPartition='${rootPartition}'" /mnt/root/2-archinstall.sh
sed -i "/set -xe/a UEFIBIOS='${UEFIBIOS}'" /mnt/root/2-archinstall.sh
sed -i "/set -xe/a passwordLuks='${passwordLuks}'" /mnt/root/2-archinstall.sh
chmod +x /mnt/root/2-archinstall.sh

arch-chroot /mnt /root/2-archinstall.sh

rm /mnt/root/2-archinstall.sh

dialog --title "Congratulations" --yes-label "Reboot" --no-label "Cancel" --yesno "First part of the installation has finished succesfully!\\n\\nDo you want to reboot your computer now?" 0 0

umount -R /mnt
reboot
