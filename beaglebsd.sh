#!/bin/sh -e

# Directory containing this script.
TOPDIR=`cd \`dirname $0\`; pwd`
# Useful values
MB=$((1024 * 1024))
GB=$((1024 * $MB))

#
# Get the config values:
#
. $TOPDIR/beaglebsd-config.sh


mkdir -p ${BUILDOBJ}
MAKEOBJDIRPREFIX=${BUILDOBJ}/_freebsd_build

#
# Check various prerequisites
#

# We need TIs modified U-Boot sources
if [ ! -f "$UBOOT_SRC/board/ti/am335x/Makefile" ]; then
    # Use TIs U-Boot sources that know about am33x processors
    echo "Expected to see U-Boot sources in $UBOOT_SRC"
    echo "Use the following command to get the U-Boot sources"
    echo
    echo "git clone git://arago-project.org/git/projects/u-boot-am33x.git $UBOOT_SRC"
    echo
    echo "Edit \$UBOOT_SRC in beaglebsd-config.sh if you want the sources in a different directory."
    echo "Run this script again after you have the U-Boot sources installed."
    exit 1
fi
echo "Found U-Boot sources in $UBOOT_SRC"

# We need the cross-tools for arm, if they're not already built.
if [ -z `which arm-freebsd-cc` ]; then
    echo "Can't find FreeBSD xdev tools for ARM."
    echo "If you have FreeBSD-CURRENT sources in /usr/src, you can build these with the following command:"
    echo
    echo "cd /usr/src && sudo make xdev XDEV=arm XDEV_ARCH=arm"
    echo
    echo "Run this script again after you have the xdev tools installed."
    exit 1
fi
echo "Found FreeBSD xdev tools for ARM"

# We need Damjan Marion's FreeBSD-armv6 tree (we can tell it's the right
# one by the presence of the BEAGLEBONE configuration file).
# Someday, this will all be merged and we can just rely on FreeBSD-CURRENT.
if [ \! -f "$FREEBSD_SRC/sys/arm/conf/BEAGLEBONE" ]; then
    echo "Need FreeBSD-armv6 tree."
    echo "You can obtain this with the folowing command:"
    echo
    echo "mkdir -p $FREEBSD_SRC && svn co http://svn.freebsd.org/base/projects/armv6 $FREEBSD_SRC"
    echo
    echo "Edit \$FREEBSD_SRC in beaglebsd-config.sh if you want the sources in a different directory."
    echo "Run this script again after you have the sources installed."
    exit 1
fi
echo "Found FreeBSD-armv6 source tree in $FREEBSD_SRC"

#
# Build and configure U-Boot
#
if [ ! -f "$UBOOT_SRC/u-boot.img" ]; then
    cd "$UBOOT_SRC"
    echo "Patching U-Boot. (Logging to ${BUILDOBJ}/_.uboot.patch.log)"
    # Works around a FreeBSD bug (freestanding builds require libc).
    patch -p1 < ../files/uboot_patch1_add_libc_to_link_on_FreeBSD.patch > ${BUILDOBJ}/_.uboot.patch.log
    # Turn on some additional U-Boot features not ordinarily present in TIs build.
    patch -p1 < ../files/uboot_patch2_add_options_to_am335x_config.patch >> ${BUILDOBJ}/_.uboot.patch.log
    # Fix a U-Boot bug that has been fixed in the master sources but not yet in TIs sources.
    patch -p1 < ../files/uboot_patch3_fix_api_disk_enumeration.patch >> ${BUILDOBJ}/_.uboot.patch.log

    echo "Configuring U-Boot. (Logging to ${BUILDOBJ}/_.uboot.configure.log)"
    gmake CROSS_COMPILE=arm-freebsd- am335x_evm_config > ${BUILDOBJ}/_.uboot.configure.log 2>&1
    echo "Building U-Boot. (Logging to ${BUILDOBJ}/_.uboot.build.log)"
    gmake CROSS_COMPILE=arm-freebsd- > ${BUILDOBJ}/_.uboot.build.log 2>&1
    cd $TOPDIR
fi

#
# Build FreeBSD for Beagle
#
if [ ! -f ${BUILDOBJ}/_.built-world ]; then
    echo "Building FreeBSD-armv6 world. (Logging to ${BUILDOBJ}/_.buildworld.log)"
    cd $FREEBSD_SRC
    make TARGET_ARCH=arm TARGET_CPUTYPE=armv6 buildworld > ${BUILDOBJ}/_.buildworld.log 2>&1
    cd $TOPDIR
    touch ${BUILDOBJ}/_.built-world
