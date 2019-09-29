#!/bin/bash -e
#
# debian-stretch-zfs-root.sh V1.00
#
# Install Debian GNU/Linux 9 Stretch to a native ZFS root filesystem
#
# (C) 2018 Hajo Noerenberg
#
#
# http://www.noerenberg.de/
# https://github.com/hn/debian-stretch-zfs-root
#
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 3.0 as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program. If not, see <http://www.gnu.org/licenses/gpl-3.0.txt>.
#

# use local squid proxy
export http_proxy=http://127.0.0.1:8000

### Static settings

ZPOOL=rpool
TARGETDIST=sid

PARTBIOS=1
PARTBOOT=2
PARTSWAP=3
PARTZFS=4

SIZESWAP=16G
SIZETMP=4G
SIZEVARTMP=4G
SIZEBOOT=512M

### User settings

declare -A BYID
while read -r IDLINK; do
	BYID["$(basename "$(readlink "$IDLINK")")"]="$IDLINK"
done < <(find /dev/disk/by-id/ -type l)

for DISK in $(lsblk -I8 -dn -o name); do
	if [ -z "${BYID[$DISK]}" ]; then
		SELECT+=("$DISK" "(no /dev/disk/by-id persistent device name available)" off)
	else
		SELECT+=("$DISK" "${BYID[$DISK]}" off)
	fi
done

TMPFILE=$(mktemp)
whiptail --backtitle "$0" --title "Drive selection" --separate-output \
	--checklist "\nPlease select ZFS RAID drives\n" 20 74 8 "${SELECT[@]}" 2>"$TMPFILE"

if [ $? -ne 0 ]; then
	exit 1
fi

while read -r DISK; do
	if [ -z "${BYID[$DISK]}" ]; then
		DISKS+=("/dev/$DISK")
		ZFSPARTITIONS+=("/dev/$DISK$PARTZFS")
	else
		DISKS+=("${BYID[$DISK]}")
		ZFSPARTITIONS+=("${BYID[$DISK]}-part$PARTZFS")
	fi
done < "$TMPFILE"

whiptail --backtitle "$0" --title "RAID level selection" --separate-output \
	--radiolist "\nPlease select ZFS RAID level\n" 20 74 8 \
	"RAID0" "Striped disks" off \
	"RAID1" "Mirrored disks (RAID10 for n>=4)" on \
	"RAIDZ" "Distributed parity, one parity block" off \
	"RAIDZ2" "Distributed parity, two parity blocks" off \
	"RAIDZ3" "Distributed parity, three parity blocks" off 2>"$TMPFILE"

if [ $? -ne 0 ]; then
	exit 1
fi

RAIDLEVEL=$(head -n1 "$TMPFILE" | tr '[:upper:]' '[:lower:]')

