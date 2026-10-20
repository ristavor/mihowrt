#!/usr/bin/env bash
#
# tools/build-sdk.sh - Build official OpenWrt 25.12.6 x86/64 SDK packages and run Linux test suite.
#
# Environment / Platform:
#   Darwin (macOS arm64): Uses Docker container with linux/amd64 emulation and a named Docker volume.
#     The macOS APFS filesystem is case-insensitive, making bind mounts unsuitable for SDK compilation.
#     Build directory and SDK feeds are persisted in the named volume 'mihowrt-sdk-25.12.6'.
#     Official OpenWrt SDK only distributes Linux ELF binaries; native macOS builds are unsupported upstream.
#   Linux: Uses Docker by default for reproducible isolated builds, or native (--native) when requested.
#
# Usage:
#   ./tools/build-sdk.sh [command] [options]
#
# Commands:
#   build          Build luci-app-mihowrt and optional luci-i18n-mihowrt-ru APKs (default).
#   test           Run Linux test suite (bash tests/run.sh) in native test container.
#   prepare        Ensure SDK archive, Docker image/volume, feeds (base, packages, luci) and deps.
#   clean          Clean build artifacts from dist/ and SDK package build directory.
#   shell          Launch an interactive shell inside the Linux SDK container.
#   help           Show this documentation.
#
# Options:
#   --docker       Force Docker execution (default for build).
#   --native       Force native execution (only supported on Linux; rejected on macOS).
#   --rebuild      Force rebuilding the Docker build image.
#   -j<N>          Set parallelism for make (defaults to sane 4 jobs).
#   -v, --verbose  Verbose output (make V=s).
#

set -euo pipefail

# SDK metadata
SDK_VERSION="25.12.6"
# shellcheck disable=SC2034
SDK_TARGET="x86"
# shellcheck disable=SC2034
SDK_SUBTARGET="64"
# shellcheck disable=SC2034
SDK_ARCH="x86-64"
SDK_DIR_NAME="openwrt-sdk-25.12.6-x86-64_gcc-14.3.0_musl.Linux-x86_64"
SDK_ARCHIVE_NAME="openwrt-sdk-25.12.6-x86-64.tar.zst"
# shellcheck disable=SC2034
SDK_ARCHIVE_SIZE=285832189
SDK_SHA256="1864152619092e781fa36a401960c8e9ae42d6a364c44ee5f0b197ca5f3c0fcc"
SDK_DOWNLOAD_URL="https://downloads.openwrt.org/releases/25.12.6/targets/x86/64/openwrt-sdk-25.12.6-x86-64_gcc-14.3.0_musl.Linux-x86_64.tar.zst"

# Docker settings
DOCKER_IMAGE="${MIHOWRT_SDK_IMAGE:-mihowrt-sdk:25.12.6}"
DOCKER_VOLUME="${MIHOWRT_SDK_VOLUME:-mihowrt-sdk-25.12.6}"
TEST_IMAGE="${MIHOWRT_TEST_IMAGE:-mihowrt-test:local}"
CONTAINER_SDK_ROOT="/sdk"
CONTAINER_SDK_DIR="${CONTAINER_SDK_ROOT}/${SDK_DIR_NAME}"

# Path discovery
SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
SDK_LOCAL_DIR="${REPO_ROOT}/.sdk"
DIST_DIR="${REPO_ROOT}/dist"

# Default runtime options
COMMAND="build"
EXEC_MODE="docker"
REBUILD_IMAGE=0
VERBOSE=0
JOBS="${JOBS:-4}"

log_info() {
	printf '==> [build-sdk] %s\n' "$*"
}

log_warn() {
	printf '==> [build-sdk:WARN] %s\n' "$*" >&2
}

log_err() {
	printf '==> [build-sdk:ERROR] %s\n' "$*" >&2
}

compute_sha256() {
	local file="$1"
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$file" | awk '{print $1}'
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$file" | awk '{print $1}'
	else
		log_err "Neither sha256sum nor shasum is available to calculate SHA256."
		exit 1
	fi
}