fi

if [ ! -f ${BUILDOBJ}/_.built-kernel ]; then
    echo "Building FreeBSD-armv6 kernel. (Logging to ${BUILDOBJ}/_.buildkernel.log)"
    cd $FREEBSD_SRC
    make TARGET_ARCH=arm KERNCONF=$KERNCONF buildkernel > ${BUILDOBJ}/_.buildkernel.log 2>&1
    cd $TOPDIR
    touch ${BUILDOBJ}/_.built-world
fi

# TODO: Build ubldr

#
# Create and partition the disk image
#
echo "Creating the raw disk image in ${IMG}"
[ -f ${IMG} ] && rm -f ${IMG}
dd if=/dev/zero of=${IMG} bs=1 seek=${SD_SIZE} count=0
MD=`mdconfig -a -t vnode -f ${IMG}`

echo "Partitioning the raw disk image"
# TI AM335x ROM code requires we use MBR partitioning.
gpart create -s MBR ${MD}
gpart add -b 63 -s10m -t '!12' ${MD}
gpart set -a active -i 1 ${MD}
gpart add -t freebsd ${MD}
gpart commit ${MD}

echo "Formatting the FAT partition"
# Note: Select FAT12, FAT16, or FAT32 depending on the size of the partition.
newfs_msdos -L "boot" -F 12 ${MD}s1
rmdir ${BUILDOBJ}/_.mounted_p1
mkdir ${BUILDOBJ}/_.mounted_p1
mount_msdosfs /dev/${MD}s1 ${BUILDOBJ}/_.mounted_p1

echo "Formatting the UFS partition"
bsdlabel -w ${MD}s2
newfs ${MD}s2a
rmdir ${BUILDOBJ}/_.mounted_p2
mkdir ${BUILDOBJ}/_.mounted_p2
mount /dev/${MD}s2a ${BUILDOBJ}/_.mounted_p2

#
# Install U-Boot onto slice 1.
#
echo "Installing U-Boot onto the FAT partition"
cp ${UBOOT_SRC}/MLO ${BUILDOBJ}/_.mounted_p1/
cp ${UBOOT_SRC}/u-boot.img ${BUILDOBJ}/_.mounted_p1/
cp ${TOPDIR}/files/uEnv.txt ${BUILDOBJ}/_.mounted_p1/

#
# TODO: Install FreeBSD's ubldr onto slice 1
#cp /usr/obj/arm.arm/usr/src/sys/boot/arm/uboot/ubldr ${BUILDOBJ}/_.mounted_p1/ubldr

# TODO: Install FreeBSD kernel somewhere

#
# Install FreeBSD kernel and world onto slice 2
#
echo "Installing FreeBSD onto the UFS partition"
cd $FREEBSD_SRC
make TARGET_ARCH=arm TARGET_CPUTYPE=armv6 DESTDIR=${BUILDOBJ}/_.mounted_p2 installkernel > ${BUILDOBJ}/_.installkernel.log 2>&1
make TARGET_ARCH=arm TARGET_CPUTYPE=armv6 DESTDIR=${BUILDOBJ}/_.mounted_p2 installworld > ${BUILDOBJ}/_.installworld.log 2>&1
make TARGET_ARCH=arm TARGET_CPUTYPE=armv6 DESTDIR=${BUILDOBJ}/_.mounted_p2 distrib-dirs > ${BUILDOBJ}/_.distrib-dirs.log 2>&1
make TARGET_ARCH=arm TARGET_CPUTYPE=armv6 DESTDIR=${BUILDOBJ}/_.mounted_p2 distribution > ${BUILDOBJ}/_.distribution.log 2>&1

# Configure FreeBSD
# These could be generated dynamically if we needed.
echo "Configuring FreeBSD"
cp ${TOPDIR}/files/rc.conf ${BUILDOBJ}/_.mounted_p2/etc/
cp ${TOPDIR}/files/fstab ${BUILDOBJ}/_.mounted_p2/etc/

#
# Unmount and clean up.
#
echo "Unmounting the disk image"
cd $TOPDIR
umount ${BUILDOBJ}/_.mounted_p1
umount ${BUILDOBJ}/_.mounted_p2
mdconfig -d -u ${MD}

#
# We have a finished image; explain what to do with it.
#
echo "DONE.  Completed disk image is in: ${IMG}"
echo
echo "Copy to a MicroSDHC card using a command such as:"
echo "dd if=${IMG} of=/dev/da0"
echo
