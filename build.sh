#!/bin/bash

SCRIPT=$(realpath "$0")
SCRIPTPATH=$(dirname "$SCRIPT")
PACCFG=${SCRIPTPATH}/pacman-build.conf

if [ $EUID -ne 0 ]; then
	echo "$(basename $0) must be ran as superuser or sudo"
	exit 1
fi

while [[ $# -gt 0 ]]
do
key="$1"
case $key in
	--flavor)
	BUILD_FLAVOR_MANIFEST="${SCRIPTPATH}/presets/$2.sh"
	BUILD_FLAVOR_MANIFEST_ID="$2"
	shift
	shift
	;;
	--deployment_rel)
	RELEASETYPE="$2.sh"
	shift
	shift
	;;
	--snapshot_ver)
	SNAPSHOTVERSION="$2"
	shift
	shift
	;;
	--workdir)
	WORKDIR="$2/buildwork"
	shift
	shift
	;;
	--output-dir)
	if [[ -z "$2" ]]; then
		OUTPUT=${WORKDIR}
	else
		OUTPUT="$2"
	fi
	shift
	shift
	;;
    --add-release)
	ADDRELEASE="$2"
    if [[ "${ADDRELEASE}" == "true" ]]; then
        ADDRELEASE_CHECK="1"
    elif [[ "${ADDRELEASE}" == "false" ]]; then
        ADDRELEASE_CHECK="0"
    else
        echo "Unknown option for --add-release, options: [true:false]"
    fi
	shift
	shift
	;;
	*)    # unknown option
    echo "Unknown option: $1"
    exit 1
    ;;
esac
done

# Check if everything is set.
if [[ -z "{$BUILD_FLAVOR_MANIFEST}" ]]; then
	echo "Build flavor was not set. Aborting."
	exit 0
fi
if [[ -z "${SNAPSHOTVERSION}" ]]; then
	echo "Snapshot directory was not set. Aborting."
	exit 0
fi
if [[ -z "${WORKDIR}" ]]; then
	echo "Workdir was not set. Aborting."
	exit 0
fi

source $BUILD_FLAVOR_MANIFEST


ROOT_WORKDIR=${WORKDIR}/rootfs_mnt
echo "Preparing to create deployment image..."
# Pre-build cleanup
umount -l ${ROOT_WORKDIR}
rm -rf ${WORKDIR}/*.img*
rm -rf ${WORKDIR}/*.img
rm -rf ${WORKDIR}/work.img

# Start building here
mkdir -p ${WORKDIR}
mkdir -p ${OUTPUT}
mkdir -p ${ROOT_WORKDIR}
fallocate -l 10000MB ${WORKDIR}/work.img
mkfs.btrfs ${WORKDIR}/work.img
mkdir -p ${WORKDIR}/rootfs_mnt
mount -t btrfs -o loop,compress-force=zstd:1,discard,noatime,nodiratime ${WORKDIR}/work.img ${ROOT_WORKDIR}

echo "(1/7) Bootstrapping main filesystem"
# Start by bootstrapping essentials
mkdir -p ${ROOT_WORKDIR}/${OS_FS_PREFIX}_root/rootfs
mkdir -p ${ROOT_WORKDIR}/var/cache/pacman/pkg
mount --bind /var/cache/pacman/pkg/ ${ROOT_WORKDIR}/var/cache/pacman/pkg
pacstrap -C ${PACCFG} ${ROOT_WORKDIR} ${BASE_BOOTSTRAP_PKGS} ${KERNELCHOICE} ${KERNELCHOICE}-headers

echo "(2/7) Generating fstab..."

# fstab
echo "
LABEL=${OS_FS_PREFIX}_root /          btrfs subvol=rootfs/${FLAVOR_BUILDVER},compress-force=zstd:1,discard,noatime,nodiratime 0 0
LABEL=${OS_FS_PREFIX}_root /${OS_FS_PREFIX}_root btrfs rw,noatime,nodatacow 0 0
LABEL=${OS_FS_PREFIX}_var /var       ext4 rw,relatime 0 0
LABEL=${OS_FS_PREFIX}_home /home      ext4 rw,relatime 0 0
" > ${ROOT_WORKDIR}/etc/fstab

sed -i 's/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/g' ${ROOT_WORKDIR}/etc/sudoers

echo "(3/7) Bootstrapping HoloISO core root"
pacstrap -C ${PACCFG} ${ROOT_WORKDIR} ${UI_BOOTSTRAP}
echo -e $OS_RELEASE > ${ROOT_WORKDIR}/etc/os-release
echo -e $HOLOISO_RELEASE > ${ROOT_WORKDIR}/etc/holoiso-release
if [[ -d "${SCRIPTPATH}/postcopy" ]]; then
	cp -r ${SCRIPTPATH}/postcopy/* ${ROOT_WORKDIR}
	arch-chroot ${ROOT_WORKDIR} systemctl enable holoiso-create-overlays steamos-offload.target etc.mount opt.mount root.mount srv.mount usr-lib-debug.mount usr-local.mount var-cache-pacman.mount var-lib-docker.mount var-lib-flatpak.mount var-lib-systemd-coredump.mount var-log.mount var-tmp.mount powerbutton-chmod
fi
arch-chroot ${ROOT_WORKDIR} systemctl enable sddm bluetooth sshd systemd-timesync NetworkManager
# Cleanup
umount -l ${ROOT_WORKDIR}/var/cache/pacman/pkg/

# Finish for now
echo "Packaging snapshot..."
btrfs subvolume snapshot -r ${ROOT_WORKDIR} ${ROOT_WORKDIR}/${OS_FS_PREFIX}_root/rootfs/${FLAVOR_BUILDVER}
btrfs send -f ${WORKDIR}/${FLAVOR_FINAL_DISTRIB_IMAGE}.img ${ROOT_WORKDIR}/${OS_FS_PREFIX}_root/rootfs/${FLAVOR_BUILDVER}
umount -l ${ROOT_WORKDIR} && umount -l ${WORKDIR}/work.img && rm -rf ${ROOT_WORKDIR} ${WORKDIR}/work.img
echo "Compressing image..."
tar -c -I'xz -8 -T4' -f ${OUTPUT}/${FLAVOR_FINAL_DISTRIB_IMAGE}.img.tar.xz ${WORKDIR}/${FLAVOR_FINAL_DISTRIB_IMAGE}.img
rm -rf ${FLAVOR_FINAL_DISTRIB_IMAGE}.img
chown 1000:1000 ${OUTPUT}/${FLAVOR_FINAL_DISTRIB_IMAGE}.img.tar.xz
chmod 777 ${OUTPUT}/${FLAVOR_FINAL_DISTRIB_IMAGE}.img.tar.xz