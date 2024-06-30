#!/bin/bash

SCRIPT=$(realpath "$0")
SCRIPTPATH=$(dirname "$SCRIPT")

if [ $EUID -ne 0 ]; then
	echo "$(basename $0) must be ran as superuser or sudo"
	exit 1
fi

while [[ $# -gt 0 ]]
do
key="$1"
case $key in
	--flavor)
	BUILD_MANIFEST="${SCRIPTPATH}/presets/$2.sh"
	BUILD_MANIFEST_ID="$2"
	POSTCOPY_DIR="$2"
	if [[ "${BUILD_MANIFEST_ID}" =~ "dev" ]]; then
		BUILD_MANIFEST_ID=$(echo $2 | cut -d '-' -f 1)
		BRANCH_OVERRIDES=$(echo $2 | cut -d '-' -f 2)
	fi
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
		if [[ -n "${BRANCH_OVERRIDES}" ]]; then
			OUTPUT="$2/${BRANCH_OVERRIDES}"
		fi
	fi
	shift
	shift
	;;
    --add-release)
	IS_HOME_BUILD=true
	if [[ ! "${OUTPUT}" =~ "steamfork-images" ]]; then
		echo "Specific output directories should be preceeded with steamfork-images for release images."
		exit 255
	fi
	shift
	shift
	;;
    --rclone_path)
	RC_PATH="$2"
	shift
	shift
	;;
	--rclone_root)
	if [[ -n "${RC_PATH}" ]]; then
		RC_ROOT="$2"
	else
		echo "rclone root can be used only with --rclone_path"
		exit 255
	fi
	shift
	shift
	;;
    --donotcompress)
	NO_COMPRESS="1"
	if [[ "${IS_HOME_BUILD}" == "true" ]]; then
		echo "Decompressed images are not supported in shipping builds"
		exit 127
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
if [[ -z "{$BUILD_MANIFEST}" ]]; then
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

source $BUILD_MANIFEST
PACCFG=${SCRIPTPATH}/pacman-build-${BUILD_MANIFEST_ID}.conf


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

echo "(1/6) Bootstrapping main filesystem"
# Start by bootstrapping essentials
mkdir -p ${ROOT_WORKDIR}/${OS_FS_PREFIX}_root/rootfs
mkdir -p ${ROOT_WORKDIR}/var/cache/pacman/pkg
mount --bind /var/cache/pacman/pkg/ ${ROOT_WORKDIR}/var/cache/pacman/pkg
pacstrap -C ${PACCFG} ${ROOT_WORKDIR} ${BASE_BOOTSTRAP_PKGS}
echo "(1.5/6) Bootstrapping kernel..."
pacstrap -C ${PACCFG} ${ROOT_WORKDIR} ${KERNELCHOICE} ${KERNELCHOICE}-headers

echo "(2/6) Generating fstab..."

# fstab
echo -e ${FSTAB} > ${ROOT_WORKDIR}/etc/fstab

sed -i 's/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/g' ${ROOT_WORKDIR}/etc/sudoers

echo "(3/6) Bootstrapping SteamFork core root"
pacstrap -C ${PACCFG} ${ROOT_WORKDIR} ${UI_BOOTSTRAP}
rm ${ROOT_WORKDIR}/etc/pacman.conf
cp ${PACCFG} ${ROOT_WORKDIR}/etc/pacman.conf

echo -e $OS_RELEASE > ${ROOT_WORKDIR}/etc/os-release
echo -e $STEAMFORK_RELEASE > ${ROOT_WORKDIR}/etc/steamfork-release
echo -e $IMAGE_HOSTNAME > ${ROOT_WORKDIR}/etc/hostname
mkdir -p ${ROOT_WORKDIR}/etc/steamos-atomupd
cat <<EOF >${ROOT_WORKDIR}/etc/steamos-atomupd/manifest.json
{
    "product": "steamos",
    "release": "holo",
    "variant": "steamfork",
    "arch": "amd64",
    "version": "${SNAPSHOTVERSION}",
    "buildid": "${SNAPSHOTVERSION}",
    "checkpoint": false,
    "estimated_size": 0
}
EOF