detect_exec_mode() {
	local os
	os="$(uname -s)"
	if [[ "$EXEC_MODE" == "native" ]]; then
		if [[ "$os" == "Darwin" ]]; then
			log_err "Native mode is not supported on macOS (Darwin)."
			log_err "Official OpenWrt SDK distributes only Linux ELF binaries (no macOS native SDK)."
			log_err "Furthermore, macOS APFS is case-insensitive, which breaks OpenWrt SDK compilation."
			log_err "Please run in Docker mode (default)."
			exit 1
		fi
		USE_DOCKER=0
	else
		USE_DOCKER=1
	fi
}

verify_or_download_archive() {
	mkdir -p "${SDK_LOCAL_DIR}"
	local candidate=""
	local target="${SDK_LOCAL_DIR}/${SDK_ARCHIVE_NAME}"

	if [[ -f "$target" ]]; then
		candidate="$target"
	elif [[ -f "${SDK_LOCAL_DIR}/${SDK_DIR_NAME}.tar.zst" ]]; then
		candidate="${SDK_LOCAL_DIR}/${SDK_DIR_NAME}.tar.zst"
	fi

	if [[ -n "$candidate" ]]; then
		log_info "Verifying existing SDK archive: ${candidate}"
		local hash
		hash="$(compute_sha256 "$candidate")"
		if [[ "$hash" == "$SDK_SHA256" ]]; then
			log_info "SHA256 verified (${hash})."
			if [[ "$candidate" != "$target" ]]; then
				cp -p "$candidate" "$target"
			fi
			return 0
		else
			log_warn "Checksum mismatch for ${candidate}: expected ${SDK_SHA256}, got ${hash}. Re-downloading..."
		fi
	fi

	log_info "Downloading official OpenWrt ${SDK_VERSION} x86/64 SDK..."
	log_info "URL: ${SDK_DOWNLOAD_URL}"
	local tmp_file="${target}.tmp.$$"
	if command -v curl >/dev/null 2>&1; then
		curl -fSL -o "$tmp_file" "$SDK_DOWNLOAD_URL"
	elif command -v wget >/dev/null 2>&1; then
		wget -O "$tmp_file" "$SDK_DOWNLOAD_URL"
	else
		log_err "Neither curl nor wget available to download SDK archive."
		exit 1
	fi

	local dl_hash
	dl_hash="$(compute_sha256 "$tmp_file")"
	if [[ "$dl_hash" != "$SDK_SHA256" ]]; then
		rm -f "$tmp_file"
		log_err "Downloaded archive checksum mismatch: expected ${SDK_SHA256}, got ${dl_hash}"
		exit 1
	fi

	mv "$tmp_file" "$target"
	log_info "SDK archive downloaded and verified successfully: ${target}"
}

ensure_docker_image() {
	if ! docker image inspect "${DOCKER_IMAGE}" >/dev/null 2>&1 || [[ "$REBUILD_IMAGE" -eq 1 ]]; then
		log_info "Building Linux SDK Docker image (${DOCKER_IMAGE})..."
		local dockerfile="${REPO_ROOT}/Dockerfile.sdk"
		if [[ ! -f "$dockerfile" ]]; then
			dockerfile="${SCRIPT_DIR}/Dockerfile.sdk"
		fi
		if [[ ! -f "$dockerfile" ]]; then
			log_err "Dockerfile.sdk not found at ${dockerfile}"
			exit 1
		fi
		docker build --platform linux/amd64 -f "$dockerfile" -t "${DOCKER_IMAGE}" "${REPO_ROOT}"
		log_info "Docker image ${DOCKER_IMAGE} ready."
	fi
}

ensure_test_image() {
	if ! docker image inspect "${TEST_IMAGE}" >/dev/null 2>&1 || [[ "$REBUILD_IMAGE" -eq 1 ]]; then
		log_info "Building native test runner Docker image (${TEST_IMAGE})..."
		local dockerfile="${REPO_ROOT}/Dockerfile.test"
		if [[ ! -f "$dockerfile" ]]; then
			log_err "Dockerfile.test not found at ${dockerfile}"
			exit 1
		fi
		docker build -f "$dockerfile" -t "${TEST_IMAGE}" "${REPO_ROOT}"
		log_info "Test Docker image ${TEST_IMAGE} ready."
	fi
}

ensure_docker_volume() {
	if ! docker volume inspect "${DOCKER_VOLUME}" >/dev/null 2>&1; then
		log_info "Creating persistent Docker volume for Linux SDK: ${DOCKER_VOLUME}..."
		docker volume create "${DOCKER_VOLUME}" >/dev/null
	fi
}

