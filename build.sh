#!/bin/bash
version=$1
repo=$2
ref=$3
debug=$4
if [ -z "$version" ]; then
    version="5.6.3"
fi
if [ -z "${repo}" ]; then
    repo="canonical/cloud-init"
fi
if [ -z "${debug}" ]; then
    debug=""
fi

set -eux
BASE=https://avalon.dragonflybsd.org/iso-images/dfly-x86_64-${version}_REL.img.bz2

test -f disk.img || fetch -o - $BASE|bunzip2 > disk.img

vn_dev=$(vnconfig vn disk.img)
mount /dev/${vn_dev}s2a /mnt
mount -t procfs proc /mnt/proc
mount -t devfs dev /mnt/dev
echo "nameserver 1.1.1.1" > /mnt/etc/resolv.conf
#chroot /mnt fetch -o - https://github.com/canonical/cloud-init/archive/master.tar.gz | tar xz -f - -C /mnt/tmp
chroot /mnt fetch -o - https://github.com/${repo}/archive/master.tar.gz | tar xz -f - -C /mnt/tmp
chroot /mnt sh -c 'pkg install -y python3'
chroot /mnt sh -c 'cd /tmp/cloud-init* && ./tools/build-on-freebsd'

echo 'boot_multicons="YES"' >> /mnt/boot/loader.conf
echo 'boot_serial="YES"' >> /mnt/boot/loader.conf
echo 'comconsole_speed="115200"' >> /mnt/boot/loader.conf
echo 'autoboot_delay="1"' >> /mnt/boot/loader.conf
echo 'console="comconsole,vidconsole"' >> /mnt/boot/loader.conf
echo 'sshd_enable="YES"' >> /mnt/etc/rc.conf
echo '' > /mnt/etc/resolv.conf

umount /mnt/proc
umount /mnt/dev
umount /mnt
fsck /dev/${vn_dev}s2a 
vnconfig -u ${vn_dev}
