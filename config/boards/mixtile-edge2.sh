# shellcheck shell=bash
# Mixtile Edge 2 -- Rockchip RK3568.

export BOARD_NAME="Mixtile Edge 2"
export BOARD_VENDOR="Mixtile"
export BOARD_SOC=rk3568
export BOARD_ARCH=arm64

# The source package under packages/, the target in its debian/targets.mk, and
# the binary package that target produces (targets.mk's <platform>_pkg). The
# last one is installed into the image, so it is named rather than derived.
export UBOOT_PACKAGE=u-boot-mixtile-rk35xx-vendor
export UBOOT_RULES_TARGET=mixtile-edge2-rk3568
export UBOOT_BINARY_PACKAGE=u-boot-mixtile-edge2

# Device tree from the vendor kernel package. The RK3568's Bifrost Mali-G52
# binds to the mainline panfrost driver directly.
export BOARD_FDT="rockchip/rk3568-mixtile-edge2.dtb"

# ttyS2 at 1.5M is the RK3568 debug UART, the rate the U-Boot defconfig uses
# (CONFIG_DEBUG_UART_BASE=0xFE660000, CONFIG_BAUDRATE=1500000). consoleblank=0
# keeps the console readable once it blanks, which is when a hang is noticed.
export BOARD_CMDLINE="console=ttyS2,1500000 console=tty1 consoleblank=0 cma=256M splash plymouth.ignore-serial-consoles"

# Called by config-image.sh with the rootfs directory as $1. Written into the
# rootfs here rather than shipped as a package or overlay file: the u-boot-menu
# config names the device tree, which depends on the kernel variant.
config_image_hook__mixtile-edge2() {
    local rootfs="$1"

    : "${BOARD_FDT:?}" "${BOARD_CMDLINE:?}" "${KERNEL_CMDLINE:?}"

    mkdir -p "${rootfs}/etc/kernel" "${rootfs}/usr/share/u-boot-menu/conf.d"

    printf '%s %s\n' "${BOARD_CMDLINE}" "${KERNEL_CMDLINE}" \
        > "${rootfs}/etc/kernel/cmdline"

    # conf.d is read after /etc/default/u-boot and before /etc/u-boot-menu/, so
    # vendor defaults land here and both /etc locations stay free for the user.
    #
    # U_BOOT_FDT_DIR is a prefix and gets the kernel version appended; see
    # config/boards/mixtile-blade3.sh for why.
    cat > "${rootfs}/usr/share/u-boot-menu/conf.d/mixtile.conf" <<CONF
U_BOOT_UPDATE="true"
U_BOOT_TIMEOUT="10"
U_BOOT_PARAMETERS="\$(cat /etc/kernel/cmdline)"
U_BOOT_FDT="${BOARD_FDT}"
U_BOOT_FDT_DIR="/usr/lib/linux-image-"
CONF

    # ssh host keys are stripped from the shared rootfs; overlay/ ships
    # mixtile-first-boot.service to regenerate them. Enabled here rather than in
    # a postinst: enabling a unit needs a running systemd, which a chroot lacks.
    chroot "${rootfs}" systemctl enable mixtile-first-boot.service > /dev/null 2>&1 || true

    local suite
    suite="$(chroot "${rootfs}" sh -c '. /etc/os-release; printf %s "${VERSION_CODENAME}"')"
    [ -n "${suite}" ] || { echo "Error: no VERSION_CODENAME in ${rootfs}/etc/os-release"; return 1; }

    [ -f "${rootfs}/etc/apt/keyrings/mixtile-archive-keyring.gpg" ] || {
        echo "Error: mixtile archive keyring missing from ${rootfs}"; return 1; }

    cat > "${rootfs}/etc/apt/sources.list.d/mixtile-archive.sources" <<SOURCES
Types: deb
URIs: https://mixtile-rockchip.github.io/archive
Suites: ${suite}
Components: main
Architectures: arm64
Signed-By: /etc/apt/keyrings/mixtile-archive-keyring.gpg
SOURCES

    local archive_packages=(
        librga2 librockchip-mpp1 librockchip-vpu0 librknnrt rockchip-multimedia-config
        rockchip-mpp-demos ffmpeg-rockchip gstreamer1.0-rockchip1 firmware-ap6275s
    )
    retry 3 chroot "${rootfs}" apt-get -y update
    chroot "${rootfs}" apt-get -y --dry-run install "${archive_packages[@]}" > /dev/null
    retry 3 chroot "${rootfs}" apt-get -y -d install "${archive_packages[@]}"
    chroot "${rootfs}" apt-get -y install "${archive_packages[@]}"
}