run_in_docker_container() {
	local cmd="$1"
	shift
	ensure_docker_image
	ensure_docker_volume

	mkdir -p "${DIST_DIR}"

	docker run --rm --platform linux/amd64 \
		-v "${DOCKER_VOLUME}:${CONTAINER_SDK_ROOT}" \
		-v "${REPO_ROOT}:/workspace:ro" \
		-v "${DIST_DIR}:/workspace/dist" \
		-w /workspace \
		-e "FORCE_UNSAFE_CONFIGURE=1" \
		-e "JOBS=${JOBS}" \
		-e "VERBOSE=${VERBOSE}" \
		-e "SDK_DIR_NAME=${SDK_DIR_NAME}" \
		-e "SDK_ARCHIVE_NAME=${SDK_ARCHIVE_NAME}" \
		-e "CONTAINER_SDK_DIR=${CONTAINER_SDK_DIR}" \
		"${DOCKER_IMAGE}" \
		bash -c "$cmd" "$@"
}

prepare_sdk_environment_docker() {
	verify_or_download_archive
	ensure_docker_image
	ensure_docker_volume

	log_info "Checking Linux SDK state in named volume '${DOCKER_VOLUME}'..."
	# shellcheck disable=SC2016
	run_in_docker_container '
		set -euo pipefail
		if [ ! -d "${CONTAINER_SDK_DIR}" ]; then
			echo "==> Extracting SDK archive to named volume..."
			tar -I zstd -xf "/workspace/.sdk/${SDK_ARCHIVE_NAME}" -C /sdk
			echo "==> Extraction complete."
		fi

		cd "${CONTAINER_SDK_DIR}"
		if [ ! -f "feeds/base.index" ] || [ ! -f "feeds/packages.index" ] || [ ! -f "feeds/luci.index" ]; then
			echo "==> Updating pinned feeds: base, packages, luci..."
			./scripts/feeds update base packages luci
		else
			echo "==> Pinned feeds base, packages, luci already initialized."
		fi

		echo "==> Installing host build prerequisite: luci-base..."
		# Clean up any previously linked runtime feed packages that introduce Kconfig cycles
		./scripts/feeds uninstall curl jq nftables 2>/dev/null || true
		rm -rf package/feeds/packages/curl package/feeds/packages/jq package/feeds/packages/nftables package/feeds/base/nftables 2>/dev/null || true
		./scripts/feeds install luci-base
		echo "==> SDK environment ready in volume."
	'
}

