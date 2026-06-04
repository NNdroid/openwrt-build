#!/bin/bash

check_error() {
    # 1. 第一步必须紧接着捕获上一条命令的返回值 $?
    local exit_code=$?
    
    # 2. 获取用户传入的自定义错误提示（如果没有传入，则使用默认提示）
    local msg="${1:-"Command execution failed"}"

    # 3. 判断返回值
    if [ "$exit_code" -ne 0 ]; then
        # 4. 将错误信息输出到标准错误 (stderr)
        echo "Error: $msg (Exit code: $exit_code)" >&2
        
        # 5. 退出脚本，并返回同样的错误码
        exit "$exit_code"
    fi
}

merge_dirs() {
    if [ "$#" -ne 2 ]; then
        echo "Usage: merge_dirs <source_dir> <target_dir>"
        return 1
    fi

    local SRC_DIR="$1"
    local DST_DIR="$2"

    if [ ! -d "$SRC_DIR" ]; then
        echo "Error: source directory not found: $SRC_DIR"
        return 1
    fi

    mkdir -p "$DST_DIR" || return 1

    rsync -av \
        --chmod=Du+rwx,Dgo+rx,Fu+rw,Fgo+r \
        "$SRC_DIR"/ "$DST_DIR"/
}

apply_versioned_patches() {
    # 参数1: 补丁根目录 (默认 userpatches)
    local patch_root_base="${1:-userpatches}"
    # 参数2: 当前编译版本号 (必填，例如 v25.12.4)
    local current_version="$2"

    local count=0
    local fail_count=0
    
    # 颜色定义
    local GREEN='\033[0;32m'
    local RED='\033[0;31m'
    local BLUE='\033[0;34m'
    local YELLOW='\033[0;33m'
    local NC='\033[0m'

    # 1. 基础检查
    if [ -z "$current_version" ]; then
        echo -e "${RED}错误: 未指定版本号 (例如 v25.12.4)${NC}"
        return 1
    fi

    if [ ! -d "$patch_root_base" ]; then
        return 0
    fi

    echo -e "正在扫描补丁..."
    echo -e "  - 根目录: ${YELLOW}$patch_root_base${NC}"
    echo -e "  - 目标版本: ${YELLOW}$current_version${NC}"

    # 2. 查找所有 .diff 文件
    while IFS= read -r patch_file; do
        
        # 获取文件所在的目录
        local full_dir=$(dirname "$patch_file")

        # --- 智能提取通配版本号 ---
        local wildcard_version="$current_version"
        if [[ "$current_version" =~ ^([vV]?[0-9]+\.[0-9]+)\. ]]; then
            wildcard_version="${BASH_REMATCH[1]}.x"
        fi

        # --- 核心路径逻辑开始 ---

        # 允许匹配精确版本号 (v25.12.4) 或通配版本号 (v25.12.x)
        if [[ "$full_dir" != *"/archive/$current_version" ]] && [[ "$full_dir" != *"/archive/$wildcard_version" ]]; then
            continue
        fi

        ((count++))

        # 计算 Target Root
        local temp_path="${full_dir#$patch_root_base/}"

        # 无论匹配到哪个后缀，都能正确截断并计算出相对目录
        local target_dir="${temp_path%/archive/$current_version}"
        target_dir="${target_dir%/archive/$wildcard_version}"

        # --- 核心路径逻辑结束 ---

        # 如果截取后为空，说明目标就是根目录
        if [ -z "$target_dir" ]; then
            target_dir="."
        fi

        # 3. 检查目标目录是否存在
        if [ ! -d "$target_dir" ]; then
            echo -e "${RED}[跳过]${NC} 目标目录不存在: $target_dir (补丁: $(basename "$patch_file"))"
            continue
        fi

        echo -e "应用: ${BLUE}$(basename "$patch_file")${NC}"
        echo -e "  └─ 映射: .../archive/[版本] -> $target_dir"

        # 4. 执行补丁
        if patch -p1 -d "$target_dir" --batch --forward --no-backup-if-mismatch < "$patch_file" > /dev/null 2>&1; then
            echo -e "  └─ 状态: ${GREEN}成功${NC}"
        else
            # 容错重试 -p0
            if patch -p0 -d "$target_dir" --batch --forward --no-backup-if-mismatch < "$patch_file" > /dev/null 2>&1; then
                echo -e "  └─ 状态: ${GREEN}成功 (-p0)${NC}"
            else
                echo -e "  └─ 状态: ${RED}失败${NC}"
                ((fail_count++))
            fi
        fi
        echo "------------------------------------------------"

    done < <(find "$patch_root_base" -type f -name "*.diff" | sort)

    # 总结
    if [ "$count" -eq 0 ]; then
        echo "未找到匹配精确版本 '$current_version' 或通配版本 '$wildcard_version' 的补丁。"
    elif [ "$fail_count" -eq 0 ]; then
        echo -e "${GREEN}完成: $count 个补丁应用成功。${NC}"
    else
        echo -e "${RED}完成: $count 个已处理, $fail_count 个失败。${NC}"
        return 1
    fi
}

