# shellcheck shell=bash
# Debian 12.

export RELEASE_DISTRO=debian
export RELEASE_VERSION=12
export RELEASE_MIRROR=http://deb.debian.org/debian
export RELEASE_KEYRING=/usr/share/keyrings/debian-archive-keyring.gpg
export RELEASE_COMPONENTS="main contrib non-free non-free-firmware"
export RELEASE_SUITES="bookworm bookworm-updates bookworm-backports"

export RELEASE_SECURITY_MIRROR=http://security.debian.org/debian-security
export RELEASE_SECURITY_SUITES="bookworm-security"
