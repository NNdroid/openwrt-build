#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPENWRT_DIR="${ROOT_DIR}/openwrt"
RESULT_ROOT="${OPENWRT_DIR}/result"
THIRD_PARTY_ENV="${ROOT_DIR}/third_party/versions.env"

log()  { printf '\033[1;34m[openwrt-build]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[openwrt-build][warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[openwrt-build][error]\033[0m %s\n' "$*" >&2; exit 1; }

trap 'die "command failed at line ${LINENO}: ${BASH_COMMAND}"' ERR

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

install_host_dependencies() {
    [[ "${SKIP_HOST_DEPS:-0}" == "1" ]] && return 0
    command -v apt-get >/dev/null 2>&1 || {
        warn "apt-get not found; skipping automatic host dependency installation"
        return 0
    }

    local -a sudo_cmd=()
    if [[ "$(id -u)" -ne 0 ]]; then
        require_cmd sudo
        sudo_cmd=(sudo)
    fi

    log "Installing build dependencies"
    "${sudo_cmd[@]}" apt-get update
    DEBIAN_FRONTEND=noninteractive "${sudo_cmd[@]}" apt-get install -y \
        build-essential clang flex bison g++ gawk gcc-multilib g++-multilib \
        gettext git libelf-dev libncurses-dev libssl-dev python3-dev \
        python3-pyelftools python3-setuptools rsync swig unzip zlib1g-dev \
        file wget curl jq ca-certificates patch xz-utils zstd
}