run_build_docker() {
	prepare_sdk_environment_docker

	log_info "Compiling MihoWRT packages with OpenWrt 25.12.6 SDK..."
	# shellcheck disable=SC2016
	run_in_docker_container '
		set -euo pipefail
		cd "${CONTAINER_SDK_DIR}"

		echo "==> Synchronizing package sources into SDK..."
		mkdir -p package/luci-app-mihowrt
		rsync -a --delete /workspace/Makefile package/luci-app-mihowrt/
		if [ -d /workspace/rootfs ]; then
			rsync -a --delete /workspace/rootfs package/luci-app-mihowrt/
			# Ensure removed Ace assets do not persist in SDK build tree
			rm -rf package/luci-app-mihowrt/rootfs/www/luci-static/resources/mihowrt/ace.js \
			       package/luci-app-mihowrt/rootfs/www/luci-static/resources/view/mihowrt/ace
		fi
		if [ -d /workspace/po ]; then
			rsync -a --delete /workspace/po package/luci-app-mihowrt/
		else
			rm -rf package/luci-app-mihowrt/po
		fi

		echo "==> Generating minimal .config (no CONFIG_ALL)..."
		cat << "EOF" > .config
# CONFIG_ALL_NONSHARED is not set
# CONFIG_ALL_KMODS is not set
# CONFIG_ALL is not set
CONFIG_IN_SDK=y
CONFIG_MODULES=y
CONFIG_HAVE_DOT_CONFIG=y
CONFIG_TARGET_x86=y
CONFIG_TARGET_x86_64=y
CONFIG_TARGET_BOARD="x86"
CONFIG_TARGET_SUBTARGET="64"
CONFIG_TARGET_ARCH_PACKAGES="x86_64"
CONFIG_PACKAGE_luci-app-mihowrt=m
CONFIG_PACKAGE_luci-i18n-mihowrt-ru=m
# CONFIG_LIBCURL_LDAP is not set
CONFIG_LIBCURL_LDAP=n
EOF
		# An interrupted metadata scan leaves an empty index that make treats as
		# up to date; drop it so the package rules are generated again.
		[ -s tmp/.packageinfo ] || rm -rf tmp
		make defconfig >/dev/null 2>&1 || true

		echo "==> Compiling host build dependencies (luci-base/host / po2lmo)..."
		make package/feeds/luci/luci-base/host/compile TOPDIR="$PWD" -j"$JOBS"
		if [ ! -x staging_dir/hostpkg/bin/po2lmo ] && [ ! -x staging_dir/host/bin/po2lmo ]; then
			echo "Error: Host tool po2lmo was not found after host compile" >&2
			exit 1
		fi

		echo "==> Direct building package/luci-app-mihowrt (jobs: $JOBS)..."
		make -C package/luci-app-mihowrt clean TOPDIR="$PWD"
		if [ "$VERBOSE" -eq 1 ]; then
			make -C package/luci-app-mihowrt compile TOPDIR="$PWD" V=s -j"$JOBS"
		else
			make -C package/luci-app-mihowrt compile TOPDIR="$PWD" -j"$JOBS"
		fi

		echo "==> Copying and asserting both MihoWRT APKs..."
		mkdir -p /workspace/dist
		app_apk="$(find bin/packages/ -type f -name "luci-app-mihowrt-*.apk" | head -n 1)"
		i18n_apk="$(find bin/packages/ -type f -name "luci-i18n-mihowrt-ru-*.apk" | head -n 1)"

		if [ -z "$app_apk" ] || [ ! -f "$app_apk" ]; then
			echo "Error: luci-app-mihowrt APK not found in bin/packages/" >&2
			exit 1
		fi
		if [ -z "$i18n_apk" ] || [ ! -f "$i18n_apk" ]; then
			echo "Error: luci-i18n-mihowrt-ru APK not found in bin/packages/" >&2
			exit 1
		fi

		cp -f "$app_apk" /workspace/dist/
		cp -f "$i18n_apk" /workspace/dist/
		echo "Copied: $(basename "$app_apk") -> dist/"
		echo "Copied: $(basename "$i18n_apk") -> dist/"
	'

	log_info "Build successful! Verified APK packages in dist/:"
	ls -l "${DIST_DIR}"/luci-app-mihowrt-*.apk "${DIST_DIR}"/luci-i18n-mihowrt-ru-*.apk
}

