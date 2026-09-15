#!/bin/bash
#
# Assembles images/<name>.img.xz from the specialised rootfs that
# config-image.sh prepared at build/rootfs-<image>.
#
# Physical image creation only: partition, filesystem, copy, bootloader and
# compression. All rootfs / board integration happened in config-image.sh.

set -eE
trap 'echo "Error: in $0 on line $LINENO"' ERR

[ "$(id -u)" -eq 0 ] || { echo "Please run as root"; exit 1; }

cd "$(dirname -- "$(readlink -f -- "$0")")" && cd ..
root="${PWD}"

[ -n "${BOARD}" ]  || { echo "Error: BOARD is not set"; exit 1; }
[ -n "${SUITE}" ]  || { echo "Error: SUITE is not set"; exit 1; }
[ -n "${FLAVOR}" ] || { echo "Error: FLAVOR is not set"; exit 1; }
export KERNEL="${KERNEL:-vendor}"
# shellcheck source=/dev/null
source "config/kernels/${KERNEL}.sh"
# shellcheck source=/dev/null
source "config/suites/${SUITE}.sh"
# shellcheck source=/dev/null
source "config/flavors/${FLAVOR}.sh"
# shellcheck source=/dev/null
source "config/boards/${BOARD}.sh"

export LC_ALL=C

rootfs_id="${RELEASE_DISTRO}-${RELEASE_VERSION}-${FLAVOR}-arm64"
image_name="${rootfs_id}-${BOARD}"
chroot_dir="build/rootfs-${image_name}"
mnt="build/mnt-${image_name}"

[ -d "${chroot_dir}" ] || {
    echo "Error: no configured rootfs at ${chroot_dir} (run config-image.sh first)"; exit 1; }

# The UUID config-image.sh minted into fstab. The filesystem must be created
# with the same one, or the extlinux/fstab root reference does not resolve.
root_uuid="$(awk '$2 == "/" { sub(/^UUID=/, "", $1); print $1 }' "${chroot_dir}/etc/fstab")"
[ -n "${root_uuid}" ] || { echo "Error: no root UUID in ${chroot_dir}/etc/fstab"; exit 1; }

mkdir -p images build

loop=""
cleanup() {
    sync
    mountpoint -q "${mnt}" && umount "${mnt}" 2> /dev/null || true
    [ -n "${loop}" ] && [ -b "${loop}" ] && losetup -d "${loop}" 2> /dev/null || true
    return 0
}
trap cleanup EXIT

img="images/${image_name}.img"
rootfs_mb="$(du --apparent-size -sm "${chroot_dir}" | cut -f1)"
size_mb="$(( rootfs_mb * 130 / 100 ))"
rm -f "${img}"
truncate -s "${size_mb}M" "${img}"
echo "==> ${img} (rootfs ${rootfs_mb} MiB -> image ${size_mb} MiB)"

loop="$(losetup --find --show --partscan "${img}")"

# One ext4 partition, and it has to be partition 1: with no bootable partition
# on the disk, U-Boot's bootstd only scans p1 (bootdev_find_in_blk). A second
# partition would need an explicit bootable flag before it is looked at.
# The type GUID is Linux root (ARM-64) from the Discoverable Partitions Spec.
parted --script "${loop}" mklabel gpt mkpart writable ext4 16MiB 100%
sgdisk --typecode=1:B921B045-1DF0-41C3-AF44-4C6F280D3FAE "${loop}" > /dev/null
partprobe "${loop}"

# Where udev is running it creates the partition nodes itself and the loop
# below is a no-op. Where it is not, nothing creates them, so read
# major:minor out of sysfs and make the nodes by hand.
base="$(basename "${loop}")"
for part in /sys/block/"${base}"/"${base}"p*; do
    [ -d "${part}" ] || continue
    name="$(basename "${part}")"
    IFS=: read -r maj min < "${part}/dev"
    [ -b "/dev/${name}" ] || mknod "/dev/${name}" b "${maj}" "${min}"
done

