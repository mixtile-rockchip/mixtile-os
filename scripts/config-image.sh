#!/bin/bash
#
# Integrates the shared rootfs with the kernel, U-Boot and board configuration,
# leaving a specialised rootfs at build/rootfs-<image> for build-image.sh.
#
# This is the board-integration stage: unpack the suite/flavor rootfs, install
# the kernel and U-Boot packages, apply overlay/ and the board's
# config_image_hook, and prepare the account, fstab, initramfs and extlinux
# configuration. Physical disk assembly is build-image.sh's job.

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
: "${UBOOT_BINARY_PACKAGE:?}" "${KERNEL_PACKAGE:?}"

export DEBIAN_FRONTEND=noninteractive LC_ALL=C

# Chroot lifecycle, kept here rather than in a shared helper so each stage owns
# its own mount lifecycle. teardown unmounts deepest-first; getting that wrong
# takes the host's /dev with it.
setup_chroot() {
    local target="$1"
    mount -t proc proc "${target}/proc"
    mount -t sysfs sys "${target}/sys"
    mount -o bind /dev "${target}/dev"
    mount -o bind /dev/pts "${target}/dev/pts"

    rm -f "${target}/etc/resolv.conf"
    printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\noptions timeout:3 attempts:2\n' \
        > "${target}/etc/resolv.conf"
}

teardown_chroot() {
    local target
    target="$(realpath "$1")"
    sync
    awk -v t="${target}" '$2 ~ "^"t"/" { print $2 }' /proc/self/mounts |
        LC_ALL=C sort -r |
        while IFS= read -r mnt; do
            umount -l "${mnt}" 2> /dev/null || true
        done
}

block_service_start() {
    local target="$1"
    printf '#!/bin/sh\nexit 101\n' > "${target}/usr/sbin/policy-rc.d"
    chmod 755 "${target}/usr/sbin/policy-rc.d"

    chroot "${target}" dpkg-divert --local --rename --add /sbin/initctl > /dev/null
    chroot "${target}" dpkg-divert --local --rename --add /sbin/start-stop-daemon > /dev/null
    printf '#!/bin/sh\n' > "${target}/sbin/initctl"
    printf '#!/bin/sh\necho "Warning: fake start-stop-daemon called, doing nothing"\n' \
        > "${target}/sbin/start-stop-daemon"
    chmod 755 "${target}/sbin/initctl" "${target}/sbin/start-stop-daemon"
}

unblock_service_start() {
    local target="$1"
    rm -f "${target}/sbin/initctl" "${target}/sbin/start-stop-daemon"
    chroot "${target}" dpkg-divert --local --rename --remove /sbin/initctl > /dev/null
    chroot "${target}" dpkg-divert --local --rename --remove /sbin/start-stop-daemon > /dev/null
    rm -f "${target}/usr/sbin/policy-rc.d"
}

retry() {
    local n=0 max="$1"; shift
    until "$@"; do
        n=$((n + 1))
        [ "${n}" -ge "${max}" ] && { echo "Error: failed after ${max} tries: $*"; return 1; }
        echo "==> retry ${n}/${max}: $*"
        sleep 5
    done
}

rootfs_id="${RELEASE_DISTRO}-${RELEASE_VERSION}-${FLAVOR}-arm64"
image_name="${rootfs_id}-${BOARD}"
tarball="build/${rootfs_id}.rootfs.tar.zst"
chroot_dir="build/rootfs-${image_name}"

[ -f "${tarball}" ] || { echo "Error: no rootfs at ${tarball}"; exit 1; }

# Product default account. The password is pre-provisioned and does not expire:
# the first console or SSH login gets a shell straight away.
default_user=mixtile
default_pass=mixtile
default_hostname="${BOARD}"

mkdir -p build

cleanup() {
    teardown_chroot "${chroot_dir}" 2> /dev/null || true
    return 0
}
trap cleanup EXIT

echo "==> unpacking ${tarball}"
rm -rf "${chroot_dir}"
mkdir -p "${chroot_dir}"
zstd -dc "${tarball}" | tar -xp --xattrs --numeric-owner -C "${chroot_dir}"
for st in "${PIPESTATUS[@]}"; do
    [ "${st}" -eq 0 ] || { echo "Error: ${tarball} did not unpack -- corrupt?"; exit 1; }