echo "(4/6) Copying postcopy items..."
if [[ -d "${SCRIPTPATH}/postcopy" ]]; then
	cp -r ${SCRIPTPATH}/postcopy/* ${ROOT_WORKDIR}
fi

for dirs in ${MKNEWDIR}; do mkdir ${ROOT_WORKDIR}/$dirs; done
if [[ -n "$PLYMOUTH_THEME" ]]; then
	echo "Setting $PLYMOUTH_THEME theme for plymouth bootsplash..."
	arch-chroot ${ROOT_WORKDIR} plymouth-set-default-theme -R $PLYMOUTH_THEME
fi

for binary in ${POSTCOPY_BIN_EXECUTION}; do arch-chroot ${ROOT_WORKDIR} $binary && rm -rf ${ROOT_WORKDIR}/usr/bin/$binary; done
echo -e "${PACMAN_ONLOAD}" > ${ROOT_WORKDIR}/usr/lib/systemd/system/var-lib-pacman.mount

echo "(4.5/6) Generating en_US.UTF-8 locale..."
sed -i 's/#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/g' ${ROOT_WORKDIR}/etc/locale.gen
arch-chroot ${ROOT_WORKDIR} locale-gen
arch-chroot ${ROOT_WORKDIR} localectl set-locale LANG=en_US.UTF-8
arch-chroot ${ROOT_WORKDIR} mkdir -p /etc/lib/steamfork_hwsupport/customdevicequirks

for ENABLED_SERVICE in ${ENABLED_SERVICES[@]}
do
  echo "(4.6/6) Enable service ${ENABLED_SERVICE}"
  arch-chroot ${ROOT_WORKDIR} systemctl enable ${ENABLED_SERVICE}
done

for DISABLED_SERVICE in ${DISABLED_SERVICES[@]}
do
  echo "(4.7/6) Disable service ${DISABLED_SERVICE}"
  arch-chroot ${ROOT_WORKDIR} systemctl disable ${DISABLED_SERVICE}
  arch-chroot ${ROOT_WORKDIR} rm -f /usr/lib/systemd/system/multi-user.target.wants/${DISABLED_SERVICE}
done

echo "(4.8/6) Enable nopasswd sudo (req by steam and other tools)"
  arch-chroot ${ROOT_WORKDIR} sed -i 's~ALL$~NOPASSWD: ALL~g' /etc/sudoers.d/wheel

echo "(4.9/6) Patch Audio output to add generic devices to the filter."
  arch-chroot ${ROOT_WORKDIR} sed -i '/matches = \[/a \      {\n\        node.name = "~alsa_output.*"\n\        alsa.card_name = "HD-Audio Generic"\n\      }' /usr/share/wireplumber/hardware-profiles/valve-jupiter/wireplumber.conf.d/alsa-card1.conf

echo "(4.10/6) Fix runtime audio configuration."
  for AUDIO_SERVICE in pipewire wireplumber
  do
    arch-chroot ${ROOT_WORKDIR} sed -i 's~multi-user.target~local-fs.target~g' /usr/lib/systemd/system/${AUDIO_SERVICE}-sysconf.service
    arch-chroot ${ROOT_WORKDIR} systemctl enable ${AUDIO_SERVICE}-sysconf.service
  done

echo "(4.11/6) Delete conflicting files..."
# Delete conflicting files
for CONFLICT in etc/X11/Xsession.d/50rotate-screen \
                etc/sddm.conf.d/steamdeck.conf
do
  if [ -e "${SCRIPTPATH}/airootfs/${CONFLICT}" ]
  then
    rm -f "${SCRIPTPATH}/airootfs/${CONFLICT}"
  fi
done

echo "(5/6) Stop doing things in container..."
# Cleanup
umount -l ${ROOT_WORKDIR}/var/cache/pacman/pkg/

# Finish for now
echo "(6/6) Packaging snapshot..."
btrfs subvolume snapshot -r ${ROOT_WORKDIR} ${ROOT_WORKDIR}/${OS_FS_PREFIX}_root/rootfs/${BUILDVER}
btrfs send -f ${OUTPUT}/${FINAL_DISTRIB_IMAGE}.img ${ROOT_WORKDIR}/${OS_FS_PREFIX}_root/rootfs/${BUILDVER}
umount -l ${ROOT_WORKDIR} && umount -l ${WORKDIR}/work.img && rm -rf ${WORKDIR} && ${WORKDIR}/work.img
if [[ -z "${NO_COMPRESS}" ]]; then
	echo "Compressing image..."
	zstd --ultra -z ${OUTPUT}/${FINAL_DISTRIB_IMAGE}.img -o ${OUTPUT}/${FINAL_DISTRIB_IMAGE}.img.zst
	rm -rf ${OUTPUT}/${FINAL_DISTRIB_IMAGE}.img
	chown 1000:1000 ${OUTPUT}/${FINAL_DISTRIB_IMAGE}.img.zst
	chmod 777 ${OUTPUT}/${FINAL_DISTRIB_IMAGE}.img.zst
fi

if [[ "${IS_HOME_BUILD}" == "true" ]]; then
	echo -e ${UPDATE_METADATA} > ${OUTPUT}/${FINAL_DISTRIB_IMAGE}.releasemeta
	echo -e ${UPDATE_METADATA} > ${OUTPUT}/latest_${BUILD_MANIFEST_ID}.releasemeta
	sha256sum ${OUTPUT}/${FINAL_DISTRIB_IMAGE}.img.zst | awk '{print $1'} > ${OUTPUT}/${FINAL_DISTRIB_IMAGE}.sha256
	chown 1000:1000 ${OUTPUT}/${FINAL_DISTRIB_IMAGE}.sha256 ${OUTPUT}/latest_${BUILD_MANIFEST_ID}.releasemeta
	chmod 777 ${OUTPUT}/${FINAL_DISTRIB_IMAGE}.sha256 ${OUTPUT}/latest_${BUILD_MANIFEST_ID}.releasemeta
	if [[ -n "${RC_PATH}" ]]; then
		rclone mkdir ${RC_PATH}:/download/$(echo ${OUTPUT} | sed 's#.*steamfork#steamfork#g')
		rclone copy ${OUTPUT}/latest_${BUILD_MANIFEST_ID}.releasemeta ${RC_PATH}:/download/$(echo ${OUTPUT} | sed 's#.*steamfork#steamfork#g') -L --progress
		rclone copy ${OUTPUT}/${FINAL_DISTRIB_IMAGE}.sha256 ${RC_PATH}:/${RC_ROOT}/$(echo ${OUTPUT} | sed 's#.*steamfork#steamfork#g') -L --progress
		rclone copy ${OUTPUT}/${FINAL_DISTRIB_IMAGE}.img.zst ${RC_PATH}:/${RC_ROOT}/$(echo ${OUTPUT} | sed 's#.*steamfork#steamfork#g') -L --progress
	fi
fi

echo "Build complete."