read_openwrt_tag() {
    local tag="${OPENWRT_TAG:-}"
    if [[ -z "$tag" ]]; then
        [[ -f "${ROOT_DIR}/VERSION" ]] || die "VERSION file is missing"
        tag="$(tr -d '[:space:]' < "${ROOT_DIR}/VERSION")"
    fi
    [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid stable OpenWrt tag: $tag"
    printf '%s\n' "$tag"
}

prepare_openwrt_source() {
    local tag="$1"
    log "Preparing OpenWrt source at ${tag}"

    if [[ ! -d "${OPENWRT_DIR}/.git" ]]; then
        rm -rf "${OPENWRT_DIR}"
        mkdir -p "${OPENWRT_DIR}"
        git -C "${OPENWRT_DIR}" init
        git -C "${OPENWRT_DIR}" remote add origin https://github.com/openwrt/openwrt.git
    fi

    git -C "${OPENWRT_DIR}" reset --hard
    git -C "${OPENWRT_DIR}" clean -fdx
    git -C "${OPENWRT_DIR}" fetch --force --depth=1 origin \
        "refs/tags/${tag}:refs/tags/${tag}"
    git -C "${OPENWRT_DIR}" checkout --detach -f "refs/tags/${tag}"
    git -C "${OPENWRT_DIR}" reset --hard "refs/tags/${tag}"
    git -C "${OPENWRT_DIR}" clean -fdx
}

apply_one_patch() {
    local patch_file="$1"
    local target_dir="$2"

    [[ -d "$target_dir" ]] || die "patch target directory does not exist: $target_dir"
    log "Applying $(basename "$patch_file") -> ${target_dir#${OPENWRT_DIR}/}"

    if patch -p1 -d "$target_dir" --dry-run --batch --forward < "$patch_file" >/dev/null 2>&1; then
        patch -p1 -d "$target_dir" --batch --forward --no-backup-if-mismatch < "$patch_file"
    elif patch -p0 -d "$target_dir" --dry-run --batch --forward < "$patch_file" >/dev/null 2>&1; then
        patch -p0 -d "$target_dir" --batch --forward --no-backup-if-mismatch < "$patch_file"
    else
        die "patch does not apply cleanly: $patch_file"
    fi
}

apply_versioned_patches() {
    local patch_root="${ROOT_DIR}/userpatches"
    local version="$1"
    local wildcard="$version"
    local rel target matched=0 candidate

    [[ -d "$patch_root" ]] || return 0
    if [[ "$version" =~ ^(v[0-9]+\.[0-9]+)\.[0-9]+$ ]]; then
        wildcard="${BASH_REMATCH[1]}.x"
    fi

    while IFS= read -r -d '' patch_file; do
        rel="${patch_file#${patch_root}/}"
        target=""
        for candidate in "$version" "$wildcard"; do
            if [[ "$rel" == "archive/${candidate}/"* ]]; then
                target="${OPENWRT_DIR}"
                break
            elif [[ "$rel" == *"/archive/${candidate}/"* ]]; then
                target="${OPENWRT_DIR}/${rel%%/archive/${candidate}/*}"
                break
            fi
        done
        [[ -n "$target" ]] || continue
        apply_one_patch "$patch_file" "$target"
        matched=$((matched + 1))
    done < <(find "$patch_root" -type f \( -name '*.patch' -o -name '*.diff' \) -print0 | sort -z)

    log "Applied ${matched} version-matched patch(es) for ${version}"
}

clone_pinned() {
    local url="$1"
    local ref="$2"
    local dest="$3"

    git clone --quiet --filter=blob:none --no-checkout "$url" "$dest"
    git -C "$dest" checkout --quiet --detach "$ref"
}

inject_third_party_packages() {
    [[ -f "$THIRD_PARTY_ENV" ]] || die "missing ${THIRD_PARTY_ENV}"
    # shellcheck disable=SC1090
    source "$THIRD_PARTY_ENV"

    local tmp
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN

    log "Injecting TCP Brutal ${TCP_BRUTAL_REF}"
    rm -rf "${OPENWRT_DIR}/package/kernel/tcp-brutal"
    mkdir -p "${OPENWRT_DIR}/package/kernel/tcp-brutal"
    cp -a "${ROOT_DIR}/third_party/tcp-brutal/." \
        "${OPENWRT_DIR}/package/kernel/tcp-brutal/"

    log "Injecting nf_deaf OpenWrt package ${NF_DEAF_OPENWRT_REF}"
    clone_pinned "$NF_DEAF_OPENWRT_REPO" "$NF_DEAF_OPENWRT_REF" "$tmp/nf_deaf-openwrt"
    rm -rf "${OPENWRT_DIR}/package/kernel/nf_deaf"
    mkdir -p "${OPENWRT_DIR}/package/kernel/nf_deaf"
    cp -a "$tmp/nf_deaf-openwrt/." "${OPENWRT_DIR}/package/kernel/nf_deaf/"
    rm -rf "${OPENWRT_DIR}/package/kernel/nf_deaf/.git"

    log "Injecting AmneziaWG OpenWrt packages ${AMNEZIAWG_OPENWRT_REF}"
    clone_pinned "$AMNEZIAWG_OPENWRT_REPO" "$AMNEZIAWG_OPENWRT_REF" "$tmp/awg-openwrt"
    rm -rf "${OPENWRT_DIR}/package/extra/amneziawg"
    mkdir -p "${OPENWRT_DIR}/package/extra/amneziawg"
    for pkg in kmod-amneziawg amneziawg-tools luci-proto-amneziawg; do
        [[ -d "$tmp/awg-openwrt/$pkg" ]] || die "AmneziaWG package missing: $pkg"
        cp -a "$tmp/awg-openwrt/$pkg" "${OPENWRT_DIR}/package/extra/amneziawg/"
    done

    rm -rf "$tmp"
    trap - RETURN
}

update_feeds() {
    log "Updating OpenWrt feeds"
    (
        cd "${OPENWRT_DIR}"
        ./scripts/feeds update -a
        ./scripts/feeds install -a
    )
}


merge_kconfig_fragment() {
    local config_file="$1"
    local fragment="$2"
    local line key

    [[ -f "$fragment" ]] || die "missing config fragment: $fragment"

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#\#* ]] && continue

        if [[ "$line" =~ ^CONFIG_([A-Za-z0-9_]+)= ]]; then
            key="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^#\ CONFIG_([A-Za-z0-9_]+)\ is\ not\ set$ ]]; then
            key="${BASH_REMATCH[1]}"
        else
            printf '%s\n' "$line" >> "$config_file"
            continue
        fi

        sed -i -E "/^CONFIG_${key}=|^# CONFIG_${key} is not set$/d" "$config_file"
        printf '%s\n' "$line" >> "$config_file"
    done < "$fragment"
}

validate_feature_config() {
    local target="$1"
    local -a required=(
        CONFIG_PACKAGE_kmod-brutal
        CONFIG_PACKAGE_brutalctl
        CONFIG_PACKAGE_kmod-tcp-bbr
        CONFIG_PACKAGE_kmod-mpls
        CONFIG_PACKAGE_kmod-nf_deaf
        CONFIG_PACKAGE_kmod-amneziawg
        CONFIG_PACKAGE_amneziawg-tools
        CONFIG_PACKAGE_luci-proto-amneziawg
    )
    local key

    for key in "${required[@]}"; do
        grep -qx "${key}=y" "${OPENWRT_DIR}/.config" ||
            die "${target}: required feature was not selected after defconfig: ${key}"
    done
}

collect_results() {
    local target="$1"
    local out="${RESULT_ROOT}/${target}"
    local target_output

    case "$target" in
        x86_64) target_output="${OPENWRT_DIR}/bin/targets/x86/64" ;;
        caimore_cm520) target_output="${OPENWRT_DIR}/bin/targets/ath79/generic" ;;
        *) die "unknown result path for target: $target" ;;
    esac

    [[ -d "$target_output" ]] || die "${target}: expected output directory missing: $target_output"

    rm -rf "$out"
    mkdir -p "$out/packages"

    find "$target_output" -maxdepth 1 -type f \
        \( -name 'openwrt*manifest' -o -name 'openwrt*.json' -o \
           -name 'openwrt*.tar.gz' -o -name 'openwrt*.img.gz' -o \
           -name 'openwrt*.bin' -o -name 'sha256sums' \) \
        -exec cp -f {} "$out/" \;

    find "${OPENWRT_DIR}/bin" -type f \
        \( -name '*brutal*.apk' -o -name '*nf_deaf*.apk' -o \
           -name '*amneziawg*.apk' -o -name '*tcp-bbr*.apk' -o \
           -name '*mpls*.apk' \) \
        -exec cp -f {} "$out/packages/" \; 2>/dev/null || true

    {
        echo "openwrt_tag=${USED_TAG}"
        echo "openwrt_commit=$(git -C "${OPENWRT_DIR}" rev-parse HEAD)"
        echo "target=${target}"
        echo "tcp_brutal_ref=${TCP_BRUTAL_REF}"
        echo "nf_deaf_openwrt_ref=${NF_DEAF_OPENWRT_REF}"
        echo "amneziawg_openwrt_ref=${AMNEZIAWG_OPENWRT_REF}"
    } > "$out/BUILDINFO.txt"

    [[ -n "$(find "$out" -maxdepth 1 -type f -name 'openwrt*' -print -quit)" ]] ||
        die "${target}: no firmware images were collected"
}

