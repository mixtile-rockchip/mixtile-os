# shellcheck shell=bash
# Rockchip vendor 6.1.
#
# This file says which package builds the kernel and what the image needs to
# know about the result. It says nothing about how the kernel is built -- the
# upstream coordinates, the patches and the config all live in the package.

# The directory under packages/. Mirrors UBOOT_PACKAGE in config/boards/.
export KERNEL_PACKAGE_DIR=linux-mixtile-rk35xx-vendor

# Passed on the make command line, so CONFIG_LOCALVERSION stays empty and no git
# hash is appended. Gives 6.1.x-rockchip-vendor, which names the debs and
# /usr/lib/linux-image-<ver>/.
#
# Do not change this string. It is baked into the package names and the
# /usr/lib/linux-image-<ver>/ path of every image already shipped, and the
# board hook writes that path into extlinux.conf; changing it breaks the
# kernel upgrade path on boards already in the field.
export KERNEL_LOCALVERSION=-rockchip-vendor

# bindeb-pkg encodes the kernel version in the package name, so apt can never
# upgrade across kernel versions. build-kernel.sh emits this metapackage to
# track whichever version is current. Derived, so it cannot drift.
export KERNEL_PACKAGE="linux${KERNEL_LOCALVERSION}"

# The cgroup arguments are what this vendor kernel needs before Docker will run.
export KERNEL_CMDLINE="rootwait rw cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory"
