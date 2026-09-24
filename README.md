# openwrt-build

Reproducible OpenWrt firmware builds for:

- `x86/64`
- Caimore CM520-86F (`ath79/generic`, AR9344)

The default release baseline is the latest stable OpenWrt release. The repository currently tracks **OpenWrt v25.12.5**.

## Default networking features

Both firmware targets select these features by default:

- **TCP Brutal v2** kernel module and `brutalctl`
- **BBR** (`kmod-tcp-bbr`), with OpenWrt's standard sysctl making BBR the default TCP congestion control
- **MPLS** (`kmod-mpls`), including `mpls_router`, `mpls_iptunnel` and `mpls_gso`
- **nf_deaf**
- **AmneziaWG 3.1** kernel module, tools and LuCI protocol UI

TCP Brutal is loaded and available, but it is intentionally **not** made the system-wide default congestion control. Use `brutalctl add ...` or an application that explicitly selects `brutal`. BBR remains the normal system default.

## Reproducible third-party modules

Third-party repositories are pinned to exact commits in:

```text
third_party/versions.env
```

The TCP Brutal OpenWrt package recipe is maintained in:

```text
third_party/tcp-brutal/Makefile
```

The build copies only the three required AmneziaWG package directories instead of injecting the entire upstream repository into the OpenWrt package tree.

## Build locally

Ubuntu/Debian:

```bash
./build.sh
```

Build only one target:

```bash
BUILD_TARGET=x86_64 ./build.sh
BUILD_TARGET=caimore_cm520 ./build.sh
```

Build an explicit stable OpenWrt tag:

```bash
OPENWRT_TAG=v25.12.5 BUILD_TARGET=x86_64 ./build.sh
```

If host dependencies are already installed:

```bash
SKIP_HOST_DEPS=1 BUILD_TARGET=x86_64 ./build.sh
```

Generated images and selected custom `.apk` packages are placed under:

```text
openwrt/result/<target>/
```

## GitHub Actions

The workflow runs daily and also supports manual dispatch.

For scheduled runs it:

1. Lists stable upstream tags.
2. Filters tags to `vMAJOR.MINOR.PATCH`.
3. Uses semantic version ordering (`sort -V`) instead of tag commit dates.
4. Skips the build when `VERSION` already matches the newest stable tag.
5. Builds x86_64 and CM520 in separate parallel jobs.
6. Publishes firmware plus selected custom kernel/package artifacts.
7. Updates `VERSION` only after the build succeeds.

This avoids the old failure mode where a later-created maintenance tag such as `v24.10.x` could incorrectly be treated as newer than `v25.12.x`.

## Caimore CM520

The CM520 board support patch is stored under:

```text
userpatches/archive/v25.12.x/
```

It is applied automatically to any `v25.12.*` build. The target uses the Linux 6.12 ath79 patch directory and includes the Longsung U9300C USB/QMI IDs.
