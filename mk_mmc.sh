#!/bin/bash -e
#
# Copyright (c) 2009-2013 Robert Nelson <robertcnelson@gmail.com>
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.
#
# Latest can be found at:
# http://github.com/RobertCNelson/flasher/blob/master/mk_mmc.sh

MIRROR="http://rcn-ee.net/deb"
BACKUP_MIRROR="http://rcn-ee.homeip.net:81/dl/mirrors/deb"

BOOT_LABEL="boot"
PARTITION_PREFIX=""

unset MMC
unset USE_BETA_BOOTLOADER

GIT_VERSION=$(git rev-parse --short HEAD)
IN_VALID_UBOOT=1

DIR="$PWD"
TEMPDIR=$(mktemp -d)

check_root () {
	if ! [ $(id -u) = 0 ] ; then
		echo "$0 must be run as sudo user or root"
		exit 1
	fi
}

check_for_command () {
	if ! which "$1" > /dev/null ; then
		echo -n "You're missing command $1"
		NEEDS_COMMAND=1
		if [ -n "$2" ] ; then
			echo -n " (consider installing package $2)"
		fi
		echo
	fi
}

detect_software () {
	unset NEEDS_COMMAND

	check_for_command mkimage uboot-mkimage
	check_for_command mkfs.vfat dosfstools
	check_for_command wget wget
	check_for_command parted parted

	if [ "${NEEDS_COMMAND}" ] ; then
		echo ""
		echo "Your system is missing some dependencies"
		echo "Ubuntu/Debian: sudo apt-get install uboot-mkimage wget dosfstools parted"
		echo "Fedora: as root: yum install uboot-tools wget dosfstools parted dpkg patch"
		echo "Gentoo: emerge u-boot-tools wget dosfstools parted dpkg"
		echo ""
		exit
	fi

	#Check for gnu-fdisk
	#FIXME: GNU Fdisk seems to halt at "Using /dev/xx" when trying to script it..
	if fdisk -v | grep "GNU Fdisk" >/dev/null ; then
		echo "Sorry, this script currently doesn't work with GNU Fdisk."
		echo "Install the version of fdisk from your distribution's util-linux package."
		exit
	fi

	unset PARTED_ALIGN
	if parted -v | grep parted | grep 2.[1-3] >/dev/null ; then
		PARTED_ALIGN="--align cylinder"
	fi
}

