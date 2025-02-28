#!/bin/zsh

# ===== 初始化配置 =====
exec > >(tee -a setup.log) 2>&1  # 启用日志记录
set -e                            # 错误立即退出
set -o pipefail                   # 管道错误捕获

# 配置颜色输出
RED='\033[1;31m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
success() { echo -e "${GREEN}[✓] $1${NC}"; }
warning() { echo -e "${YELLOW}[!] $1${NC}"; }
error() { echo -e "${RED}[✗] $1${NC}"; exit 1; }

echo -e "${GREEN}
______________________________________________________________
                        ___  ____             _               
  _ __ ___   __ _  ___ / _ \/ ___|   ___  ___| |_ _   _ _ __  
 | '_ ` _ \ / _` |/ __| | | \___ \  / __|/ _ \ __| | | | '_ \ 
 | | | | | | (_| | (__| |_| |___) | \__ \  __/ |_| |_| | |_) |
 |_| |_| |_|\__,_|\___|\___/|____/  |___/\___|\__|\__,_| .__/ 
                                                       |_|    
______________________________________________________________
${NC}"

# ===== 配置文件路径 =====
CONFIG_DIR=$(cd "$(dirname "$0")"; pwd)  # 脚本所在目录
FORMULAE_FILE="${CONFIG_DIR}/brew_formulae.txt"
CASKS_FILE="${CONFIG_DIR}/brew_casks.txt"

# ===== 预检模块 =====
precheck() {
    echo -e "\n${GREEN}=== 系统环境预检 ===${NC}"

    # 检查配置文件存在性
    [[ ! -f $FORMULAE_FILE ]] && error "缺失 formulae 配置文件: $FORMULAE_FILE"
    [[ ! -f $CASKS_FILE ]] && error "缺失 cask 配置文件: $CASKS_FILE"

    # 系统版本检查 (macOS 10.15+) - 修正版本判断逻辑
    local os_version=$(sw_vers -productVersion)
    local major_version=$(echo $os_version | awk -F. '{print $1}')
    local minor_version=$(echo $os_version | awk -F. '{print $2}')
    
    # 转换为可比较的数值（10.15 → 1015，11.0 → 1100）
    local version_code=$(( major_version * 100 + minor_version ))
    
    if [[ $version_code -lt 1015 ]]; then
        error "需要 macOS Catalina (10.15) 或更高版本，当前版本：$os_version"
    fi

    # 磁盘空间检查 (15GB+)
    local free_space=$(df -g / | tail -1 | awk '{print $4}')
    [[ $free_space -lt 15 ]] && error "磁盘空间不足15GB (剩余: ${free_space}GB)"

    # 网络连通性检查
    if ! curl -sIm3 --retry 2 --connect-timeout 30 https://mirrors.ustc.edu.cn >/dev/null; then
        if ! ping -c2 223.5.5.5 &>/dev/null; then
            error "中科大源异常，网络连接失败，请检查网络设置"
        fi
    fi

    success "系统环境预检通过"
}

