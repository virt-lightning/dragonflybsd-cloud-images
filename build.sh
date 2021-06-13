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
    version="5.8.3"
fi
if [ -z "${repo}" ]; then
    repo="canonical/cloud-init"
fi
if [ -z "${debug}" ]; then
    debug=""
fi

set -eux
var=
fopt=0
swap=1g
serno=
root_fs='hammer2'
#root_fs='ufs'

if [ ! -f dfly-x86_64-${version}_REL.iso ]; then
    fetch -o - https://avalon.dragonflybsd.org/iso-images/dfly-x86_64-${version}_REL.iso.bz2|bunzip2 > dfly-x86_64-${version}_REL.iso
fi
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
#gpt init -B -f $drive
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
disklabel -R ${drive}s0 /tmp/newlabel
##
gpt add -i 1 -s 1048576 -t efi ${drive}
gpt label -i 1 -l "EFI System" ${drive}


gpt add -i 2 -s 2000000 -t swap ${drive}
gpt add -i 3 -t ${root_fs} ${drive}
gpt label -i 3 -l ROOT ${drive}
sleep 0.5
gpt -v show -l $drive


newfs ${drive}s0a
if [ "$root_fs" = "hammer2" ]; then 
    newfs_hammer2 -L DATA ${drive}s3
else
    newfs ${drive}s3
fi

# DragonFly mounts, setup for installation
#
echo "Mounting DragonFly for copying"
mkdir -p /new
mount -t ${root_fs} ${drive}s3 /new
mkdir -p /new/boot
mount ${drive}s0a /new/boot

vn_cdrom=$(vnconfig vn dfly-x86_64-${version}_REL.iso)
mount -t cd9660 /dev/${vn_cdrom} /mnt/

cpdup -q /mnt /new
cpdup -q /mnt/boot /new/boot
umount /mnt
vnconfig -u ${vn_cdrom}

rm -r /new/etc
mv /new/etc.hdd /new/etc
rm -r /new/README* /new/autorun* /new/dflybsd.ico /new/index.html


# TODO adjust the mount point names
mkdir -p /new2
newfs_msdos ${drive}s1
mount_msdos ${drive}s1 /new2
mkdir -p /new2/efi/boot
cp -v /new/boot/boot1.efi /new2/efi/boot/bootx64.efi
umount /new2

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

# Add mountfrom to /new/boot/loader.conf
#
echo "vfs.root.mountfrom=\"${root_fs}:vbd0s3\"" > /new/boot/loader.conf

# Create a fresh /etc/fstab
#
echo '# Device		Mountpoint	FStype	Options		Dump	Pass#' > /new/etc/fstab
printf "%-20s %-15s ${root_fs}\trw\t1 1\n" "${mfrom}s3" "/" >> /new/etc/fstab
printf "%-20s %-15s ufs\trw\t1 1\n" "${mfrom}s0a" "/boot" >> /new/etc/fstab
printf "%-20s %-15s swap\tsw\t0 0\n" "${mfrom}s1" "none" >> /new/etc/fstab
printf "%-20s %-15s procfs\trw\t4 4\n" "proc" "/proc" >> /new/etc/fstab

cat /new/etc/fstab
chroot /new sh -c '/usr/sbin/pwd_mkdb -p /etc/master.passwd' || true

cp -v growpart /new/usr/local/bin/growpart
chmod +x /new/usr/local/bin/growpart

# Enable Cloud-init
mount -t procfs proc /new/proc
mount -t devfs dev /new/dev
echo "nameserver 1.1.1.1" > /new/etc/resolv.conf
#chroot /new fetch -o - https://github.com/canonical/cloud-init/archive/master.tar.gz | tar xz -f - -C /new/tmp
fetch -o - https://github.com/${repo}/archive/master.tar.gz | tar xz -f - -C /new/tmp
# See: https://www.mail-archive.com/users@dragonflybsd.org/msg05733.html
chroot /new sh -c 'pkg install -y pkg' || true
chroot /new sh -c 'cp /usr/local/etc/pkg/repos/df-latest.conf.sample /usr/local/etc/pkg/repos/df-latest.conf'
chroot /new sh -c 'pkg install -y python37 dmidecode'
chroot /new sh -c 'cd /tmp/cloud-init* && PYTHON=python3.7 ./tools/build-on-freebsd'


echo '
growpart:
   mode: growpart
   devices:
      - "/dev/vbd0s3"
' >> /new/etc/cloud/cloud.cfg

rm /new/var/db/pkg/repo-Avalon.sqlite
umount /new/proc
umount /new/dev

echo 'boot_multicons="YES"' >> /new/boot/loader.conf
echo 'boot_serial="YES"' >> /new/boot/loader.conf
echo 'comconsole_speed="115200"' >> /new/boot/loader.conf
echo 'autoboot_delay="1"' >> /new/boot/loader.conf
echo 'console="comconsole,vidconsole"' >> /new/boot/loader.conf
echo 'sshd_enable="YES"' >> /new/etc/rc.conf
echo '' > /new/etc/resolv.conf

echo "Welcome to DragonFly!" > /new/etc/issue

if [ -z "${debug}" ]; then # Lock root account
    chroot /new sh -c "pw mod user root -w no"
else
    chroot /new sh -c 'echo "!234AaAa56" | pw usermod -n root -h 0'
fi

sed -i .bak '/installer.*/d' /new/etc/passwd
rm /new/etc/passwd.bak
echo "Unmounting /new/boot and /new"

umount /new/boot
umount /new
vnconfig -u ${drive}