dl_bootloader () {
	echo ""
	echo "Downloading Device's Bootloader"
	echo "-----------------------------"
	minimal_boot="1"
	conf_bl_http="http://rcn-ee.net/deb/tools/latest"
	conf_bl_listfile="bootloader-ng"

	mkdir -p ${TEMPDIR}/dl

	wget --no-verbose --directory-prefix=${TEMPDIR}/dl/ ${conf_bl_http}/${conf_bl_listfile}

	if [ ! -f ${TEMPDIR}/dl/${conf_bl_listfile} ] ; then
		echo "error: can't connect to rcn-ee.net, retry in a few minutes..."
		exit
	fi

	boot_version=$(cat ${TEMPDIR}/dl/${conf_bl_listfile} | grep "VERSION:" | awk -F":" '{print $2}')
	if [ "x${boot_version}" != "x${minimal_boot}" ] ; then
		echo "Error: This script is out of date and unsupported..."
		echo "Please Visit: https://github.com/RobertCNelson to find updates..."
		exit
	fi

	if [ "${USE_BETA_BOOTLOADER}" ] ; then
		ABI="ABX2"
	else
		ABI="ABI2"
	fi

	if [ "${spl_name}" ] ; then
		MLO=$(cat ${TEMPDIR}/dl/${conf_bl_listfile} | grep "${ABI}:${conf_board}:SPL" | awk '{print $2}')
		wget --no-verbose --directory-prefix=${TEMPDIR}/dl/ ${MLO}
		MLO=${MLO##*/}
		echo "SPL Bootloader: ${MLO}"
	else
		unset MLO
	fi

	if [ "${boot_name}" ] ; then
		UBOOT=$(cat ${TEMPDIR}/dl/${conf_bl_listfile} | grep "${ABI}:${conf_board}:BOOT" | awk '{print $2}')
		wget --directory-prefix=${TEMPDIR}/dl/ ${UBOOT}
		UBOOT=${UBOOT##*/}
		echo "UBOOT Bootloader: ${UBOOT}"
	else
		unset UBOOT
	fi
}

drive_error_ro () {
	echo "-----------------------------"
	echo "Error: [LC_ALL=C parted --script ${MMC} mklabel msdos] failed..."
	echo "Error: for some reason your SD card is not writable..."
	echo "Check: is the write protect lever set the locked position?"
	echo "Check: do you have another SD card reader?"
	echo "-----------------------------"
	echo "Script gave up..."

	exit
}

unmount_all_drive_partitions () {
	echo ""
	echo "Unmounting Partitions"
	echo "-----------------------------"

	NUM_MOUNTS=$(mount | grep -v none | grep "$MMC" | wc -l)

	for (( c=1; c<=$NUM_MOUNTS; c++ ))
	do
		DRIVE=$(mount | grep -v none | grep "$MMC" | tail -1 | awk '{print $1}')
		umount ${DRIVE} >/dev/null 2>&1 || true
	done

	echo "Zeroing out Partition Table"
	dd if=/dev/zero of=${MMC} bs=1024 count=1024
	LC_ALL=C parted --script ${MMC} mklabel msdos || drive_error_ro
	sync
}

fatfs_boot_error () {
	echo "Failure: [parted --script ${MMC} set 1 boot on]"
	exit
}

omap_fatfs_boot_part () {
	echo ""
	echo "Using fdisk to create an omap compatible fatfs BOOT partition"
	echo "-----------------------------"

	fdisk ${MMC} <<-__EOF__
		n
		p
		1

		+64M
		t
		e
		p
		w
	__EOF__

	sync

	echo "Setting Boot Partition's Boot Flag"
	echo "-----------------------------"
	LC_ALL=C parted --script ${MMC} set 1 boot on || fatfs_boot_error
}

dd_to_drive () {
	echo ""
	echo "Using dd to place bootloader on drive"
	echo "-----------------------------"
	dd if=${TEMPDIR}/dl/${UBOOT} of=${MMC} seek=${dd_seek} bs=${dd_bs}
	bootloader_installed=1

	echo "Using parted to create BOOT Partition"
	echo "-----------------------------"
	if [ "x${boot_fstype}" = "xfat" ] ; then
		parted --script ${PARTED_ALIGN} ${MMC} mkpart primary fat16 ${boot_startmb} ${boot_endmb}
	else
		parted --script ${PARTED_ALIGN} ${MMC} mkpart primary ext2 ${boot_startmb} ${boot_endmb}
	fi
}

no_boot_on_drive () {
	echo "Using parted to create BOOT Partition"
	echo "-----------------------------"
	if [ "x${boot_fstype}" = "xfat" ] ; then
		parted --script ${PARTED_ALIGN} ${MMC} mkpart primary fat16 ${boot_startmb} ${boot_endmb}
	else
		parted --script ${PARTED_ALIGN} ${MMC} mkpart primary ext2 ${boot_startmb} ${boot_endmb}
	fi
}

format_boot_partition () {
	echo "Formating Boot Partition"
	echo "-----------------------------"
	if [ "x${boot_fstype}" = "xfat" ] ; then
		boot_part_format="vfat"
		mkfs.vfat -F 16 ${MMC}${PARTITION_PREFIX}1 -n ${BOOT_LABEL}
	else
		boot_part_format="ext2"
		mkfs.ext2 ${MMC}${PARTITION_PREFIX}1 -L ${BOOT_LABEL}
	fi
}

create_partitions () {
	unset bootloader_installed
	case "${bootloader_location}" in
	omap_fatfs_boot_part)
		omap_fatfs_boot_part
		;;
	dd_to_drive)
		let boot_endmb=${boot_startmb}+${boot_partition_size}
		dd_to_drive
		;;
	*)
		let boot_endmb=${boot_startmb}+${boot_partition_size}
		no_boot_on_drive
		;;
	esac
	format_boot_partition
}