function update_kernel_config() {
    # 1. 设置目标路径 (默认为 target/linux/x86/64/config-*)
    local target_path="${1:-target/linux/x86/64/config-*}"
    
    # 2. 定义配置内容
    local config_content
    read -r -d '' config_content << 'EOF'
CONFIG_INET=y
CONFIG_IPV6=y
CONFIG_MPTCP=y
CONFIG_MPTCP_KUNIT_TESTS=y
CONFIG_MPTCP_IPV6=y
CONFIG_NET_MPTCP=y
CONFIG_MPTCP_PM=y
CONFIG_MPTCP_FULLMESH=y
CONFIG_MPTCP_NDIAG=y
CONFIG_BPF=y
CONFIG_BPF_SYSCALL=y
CONFIG_BPF_JIT=y
CONFIG_CGROUPS=y
CONFIG_KPROBES=y
CONFIG_NET_INGRESS=y
CONFIG_NET_EGRESS=y
CONFIG_NET_SCH_INGRESS=y
CONFIG_NET_CLS_BPF=y
CONFIG_NET_CLS_ACT=y
CONFIG_BPF_STREAM_PARSER=y
CONFIG_DEBUG_INFO=y
# CONFIG_DEBUG_INFO_REDUCED is not set
CONFIG_DEBUG_INFO_BTF=y
CONFIG_KPROBE_EVENTS=y
CONFIG_BPF_EVENTS=y
EOF

    echo "正在处理内核配置..."

    shopt -s nullglob
    local files=($target_path)
    
    if [ ${#files[@]} -eq 0 ]; then
        echo "⚠️  错误: 未找到匹配的文件: $target_path"
        return 1
    fi

    for file in "${files[@]}"; do
        echo "正在更新文件: $file"
        
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            
            local key=""
            if [[ "$line" =~ ^CONFIG_([^=]+)= ]]; then
                key="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ ^#\ CONFIG_([a-zA-Z0-9_]+)\ is\ not\ set ]]; then
                key="${BASH_REMATCH[1]}"
            else
                continue
            fi

            if grep -qE "^#? ?CONFIG_${key}([= ]|$)" "$file"; then
                sed -i "s|^.*CONFIG_${key}[= ].*$|${line}|" "$file"
            else
                if [ -n "$(tail -c 1 "$file")" ]; then
                    echo "" >> "$file"
                fi
                echo "$line" >> "$file"
            fi
            
        done <<< "$config_content"
        
        echo "✅ 完成: $file"
    done
}

sudo apt update
sudo apt install ed build-essential clang flex bison g++ gawk gcc-multilib g++-multilib gettext git libncurses5-dev libssl-dev python3-setuptools rsync swig unzip zlib1g-dev file wget lsof yq jq -y

if [ -d "openwrt" ]; then
    echo "Directory 'build' exists. Updating..."
    cd openwrt
    git checkout master
    git pull --force origin master
else
    echo "Directory 'build' not found. Cloning..."
    git clone https://github.com/openwrt/openwrt
    cd openwrt
fi

USED_TAG=$(git tag --sort=-creatordate | head -n 1)
if [ -n "${OPENWRT_TAG}" ]; then
  USED_TAG="${OPENWRT_TAG}"
  echo "Using explicit tag: ${USED_TAG}"
else
  echo "OPENWRT_TAG not set, fetching latest tag..."
  USED_TAG=$(cat ../VERSION)
fi
echo "OPENWRT_TAG=$USED_TAG" >> "$GITHUB_ENV"
echo "已更新 TAG 为: $USED_TAG"
git checkout -f "${USED_TAG}"
git clean -fdx
echo "Reset to tag ${USED_TAG}"

apply_versioned_patches "../userpatches" "${USED_TAG}"
check_error

update_kernel_config
check_error

if [ -d "package/kernel/nf_deaf" ]; then
    git -C package/kernel/nf_deaf pull
else
    git clone https://github.com/NNdroid/nf_deaf-openwrt.git package/kernel/nf_deaf
fi
echo "pull nf_deaf"
git clone https://github.com/Slava-Shchipunov/awg-openwrt package/awg-openwrt
echo "pull amneziawg"

./scripts/feeds update -a
check_error
./scripts/feeds install -a
check_error
echo "feeds update & feeds install"

function build_openwrt() {
    if [ $# -lt 1 ]; then
        echo "❌ 错误: 缺少参数。"
        echo "用法: build_openwrt <target_name>"
        return 1
    fi

    local target=$1
    local config_path="../config/openwrt-${target}.diff"

    if [ ! -f "$config_path" ]; then
        echo "❌ 错误: 找不到配置文件: $config_path"
        return 1
    fi

    echo "🚀 正在为目标 [${target}] 准备构建..."

    cp "$config_path" .config
    yes "" | make defconfig
        check_error
    make dirclean
        check_error
    make download
        check_error
    make -j$(($(nproc) + 1)) V=sc
        check_error
}

function move_targets_to_result_dir() {
    mkdir -p result
    find bin/targets/ -type f \
        \( -name 'openwrt*manifest' -o -name 'openwrt*.tar.gz' -o -name 'openwrt*.img.gz' -o -name 'openwrt*.bin' \) \
        -print | while read -r file; do
            echo "Moving $file ..."
            cp "$file" result/
        done
}

# =========================================================
# 执行编译队列
# =========================================================

build_openwrt x86_64
build_openwrt caimore_cm520

move_targets_to_result_dir