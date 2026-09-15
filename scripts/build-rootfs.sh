#!/bin/bash
#
# Builds a rootfs into build/<distro>-<version>-<flavor>-arm64.rootfs.tar.zst.
#
# Board-independent: the tarball is named by suite and flavor only, and every
# board shares it. Anything board-specific belongs in config-image.sh.
#
# mmdebstrap rather than debootstrap or live-build: it bootstraps Debian and
# Ubuntu alike, which is what lets one script serve all four suites.

set -eE
trap 'echo "Error: in $0 on line $LINENO"' ERR

[ "$(id -u)" -eq 0 ] || { echo "Please run as root"; exit 1; }

cd "$(dirname -- "$(readlink -f -- "$0")")" && cd ..
root="${PWD}"

# Runnable on its own, so re-source what it needs rather than trusting build.sh.
[ -n "${SUITE}" ]  || { echo "Error: SUITE is not set"; exit 1; }
[ -n "${FLAVOR}" ] || { echo "Error: FLAVOR is not set"; exit 1; }
# shellcheck source=/dev/null
source "config/suites/${SUITE}.sh"
# shellcheck source=/dev/null
source "config/flavors/${FLAVOR}.sh"
: "${RELEASE_DISTRO:?}" "${RELEASE_MIRROR:?}" "${RELEASE_KEYRING:?}"
: "${RELEASE_COMPONENTS:?}" "${RELEASE_SUITES:?}" "${FLAVOR_PACKAGE_LISTS:?}"

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
tarball="build/${rootfs_id}.rootfs.tar.zst"
sdcard="build/rootfs-${rootfs_id}"

mkdir -p build
if [ -f "${tarball}" ]; then
    echo "==> ${tarball} exists, skipping"
    exit 0
fi

# Package lists: the shared one, then the same name under the suite, which only
# ever adds. No override semantics, no aggregator -- if a suite needs a
# different metapackage, that is what its own file is for.
package_list() {
    local name
    for name in ${FLAVOR_PACKAGE_LISTS}; do
        cat "config/packages/${name}.list" 2> /dev/null || true
        cat "config/packages/${SUITE}/${name}.list" 2> /dev/null || true
    done | sed -e 's/#.*//' -e '/^[[:space:]]*$/d'
}

write_apt_sources() {
    local target="$1"
    local dir="${target}/etc/apt/sources.list.d"
    mkdir -p "${dir}"

    # mmdebstrap leaves a one-line sources.list behind; it would shadow this.
    rm -f "${target}/etc/apt/sources.list"

    cat > "${dir}/${RELEASE_DISTRO}.sources" <<SOURCES
Types: deb
URIs: ${RELEASE_MIRROR}
Suites: ${RELEASE_SUITES}
Components: ${RELEASE_COMPONENTS}
Signed-By: ${RELEASE_KEYRING}
SOURCES

    # Debian serves security from a different host, so it needs its own stanza.
    # Ubuntu does not, and an empty stanza is a parse error rather than a no-op.
    if [ -n "${RELEASE_SECURITY_MIRROR}" ]; then
        cat >> "${dir}/${RELEASE_DISTRO}.sources" <<SOURCES

Types: deb
URIs: ${RELEASE_SECURITY_MIRROR}
Suites: ${RELEASE_SECURITY_SUITES}
Components: ${RELEASE_COMPONENTS}
Signed-By: ${RELEASE_KEYRING}
SOURCES
    fi
}

cleanup() {
    teardown_chroot "${sdcard}" 2> /dev/null || true
}
trap cleanup EXIT

rm -rf "${sdcard}"
mkdir -p "${sdcard}"

echo "==> bootstrapping ${SUITE} (${RELEASE_DISTRO} ${RELEASE_VERSION})"
retry 3 mmdebstrap \
    --architectures=arm64 \
    --variant=minbase \
    --components="$(echo "${RELEASE_COMPONENTS}" | tr ' ' ',')" \
    --include="$(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' config/packages/debootstrap.list | paste -sd,)" \
    --keyring="${RELEASE_KEYRING}" \
    "${SUITE}" "${sdcard}" "${RELEASE_MIRROR}"

[ -f "${sdcard}/bin/bash" ] || { echo "Error: bootstrap produced no /bin/bash"; exit 1; }

write_apt_sources "${sdcard}"
setup_chroot "${sdcard}"
block_service_start "${sdcard}"

