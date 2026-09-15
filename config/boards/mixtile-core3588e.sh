# shellcheck shell=bash
# Mixtile Core 3588E -- Rockchip RK3588.

export BOARD_NAME="Mixtile Core 3588E"
export BOARD_VENDOR="Mixtile"
export BOARD_SOC=rk3588
export BOARD_ARCH=arm64

# The source package under packages/, the target in its debian/targets.mk, and
# the binary package that target produces (targets.mk's <platform>_pkg). The
# last one is installed into the image, so it is named rather than derived.
export UBOOT_PACKAGE=u-boot-mixtile-rk35xx-vendor
export UBOOT_RULES_TARGET=mixtile-core3588e-rk3588
export UBOOT_BINARY_PACKAGE=u-boot-mixtile-core3588e

# Device tree from the vendor kernel package. Same RK3588 GPU as the Blade 3,
# so the same panthor overlay applies; without it Mesa finds no render node and
# falls back to llvmpipe.
export BOARD_FDT="rockchip/rk3588-mixtile-core3588e.dtb"
export BOARD_FDT_OVERLAYS="rockchip/overlay/rockchip-rk3588-panthor-gpu.dtbo"

# ttyS2 at 1.5M is the RK3588 debug UART. consoleblank=0 keeps the console
# readable once it blanks, which is when a hang is usually noticed.
export BOARD_CMDLINE="console=ttyS2,1500000 console=tty1 consoleblank=0 cma=256M"

# Called by config-image.sh with the rootfs directory as $1 and the installed
# kernel version as $2. Written into the rootfs here rather than shipped as a
# package or overlay file: the u-boot-menu config names the device tree, which
# depends on the kernel variant.
config_image_hook__mixtile-core3588e() {
    local rootfs="$1" kver="$2"

    : "${BOARD_FDT:?}" "${BOARD_CMDLINE:?}" "${KERNEL_CMDLINE:?}" "${kver:?}"

    mkdir -p "${rootfs}/etc/kernel" "${rootfs}/usr/share/u-boot-menu/conf.d"

    printf '%s %s\n' "${BOARD_CMDLINE}" "${KERNEL_CMDLINE}" \
        > "${rootfs}/etc/kernel/cmdline"

    # conf.d is read after /etc/default/u-boot and before /etc/u-boot-menu/, so
    # vendor defaults land here and both /etc locations stay free for the user.
    #
    # U_BOOT_FDT_DIR is a prefix and gets the kernel version appended;
    # U_BOOT_FDT_OVERLAYS_DIR is a complete directory and does not. Hence $2;
    # see config/boards/mixtile-blade3.sh for why.
    cat > "${rootfs}/usr/share/u-boot-menu/conf.d/mixtile.conf" <<CONF
U_BOOT_UPDATE="true"
U_BOOT_TIMEOUT="20"
U_BOOT_PARAMETERS="\$(cat /etc/kernel/cmdline)"
U_BOOT_FDT="${BOARD_FDT}"
U_BOOT_FDT_OVERLAYS="${BOARD_FDT_OVERLAYS}"
U_BOOT_FDT_DIR="/usr/lib/linux-image-"
U_BOOT_FDT_OVERLAYS_DIR="/usr/lib/linux-image-${kver}"
CONF

    # ssh host keys are stripped from the shared rootfs; overlay/ ships
    # mixtile-first-boot.service to regenerate them. Enabled here rather than in
    # a postinst: enabling a unit needs a running systemd, which a chroot lacks.
    chroot "${rootfs}" systemctl enable mixtile-first-boot.service > /dev/null 2>&1 || true
}