case "$RAIDLEVEL" in
  raid0)
	RAIDDEF="${ZFSPARTITIONS[*]}"
  	;;
  raid1)
	if [ $((${#ZFSPARTITIONS[@]} % 2)) -ne 0 ]; then
		echo "Need an even number of disks for RAID level '$RAIDLEVEL': ${ZFSPARTITIONS[@]}" >&2
		exit 1
	fi
	I=0
	for ZFSPARTITION in "${ZFSPARTITIONS[@]}"; do
		if [ $((I % 2)) -eq 0 ]; then
			RAIDDEF+=" mirror"
		fi
		RAIDDEF+=" $ZFSPARTITION"
		((I++)) || true
	done
  	;;
  *)
	if [ ${#ZFSPARTITIONS[@]} -lt 3 ]; then
		echo "Need at least 3 disks for RAID level '$RAIDLEVEL': ${ZFSPARTITIONS[@]}" >&2
		exit 1
	fi
	RAIDDEF="$RAIDLEVEL ${ZFSPARTITIONS[*]}"
  	;;
esac

GRUBPKG=grub-pc
#GRUBPKG=grub-efi-amd64
#if [ -d /sys/firmware/efi ]; then
#	whiptail --backtitle "$0" --title "EFI boot" --separate-output \
#		--menu "\nYour hardware supports EFI. Which boot method should be used in the new to be installed system?\n" 20 74 8 \
#		"EFI" "Extensible Firmware Interface boot" \
#		"BIOS" "Legacy BIOS boot" 2>"$TMPFILE"
#
#	if [ $? -ne 0 ]; then
#		exit 1
#	fi
#	if grep -qi EFI $TMPFILE; then
#		GRUBPKG=grub-efi-amd64
#	fi
#fi

whiptail --backtitle "$0" --title "Confirmation" \
	--yesno "\nAre you sure to destroy ZFS pool '$ZPOOL' (if existing), wipe all data of disks '${DISKS[*]}' and create a RAID '$RAIDLEVEL'?\n" 20 74

if [ $? -ne 0 ]; then
	exit 1
fi

### Start the real work

# https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=595790
if [ "$(hostid | cut -b-6)" == "007f01" ]; then
	dd if=/dev/urandom of=/etc/hostid bs=1 count=4
fi

DEBRELEASE=9

case $DEBRELEASE in
	9*)
		echo "deb http://deb.debian.org/debian/ stretch contrib non-free" >/etc/apt/sources.list.d/contrib-non-free.list
		test -f /var/lib/apt/lists/deb.debian.org_debian_dists_stretch_non-free_binary-amd64_Packages || apt-get update
		if [ ! -d /usr/share/doc/zfs-dkms ]; then NEED_PACKAGES+=(zfs-dkms); fi
		;;
esac
if [ ! -f /sbin/zpool ]; then NEED_PACKAGES+=(zfsutils-linux); fi
if [ ! -f /usr/sbin/debootstrap ]; then NEED_PACKAGES+=(debootstrap); fi
if [ ! -f /sbin/sgdisk ]; then NEED_PACKAGES+=(gdisk); fi
if [ ! -f /sbin/mkdosfs ]; then NEED_PACKAGES+=(dosfstools); fi
echo "Need packages: ${NEED_PACKAGES[@]}"
if [ -n "${NEED_PACKAGES[*]}" ]; then DEBIAN_FRONTEND=noninteractive apt-get install --yes "${NEED_PACKAGES[@]}"; fi

modprobe zfs
if [ $? -ne 0 ]; then
	echo "Unable to load ZFS kernel module" >&2
	exit 1
fi
test -d /proc/spl/kstat/zfs/$ZPOOL && zpool destroy $ZPOOL

for DISK in "${DISKS[@]}"; do
	echo -e "\nPartitioning disk $DISK"

	sgdisk --zap-all $DISK
	sgdisk --zap-all $DISK

    sgdisk -a1 -n$PARTBIOS:34:2047   -t$PARTBIOS:EF02 \
        -n$PARTEFI:2048:+512M        -t$PARTEFI:EF00 \
        -n3:0:+16G                   -t3:8200 \
        -n4:0:0                      -t4:BF01 $DISK
    # separate into two steps so we can align the root zfs pool

	sgdisk -a1  -n$PARTBIOS:34:2047         -t$PARTBIOS:EF02    $DISK
	sgdisk      -n$PARTBOOT:0:+$SIZEBOOT    -t$PARTBOOT:8300    $DISK
	sgdisk      -n$PARTSWAP:0:+$SIZESWAP    -t$PARTSWAP:8300    $DISK # was 8200 for unencrypted
	sgdisk      -n$PARTZFS:0:0              -t$PARTZFS:8300     $DISK #TODO switch to 8300 (was BF01)
done

sleep 2

# setup luks
cryptsetup luksFormat -c aes-xts-plain64 -s 256 -h sha256 $DISK-part$PARTSWAP
cryptsetup luksOpen $DISK-part$PARTSWAP luks-swap

cryptsetup luksFormat -c aes-xts-plain64 -s 256 -h sha256 $DISK-part$PARTZFS
cryptsetup luksOpen $DISK-part$PARTZFS luks-zfs

# Workaround for Debian's grub, especially grub-probe, not supporting all ZFS features
# Using "-d" to disable all features, and selectivly enable features later (but NOT 'hole_birth' and 'embedded_data')
# https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=776676
zpool create -f -o ashift=12 -d -o altroot=/target -O atime=off -O mountpoint=none $ZPOOL /dev/mapper/luks-zfs # $RAIDDEF
if [ $? -ne 0 ]; then
	echo "Unable to create zpool '$ZPOOL'" >&2
	exit 1
fi
for ZFSFEATURE in async_destroy empty_bpobj lz4_compress spacemap_histogram enabled_txg extensible_dataset bookmarks filesystem_limits large_blocks; do
	zpool set feature@$ZFSFEATURE=enabled $ZPOOL
done
zfs set compression=lz4 $ZPOOL

zfs create $ZPOOL/ROOT
zfs create -o mountpoint=/ $ZPOOL/ROOT/debian
zpool set bootfs=$ZPOOL/ROOT/debian $ZPOOL

zfs create -o mountpoint=/tmp -o devices=off -o com.sun:auto-snapshot=false -o quota=$SIZETMP $ZPOOL/tmp
# TODO turn off exec for /tmp & turn off devices #ALTERNATE OPTIONS - maybe for next system?
#zfs create -o mountpoint=/tmp -o setuid=off -o exec=on -o devices=on -o com.sun:auto-snapshot=false -o quota=$SIZETMP $ZPOOL/tmp
chmod 1777 /target/tmp

# /var needs to be mounted via fstab, the ZFS mount script runs too late during boot
zfs create -o mountpoint=legacy $ZPOOL/var
mkdir -v /target/var
mount -t zfs $ZPOOL/var /target/var

# /var/tmp needs to be mounted via fstab, the ZFS mount script runs too late during boot
zfs create -o mountpoint=legacy -o com.sun:auto-snapshot=false -o quota=$SIZEVARTMP $ZPOOL/var/tmp

zfs create -o mountpoint=legacy $ZPOOL/var/cache && mkdir -v /target/var/cache
zfs create -o mountpoint=legacy $ZPOOL/var/log && mkdir -v /target/var/log
zfs create -o mountpoint=legacy $ZPOOL/var/spool && mkdir -v /target/var/spool
zfs create -o mountpoint=legacy $ZPOOL/var/lib && mkdir -v /target/var/lib
zfs create -o mountpoint=legacy $ZPOOL/var/www && mkdir -v /target/var/www
zfs create -o mountpoint=legacy $ZPOOL/var/mail && mkdir -v /target/var/mail
#zfs create -o com.sun:auto-snapshot=false -o mountpoint=legacy $ZPOOL/var/lib/docker && mkdir -v /target/var/lib/docker
zfs create -o mountpoint=legacy $ZPOOL/opt && mkdir -v /target/opt
zfs create -o mountpoint=legacy $ZPOOL/home && mkdir -v /target/home

mount -t zfs $ZPOOL/var/cache /target/var/cache
mount -t zfs $ZPOOL/var/log /target/var/log
mount -t zfs $ZPOOL/var/spool /target/var/spool
mount -t zfs $ZPOOL/var/lib /target/var/lib
mount -t zfs $ZPOOL/var/www /target/var/www
mount -t zfs $ZPOOL/var/mail /target/var/mail
#mount -t zfs $ZPOOL/var/lib/docker /target/var/lib/docker
mount -t zfs $ZPOOL/opt /target/opt
mount -t zfs $ZPOOL/home /target/home

mkdir -v -m 1777 /target/var/tmp
mount -t zfs $ZPOOL/var/tmp /target/var/tmp
chmod 1777 /target/var/tmp

sleep 2
mkswap -f /dev/mapper/luks-swap

mkfs.ext4 -L boot $DISK-part$PARTBOOT
mkdir /target/boot
mount $DISK-part$PARTBOOT /target/boot

zpool status
zfs list

while true
do
	debootstrap --cache-dir=/var/cache/debootstrap --include=locales,linux-headers-amd64,linux-image-amd64 --components main,contrib,non-free $TARGETDIST /target http://deb.debian.org/debian/ && break
done

NEWHOST=YOURHOST
echo "$NEWHOST" >/target/etc/hostname
sed -i "1s/^/127.0.1.1\t$NEWHOST\n/" /target/etc/hosts

# Copy hostid as the target system will otherwise not be able to mount the misleadingly foreign file system
cp -va /etc/hostid /target/etc/


UUID=$(blkid -s UUID -o value $DISK-part$PARTZFS)
UUID_SWAP=$(blkid -s UUID -o value $DISK-part$PARTSWAP)

cat << EOF >/target/etc/crypttab
luks-zfs UUID=$UUID         none luks,initramfs,keyscript=decrypt_keyctl
luks-swap UUID=$UUID_SWAP   none luks,initramfs,keyscript=decrypt_keyctl,swap
EOF

cat << EOF >/target/etc/fstab
# /etc/fstab: static file system information.
#
# Use 'blkid' to print the universally unique identifier for a
# device; this may be used with UUID= as a more robust way to name devices
# that works even if disks are added and removed. See fstab(5).
#
# <file system>                     <mount point>   <type>  <options>       <dump>  <pass>
$DISK-part$PARTBOOT                 /boot           ext4    noatime         0       2
/dev/disk/by-id/dm-name-luks-swap   none            swap    defaults        0       0
/dev/disk/by-id/dm-name-luks-zfs    /               zfs     defaults        0       0
$ZPOOL/home                         /home           zfs     defaults        0       0
$ZPOOL/opt                          /opt            zfs     defaults        0       0
$ZPOOL/var                          /var            zfs     defaults        0       0
$ZPOOL/var/tmp                      /var/tmp        zfs     defaults        0       0
$ZPOOL/var/cache                    /var/cache      zfs     defaults        0       0
$ZPOOL/var/lib                      /var/lib        zfs     defaults        0       0
#$ZPOOL/var/lib/docker               /var/lib/docker zfs     defaults        0       0
$ZPOOL/var/log                      /var/log        zfs     defaults        0       0
$ZPOOL/var/mail                     /var/mail       zfs     defaults        0       0
$ZPOOL/var/spool                    /var/spool      zfs     defaults        0       0
$ZPOOL/var/www                      /var/www        zfs     defaults        0       0
EOF

mount --rbind /dev /target/dev
mount --rbind /proc /target/proc
mount --rbind /sys /target/sys
ln -s /proc/mounts /target/etc/mtab

perl -i -pe 's/# (en_US.UTF-8)/$1/' /target/etc/locale.gen
echo 'LANG="en_US.UTF-8"' > /target/etc/default/locale
chroot /target /usr/sbin/locale-gen

chroot /target /usr/bin/apt-get update

chroot /target /usr/bin/apt-get install --yes grub2-common grub-pc zfs-initramfs zfs-dkms
chroot /target /usr/bin/apt-get install --yes firmware-iwlwifi haveged cryptsetup wpasupplicant iw keyutils #gnome-core firefox
chroot /target /bin/systemctl enable haveged

grep -q zfs /target/etc/default/grub || perl -i -pe 's/quiet/boot=zfs/' /target/etc/default/grub
chroot /target /usr/sbin/update-grub

if [ -d /proc/acpi ]; then
	chroot /target /usr/bin/apt-get install --yes acpi acpid
	chroot /target service acpid stop
fi

ETHDEV=$(udevadm info -e | grep "ID_NET_NAME_PATH=" | head -n1 | cut -d= -f2)
test -n "$ETHDEV" || ETHDEV=enp0s25
echo -e "\nauto lo\niface lo inet loopback\n" >>/target/etc/network/interfaces
echo -e "\nauto $ETHDEV\niface $ETHDEV inet dhcp\n" >>/target/etc/network/interfaces
echo -e "\nauto $ETHDEV\niface $ETHDEV inet6 dhcp\n" >>/target/etc/network/interfaces
echo -e "nameserver 1.1.1.1" >> /target/etc/resolv.conf
echo -e "network={\n\tssid=\"NETWORK_SSID\"\n\tkey_mgmt=NONE\n}" > /target/etc/wpa_supplicant/wpa_supplicant.conf

chroot /target /usr/bin/passwd
chroot /target /usr/sbin/dpkg-reconfigure tzdata

sync

#zfs umount -a

## chroot /target /bin/bash --login
## zpool import -R /target rpool

# cryptsetup: ERROR: Couldn't resolve device rpool/ROOT/debian-sid
# cryptsetup: WARNING: Couldn't determine root device
# cryptsetup: WARNING: target 'sda5_crypt' not found in /etc/crypttab

