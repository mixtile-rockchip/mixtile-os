# One stanza per board. The platform name is the U-Boot defconfig basename and
# is what build.sh passes as UBOOT_RULES_TARGET.
#
#   _board  directory under debian/board/; must match the config/boards/ name,
#           which is how build.sh scopes the U-Boot build cache per board
#   _soc    Rockchip SoC name, passed to mkimage -n; the idbloader header
#           carries it and the boot ROM checks it against the part it is on
#   _ddr    ROCKCHIP_TPL DDR init blob in debian/rkbin/
#   _bl31   BL31 (ATF) blob in debian/rkbin/, fed to the FIT generator
#   _pkg    binary package suffix -> u-boot-<pkg>

uboot_platforms += mixtile-blade3-rk3588
mixtile-blade3-rk3588_board := blade3
mixtile-blade3-rk3588_soc   := rk3588
mixtile-blade3-rk3588_ddr   := rk3588_ddr_lp4_2112MHz_lp5_2400MHz_v1.24.bin
mixtile-blade3-rk3588_bl31  := rk3588_bl31_v1.56.elf
mixtile-blade3-rk3588_pkg   := mixtile-blade3

uboot_platforms += mixtile-edge2-rk3568
mixtile-edge2-rk3568_board := edge2
mixtile-edge2-rk3568_soc   := rk3568
mixtile-edge2-rk3568_ddr   := rk3568_ddr_1560MHz_v1.26.bin
mixtile-edge2-rk3568_bl31  := rk3568_bl31_v1.46.elf
mixtile-edge2-rk3568_pkg   := mixtile-edge2

uboot_platforms += mixtile-core3588e-rk3588
mixtile-core3588e-rk3588_board := core3588e
mixtile-core3588e-rk3588_soc   := rk3588
mixtile-core3588e-rk3588_ddr   := rk3588_ddr_lp4_2112MHz_lp5_2400MHz_v1.24.bin
mixtile-core3588e-rk3588_bl31  := rk3588_bl31_v1.56.elf
mixtile-core3588e-rk3588_pkg   := mixtile-core3588e
