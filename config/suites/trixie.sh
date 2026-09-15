# shellcheck shell=bash
# Debian 13.

export RELEASE_DISTRO=debian
export RELEASE_VERSION=13
export RELEASE_MIRROR=http://deb.debian.org/debian
export RELEASE_KEYRING=/usr/share/keyrings/debian-archive-keyring.gpg
export RELEASE_COMPONENTS="main contrib non-free non-free-firmware"
export RELEASE_SUITES="trixie trixie-updates trixie-backports"

# Debian serves security from its own host, so it needs a second stanza.
export RELEASE_SECURITY_MIRROR=http://security.debian.org/debian-security
export RELEASE_SECURITY_SUITES="trixie-security"
