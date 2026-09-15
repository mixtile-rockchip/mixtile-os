# shellcheck shell=bash
# Ubuntu 24.04 LTS.
#
# The codename determines the distribution: there is no separate distribution
# dimension, because nothing can pick "debian" and "noble" together.

export RELEASE_DISTRO=ubuntu
export RELEASE_VERSION=24.04
export RELEASE_MIRROR=http://ports.ubuntu.com/ubuntu-ports
export RELEASE_KEYRING=/usr/share/keyrings/ubuntu-archive-keyring.gpg
export RELEASE_COMPONENTS="main restricted universe multiverse"
export RELEASE_SUITES="noble noble-security noble-updates noble-backports"

# Ubuntu serves security from the same host, so there is no second stanza.
export RELEASE_SECURITY_MIRROR=""
export RELEASE_SECURITY_SUITES=""