echo "==> installing packages"
mapfile -t packages < <(package_list)
[ "${#packages[@]}" -gt 0 ] || { echo "Error: package list is empty"; exit 1; }
echo "    ${#packages[@]} packages"

retry 3 chroot "${sdcard}" apt-get -y update
chroot "${sdcard}" apt-get -y upgrade

# Prove the set resolves before spending bandwidth on it, then fetch and install
# in separate steps so a mirror hiccup retries the download and not the install.
chroot "${sdcard}" apt-get -y --dry-run install "${packages[@]}" > /dev/null
retry 3 chroot "${sdcard}" apt-get -y -d install "${packages[@]}"
chroot "${sdcard}" apt-get -y install "${packages[@]}"

# One named locale. Left unset, locale-gen builds every locale there is, which
# takes longer than the rest of this script.
echo "==> configuring locale"
chroot "${sdcard}" sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
chroot "${sdcard}" locale-gen en_US.UTF-8
chroot "${sdcard}" update-locale LANG=en_US.UTF-8

# Crash reporting and usage telemetry. These arrive as Recommends of the desktop
# metapackage, never from config/packages/, so they cannot be dropped by not
# naming them -- and turning Recommends off wholesale would also take the CJK
# fonts and the input method with it. Purged by name instead, which is a no-op
# on the server flavor where they were never pulled in.
echo "==> removing crash reporting and telemetry"
for pkg in apport apport-symptoms apport-core-dump-handler apport-gtk \
           whoopsie ubuntu-report; do
    chroot "${sdcard}" dpkg-query -W -f='${Status}' "${pkg}" 2> /dev/null |
        grep -q ' installed' || continue
    chroot "${sdcard}" apt-get -y purge "${pkg}"
done

echo "==> cleaning up"
chroot "${sdcard}" apt-get -y autoremove --purge
chroot "${sdcard}" apt-get -y clean

# Per-machine identity must not be baked into a shared rootfs.
#
# Empty, not absent: systemd treats an empty machine-id as "generate on first
# boot", while a missing one is an error in some units.
: > "${sdcard}/etc/machine-id"
rm -f "${sdcard}/var/lib/dbus/machine-id"

# openssh-server generates host keys in its postinst, i.e. at install time and
# not at first start -- blocking service startup does not prevent it. Left in,
# every board flashed from this image would answer with the same SSH identity.
# The board's mixtile-first-boot.service regenerates them on the board, keyed on
# these files being absent.
rm -f "${sdcard}"/etc/ssh/ssh_host_*
# Would otherwise prompt for locale, timezone and root password on the console
# before anything else can run.
chroot "${sdcard}" systemctl mask systemd-firstboot.service > /dev/null

# Units that reach out to the vendor's servers on a timer. A product image must
# not do that unasked, and the boards these run on are frequently on networks
# where the traffic is unexpected.
#
# Masked rather than the packages removed: base-files owns motd-news and is
# Essential, and ubuntu-pro-client is depended on by the desktop seed. Masking
# is also what survives an upgrade of the owning package, which deleting the
# unit file would not.
#
#   motd-news.timer    fetches news from motd.ubuntu.com for /etc/motd
#   ua-timer.timer     ubuntu-pro-client, contacts contracts.canonical.com
#   apt-news.service   \
#   esm-cache.service  / the same client's other two network paths; without
#                        them 91-contract-ua-esm-status has no cache to print
for unit in motd-news.timer ua-timer.timer apt-news.service esm-cache.service; do
    chroot "${sdcard}" systemctl mask "${unit}" > /dev/null 2>&1 || true
done

unblock_service_start "${sdcard}"
teardown_chroot "${sdcard}"
trap - EXIT

# The excluded paths are also where nothing that must survive may live.
echo "==> packing ${tarball}"
tar -cp --xattrs --numeric-owner \
    --exclude='./dev/*' --exclude='./proc/*' --exclude='./sys/*' \
    --exclude='./run/*' --exclude='./tmp/*' \
    -C "${sdcard}" . | zstd -T0 -3 -q -o "${tarball}"
for st in "${PIPESTATUS[@]}"; do
    [ "${st}" -eq 0 ] || { echo "Error: packing failed (${PIPESTATUS[*]})"; exit 1; }
done

rm -rf "${sdcard}"
ls -la "${tarball}" | awk '{printf "==> %s  %.0f MB\n", $9, $5/1048576}'