populate_boot () {
	echo "Populating Boot Partition"
	echo "-----------------------------"

	partprobe ${MMC}
	if [ ! -d ${TEMPDIR}/disk ] ; then
		mkdir -p ${TEMPDIR}/disk
	fi

	if mount -t ${boot_part_format} ${MMC}${PARTITION_PREFIX}1 ${TEMPDIR}/disk; then

		if [ "${spl_name}" ] ; then
			if [ -f ${TEMPDIR}/dl/${MLO} ] ; then
				cp -v ${TEMPDIR}/dl/${MLO} ${TEMPDIR}/disk/${spl_name}
				echo "-----------------------------"
			fi
		fi

		if [ "${boot_name}" ] ; then
			if [ -f ${TEMPDIR}/dl/${UBOOT} ] ; then
				cp -v ${TEMPDIR}/dl/${UBOOT} ${TEMPDIR}/disk/${boot_name}
			fi
		fi

		case "${SYSTEM}" in
		omap3_beagle)
			cat > ${TEMPDIR}/disk/reset.cmd <<-__EOF__
				echo "Starting NAND UPGRADE, do not REMOVE SD CARD or POWER till Complete"
				fatload mmc 0:1 0x80200000 ${spl_name}
				nandecc hw
				nand erase 0 80000
				nand write 0x80200000 0 20000
				nand write 0x80200000 20000 20000
				nand write 0x80200000 40000 20000
				nand write 0x80200000 60000 20000

				fatload mmc 0:1 0x80200000 ${boot_name}
				nandecc hw
				nand erase 80000 160000
				nand write 0x80200000 80000 170000
				nand erase 260000 20000
				echo "FLASH UPGRADE Complete"
				exit

			__EOF__

			mkimage -A arm -O linux -T script -C none -a 0 -e 0 -n "Reset NAND" -d ${TEMPDIR}/disk/reset.cmd ${TEMPDIR}/disk/user.scr
			cat ${TEMPDIR}/disk/reset.cmd

			cat > ${TEMPDIR}/disk/uEnv.txt <<-__EOF__
				bootenv=user.scr
				loaduimage=fatload mmc \${mmcdev} \${loadaddr} \${bootenv}
				mmcboot=echo Running user.scr script from mmc ...; source \${loadaddr}

			__EOF__

			cp -v ${TEMPDIR}/disk/uEnv.txt ${TEMPDIR}/disk/user.txt
			;;
		esac

		cd ${TEMPDIR}/disk
		sync
		cd "${DIR}"/

		echo "Debug: Contents of Boot Partition"
		echo "-----------------------------"
		ls -lh ${TEMPDIR}/disk/
		echo "-----------------------------"

		umount ${TEMPDIR}/disk || true

		echo "Finished populating Boot Partition"
		echo "-----------------------------"
	else
		echo "-----------------------------"
		echo "Unable to mount ${MMC}${PARTITION_PREFIX}1 at ${TEMPDIR}/disk to complete populating Boot Partition"
		echo "Please retry running the script, sometimes rebooting your system helps."
		echo "-----------------------------"
		exit
	fi
	echo "mk_mmc.sh script complete"
	echo "Script Version git: ${GIT_VERSION}"
	echo "-----------------------------"
}

check_mmc () {
	FDISK=$(LC_ALL=C fdisk -l 2>/dev/null | grep "Disk ${MMC}" | awk '{print $2}')

	if [ "x${FDISK}" = "x${MMC}:" ] ; then
		echo ""
		echo "I see..."
		echo "fdisk -l:"
		LC_ALL=C fdisk -l 2>/dev/null | grep "Disk /dev/" --color=never
		echo ""
		if which lsblk > /dev/null ; then
			echo "lsblk:"
			lsblk | grep -v sr0
		else
			echo "mount:"
			mount | grep -v none | grep "/dev/" --color=never
		fi
		echo ""
		unset response
		echo -n "Are you 100% sure, on selecting [${MMC}] (y/n)? "
		read response
		if [ "x${response}" != "xy" ] ; then
			exit
		fi
		echo ""
	else
		echo ""
		echo "Are you sure? I Don't see [${MMC}], here is what I do see..."
		echo ""
		echo "fdisk -l:"
		LC_ALL=C fdisk -l 2>/dev/null | grep "Disk /dev/" --color=never
		echo ""
		echo "mount:"
		mount | grep -v none | grep "/dev/" --color=never
		echo ""
		exit
	fi
}