p1="${loop}p1"
[ -b "${p1}" ] || { echo "Error: ${p1} did not appear"; exit 1; }

# ^orphan_file: e2fsprogs enables it by default now and the 6.1 kernel cannot
# mount a filesystem that has it. -m 2 leaves less reserved space than the 5%
# default, which on a root filesystem this size is just waste.
mkfs.ext4 -q -m 2 -O ^orphan_file -U "${root_uuid}" -L writable "${p1}"

mkdir -p "${mnt}"
mount "${p1}" "${mnt}"

# How far the image has drifted from the packages it is made of. Both numbers
# should stay small: a distribution configured through drop-ins and package
# selection scores near zero, one configured by editing its files in place does
# not. Reported, not enforced -- this is a number to watch in the build log, and
# deciding what an acceptable value is would be a separate conversation.
echo "==> image vs packages"
verify_count="$(chroot "${chroot_dir}" dpkg --verify 2> /dev/null | grep -c . || true)"
# dpkg records paths as the package shipped them; usr-merge means the same file
# can be found under either spelling, so both sides are normalised before the
# comparison or every file under /bin and /lib counts as unowned.
norm='s#^/\(bin\|sbin\|lib\|lib64\)/#/usr/\1/#'
cat "${chroot_dir}"/var/lib/dpkg/info/*.list 2> /dev/null |
    sed -e "${norm}" | LC_ALL=C sort -u > "${chroot_dir}/tmp/.owned"
# -printf %p, not %P: %P strips the starting point, which would turn
# /usr/share/x into /share/x and make every file under it look unowned.
find "${chroot_dir}/etc" "${chroot_dir}/usr" -xdev -type f -printf '%p\n' 2> /dev/null |
    sed -e "s#^${chroot_dir}##" -e "${norm}" | LC_ALL=C sort -u > "${chroot_dir}/tmp/.present"
unowned_count="$(LC_ALL=C comm -23 "${chroot_dir}/tmp/.present" "${chroot_dir}/tmp/.owned" |
    grep -vc -e '__pycache__' -e '^/etc/ssl/certs/' || true)"
rm -f "${chroot_dir}/tmp/.owned" "${chroot_dir}/tmp/.present"
echo "    dpkg --verify            : ${verify_count} line(s)"
echo "    unowned /etc + /usr      : ${unowned_count} file(s)"

# Straight from the directory rather than staging through a tarball: the tarball
# would be another full uncompressed copy of the rootfs on disk. -W skips the
# delta algorithm for a local copy, -H keeps hardlinks, -X keeps xattrs.
echo "==> copying rootfs"
rsync -aHWX --info=progress0,stats1 "${chroot_dir}/" "${mnt}/"

echo "==> writing bootloader"
# Radxa vendor U-Boot two-file layout: idbloader.img (DDR+SPL) at LBA 64,
# u-boot.itb (FIT: U-Boot + BL31) at LBA 16384. conv=notrunc leaves the GPT
# and rootfs written above it intact.
dd if="${mnt}/usr/lib/u-boot/idbloader.img" of="${loop}" \
   seek=64 conv=notrunc,fsync status=none
dd if="${mnt}/usr/lib/u-boot/u-boot.itb" of="${loop}" \
   seek=16384 conv=notrunc,fsync status=none

# Board-specific image operations, if the board defines any. mixtile-blade3's
# bootloader write is the generic Rockchip path above and needs no hook.
if declare -f "build_image_hook__${BOARD}" > /dev/null; then
    echo "==> build_image_hook__${BOARD}"
    "build_image_hook__${BOARD}" "${loop}" "${mnt}"
fi

sync
umount "${mnt}"
rmdir "${mnt}"
losetup -d "${loop}"
loop=""
rm -rf "${chroot_dir}"
trap - EXIT

echo "==> compressing"
xz -6 -T0 --force "${img}"
( cd images && sha256sum "$(basename "${img}.xz")" > "$(basename "${img}.xz.sha256")" )
ls -la "${img}.xz" | awk '{printf "==> %s  %.0f MB\n", $9, $5/1048576}'
