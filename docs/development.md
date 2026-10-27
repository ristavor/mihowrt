# MihoWRT development

[Quick start](../README.md) · [Technical reference](reference.md) · [Open issues](open-issues.md)

## Build

Linux and macOS builds use Docker, not a native SDK. The packages are architecture-independent; the SDK compiles `luci-base/host` for `po2lmo`, not the Mihomo core. Build both app and Russian translation into `dist/`:

```sh
MIHOWRT_SDK=25.12 ./tools/build-sdk.sh build
MIHOWRT_SDK=24.10 ./tools/build-sdk.sh build
```

The default is 25.12: OpenWrt 25.12.6 SDK, `.apk`. The 24.10 selector uses the 24.10.8 SDK, `.ipk`. Archives are checksum-verified and cached in `.sdk/`; case-sensitive SDK trees live in Docker volumes `mihowrt-sdk-25.12.6` / `mihowrt-sdk-24.10.8` (important on macOS APFS). `prepare`, `shell`, `clean`, `test`, `--rebuild`, `-j<N>` and `--verbose` are listed by `./tools/build-sdk.sh help`. `clean` removes APKs and IPKs from `dist/`.

Runtime dependencies currently include **jq**; a proposed ucode migration is not implemented in this source tree. See `Makefile` for package dependencies, conffiles and install/remove hooks. APK-only protected paths are guarded by `CONFIG_USE_APK`; both builds use the same runtime code and package-manager adapter.

## Tests

Run tests only in the test container, from the repository root:

```sh
docker build -t mihowrt-test:local -f Dockerfile.test .
# One suite (replace <file> with its actual name):
docker run --rm -v "$PWD:/workspace" -w /workspace mihowrt-test:local bash tests/<file>.sh
# Full suite:
docker run --rm -v "$PWD:/workspace" -w /workspace mihowrt-test:local bash tests/run.sh
```

`tests/run.sh` does not select files from arguments. A successful full run ends with `all tests passed`; report its actual `ok` count, not a fixed historical total. Follow `tests/testlib.sh` and the nearest test: add a failing regression test before changing behaviour, then verify red and green. Shell targets BusyBox ash, not host bash; LuCI user strings are English with Russian entries in `po/ru/mihowrt.po`. CSS is layout-only. Keep steady-state flash writes and resource costs minimal.

## VM harness

See [tests/router/README.md](../tests/router/README.md) for isolation, prerequisites, ports and evidence paths. It uses disposable QEMU x86/64 guests in Docker, not a physical router:

```sh
./tests/router/start.sh                         # default: 25.12.6, apk
./tests/router/run-smoke.sh --integration --watchdog
./tests/router/run-network.sh                   # synthetic guest-only network acceptance
./tests/router/stop.sh

ROUTER_OPENWRT=24.10 ./tests/router/start.sh      # 24.10.8, opkg
./tests/router/status.sh
./tests/router/stop.sh
```

`ROUTER_OPENWRT=25.12|24.10` selects the guest in `start.sh`; one VM runs at a time (shared container name). The integration smoke script currently installs APKs with apk: do **not** assume it is an IPK acceptance runner. For 24.10 install the built IPKs and run target-specific checks through the isolated guest SSH wrapper. `run-network.sh` requires its documented guest tools and a running installed service. Synthetic marks/namespaces are not real NetBird peer, NAT traversal or hardware-offload proof. Never point these tests at a real LAN router without explicit approval.

## Versioning and releases

`PKG_VERSION` in `Makefile` is the upstream version; `PKG_RELEASE` is the package revision. Keep `PKG_VERSION` unchanged across its release candidates, and **bump `PKG_RELEASE` for every new rc** so package managers can upgrade between candidates. If code changes between the last rc and the final build, bump the revision again: do not ship different code with the same package version/revision. For a new upstream version, use its new `PKG_VERSION` and normal initial revision.

`.github/workflows/release.yml` accepts `v<PKG_VERSION>` for a release or `v<PKG_VERSION>-rc<N>` (numeric N) for a pre-release. The rc suffix is in the tag, not `PKG_VERSION`. RC pre-releases are skipped by GitHub's latest-release endpoint and the installer's default URL; testers must explicitly select the rc asset base with `MIHOWRT_RELEASE_URL` (see [offline/mirror installation](../README.md#if-github-is-unavailable)).

Release flow, **only after explicit approval to tag/push/publish**:

1. Update `Makefile` version/revision and the matching `## <PKG_VERSION>` changelog section. Run tests and review the diff.
2. Tag the approved commit with the matching rc/release tag and push that tag. A tag push starts publication; it is not just a build check.
   ```sh
   # X must match PKG_VERSION; example order, not approval to publish:
   git tag vX-rc1 && git push origin vX-rc1
   # After rc acceptance and separate final-release approval:
   git tag vX && git push origin vX
   ```
3. The workflow matrix runs tests, builds SDKs 25.12 and 24.10, inspects APK metadata/modes/scripts/dependencies with `apk adbdump` and IPK metadata/conffiles/app modes from archives, then uploads build artifacts.
4. The publish job combines app + Russian APK/IPK packages, versioned names and fixed-name aliases, into one release with `SHA256SUMS` covering all eight assets. Notes come from the matching changelog section. Numeric rc tags create GitHub pre-releases.
5. Check artifacts and the workflow output, then perform the approved acceptance checks before the next candidate/final release. Publishing the branch is a separate approved action.

`workflow_dispatch` runs the build/inspection matrix without publishing (publication requires a tag ref). Timeouts and per-ref concurrency are configured in the workflow. Packages are not signed; SHA256SUMS is not a replacement for a trusted signing key or signed feed.