run_build_native_linux() {
	verify_or_download_archive

	log_info "Running native Linux SDK build..."
	local sdk_build_dir="${REPO_ROOT}/.build/sdk/${SDK_DIR_NAME}"
	mkdir -p "${REPO_ROOT}/.build/sdk"

	if [ ! -d "$sdk_build_dir" ]; then
		log_info "Extracting SDK archive to ${sdk_build_dir}..."
		tar -I zstd -xf "${SDK_LOCAL_DIR}/${SDK_ARCHIVE_NAME}" -C "${REPO_ROOT}/.build/sdk"
	fi

	cd "$sdk_build_dir"

	# Check native build tools
	for req_tool in make gcc g++ rsync tar zstd; do
		if ! command -v "$req_tool" >/dev/null 2>&1; then
			log_err "Missing required native tool: $req_tool"
			exit 1
		fi
	done

	if [ ! -f "feeds/base.index" ] || [ ! -f "feeds/packages.index" ] || [ ! -f "feeds/luci.index" ]; then
		log_info "Updating feeds base, packages, luci..."
		./scripts/feeds update base packages luci
	fi
	./scripts/feeds uninstall curl jq nftables 2>/dev/null || true
	rm -rf package/feeds/packages/curl package/feeds/packages/jq package/feeds/packages/nftables package/feeds/base/nftables 2>/dev/null || true
	./scripts/feeds install luci-base

	mkdir -p package/luci-app-mihowrt
	rsync -a --delete "${REPO_ROOT}/Makefile" package/luci-app-mihowrt/
	if [ -d "${REPO_ROOT}/rootfs" ]; then
		rsync -a --delete "${REPO_ROOT}/rootfs" package/luci-app-mihowrt/
		rm -rf package/luci-app-mihowrt/rootfs/www/luci-static/resources/mihowrt/ace.js \
		       package/luci-app-mihowrt/rootfs/www/luci-static/resources/view/mihowrt/ace
	fi
	if [ -d "${REPO_ROOT}/po" ]; then
		rsync -a --delete "${REPO_ROOT}/po" package/luci-app-mihowrt/
	else
		rm -rf package/luci-app-mihowrt/po
	fi

	cat << "EOF" > .config
# CONFIG_ALL_NONSHARED is not set
# CONFIG_ALL_KMODS is not set
# CONFIG_ALL is not set
CONFIG_IN_SDK=y
CONFIG_MODULES=y
CONFIG_HAVE_DOT_CONFIG=y
CONFIG_TARGET_x86=y
CONFIG_TARGET_x86_64=y
CONFIG_TARGET_BOARD="x86"
CONFIG_TARGET_SUBTARGET="64"
CONFIG_TARGET_ARCH_PACKAGES="x86_64"
CONFIG_PACKAGE_luci-app-mihowrt=m
CONFIG_PACKAGE_luci-i18n-mihowrt-ru=m
# CONFIG_LIBCURL_LDAP is not set
CONFIG_LIBCURL_LDAP=n
EOF
	make defconfig >/dev/null 2>&1 || true
	make package/feeds/luci/luci-base/host/compile TOPDIR="$PWD" -j"$JOBS"
	if [ ! -x staging_dir/hostpkg/bin/po2lmo ] && [ ! -x staging_dir/host/bin/po2lmo ]; then
		log_err "Host tool po2lmo was not found after host compile"
		exit 1
	fi
	make -C package/luci-app-mihowrt clean TOPDIR="$PWD"
	if [ "$VERBOSE" -eq 1 ]; then
		make -C package/luci-app-mihowrt compile TOPDIR="$PWD" V=s -j"$JOBS"
	else
		make -C package/luci-app-mihowrt compile TOPDIR="$PWD" -j"$JOBS"
	fi

	mkdir -p "${DIST_DIR}"
	local app_apk i18n_apk
	app_apk="$(find bin/packages/ -type f -name "luci-app-mihowrt-*.apk" | head -n 1)"
	i18n_apk="$(find bin/packages/ -type f -name "luci-i18n-mihowrt-ru-*.apk" | head -n 1)"

	if [ -z "$app_apk" ] || [ ! -f "$app_apk" ]; then
		log_err "luci-app-mihowrt APK not found in bin/packages/"
		exit 1
	fi
	if [ -z "$i18n_apk" ] || [ ! -f "$i18n_apk" ]; then
		log_err "luci-i18n-mihowrt-ru APK not found in bin/packages/"
		exit 1
	fi

	cp -f "$app_apk" "${DIST_DIR}/"
	cp -f "$i18n_apk" "${DIST_DIR}/"
	log_info "Native build successful! Copied APKs to dist/:"
	ls -l "${DIST_DIR}"/luci-app-mihowrt-*.apk "${DIST_DIR}"/luci-i18n-mihowrt-ru-*.apk
}

run_test() {
	if [[ "$USE_DOCKER" -eq 1 ]]; then
		ensure_test_image
		log_info "Running test suite (bash tests/run.sh) in native container (${TEST_IMAGE})..."
		docker run --rm \
			-v "${REPO_ROOT}:/workspace:ro" \
			-w /workspace \
			"${TEST_IMAGE}" \
			bash tests/run.sh "$@"
	else
		log_info "Running test suite natively..."
		bash "${REPO_ROOT}/tests/run.sh" "$@"
	fi
}

run_clean() {
	log_info "Cleaning dist/ directory..."
	rm -rf "${DIST_DIR}"/*.apk
	if [[ "$USE_DOCKER" -eq 1 ]]; then
		if docker volume inspect "${DOCKER_VOLUME}" >/dev/null 2>&1; then
			log_info "Cleaning package build inside Docker volume '${DOCKER_VOLUME}'..."
			# shellcheck disable=SC2016
			run_in_docker_container '
				if [ -d "${CONTAINER_SDK_DIR}" ]; then
					cd "${CONTAINER_SDK_DIR}"
					make -C package/luci-app-mihowrt clean TOPDIR="$PWD" 2>/dev/null || true
					rm -rf bin/packages/*/*luci*mihowrt* 2>/dev/null || true
				fi
			'
		fi
	fi
	log_info "Clean completed."
}

