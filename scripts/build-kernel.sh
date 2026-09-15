#!/bin/bash
#
# Builds the kernel with upstream's own `make bindeb-pkg` into build/linux-*.deb.
#
# bindeb-pkg rather than a distribution's kernel packaging: its output is
# distribution-agnostic, so one build serves all four suites. It also installs
# DTBs under /usr/lib/linux-image-<ver>/, which is exactly where u-boot-menu can
# point at them.

set -eE
trap 'echo "Error: in $0 on line $LINENO"' ERR

cd "$(dirname -- "$(readlink -f -- "$0")")" && cd ..
root="${PWD}"

# Runnable on its own, so re-source what it needs rather than trusting build.sh.
export KERNEL="${KERNEL:-vendor}"
# shellcheck source=/dev/null
source "config/kernels/${KERNEL}.sh"
: "${KERNEL_PACKAGE_DIR:?}" "${KERNEL_LOCALVERSION:?}" "${KERNEL_PACKAGE:?}"

# Everything needed to build the kernel lives in the package; the dimension file
# only points at it.
pkgdir="${root}/packages/${KERNEL_PACKAGE_DIR}"
[ -d "${pkgdir}" ] || { echo "Error: no package at ${pkgdir}"; exit 1; }
# shellcheck source=/dev/null
source "${pkgdir}/upstream"
: "${GIT:?}" "${BRANCH:?}"

# The base config keeps its upstream file name, so re-syncing it is a same-name
# overwrite. Not derived from the dimension value: if upstream renames the file
# we follow upstream, not our own naming.
base_config="${pkgdir}/configs/linux-rk35xx-vendor.config"
[ -f "${base_config}" ] || { echo "Error: no ${base_config}"; exit 1; }

series="${pkgdir}/patches/series"
[ -f "${series}" ] || { echo "Error: no ${series}"; exit 1; }

src=build/linux

mkdir -p build
if [ -e "$(find build -maxdepth 1 -name "linux-image-*${KERNEL_LOCALVERSION}_*.deb" \
           ! -name '*-dbg_*' | head -n1)" ]; then
    echo "==> kernel ${KERNEL} already built, skipping"
    exit 0
fi

echo "==> kernel: ${GIT} @ ${BRANCH}"
reuse=no
if [ -d "${src}/.git" ]; then
    # A build interrupted mid-flight leaves object files whose directories are
    # already gone, and `git clean` then aborts with "Cannot lstat". Re-cloning
    # is slow but always correct, so treat any failure here as "start over".
    if git -C "${src}" fetch --depth=1 origin "${BRANCH}" &&
       git -C "${src}" checkout -f FETCH_HEAD &&
       git -C "${src}" clean -xdff; then
        reuse=yes
    else
        echo "==> existing tree is unusable, re-cloning"
    fi
fi
if [ "${reuse}" != "yes" ]; then
    rm -rf "${src}"
    git clone --depth=1 --branch "${BRANCH}" "${GIT}" "${src}"
fi

kernel_sha="$(git -C "${src}" rev-parse --short HEAD)"
echo "==> kernel sha: ${kernel_sha}"

# Patches before config: a patch may add Kconfig symbols that a fragment then
# sets, and olddefconfig below has to see both.
#
# The emptiness test is deliberately done here rather than on quilt's exit
# status: `quilt push -a` exits 2 on an empty series but 1 on both a failed
# patch and a missing series file, so the status alone cannot tell "nothing to
# do" from "it broke". With the test up front, any non-zero exit is a failure.
if grep -qvE '^[[:space:]]*(#|$)' "${series}"; then
    echo "==> applying $(grep -cvE '^[[:space:]]*(#|$)' "${series}") patch(es)"
    ( cd "${src}" && QUILT_PATCHES="${pkgdir}/patches" quilt push -a )
else
    echo "==> no patches to apply"
fi

# Upstream base plus whatever fragments we carry, merged by the kernel tree's
# own script. -m stops it running a make of its own: olddefconfig below is the
# one we want. -r reports fragment entries that merely repeat the base, which is
# how a fragment becomes removable once upstream adopts the same value.
#
# An empty fragments directory needs no special case -- with only the base
# passed, merge_config.sh is a copy.
mapfile -t fragments < <(find "${pkgdir}/configs/fragments" -maxdepth 1 -name '*.config' \
                         -printf '%p\n' 2> /dev/null | LC_ALL=C sort)
echo "==> config: base + ${#fragments[@]} fragment(s)"
"${src}/scripts/kconfig/merge_config.sh" -m -r -O "${src}" \
    "${base_config}" "${fragments[@]}"

# LOCALVERSION on the command line, with CONFIG_LOCALVERSION left empty, so no
# git hash is appended and the version string is reproducible.
make_args=(
    -C "${src}"
    ARCH=arm64
    CROSS_COMPILE=aarch64-linux-gnu-
    LOCALVERSION="${KERNEL_LOCALVERSION}"
)

make "${make_args[@]}" olddefconfig

kernel_version="$(make -s "${make_args[@]}" kernelrelease)"
echo "==> kernel version: ${kernel_version}"

make "${make_args[@]}" "-j$(nproc)" Image modules dtbs

# Package serially: 6.1's Makefile.dtbinst installs each dtb with `install -D`,
# and concurrent jobs race creating the shared rockchip/ directory.
#
# INSTALL_MOD_STRIP=1 drops module DWARF but keeps .BTF. Without it the image
# deb is over 300MB instead of ~32MB, because the config we inherit from Armbian
# has DEBUG_INFO_DWARF5 on. Stripping at package time rather than turning that
# off keeps the -dbg package useful.
# KDEB_PKGVERSION is set explicitly because bindeb-pkg's default appends a
# build counter from .version, which increments on every make and so is not
# reproducible.
make "${make_args[@]}" -j1 \
    KDEB_PKGVERSION="${kernel_version}-1" \
    KBUILD_IMAGE=arch/arm64/boot/Image \
    INSTALL_MOD_STRIP=1 \
    bindeb-pkg

rm -f build/*.buildinfo build/*.changes

# bindeb-pkg encodes the kernel version in the package name, so apt can never
# upgrade across kernel versions. This metapackage tracks whichever is current.
meta="build/meta/${KERNEL_PACKAGE}"
rm -rf "${meta}"
mkdir -p "${meta}/DEBIAN"
cat > "${meta}/DEBIAN/control" <<CONTROL
Package: ${KERNEL_PACKAGE}
Version: ${kernel_version}-1
Architecture: arm64
Maintainer: Mixtile <support@mixtile.com>
Depends: linux-image-${kernel_version} (= ${kernel_version}-1)
Section: kernel
Priority: optional
Description: Mixtile OS kernel metapackage (${KERNEL})
 Depends on the kernel image built for this Mixtile OS release, so that
 'apt upgrade' follows kernel version bumps.
CONTROL
dpkg-deb --build --root-owner-group "${meta}" \
    "build/${KERNEL_PACKAGE}_${kernel_version}-1_arm64.deb"

ls -la build/linux-*.deb "build/${KERNEL_PACKAGE}"_*.deb |
    awk '{printf "==> %-72s %.1f MB\n", $9, $5/1048576}'
