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
    # 参数2: 当前编译版本号 (必填，例如 rockchip64-6.12)
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
        echo -e "${RED}错误: 未指定版本号 (例如 rockchip64-6.12)${NC}"
        return 1
    fi

    if [ ! -d "$patch_root_base" ]; then
        echo -e "${RED}错误: 目录 $patch_root_base 不存在${NC}"
        return 1
    fi

    echo -e "正在扫描补丁..."
    echo -e "  - 根目录: ${YELLOW}$patch_root_base${NC}"
    echo -e "  - 目标版本: ${YELLOW}$current_version${NC}"

    # 2. 查找所有 .diff 文件
    while IFS= read -r patch_file; do
        
        # 获取文件所在的目录
        # 例如: userpatches/kernel/archive/rockchip64-6.12
        local full_dir=$(dirname "$patch_file")

        # --- 核心路径逻辑开始 ---

        # 检查1: 该补丁是否属于当前版本目录？
        # 我们检查路径结尾是否是 "/archive/版本号"
        # 如果路径里包含 archive 但版本号不对，直接跳过
        if [[ "$full_dir" != *"/archive/$current_version" ]]; then
            # 这里静默跳过，因为 userpatches 下可能有其他版本的补丁
            continue
        fi

        ((count++))

        # 计算 Target Root
        # 步骤 A: 去掉前缀 "userpatches/"
        # 结果: kernel/archive/rockchip64-6.12
        local temp_path="${full_dir#$patch_root_base/}"

        # 步骤 B: 去掉后缀 "/archive/版本号"
        # % 表示从右边删除匹配的部分
        # 结果: kernel
        local target_dir="${temp_path%/archive/$current_version}"

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
        echo -e "  └─ 映射: .../archive/$current_version -> $target_dir"

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
        echo "未找到匹配版本 '$current_version' 的补丁。"
    elif [ "$fail_count" -eq 0 ]; then
        echo -e "${GREEN}完成: $count 个补丁应用成功。${NC}"
    else
        echo -e "${RED}完成: $count 个已处理, $fail_count 个失败。${NC}"
        return 1
    fi
}

sudo apt update
sudo apt install ed build-essential clang flex bison g++ gawk gcc-multilib g++-multilib gettext git libncurses5-dev libssl-dev python3-setuptools rsync swig unzip zlib1g-dev file wget lsof yq jq -y

if [ -d "openwrt" ]; then
    echo "Directory 'build' exists. Updating..."
#    replace_userpatches_dir
    cd openwrt
    git checkout master
    git pull --force origin master
else
    echo "Directory 'build' not found. Cloning..."
    git clone https://github.com/openwrt/openwrt
#    replace_userpatches_dir
    cd openwrt
fi

#拉取最新代码
#git branch -a
USED_TAG=$(git tag --sort=-creatordate | head -n 1)
#git reset --hard "origin/dev"
# 使用 -n (not empty)
if [ -n "${OPENWRT_TAG}" ]; then
  USED_TAG="${OPENWRT_TAG}"
  echo "Using explicit tag: ${USED_TAG}"
else
  # 这里写获取最新 tag 的逻辑
  # USED_TAG=$(git describe --tags...)
  echo "OPENWRT_TAG not set, fetching latest tag..."
  USED_TAG=$(cat ../VERSION)
fi
echo "OPENWRT_TAG=$USED_TAG" >> "$GITHUB_ENV"
echo "已更新 TAG 为: $USED_TAG"
git checkout -f "${USED_TAG}"
git clean -fdx
echo "Reset to tag ${USED_TAG}"

#merge_dirs ../userpatches ./
apply_versioned_patches "../userpatches" "${USED_TAG}"
check_error

./scripts/feeds update -a
check_error
./scripts/feeds install -a
check_error
echo "feeds update & feeds install"

#其他软件包
if [ -d "package/kernel/nf_deaf" ]; then
    git -C package/kernel/nf_deaf pull
else
    git clone https://github.com/NNdroid/nf_deaf-openwrt.git package/kernel/nf_deaf
fi
echo "pull nf_deaf"

if [ -d "package/dae" ]; then
    git -C package/dae pull
else
    git clone https://github.com/QiuSimons/luci-app-daed package/dae
fi
echo "pull dae"

if [ ! -d "package/libcron" ]; then
    mkdir -p package/libcron
fi
wget -O package/libcron/Makefile https://raw.githubusercontent.com/immortalwrt/packages/refs/heads/master/libs/libcron/Makefile
echo "pull libcron"

function build_openwrt() {
    # 1. 检查参数数量
    # $# 代表参数个数，-lt 代表 less than (小于)
    if [ $# -lt 1 ]; then
        echo "❌ 错误: 缺少参数。"
        echo "用法: build_openwrt <target_name>"
        return 1
    fi

    local target=$1
    local config_path="../config/openwrt-${target}.diff"

    # 2. (建议添加) 检查对应的配置文件是否存在
    if [ ! -f "$config_path" ]; then
        echo "❌ 错误: 找不到配置文件: $config_path"
        return 1
    fi

    echo "🚀 正在为目标 [${target}] 准备构建..."

    # 执行构建流程
    cp "$config_path" .config
    yes "" | make defconfig
	check_error
    make dirclean
	check_error
    make download
	check_error
    make -j$(($(nproc) + 1)) V=sc
	check_error
#    make -j1 V=sc
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

build_openwrt x86_64
move_targets_to_result_dir
