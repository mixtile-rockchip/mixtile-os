# shellcheck shell=bash
# Ubuntu 26.04 LTS.

export RELEASE_DISTRO=ubuntu
export RELEASE_VERSION=26.04
export RELEASE_MIRROR=http://ports.ubuntu.com/ubuntu-ports
export RELEASE_KEYRING=/usr/share/keyrings/ubuntu-archive-keyring.gpg
export RELEASE_COMPONENTS="main restricted universe multiverse"
export RELEASE_SUITES="resolute resolute-security resolute-updates resolute-backports"

export RELEASE_SECURITY_MIRROR=""
export RELEASE_SECURITY_SUITES=""