is_omap () {
	IS_OMAP=1

	bootloader_location="omap_fatfs_boot_part"
	spl_name="MLO"
	boot_name="u-boot.img"

	boot_fstype="fat"
}

is_imx () {
	IS_IMX=1

	bootloader_location="dd_to_drive"
	unset spl_name
	boot_name="u-boot.imx"
	offset="0x400"
	dd_seek="1"
	dd_bs="1024"
	boot_startmb="2"

	boot_fstype="ext2"
}

check_uboot_type () {
	unset DO_UBOOT
	unset IN_VALID_UBOOT
	boot_partition_size="50"

	case "${UBOOT_TYPE}" in
	beagle_bx|beagle_cx|omap3_beagle)
		SYSTEM="omap3_beagle"
		DO_UBOOT=1
		conf_board="omap3_beagle"
		is_omap
		;;
	*)
		IN_VALID_UBOOT=1
		cat <<-__EOF__
			-----------------------------
			ERROR: This script does not currently recognize the selected: [--uboot ${UBOOT_TYPE}] option..
			Please rerun $(basename $0) with a valid [--uboot <device>] option from the list below:
			-----------------------------
			        TI:
			                beagle_bx - <BeagleBoard Ax/Bx>
			                beagle_cx - <BeagleBoard Cx>
			-----------------------------
		__EOF__
		exit
		;;
	esac
}

usage () {
	echo "usage: sudo $(basename $0) --mmc /dev/sdX --uboot <dev board>"
	#tabed to match 
		cat <<-__EOF__
			Script Version git: ${GIT_VERSION}
			-----------------------------
			Bugs email: "bugs at rcn-ee.com"

			Required Options:
			--mmc </dev/sdX>

			--uboot <dev board>
			        TI:
			                beagle_bx - <BeagleBoard Ax/Bx>
			                beagle_cx - <BeagleBoard Cx>
			        Freescale:
			                mx6qsabrelite - (boot off SPI)
			                mx6qsabrelite_sd - (boot off SD)
			                mx6qsabrelite_uboot - (mainline testing DO NOT USE)

			Additional Options:
			        -h --help

			--probe-mmc
			        <list all partitions: sudo ./mk_mmc.sh --probe-mmc>

			__EOF__
	exit
}

checkparm () {
	if [ "$(echo $1|grep ^'\-')" ] ; then
		echo "E: Need an argument"
		usage
	fi
}

IN_VALID_UBOOT=1

# parse commandline options
while [ ! -z "$1" ] ; do
	case $1 in
	-h|--help)
		usage
		MMC=1
		;;
	--probe-mmc)
		MMC="/dev/idontknow"
		check_root
		check_mmc
		;;
	--mmc)
		checkparm $2
		MMC="$2"
		if [[ "${MMC}" =~ "mmcblk" ]] ; then
			PARTITION_PREFIX="p"
		fi
		check_root
		check_mmc
		;;
	--uboot)
		checkparm $2
		UBOOT_TYPE="$2"
		check_uboot_type
		;;
	--use-beta-bootloader)
		USE_BETA_BOOTLOADER=1
		;;
	esac
	shift
done

if [ ! "${MMC}" ] ; then
	echo "ERROR: --mmc undefined"
	usage
fi

if [ "${IN_VALID_UBOOT}" ] ; then
	echo "ERROR: --uboot undefined"
	usage
fi

echo ""
echo "Script Version git: ${GIT_VERSION}"
echo "-----------------------------"

check_root
detect_software

if [ "${spl_name}" ] || [ "${boot_name}" ] ; then
	dl_bootloader
fi

unmount_all_drive_partitions
create_partitions
populate_boot

