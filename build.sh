#!/bin/bash
#
# Mixtile OS build entry point.
#
# Parses the arguments, sources the configuration by name and calls the stage
# scripts in order; it does no build work of its own. Every stage script
# re-sources and validates the configuration it needs, so each one can also be
# run directly.
#
# Needs root and a prepared build environment (dependencies, arm64 binfmt
# handler, a recent enough mmdebstrap).

set -eE
trap 'echo "Error: in $0 on line $LINENO"' ERR

cd "$(dirname -- "$(readlink -f -- "$0")")"

usage() {
cat << HEREDOC
Usage: $0 --board=<board> --suite=<suite> --flavor=<flavor>

Required:
  -b, --board=BOARD        target board, see config/boards/
  -s, --suite=SUITE        suite codename, see config/suites/
  -f, --flavor=FLAVOR      flavor, see config/flavors/

Optional dimension:
  -k, --kernel=KERNEL      kernel variant, see config/kernels/ (only vendor today)

  Pass help to any of them to list the values, e.g. $0 --board=help

Options:
  -h,  --help              show this help
  -c,  --clean             remove build/ and start over
  -uo, --uboot-only        build U-Boot only (needs --board)
  -ko, --kernel-only       build the kernel only (needs no dimension)
  -ro, --rootfs-only       build the rootfs only (needs --suite --flavor)
  -v,  --verbose           enable bash tracing
HEREDOC
}

list_dimension() {
    local dir="config/${1}"
    local f
    for f in "${dir}"/*.sh; do
        [ -e "${f}" ] || continue
        basename "${f%.sh}"
    done
}

# The file names are the valid values, so no registry is needed.
load_dimension() {
    local dimension="${1}" name="${2}"
    if [ "${name}" == "help" ]; then
        list_dimension "${dimension}"
        exit 0
    fi
    local file="config/${dimension}/${name}.sh"
    if [ ! -f "${file}" ]; then
        echo "Error: \"${name}\" is not a known ${dimension%s}, valid values:"
        list_dimension "${dimension}" | sed 's/^/  /'
        exit 1
    fi
    # shellcheck source=/dev/null
    source "${file}"
}

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run as root (sudo ./build.sh ...)"
    exit 1
fi

while [ "$#" -gt 0 ]; do
    case "${1}" in
        -h|--help)          usage; exit 0 ;;
        -b=*|--board=*)     export BOARD="${1#*=}"; shift ;;
        -b|--board)         export BOARD="${2}"; shift 2 ;;
        -s=*|--suite=*)     export SUITE="${1#*=}"; shift ;;
        -s|--suite)         export SUITE="${2}"; shift 2 ;;
        -f=*|--flavor=*)    export FLAVOR="${1#*=}"; shift ;;
        -f|--flavor)        export FLAVOR="${2}"; shift 2 ;;
        -k=*|--kernel=*)    export KERNEL="${1#*=}"; shift ;;
        -k|--kernel)        export KERNEL="${2}"; shift 2 ;;
        -uo|--uboot-only)   export UBOOT_ONLY=Y; shift ;;
        -ko|--kernel-only)  export KERNEL_ONLY=Y; shift ;;
        -ro|--rootfs-only)  export ROOTFS_ONLY=Y; shift ;;
        -c|--clean)         export CLEAN=Y; shift ;;
        -v|--verbose)       set -x; shift ;;
        -*)                 echo "Error: unknown argument \"${1}\""; exit 1 ;;
        *)                  shift ;;
    esac
done

# Always set: the kernel variant decides which device tree the board uses,
# so there is no "unset" case.
export KERNEL="${KERNEL:-vendor}"
load_dimension kernels "${KERNEL}"

[ -n "${SUITE}" ]  && load_dimension suites  "${SUITE}"
[ -n "${FLAVOR}" ] && load_dimension flavors "${FLAVOR}"
# After kernels: the board device tree and overlays follow the kernel variant.
[ -n "${BOARD}" ]  && load_dimension boards  "${BOARD}"

if [ "${CLEAN}" == "Y" ]; then
    # The rootfs may still have mounts under it; unmount before removing, or rm
    # follows them and takes the host's /dev with it.
    if [ -d build/rootfs ]; then
        umount -lf build/rootfs/dev/pts 2> /dev/null || true
        umount -lf build/rootfs/* 2> /dev/null || true
    fi
    rm -rf build
fi

mkdir -p build/logs
exec > >(tee "build/logs/build-$(date +"%Y%m%d%H%M%S").log") 2>&1

if [ "${UBOOT_ONLY}" == "Y" ]; then
    [ -z "${BOARD}" ] && { usage; exit 1; }
    ./scripts/build-u-boot.sh
    exit 0
fi

if [ "${KERNEL_ONLY}" == "Y" ]; then
    ./scripts/build-kernel.sh
    exit 0
fi

if [ "${ROOTFS_ONLY}" == "Y" ]; then
    { [ -z "${SUITE}" ] || [ -z "${FLAVOR}" ]; } && { usage; exit 1; }
    ./scripts/build-rootfs.sh
    exit 0
fi

if [ -z "${BOARD}" ] || [ -z "${SUITE}" ] || [ -z "${FLAVOR}" ]; then
    usage
    exit 1
fi

# The kernel is independent of the suite (bindeb-pkg output is
# distribution-agnostic), so it is built once.
./scripts/build-kernel.sh
./scripts/build-u-boot.sh
./scripts/build-rootfs.sh
./scripts/config-image.sh
./scripts/build-image.sh

exit 0
