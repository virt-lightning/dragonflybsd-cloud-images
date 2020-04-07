#!/bin/sh
#
# Copyright (c) 2017 Matthew Dillon. All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
# IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
# OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
# IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT,
# INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
# NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
# DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
# THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
# THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#
version=$1
repo=$2
ref=$3
debug=$4
if [ -z "$version" ]; then
    version="12.1"
fi
if [ -z "${repo}" ]; then
    repo="canonical/cloud-init"
fi
if [ -z "${debug}" ]; then
    debug=""
fi
set -eux

set -eux
var=
fopt=0
swap=1g
serno=
#root_fs='hammer2'
root_fs='ufs'

fetch -o - https://avalon.dragonflybsd.org/iso-images/dfly-x86_64-${version}_REL.iso.bz2|bunzip2 > dfly-x86_64-${version}_REL.iso
dd if=/dev/zero of=final.raw bs=4096 count=1000000

drive=/dev/$(vnconfig vn final.raw)

if [ "x$drive" = "x" ]; then
	help
fi

if [ ! -c $drive ]; then
	if [ ! -c /dev/$drive ]; then
	    echo "efisetup: $drive is not a char-special device"
	    exit 1
	fi
	drive="/dev/$drive"
fi

# Ok, do all the work.  Start by creating a fresh EFI
# partition table
#
gpt destroy $drive
dd if=/dev/zero of=$drive bs=32k count=64 > /dev/null 2>&1
gpt create $drive
if [ $? != 0 ]; then
    echo "gpt create failed"
    exit 1
fi

# GPT partitioning
#
#
#sects=`gpt show ${drive} | sort -n +1 | tail -1 | awk '{ print $2; }'`
#sects=$(($sects / 2048 * 2048))
gpt boot ${drive}
boot0cfg -B -t 20 -s 2 ${drive}
disklabel -B -r -w ${drive}s0 auto


disklabel ${drive}s0 > /tmp/newlabel
echo 'a: * * 4.2BSD' >> /tmp/newlabel

disklabel -R ${drive}s0	/tmp/newlabel # add `a: * * 4.2BSD', to add `a' partition
gpt add -i 1 -s 1000 -t swap ${drive}
gpt add -i 2 -t ${root_fs} ${drive}
gpt label -i 2 -l ROOT ${drive}
sleep 0.5


newfs ${drive}s0a
if [ "$root_fs" = "hammer2" ]; then 
    newfsi_hammer2 ${drive}s2
else
    newfs ${drive}s2
fi

# DragonFly mounts, setup for installation
#
echo "Mounting DragonFly for copying"
mkdir -p /efimnt
mount -t ${root_fs} ${drive}s2 /efimnt
mkdir -p /efimnt/boot
mount ${drive}s0a /efimnt/boot

vn_cdrom=$(vnconfig vn dfly-x86_64-${version}_REL.iso)
mount -t cd9660 /dev/${vn_cdrom} /mnt/

cpdup -v /mnt /efimnt
cpdup -v /mnt/boot /efimnt/boot

umount /mnt
vnconfig -u ${vn_cdrom}

# number (or no serial number).
#
# serno - full drive path or serial number, sans slice & partition,
#	  including the /dev/, which we use as an intermediate
#	  variable.
#
# mfrom - partial drive path as above except without the /dev/,
#	  allowed in mountfrom and fstab.
#
if [ "x$serno" == "x" ]; then
    serno=${drive}
    mfrom="`echo ${drive} | sed -e 's#/dev/##g'`"
else
    serno="serno/${serno}."
    mfrom="serno/${serno}."
fi

serno=/dev/serno/QM00001
mfrom=vbd0

echo "Fixingup files for a ${serno}s1d root"

# Add mountfrom to /efimnt/boot/loader.conf
#
echo "vfs.root.mountfrom=\"${root_fs}:vbd0s2\"" > /efimnt/boot/loader.conf

# Add dumpdev to /etc/rc.conf
#
#echo "dumpdev=\"/dev/${mfrom}s1b\"" >> /efimnt/etc/rc.conf

# Create a fresh /etc/fstab
#
echo '# Device		Mountpoint	FStype	Options		Dump	Pass#' > /efimnt/etc/fstab
printf "%-20s %-15s ${root_fs}\trw\t1 1\n" "${mfrom}s2" "/" \
			>> /efimnt/etc/fstab
printf "%-20s %-15s ufs\trw\t1 1\n" "${mfrom}s0a" "/boot" \
			>> /efimnt/etc/fstab
printf "%-20s %-15s swap\tsw\t0 0\n" "${mfrom}s1" "none" \
			>> /efimnt/etc/fstab
printf "%-20s %-15s procfs\trw\t4 4\n" "proc" "/proc" \
			>> /efimnt/etc/fstab

echo "tmpfs	/tmp		tmpfs	rw		0	0" >> /efimnt/etc/fstab


# Enable Cloud-init
mount -t procfs proc /efimnt/proc
mount -t devfs dev /efimnt/dev
echo "nameserver 1.1.1.1" > /efimnt/etc/resolv.conf
#chroot /efimnt fetch -o - https://github.com/canonical/cloud-init/archive/master.tar.gz | tar xz -f - -C /efimnt/tmp
fetch -o - https://github.com/${repo}/archive/master.tar.gz | tar xz -f - -C /efimnt/tmp
chroot /efimnt sh -c 'pkg install -y python3'
chroot /efimnt sh -c 'cd /tmp/cloud-init* && ./tools/build-on-freebsd'
rm /efimnt/var/db/pkg/repo-Avalon.sqlite
test -z "$debug" || chroot /efimnt pw mod user root -w no  # Lock root account

echo 'boot_multicons="YES"' >> /efimnt/boot/loader.conf
echo 'boot_serial="YES"' >> /efimnt/boot/loader.conf
echo 'comconsole_speed="115200"' >> /efimnt/boot/loader.conf
echo 'autoboot_delay="1"' >> /efimnt/boot/loader.conf
echo 'console="comconsole,vidconsole"' >> /efimnt/boot/loader.conf
echo 'sshd_enable="YES"' >> /efimnt/etc/rc.conf
echo 'firstboot_growfs_enable="YES"' >> /efimnt/etc/rc.conf
sed -e '' -i 's,nfs_client_enable=.*,nfs_client_enable=NO,' /efimnt/etc/rc.conf
echo '' > /efimnt/etc/resolv.conf
echo '' > /efimnt/firstboot

echo '#!/bin/sh

# $FreeBSD$
# KEYWORD: firstboot
# PROVIDE: firstboot_growfs
# BEFORE: root

. /etc/rc.subr

name="firstboot_growfs"
rcvar=firstboot_growfs_enable
start_cmd="firstboot_growfs_run"
stop_cmd=":"

firstboot_growfs_run()
{
if [ ! "$(gpt recover vbd0 2>&1)" = "" ]; then
    mount -fur /
    gpt show vbd0
    gpt remove -i 2 vbd0
    gpt add -i 2 -t ufs vbd0
    growfs -y /dev/vbd0s2
    reboot -q
fi
}

load_rc_config $name
run_rc_command "$1"
' > /efimnt/usr/local/etc/rc.d/firstboot_growfs
chmod 755 /efimnt/usr/local/etc/rc.d/firstboot_growfs


echo "Unmounting /efimnt/boot and /efimnt"

umount /efimnt/proc
umount /efimnt/dev
umount /efimnt/boot
umount /efimnt
vnconfig -u ${drive}