done

setup_chroot "${chroot_dir}"
block_service_start "${chroot_dir}"

# Board-specific static files live in overlay/ and are applied here, so the
# shared rootfs stays board-neutral. Modes are taken from the work tree and
# ownership is forced to root. Git records only the executable bit, so a file
# whose exact mode matters cannot rely on this loop -- see netplan below.
if [ -d overlay ]; then
    echo "==> applying overlay"
    while IFS= read -r -d '' f; do
        install -D -m "$(stat -c '%a' "overlay/${f}")" -o root -g root \
            "overlay/${f}" "${chroot_dir}/${f}"
    done < <(cd overlay && find . -type f -printf '%P\0')
fi

# netplan warns on every boot about any config that is not 0600, and upstream
# requires that mode (https://netplan.readthedocs.io/en/stable/security/).
# It is set here rather than carried by the overlay file because git cannot
# record 0600: a fresh clone would hand the file over as 0644 and the image
# would ship the warning. This is the one mode the overlay loop does not own.
if compgen -G "${chroot_dir}/etc/netplan/*.yaml" > /dev/null; then
    chmod 600 "${chroot_dir}"/etc/netplan/*.yaml
fi

# Installing the kernel deb fires every hook in /etc/kernel/postinst.d, and two
# of them cannot run yet:
#   initramfs-tools  would build an initramfs before /etc/fstab exists and
#                    before the rest of the packages are in;
#   zz-u-boot-menu   reads /etc/kernel/cmdline, which the board hook writes
#                    below.
# Both are run once, deliberately, further down.
kernel_hooks=(initramfs-tools zz-u-boot-menu)
for hook in "${kernel_hooks[@]}"; do
    h="${chroot_dir}/etc/kernel/postinst.d/${hook}"
    [ -f "${h}" ] || continue
    chmod -x "${h}"
done

retry 3 chroot "${chroot_dir}" apt-get -y update

echo "==> installing kernel and u-boot"
mkdir -p "${chroot_dir}/tmp/debs"
debs=()
for glob in "${UBOOT_BINARY_PACKAGE}_*.deb" "linux-image-*.deb" "linux-headers-*.deb" \
            "${KERNEL_PACKAGE}_*.deb"; do
    # linux-image-*-dbg is 120MB of symbols, and linux-libc-dev would displace
    # the distribution's own and break later apt upgrades. Neither belongs here.
    f="$(find build -maxdepth 1 -name "${glob}" \
         ! -name '*-dbg_*.deb' ! -name 'linux-libc-dev_*.deb' | sort -V | tail -n1)"
    [ -n "${f}" ] || { echo "Error: nothing matches ${glob} in build/"; exit 1; }
    cp "${f}" "${chroot_dir}/tmp/debs/"
    debs+=("/tmp/debs/$(basename "${f}")")
done
# apt-get, not dpkg -i: these have real Depends (u-boot-menu, sysfsutils) that
# have to come from the archive.
chroot "${chroot_dir}" apt-get -y install "${debs[@]}"
rm -rf "${chroot_dir}/tmp/debs"

# From the installed package, not from /lib/modules: a headers package leaves a
# modules directory behind for a kernel that is not installed.
kver="$(chroot "${chroot_dir}" dpkg-query -W -f='${Package}\n' 'linux-image-*' |
        sed -n 's/^linux-image-//p' | grep -v -- '-dbg$' | sort -V | tail -n1)"
[ -n "${kver}" ] || { echo "Error: cannot determine installed kernel version"; exit 1; }
echo "==> kernel ${kver}"

# These came from local files, so they are in no archive; without a hold apt
# treats them as orphans and removes them on the next autoremove.
chroot "${chroot_dir}" apt-mark hold \
    "${UBOOT_BINARY_PACKAGE}" "${KERNEL_PACKAGE}" "linux-image-${kver}" > /dev/null

# Board-specific rootfs customization: generated boot configuration and any
# board service enablement. Everything board-specific lives in the hook.
if declare -f "config_image_hook__${BOARD}" > /dev/null; then
    echo "==> config_image_hook__${BOARD}"
    "config_image_hook__${BOARD}" "${chroot_dir}" "${kver}"
fi

echo "==> default account ${default_user}"
groups=""
for g in sudo video render audio dialout plugdev netdev i2c gpio spi; do
    chroot "${chroot_dir}" getent group "${g}" > /dev/null 2>&1 || continue
    groups="${groups}${groups:+,}${g}"
done
chroot "${chroot_dir}" useradd -m -s /bin/bash -G "${groups}" "${default_user}"
echo "${default_user}:${default_pass}" | chroot "${chroot_dir}" chpasswd

if [ -f "${chroot_dir}/usr/share/mixtile/user-icon.png" ] && [ -d "${chroot_dir}/var/lib/AccountsService" ]; then
    mkdir -p "${chroot_dir}/var/lib/AccountsService/icons" "${chroot_dir}/var/lib/AccountsService/users"
    install -m 0644 -o root -g root "${chroot_dir}/usr/share/mixtile/user-icon.png" \
        "${chroot_dir}/var/lib/AccountsService/icons/${default_user}"
    cat > "${chroot_dir}/var/lib/AccountsService/users/${default_user}" <<CONF
[User]
Icon=/var/lib/AccountsService/icons/${default_user}
SystemAccount=false
CONF
    chmod 0644 "${chroot_dir}/var/lib/AccountsService/users/${default_user}"
fi

# mmdebstrap writes the build environment's hostname here, and its /etc/hosts has no
# IPv6 block at all -- appending one line would leave the hostname unresolvable
# over v6, so both files are written whole.
echo "${default_hostname}" > "${chroot_dir}/etc/hostname"
cat > "${chroot_dir}/etc/hosts" <<HOSTS
127.0.0.1	localhost
127.0.1.1	${default_hostname}
::1		localhost ${default_hostname} ip6-localhost ip6-loopback
fe00::0		ip6-localnet
ff00::0		ip6-mcastprefix
ff02::1		ip6-allnodes
ff02::2		ip6-allrouters
HOSTS

# Minted here, not by mkfs, so that fstab -- and through it extlinux.conf --
# can be written while the chroot is still mounted. build-image.sh reads this
# UUID back out of the fstab so the filesystem is created with the same one.
root_uuid="$(uuidgen)"
{
    printf '# %-42s %-14s %-6s %-46s %-6s %s\n' \
        '<file system>' '<mount point>' '<type>' '<options>' '<dump>' '<pass>'
    printf '%-44s %-14s %-6s %-46s %-6s %s\n' \
        "UUID=${root_uuid}" '/' 'ext4' \
        'defaults,commit=120,errors=remount-ro,x-systemd.growfs' '0' '1'
    printf '%-44s %-14s %-6s %-46s %-6s %s\n' \
        'tmpfs' '/tmp' 'tmpfs' 'defaults,nosuid' '0' '0'
} > "${chroot_dir}/etc/fstab"

echo "==> building initramfs for ${kver}"
chroot "${chroot_dir}" update-initramfs -c -k "${kver}"
for hook in "${kernel_hooks[@]}"; do
    h="${chroot_dir}/etc/kernel/postinst.d/${hook}"
    [ -f "${h}" ] || continue
    chmod +x "${h}"
done

echo "==> generating extlinux.conf"
chroot "${chroot_dir}" u-boot-update

# Ship a usable /var/lib/apt/lists so the board can apt-install without running
# apt update first; without it every install fails with "Unable to locate
# package".
echo "==> refreshing shipped apt lists"
chroot "${chroot_dir}" apt-get -y clean
retry 3 chroot "${chroot_dir}" apt-get -y update

unblock_service_start "${chroot_dir}"
teardown_chroot "${chroot_dir}"
trap - EXIT

# This is the last chroot stage, so this is the only place the shipped resolv
# symlink can be restored without a later setup_chroot writing over it.
rm -f "${chroot_dir}/etc/resolv.conf"
ln -s /run/systemd/resolve/stub-resolv.conf "${chroot_dir}/etc/resolv.conf"
# systemd-resolved's postinst saves whatever it found before taking over, which
# here is the build-time file. Nothing reads it, but it carries public resolvers
# into the image.
rm -f "${chroot_dir}/etc/.resolv.conf.systemd-resolved.bak"

sed 's/^/    /' "${chroot_dir}/boot/extlinux/extlinux.conf"
echo "==> configured rootfs ready at ${chroot_dir}"