show_help() {
	cat << EOF
MihoWRT SDK Build Tool
Official OpenWrt 25.12.6 x86/64 SDK package builder and Linux test runner.

Usage:
  ./tools/build-sdk.sh [command] [options]

Commands:
  build          Build luci-app-mihowrt and optional luci-i18n-mihowrt-ru APKs (default)
  test           Run full Linux test suite (bash tests/run.sh) in native test container
  prepare        Ensure archive, Docker image, Docker volume, and feeds cache
  clean          Remove built APKs from dist/ and clean package build directory
  shell          Open an interactive bash shell in the Linux SDK container
  help, -h       Show this help message

Options:
  --docker       Force Docker execution (default for build)
  --native       Force native execution (supported on Linux only; rejected on macOS)
  --rebuild      Force rebuilding the Docker build image
  -j<N>          Set number of parallel jobs for compilation (default: 4)
  -v, --verbose  Verbose build output (make V=s)

Environment Variables:
  MIHOWRT_SDK_IMAGE    Docker image name (default: mihowrt-sdk:25.12.6)
  MIHOWRT_SDK_VOLUME   Docker volume name (default: mihowrt-sdk-25.12.6)
  MIHOWRT_TEST_IMAGE   Test runner Docker image name (default: mihowrt-test:local)

Architecture & Volume Notes:
  - Architecture caveat: Official OpenWrt 25.12.6 SDK only distributes Linux ELF binaries;
    native macOS is unsupported upstream. Furthermore, macOS APFS is case-insensitive, which
    causes OpenWrt buildroot failures on host bind mounts.
  - This script extracts and builds the SDK inside a persistent named Docker volume
    ('${DOCKER_VOLUME}' mounted at /sdk), providing native case-sensitive Linux filesystem semantics.
  - Feeds and host prerequisite isolation: For noarch packages, only luci-base/host
    is compiled (providing po2lmo). Runtime dependencies (curl, jq, nftables) remain in
    package metadata without installing feed directories, preventing Kconfig dependency loops.
  - Direct package compile: Compiles directly via 'make -C package/luci-app-mihowrt' after
    validating host target tools, avoiding unnecessary target C cross-compilation.
  - Test mode executes natively via multi-arch Alpine container ('${TEST_IMAGE}'), ensuring
    tools like shellcheck and node run without emulation issues or fake stubs.
  - Source files (Makefile, rootfs, po) are synchronized via rsync into the SDK package
    directory, removing obsolete Ace assets and avoiding recursive symlinks.
EOF
}

# Parse command line
while [[ $# -gt 0 ]]; do
	case "$1" in
		build|test|prepare|clean|shell|help)
			COMMAND="$1"
			shift
			;;
		--docker)
			EXEC_MODE="docker"
			shift
			;;
		--native)
			EXEC_MODE="native"
			shift
			;;
		--rebuild)
			REBUILD_IMAGE=1
			shift
			;;
		-v|--verbose)
			VERBOSE=1
			shift
			;;
		-j*)
			JOBS="${1#-j}"
			shift
			;;
		-h|--help)
			show_help
			exit 0
			;;
		*)
			log_err "Unknown argument: $1"
			show_help
			exit 1
			;;
	esac
done

detect_exec_mode

case "$COMMAND" in
	help)
		show_help
		;;
	prepare)
		if [[ "$USE_DOCKER" -eq 1 ]]; then
			prepare_sdk_environment_docker
		else
			verify_or_download_archive
			log_info "Native Linux SDK preparation complete."
		fi
		;;
	build)
		if [[ "$USE_DOCKER" -eq 1 ]]; then
			run_build_docker
		else
			run_build_native_linux
		fi
		;;
	test)
		run_test "$@"
		;;
	clean)
		run_clean
		;;
	shell)
		ensure_docker_image
		ensure_docker_volume
		log_info "Launching interactive shell in SDK container..."
		docker run -it --rm --platform linux/amd64 \
			-v "${DOCKER_VOLUME}:${CONTAINER_SDK_ROOT}" \
			-v "${REPO_ROOT}:/workspace:ro" \
			-v "${DIST_DIR}:/workspace/dist" \
			-w /workspace \
			-e "FORCE_UNSAFE_CONFIGURE=1" \
			"${DOCKER_IMAGE}" \
			bash
		;;
esac