build_target() {
    local target="$1"
    local config="${ROOT_DIR}/config/openwrt-${target}.diff"

    [[ -f "$config" ]] || die "missing target config: $config"
    log "Configuring target ${target}"

    cp "$config" "${OPENWRT_DIR}/.config"
    merge_kconfig_fragment "${OPENWRT_DIR}/.config" \
        "${ROOT_DIR}/config/common-networking.config"
    (
        cd "${OPENWRT_DIR}"
        make defconfig
    )
    validate_feature_config "$target"

    log "Downloading sources for ${target}"
    (
        cd "${OPENWRT_DIR}"
        make download -j"$(nproc)"
    )

    log "Building ${target}"
    (
        cd "${OPENWRT_DIR}"
        make -j"$(( $(nproc) + 1 ))" V=sc
    )
    collect_results "$target"
}

main() {
    install_host_dependencies
    require_cmd git
    require_cmd patch
    require_cmd rsync

    USED_TAG="$(read_openwrt_tag)"
    export USED_TAG
    [[ -n "${GITHUB_ENV:-}" ]] && echo "OPENWRT_TAG=${USED_TAG}" >> "$GITHUB_ENV"

    prepare_openwrt_source "$USED_TAG"
    apply_versioned_patches "$USED_TAG"
    inject_third_party_packages
    update_feeds

    case "${BUILD_TARGET:-all}" in
        x86_64|caimore_cm520)
            build_target "${BUILD_TARGET}"
            ;;
        all)
            build_target x86_64
            log "Switching architecture; cleaning target-specific build output"
            (cd "${OPENWRT_DIR}" && make dirclean)
            inject_third_party_packages
            update_feeds
            build_target caimore_cm520
            ;;
        *)
            die "unsupported BUILD_TARGET=${BUILD_TARGET}; use all, x86_64 or caimore_cm520"
            ;;
    esac
}

main "$@"
