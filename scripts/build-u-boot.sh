#!/bin/bash
#
# Builds U-Boot into build/u-boot-<board>_<version>_arm64.deb.
#
# The per-board U-Boot recipe lives in packages/${UBOOT_PACKAGE}/debian/; this
# script only fetches the pinned source, drops debian/ on top and runs
# dpkg-buildpackage. What the recipe emits is board-specific -- the Mixtile
# Blade 3 uses radxa vendor U-Boot and produces the two-file Rockchip loader
# (idbloader.img + u-boot.itb), assembled from the rkbin DDR blob and BL31.

set -eE
trap 'echo "Error: in $0 on line $LINENO"' ERR

[ "$(id -u)" -eq 0 ] || { echo "Please run as root"; exit 1; }

cd "$(dirname -- "$(readlink -f -- "$0")")" && cd ..
root="${PWD}"

# Runnable on its own, so re-source what it needs rather than trusting build.sh.
# The board file alone: U-Boot needs nothing from config/kernels/.
[ -n "${BOARD}" ] || { echo "Error: BOARD is not set"; exit 1; }
# shellcheck source=/dev/null
source "config/boards/${BOARD}.sh"
: "${UBOOT_PACKAGE:?}" "${UBOOT_RULES_TARGET:?}" "${UBOOT_BINARY_PACKAGE:?}"

pkgdir="${root}/packages/${UBOOT_PACKAGE}"

mkdir -p build && cd build

# shellcheck source=/dev/null
source "${pkgdir}/debian/upstream"

if [ -e "$(find . -maxdepth 1 -name "${UBOOT_BINARY_PACKAGE}_*.deb" | head -n1)" ]; then
    echo "==> ${UBOOT_BINARY_PACKAGE} already built, skipping"
    exit 0
fi

# Fetch the exact pinned COMMIT, not the branch tip. BRANCH on a vendor tree
# moves, so only COMMIT is reproducible; GitHub serves any commit reachable
# from a branch, and BRANCH is what documents that reachability. This also
# reuses an existing checkout regardless of which upstream it was cloned from.
if [ ! -d "${UBOOT_PACKAGE}/.git" ]; then
    rm -rf "${UBOOT_PACKAGE}"
    git init -q "${UBOOT_PACKAGE}"
    git -C "${UBOOT_PACKAGE}" remote add origin "${GIT}"
fi
git -C "${UBOOT_PACKAGE}" remote set-url origin "${GIT}"
git -C "${UBOOT_PACKAGE}" fetch --depth 1 origin "${COMMIT}"
git -C "${UBOOT_PACKAGE}" checkout -f FETCH_HEAD
git -C "${UBOOT_PACKAGE}" clean -xdf

# The commit is what was actually tested; assert we are on it.
head="$(git -C "${UBOOT_PACKAGE}" rev-parse HEAD)"
[ "${head}" == "${COMMIT}" ] || {
    echo "Error: HEAD is ${head}, expected ${COMMIT}"; exit 1; }

cp -r "${pkgdir}/debian" "${UBOOT_PACKAGE}/debian"
cd "${UBOOT_PACKAGE}"

# Apply debian/patches/ onto the upstream tree. dpkg-buildpackage is invoked
# below with -b -nc on a plain git checkout, which does not run the quilt
# "before-build" hook, so the series would otherwise be ignored. quilt keeps
# the .pc state, so any later dpkg-source pass is a no-op rather than a
# double-apply. A package without a series file simply skips this step.
if [ -f debian/patches/series ]; then
    QUILT_PATCHES=debian/patches quilt push -a
fi

# Generated, not committed: the version is upstream's, from debian/upstream,
# and the Debian revision is fixed at 1 -- this project has no version of its
# own to fold in.
cat > debian/changelog <<CHANGELOG
${UBOOT_PACKAGE} (${VERSION}-1) unstable; urgency=medium

  * Build of U-Boot ${VERSION} (${COMMIT}).

 -- Mixtile <support@mixtile.com>  $(date -uR)
CHANGELOG

# -d: build-deps are satisfied by the build environment, not by what control
#     declares.
# -nc: the tree was just cleaned by git, and the rules file has no clean target
#      worth running twice.
dpkg-buildpackage -a "$(cat debian/arch)" -d -b -nc -uc \
    --rules-target="${UBOOT_RULES_TARGET},package-${UBOOT_RULES_TARGET}"

rm -f ../*.buildinfo ../*.changes
cd ..
ls -la "${UBOOT_BINARY_PACKAGE}"_*.deb