# ===== 配置文件解析函数 =====
load_packages() {
    local file=$1
    local packages=()
    
    # 过滤注释和空行
    while IFS= read -r line; do
        line=$(echo $line | sed 's/#.*//')  # 去除行内注释
        line=${line// /}                   # 去除空格
        [[ -n $line ]] && packages+=($line)
    done < $file
    
    echo $packages
}

# ===== Xcode CLI 工具安装 =====
install_xcode_cli() {
    echo -e "\n${GREEN}=== 安装 Xcode 命令行工具 ===${NC}"
    
    if ! xcode-select -p &>/dev/null; then
        warning "正在安装 Xcode CLI 工具..."
        xcode-select --install
        
        # 异步等待安装完成
        local wait_count=0
        until xcode-select -p &>/dev/null; do
            sleep $(( wait_count++ ))
            [[ $wait_count -gt 300 ]] && error "安装超时，请手动执行: xcode-select --install"
        done
        
        # 验证编译器存在
        [[ -f /usr/bin/clang ]] || error "CLI 工具安装不完整"
    fi
    success "Xcode 命令行工具就绪"
}

# ===== Homebrew 安装与配置 =====
configure_homebrew() {
    echo -e "\n${GREEN}=== 配置 Homebrew (中科大源) ===${NC}"
    
    # 环境变量配置
    export HOMEBREW_BREW_GIT_REMOTE="https://mirrors.ustc.edu.cn/brew.git"
    export HOMEBREW_CORE_GIT_REMOTE="https://mirrors.ustc.edu.cn/homebrew-core.git"
    export HOMEBREW_BOTTLE_DOMAIN="https://mirrors.ustc.edu.cn/homebrew-bottles"
    export HOMEBREW_API_DOMAIN="https://mirrors.ustc.edu.cn/homebrew-bottles/api"

    # 安装 Homebrew
    if ! command -v brew &>/dev/null; then
        warning "正在安装 Homebrew..."
        local install_script=$(mktemp)
        # 中科大源的安装脚本 详见https://mirrors.ustc.edu.cn/help/brew.git.html
        curl -fsSL https://mirrors.ustc.edu.cn/misc/brew-install.sh -o $install_script
        /bin/bash $install_script || {
            rm -f $install_script
            error "Homebrew 安装失败"
        }
        rm -f $install_script

        # 环境变量持久化
        cat >> ~/.zshrc <<EOF

# Homebrew 配置
export HOMEBREW_BREW_GIT_REMOTE="https://mirrors.ustc.edu.cn/brew.git"
export HOMEBREW_CORE_GIT_REMOTE="https://mirrors.ustc.edu.cn/homebrew-core.git"
export HOMEBREW_BOTTLE_DOMAIN="https://mirrors.ustc.edu.cn/homebrew-bottles"
export HOMEBREW_API_DOMAIN="https://mirrors.ustc.edu.cn/homebrew-bottles/api"
EOF
        source ~/.zshrc
    fi

    # 仓库配置
    brew config &>/dev/null || {
        warning "修复 Homebrew 仓库..."
        sudo chown -R $(whoami) $(brew --prefix)/*
        brew update-reset -q
    }
    success "Homebrew 配置完成"
}

# ===== 核心软件安装 =====
install_core_software() {
    echo -e "\n${GREEN}=== 安装核心开发工具 ===${NC}"

    # 开发环境配置
    install_node
    install_python
    install_ruby
    install_go
    config_flutter
    config_android_and_java
    
    # 从配置文件加载软件列表
    local formulae=($(load_packages $FORMULAE_FILE))
    local casks=($(load_packages $CASKS_FILE))
    
    # 安装 formulae
    for tool in $formulae; do
        if ! brew install $tool; then
            warning "$tool 安装失败，尝试从国内镜像下载..."
            brew fetch --force $tool
            brew install $tool
        fi
    done

    # 安装 casks
    for cask in $casks; do
        if ! brew install --cask $cask; then
            warning "$cask 安装失败，尝试从国内镜像下载..."
            brew fetch --cask --force $cask
            brew install --cask $cask
        fi
    done

    success "核心软件安装完成"
}

# ===== Node.js 环境配置 =====
install_node() {
    echo -e "\n${GREEN}=== 配置 Node.js 环境 ===${NC}"
    
    # 使用 Homebrew 安装 nvm
    brew install nvm
    
    # 配置环境变量
    mkdir -p ~/.nvm
    cat >> ~/.zshrc <<EOF

# Node.js 配置
export NVM_DIR="$HOME/.nvm"
[ -s "$(brew --prefix)/opt/nvm/nvm.sh" ] && \. "$(brew --prefix)/opt/nvm/nvm.sh"
[ -s "$(brew --prefix)/opt/nvm/etc/bash_completion.d/nvm" ] && \. "$(brew --prefix)/opt/nvm/etc/bash_completion.d/nvm"
EOF
    source ~/.zshrc

    nvm install --lts --latest-npm
    # 配置 npm 镜像为淘宝源
    npm config set registry https://registry.npmmirror.com
    source ~/.zshrc

    success "Node $(node --version) 安装完成"
}

# ===== Python 环境配置 (新增PATH设置) =====
install_python() {
    echo -e "\n${GREEN}=== 配置 Python 环境 ===${NC}"
    
    # 安装最新 Python 稳定版
    brew install python
    
    # 配置路径和环境变量
    cat > ~/.zshrc <<EOF

export PATH="$(brew --prefix python)/libexec/bin:$PATH"
EOF
    
    # 配置 pip 镜像
    mkdir -p ~/.pip
    cat > ~/.pip/pip.conf <<EOF
[global]
index-url = https://mirrors.ustc.edu.cn/pypi/simple
trusted-host = mirrors.ustc.edu.cn
EOF

    source ~/.zshrc
    python3 --version || error "Python 安装失败"
    pip3 --version || error "pip 安装失败"

    success "$(python --version) 安装完成"
}

# ===== Ruby 环境配置 =====
install_ruby() {
    echo -e "\n${GREEN}=== 配置 Ruby 环境 ===${NC}"
    
    # 安装最新 Ruby
    brew install ruby
    
    # 配置路径和环境变量
    cat > ~/.zshrc <<EOF

# Ruby 配置
export PATH="$(brew --prefix ruby)/bin:$PATH"
export LDFLAGS="-L$(brew --prefix ruby)/lib"
export CPPFLAGS="-I$(brew --prefix ruby)/include"
EOF
    source ~/.zshrc
    
    # 配置 gem 镜像为中科大源
    gem sources --add https://mirrors.ustc.edu.cn/rubygems/ --remove https://rubygems.org/

    success "Ruby $(ruby -v) 安装完成"
}

# ===== Go 环境配置 (新增GOPROXY设置) =====
install_go() {
    echo -e "\n${GREEN}=== 配置 Go 环境 ===${NC}"
    
    # 安装最新 Go 版本
    brew install go
    
    # 配置环境变量
    cat >> ~/.zshrc <<EOF

# Go 配置
export GOPATH="$HOME/Coding/go"
export PATH="$GOPATH/bin:$PATH"
export GOPROXY="https://goproxy.cn,direct"
EOF
    source ~/.zshrc
    
    # 创建 Go 工作目录
    mkdir -p $GOPATH/{src,bin,pkg}

    success "$(go version) 安装完成"
}

# ===== 其他 环境配置 (Flutter配置、 Java和Android配置) =====
config_flutter() {
    echo -e "\n${GREEN}=== 配置 Flutter 环境 ===${NC}"
    
    # 配置环境变量
    cat >> ~/.zshrc <<EOF

# Flutter
export PUB_HOSTED_URL="https://mirrors.cloud.tencent.com/dart-pub"
export FLUTTER_STORAGE_BASE_URL="https://mirrors.cloud.tencent.com/flutter"
EOF
    source ~/.zshrc

    success "Flutter环境变量 设置完成"
}

config_android_and_java() {
    echo -e "\n${GREEN}=== 配置 Android和Java 环境 ===${NC}"
    
    # 配置环境变量
    cat >> ~/.zshrc <<EOF

# Java
export JAVA_HOME=/Library/Java/JavaVirtualMachines/zulu-17.jdk/Contents/Home

# Android
export ANDROID_HOME=$HOME/Library/Android/sdk
export PATH=$PATH:$ANDROID_HOME/emulator
export PATH=$PATH:$ANDROID_HOME/platform-tools
EOF
    source ~/.zshrc

    success "Android和Java环境变量 设置完成"
}


# ===== 安装后验证 =====
post_verification() {
    echo -e "\n${GREEN}=== 安装后验证 ===${NC}"
    
    # 关键命令检查
    local critical_cmds=(git brew node npm python3 pip3 ruby go)
    for cmd in $critical_cmds; do
        if ! command -v $cmd &>/dev/null; then
            warning "命令缺失: $cmd"
            return 1
        fi
    done

    # 验证环境变量
    [[ -z $(go env GOPROXY) ]] && warning "GOPROXY 未正确配置"
    [[ $(which python3) != $(brew --prefix python)* ]] && warning "Python 路径优先级异常"

    # 路径安全检测
    local sensitive_paths=(/usr/local/bin /usr/local/sbin /etc/paths.d)
    for path in $sensitive_paths; do
        [[ -w $path ]] && warning "敏感路径可写: $path"
    done

    success "基础环境验证通过"
}

# ===== 主执行流程 =====
main() {
    precheck
    install_xcode_cli
    configure_homebrew
    install_core_software
    post_verification
    
    echo -e "\n${GREEN}=== 配置完成! ===${NC}"
    echo "建议后续操作:"
    echo "1. 执行 source ~/.zshrc 刷新环境"
    echo "2. 检查配置文件位置："
    echo "   - Formulae: $FORMULAE_FILE"
    echo "   - Casks:    $CASKS_FILE"
    echo "3. 运行 docker --context default 初始化 Docker"
}

# 启动主流程
main