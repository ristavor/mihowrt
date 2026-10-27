# shellcheck shell=bash disable=SC2034
# Guest release table shared by start.sh and the harness test.
# ROUTER_OPENWRT=25.12 (default) or 24.10 selects official x86/64 artifacts.

router_select_release() {
  case "${ROUTER_OPENWRT:-25.12}" in
  25.12)
    OPENWRT_VERSION=25.12.6
    KERNEL_SHA256=8f70595f3a6eec3112e007450a1a600153904deffa52ab368712342583cb387c
    ROOTFS_SHA256=8c243392d09b960a9f0edbfd996153bec213435b0034e6b2db9437115c5178ec
    DEFAULT_IMAGE_NAME=mihowrt-openwrt-test:latest
    ;;
  24.10)
    OPENWRT_VERSION=24.10.8
    KERNEL_SHA256=75e5ec1a12c6e253173cf51a2ae5ab13380931849ab4588407e72c51cac562f3
    ROOTFS_SHA256=cf39cd1043fbff86ad2936c951fd6afe607437acf3531082cf11b20febc95b03
    DEFAULT_IMAGE_NAME=mihowrt-openwrt-test:24.10
    ;;
  *)
    echo "Error: unsupported ROUTER_OPENWRT=${ROUTER_OPENWRT} (use 25.12 or 24.10)" >&2
    return 1
    ;;
  esac
  KERNEL_NAME="openwrt-${OPENWRT_VERSION}-x86-64-generic-kernel.bin"
  ROOTFS_NAME="openwrt-${OPENWRT_VERSION}-x86-64-generic-ext4-rootfs.img.gz"
  BASE_URL="https://downloads.openwrt.org/releases/${OPENWRT_VERSION}/targets/x86/64"
}
