set -euo pipefail
readonly RED='\033[1;31m'
readonly GREEN='\033[1;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[1;34m'
readonly PURPLE='\033[1;35m'
readonly CYAN='\033[1;36m'
readonly NC='\033[0m'
readonly TOOLBOX_DIR="/etc/toolbox"
readonly CONFIG_FILE="$TOOLBOX_DIR/config.cfg"
readonly COUNTER_FILE="$TOOLBOX_DIR/counter"
readonly SCRIPT_VERSION="2.0"
readonly GITHUB_RAW_URL="https://raw.githubusercontent.com/GamblerIX/linux-toolbox/main/toolv1.sh"
OS_TYPE=""
INSTALLED="false"
SCRIPT_PID=$$
error_exit() {
    local line_no=$1
    local error_code=$2
    echo -e "${RED}错误：脚本在第 ${line_no} 行退出，错误代码：${error_code}${NC}" >&2
    cleanup
    exit "${error_code}"
}
cleanup() {
    local temp_files=("/tmp/toolbox_$$" "/tmp/speedtest_$$")
    for file in "${temp_files[@]}"; do
        [[ -f "$file" ]] && rm -f "$file"
    done
}
trap 'error_exit ${LINENO} $?' ERR
trap cleanup EXIT
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    case "$level" in
        "INFO")  echo -e "${GREEN}[INFO]${NC} $message" ;;
        "WARN")  echo -e "${YELLOW}[WARN]${NC} $message" ;;
        "ERROR") echo -e "${RED}[ERROR]${NC} $message" >&2 ;;
        "DEBUG") [[ "${DEBUG:-0}" == "1" ]] && echo -e "${CYAN}[DEBUG]${NC} $message" ;;
    esac
}
safe_read() {
    local prompt="$1"
    local default="${2:-}"
    local timeout="${3:-30}"
    local response
    if [[ -n "$default" ]]; then
        prompt="$prompt (默认: $default): "
    else
        prompt="$prompt: "
    fi
    if read -t "$timeout" -r -p "$prompt" response < /dev/tty; then
        echo "${response:-$default}"
        return 0
    else
        log "WARN" "输入超时，使用默认值: $default"
        echo "$default"
        return 1
    fi
}
command_exists() {
    command -v "$1" >/dev/null 2>&1
}
check_network() {
    local test_urls=("www.google.com" "www.baidu.com" "github.com")
    for url in "${test_urls[@]}"; do
        if timeout 5 ping -c 1 "$url" >/dev/null 2>&1; then
            return 0
        fi
    done
    log "ERROR" "网络连接检查失败，请检查网络设置"
    return 1
}
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log "WARN" "检测到非root用户，正尝试提权..."
        if ! command_exists sudo; then
            log "ERROR" "需要root权限但sudo不可用"
            exit 1
        fi
        exec sudo -E "$0" "$@"
    fi
}
detect_os() {
    local os_release="/etc/os-release"
    local redhat_release="/etc/redhat-release"
    if [[ -f "$os_release" ]]; then
        local ID VERSION_ID
        source "$os_release"
        case "$ID" in
            "ubuntu") OS_TYPE="ubuntu" ;;
            "debian") OS_TYPE="debian" ;;
            "centos")
                case "$VERSION_ID" in
                    7) OS_TYPE="centos7" ;;
                    8) OS_TYPE="centos8" ;;
                    *) OS_TYPE="unsupported" ;;
                esac
                ;;
            *) OS_TYPE="unsupported" ;;
        esac
    elif [[ -f "$redhat_release" ]]; then
        if grep -q "CentOS release 7" "$redhat_release"; then
            OS_TYPE="centos7"
        elif grep -q "CentOS Stream release 8" "$redhat_release"; then
            OS_TYPE="centos8"
        else
            OS_TYPE="unsupported"
        fi
    else
        OS_TYPE="unsupported"
    fi
    if [[ "$OS_TYPE" == "unsupported" ]]; then
        log "ERROR" "不支持的操作系统。仅支持 Ubuntu, Debian, CentOS 7/8"
        exit 1
    fi
    log "INFO" "检测到系统: $OS_TYPE"
}
init_config() {
    [[ ! -d "$TOOLBOX_DIR" ]] && mkdir -p "$TOOLBOX_DIR"
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
    else
        INSTALLED="false"
        cat > "$CONFIG_FILE" << EOF
INSTALLED=false
INSTALL_DATE=$(date '+%Y-%m-%d %H:%M:%S')
VERSION=$SCRIPT_VERSION
EOF
    fi
    [[ ! -f "$COUNTER_FILE" ]] && echo "0" > "$COUNTER_FILE"
}
show_header() {
    clear
    local counter
    counter=$(< "$COUNTER_FILE")
    ((counter++))
    echo "$counter" > "$COUNTER_FILE"
    cat << 'EOF'
██╗     ██╗███╗   ██╗██╗   ██╗██╗  ██╗
██║     ██║████╗  ██║██║   ██║╚██╗██╔╝
██║     ██║██╔██╗ ██║██║   ██║ ╚███╔╝ 
██║     ██║██║╚██╗██║██║   ██║ ██╔██╗ 
███████╗██║██║ ╚████║╚██████╔╝██╔╝ ██╗
╚══════╝╚═╝╚═╝  ╚═══╝ ╚═════╝ ╚═╝  ╚═╝
EOF
    echo -e "${CYAN}╔═══════════════════════════════╗${NC}"
    echo -e "${GREEN}       Linux工具箱 v${SCRIPT_VERSION}       ${NC}"
    echo -e "${CYAN}╚═══════════════════════════════╝${NC}"
    if [[ "$INSTALLED" == "true" ]]; then
        echo -e "${BLUE}  运行模式: 已安装 (执行命令: toolv1)${NC}"
    else
        echo -e "${BLUE}  运行模式: 直接运行${NC}"
    fi
    echo -e "${PURPLE}  检测到系统: ${OS_TYPE}${NC}"
    echo -e "${CYAN}  运行次数: ${counter}${NC}"
    echo
}
get_package_manager() {
    case "$OS_TYPE" in
        "ubuntu"|"debian") echo "apt" ;;
        "centos7") echo "yum" ;;
        "centos8") echo "dnf" ;;
        *) echo "unknown" ;;
    esac
}
install_package() {
    local package="$1"
    local pm
    pm=$(get_package_manager)
    if [[ "$pm" == "unknown" ]]; then
        log "ERROR" "未知的包管理器"
        return 1
    fi
    log "INFO" "正在安装 $package..."
    case "$pm" in
        "apt")
            apt-get update -qq && apt-get install -y "$package"
            ;;
        "yum"|"dnf")
            "$pm" install -y "$package"
            ;;
    esac
}
network_speed_test() {
    show_header
    echo -e "${YELLOW}====== 网络速度测试 ======${NC}"
    if ! check_network; then
        log "ERROR" "网络连接失败，无法进行速度测试"
        safe_read "按回车键返回"
        network_tools_menu
        return 1
    fi
    if ! command_exists speedtest-cli; then
        local install_choice
        install_choice=$(safe_read "speedtest-cli 未安装，是否立即安装? (y/N)" "N" 10)
        if [[ "$install_choice" =~ ^[Yy]$ ]]; then
            if ! install_package speedtest-cli; then
                log "ERROR" "speedtest-cli 安装失败"
                safe_read "按回车键返回"
                network_tools_menu
                return 1
            fi
        else
            log "INFO" "已跳过网络测试"
            safe_read "按回车键返回"
            network_tools_menu
            return 0
        fi
    fi
    if command_exists speedtest-cli; then
        echo -e "${CYAN}正在测试网络，请稍候...${NC}"
        local temp_file="/tmp/speedtest_$$"
        if timeout 60 speedtest-cli --simple > "$temp_file" 2>&1; then
            local ping download upload
            ping=$(grep "Ping" "$temp_file" | cut -d':' -f2 | xargs)
            download=$(grep "Download" "$temp_file" | cut -d':' -f2 | xargs)
            upload=$(grep "Upload" "$temp_file" | cut -d':' -f2 | xargs)
            echo -e "${GREEN}测试结果：${NC}"
            printf "  %-12s %s\n" "延迟:" "$ping"
            printf "  %-12s %s\n" "下载速度:" "$download"
            printf "  %-12s %s\n" "上传速度:" "$upload"
        else
            log "ERROR" "网络测试失败或超时"
        fi
        rm -f "$temp_file"
    fi
    safe_read "按回车键返回"
    network_tools_menu
}
clean_system() {
    show_header
    echo -e "${YELLOW}====== 清理系统垃圾 ======${NC}"
    local cleanup_tasks=(
        "清理临时文件"
        "清理包缓存"
        "清理旧内核"
        "清理日志文件"
    )
    for task in "${cleanup_tasks[@]}"; do
        echo -e "${BLUE}正在${task}...${NC}"
        case "$task" in
            "清理临时文件")
                find /tmp -type f -mtime +7 -delete 2>/dev/null || true
                find /var/tmp -type f -mtime +7 -delete 2>/dev/null || true
                ;;
            "清理包缓存")
                case "$OS_TYPE" in
                    "ubuntu"|"debian") apt-get clean && apt-get autoclean ;;
                    "centos7") yum clean all ;;
                    "centos8") dnf clean all ;;
                esac
                ;;
            "清理旧内核")
                case "$OS_TYPE" in
                    "ubuntu"|"debian") 
                        apt-get autoremove --purge -y
                        ;;
                    "centos7") 
                        if command_exists package-cleanup; then
                            package-cleanup --oldkernels --count=1 -y
                        fi
                        ;;
                    "centos8") 
                        dnf autoremove -y
                        ;;
                esac
                ;;
            "清理日志文件")
                if command_exists journalctl; then
                    journalctl --vacuum-time=7d
                fi
                ;;
        esac
    done
    echo -e "${GREEN}系统垃圾清理完成！${NC}"
    safe_read "按回车键返回"
    manage_tools
}
change_mirror_apt() {
    local mirror_base_url="$1"
    local mirror_name="$2"
    local codename
    if ! codename=$(lsb_release -sc 2>/dev/null); then
        log "ERROR" "无法获取系统代号"
        return 1
    fi
    log "INFO" "检测到 $OS_TYPE 系统，正在更换为 $mirror_name 源..."
    local backup_file="/etc/apt/sources.list.backup.$(date +%s)"
    cp /etc/apt/sources.list "$backup_file"
    log "INFO" "已备份原有源文件至 $backup_file"
    case "$OS_TYPE" in
        "ubuntu")
            cat > /etc/apt/sources.list << EOF
deb ${mirror_base_url}/ubuntu/ ${codename} main restricted universe multiverse
deb ${mirror_base_url}/ubuntu/ ${codename}-security main restricted universe multiverse
deb ${mirror_base_url}/ubuntu/ ${codename}-updates main restricted universe multiverse
deb ${mirror_base_url}/ubuntu/ ${codename}-backports main restricted universe multiverse
deb-src ${mirror_base_url}/ubuntu/ ${codename} main restricted universe multiverse
deb-src ${mirror_base_url}/ubuntu/ ${codename}-security main restricted universe multiverse
deb-src ${mirror_base_url}/ubuntu/ ${codename}-updates main restricted universe multiverse
deb-src ${mirror_base_url}/ubuntu/ ${codename}-backports main restricted universe multiverse
EOF
            ;;
        "debian")
            local security_mirror_url
            case "$mirror_base_url" in
                *"aliyun"*) security_mirror_url="http://mirrors.aliyun.com/debian-security" ;;
                *"tencent"*) security_mirror_url="http://mirrors.tencent.com/debian-security" ;;
                *"ustc"*) security_mirror_url="https://mirrors.ustc.edu.cn/debian-security" ;;
                *) security_mirror_url="http://security.debian.org/debian-security" ;;
            esac
            local components="main contrib non-free"
            if [[ "$codename" =~ ^(bookworm|trixie|sid)$ ]]; then
                components="main contrib non-free non-free-firmware"
            fi
            cat > /etc/apt/sources.list << EOF
deb ${mirror_base_url}/debian/ ${codename} ${components}
deb-src ${mirror_base_url}/debian/ ${codename} ${components}
deb ${security_mirror_url} ${codename}-security ${components}
deb-src ${security_mirror_url} ${codename}-security ${components}
deb ${mirror_base_url}/debian/ ${codename}-updates ${components}
deb-src ${mirror_base_url}/debian/ ${codename}-updates ${components}
deb ${mirror_base_url}/debian/ ${codename}-backports ${components}
deb-src ${mirror_base_url}/debian/ ${codename}-backports ${components}
EOF
            ;;
        *)
            log "ERROR" "当前系统 ($OS_TYPE) 不适用于APT换源"
            return 1
            ;;
    esac
    if ! apt-get update; then
        log "WARN" "源更新失败，正在恢复备份..."
        cp "$backup_file" /etc/apt/sources.list
        apt-get update
        return 1
    fi
    log "INFO" "$OS_TYPE 源已更换为 $mirror_name"
    return 0
}
change_mirror_yum() {
    local mirror_base_url="$1"
    local mirror_name="$2"
    if [[ "$OS_TYPE" != "centos7" ]]; then
        log "ERROR" "此YUM换源功能目前仅支持 CentOS 7 系统"
        return 1
    fi
    log "INFO" "检测到 CentOS 7 系统，正在更换为 $mirror_name 源..."
    local backup_dir="/etc/yum.repos.d/backup-$(date +%s)"
    mkdir -p "$backup_dir"
    cp -r /etc/yum.repos.d/*.repo "$backup_dir/" 2>/dev/null || true
    log "INFO" "已备份原有源文件至 $backup_dir"
    find /etc/yum.repos.d/ -name "*.repo" -exec mv {} {}.disabled \;
    cat > /etc/yum.repos.d/CentOS-Base.repo << EOF
[base]
name=CentOS-7 - Base - $mirror_name
baseurl=$mirror_base_url/centos/7/os/\$basearch/
gpgcheck=1
gpgkey=$mirror_base_url/centos/RPM-GPG-KEY-CentOS-7
enabled=1
[updates]
name=CentOS-7 - Updates - $mirror_name
baseurl=$mirror_base_url/centos/7/updates/\$basearch/
gpgcheck=1
gpgkey=$mirror_base_url/centos/RPM-GPG-KEY-CentOS-7
enabled=1
[extras]
name=CentOS-7 - Extras - $mirror_name
baseurl=$mirror_base_url/centos/7/extras/\$basearch/
gpgcheck=1
gpgkey=$mirror_base_url/centos/RPM-GPG-KEY-CentOS-7
enabled=1
[centosplus]
name=CentOS-7 - Plus - $mirror_name
baseurl=$mirror_base_url/centos/7/centosplus/\$basearch/
gpgcheck=1
gpgkey=$mirror_base_url/centos/RPM-GPG-KEY-CentOS-7
enabled=0
EOF
    if yum clean all && yum makecache; then
        log "INFO" "CentOS 7 源已更换为 $mirror_name"
        return 0
    else
        log "ERROR" "源更换失败，正在恢复备份..."
        rm -f /etc/yum.repos.d/CentOS-Base.repo
        cp "$backup_dir"/*.repo /etc/yum.repos.d/
        return 1
    fi
}
user_management() {
    show_header
    echo -e "${YELLOW}====== 用户管理 ======${NC}"
    local menu_items=(
        "列出可登录用户"
        "创建新用户"
        "删除用户"
        "修改密码"
        "查看用户组"
        "切换用户"
        "返回主菜单"
    )
    for i in "${!menu_items[@]}"; do
        echo -e "${GREEN}$((i+1)). ${menu_items[$i]}${NC}"
    done
    echo -e "${CYAN}==============================================${NC}"
    local choice
    choice=$(safe_read "请输入选项 [1-${#menu_items[@]}]" "7")
    case "$choice" in
        1) list_login_users ;;
        2) create_user ;;
        3) delete_user ;;
        4) change_user_password ;;
        5) show_user_groups ;;
        6) switch_user ;;
        7) main_menu; return ;;
        *) log "WARN" "无效选项"; sleep 1; user_management ;;
    esac
    safe_read "按回车键返回"
    user_management
}
list_login_users() {
    echo -e "${YELLOW}--- 可登录用户列表 ---${NC}"
    awk -F: '($1 == "root") || ($3 >= 1000 && $7 ~ /^\/bin\/(bash|sh|zsh|dash)$/) {
        printf "%-15s UID:%-5s Shell:%s\n", $1, $3, $7
    }' /etc/passwd | sort
}
create_user() {
    local username
    username=$(safe_read "请输入新用户名")
    if [[ -z "$username" ]]; then
        log "ERROR" "用户名不能为空"
        return 1
    fi
    if id "$username" &>/dev/null; then
        log "ERROR" "用户 $username 已存在"
        return 1
    fi
    case "$OS_TYPE" in
        "ubuntu"|"debian") 
            adduser "$username"
            ;;
        *) 
            useradd -m -s /bin/bash "$username" && passwd "$username"
            ;;
    esac
}
network_tools_menu() {
    show_header
    echo -e "${YELLOW}====== 网络与安全工具 ======${NC}"
    local network_menu=(
        "网络速度测试"
        "查看SSH登录日志"
        "防火墙管理"
        "BBR网络加速管理"
        "列出已占用端口"
        "网络诊断工具"
        "返回主菜单"
    )
    for i in "${!network_menu[@]}"; do
        echo -e "${GREEN}$((i+1)). ${network_menu[$i]}${NC}"
    done
    echo -e "${CYAN}==============================================${NC}"
    local choice
    choice=$(safe_read "请输入选项 [1-${#network_menu[@]}]" "7")
    case "$choice" in
        1) network_speed_test ;;
        2) view_ssh_logs ;;
        3) firewall_management ;;
        4) bbr_management ;;
        5) list_used_ports ;;
        6) network_diagnostic ;;
        7) main_menu; return ;;
        *) log "WARN" "无效选项"; sleep 1; network_tools_menu ;;
    esac
}
network_diagnostic() {
    show_header
    echo -e "${YELLOW}====== 网络诊断工具 ======${NC}"
    echo -e "${CYAN}正在进行网络诊断...${NC}"
    echo -e "\n${GREEN}--- 网络接口信息 ---${NC}"
    ip addr show | grep -E '^[0-9]+:|inet '
    echo -e "\n${GREEN}--- 路由表 ---${NC}"
    ip route show
    echo -e "\n${GREEN}--- DNS配置 ---${NC}"
    cat /etc/resolv.conf
    echo -e "\n${GREEN}--- 网络连通性测试 ---${NC}"
    local test_hosts=("8.8.8.8" "114.114.114.114" "www.baidu.com")
    for host in "${test_hosts[@]}"; do
        if ping -c 1 -W 3 "$host" >/dev/null 2>&1; then
            echo -e "${GREEN}✓${NC} $host - 可达"
        else
            echo -e "${RED}✗${NC} $host - 不可达"
        fi
    done
    safe_read "按回车键返回"
    network_tools_menu
}
install_toolbox() {
    log "INFO" "正在从 GitHub 下载并安装工具箱..."
    if [[ $EUID -ne 0 ]]; then
        log "ERROR" "此操作需要root权限"
        return 1
    fi
    if ! check_network; then
        log "ERROR" "网络连接失败，无法下载工具箱"
        return 1
    fi
    local temp_file="/tmp/toolbox_install_$$"
    if command_exists curl; then
        if ! curl -fsSL "$GITHUB_RAW_URL" -o "$temp_file"; then
            log "ERROR" "下载失败，请检查网络连接"
            return 1
        fi
    elif command_exists wget; then
        if ! wget -q "$GITHUB_RAW_URL" -O "$temp_file"; then
            log "ERROR" "下载失败，请检查网络连接"
            return 1
        fi
    else
        log "ERROR" "系统中未找到 curl 或 wget"
        return 1
    fi
    if [[ ! -s "$temp_file" ]]; then
        log "ERROR" "下载的文件为空"
        rm -f "$temp_file"
        return 1
    fi
    if cp "$temp_file" /usr/local/bin/toolv1 && chmod +x /usr/local/bin/toolv1; then
        mkdir -p "$TOOLBOX_DIR"
        cat > "$CONFIG_FILE" << EOF
INSTALLED=true
INSTALL_DATE=$(date '+%Y-%m-%d %H:%M:%S')
VERSION=$SCRIPT_VERSION
EOF
        echo "0" > "$COUNTER_FILE"
        log "INFO" "工具箱安装/更新成功！"
        log "INFO" "正在重启工具箱..."
        sleep 2
        rm -f "$temp_file"
        exec /usr/local/bin/toolv1
    else
        log "ERROR" "安装失败，请检查权限"
        rm -f "$temp_file"
        return 1
    fi
}
main_menu() {
    show_header
    local main_menu_items=(
        "系统管理工具"
        "网络与安全工具"
        "一键换源加速"
        "一键安装面板"
        "一键安装singbox-yg脚本"
        "工具箱管理"
        "退出"
    )
    for i in "${!main_menu_items[@]}"; do
        echo -e "${GREEN}$((i+1)). ${main_menu_items[$i]}${NC}"
    done
    echo -e "${CYAN}==============================================${NC}"
    local choice
    choice=$(safe_read "请输入选项 [1-${#main_menu_items[@]}]" "7")
    case "$choice" in
        1) manage_tools ;;
        2) network_tools_menu ;;
        3) change_source ;;
        4) panel_installation ;;
        5) install_singbox_yg ;;
        6) toolbox_management ;;
        7) 
            if [[ "$INSTALLED" == "false" ]]; then
                echo -e "\n${YELLOW}一键运行命令: ${CYAN}curl -Ls $GITHUB_RAW_URL | bash${NC}\n"
            fi
            log "INFO" "感谢使用 Linux 工具箱！"
            exit 0
            ;;
        *) 
            log "WARN" "无效选项"
            sleep 1
            main_menu
            ;;
    esac
}
manage_tools() {
    show_header
    echo -e "${YELLOW}====== 系统管理工具 ======${NC}"
    echo -e "${GREEN}1. 清理系统垃圾${NC}"
    echo -e "${GREEN}2. 用户管理${NC}"
    echo -e "${GREEN}3. 内核管理${NC}"
    echo -e "${GREEN}0. 返回主菜单${NC}"
    echo -e "${CYAN}==============================================${NC}"
    local choice
    choice=$(safe_read "请输入选项 [0-3]" "0")
    case "$choice" in
        1) clean_system ;;
        2) user_management ;;
        3) kernel_management ;;
        0) main_menu; return ;;
        *) log "WARN" "无效选项"; sleep 1; manage_tools ;;
    esac
}
kernel_management() {
    show_header
    echo -e "${YELLOW}====== 内核管理 ======${NC}"
    echo -e "${GREEN}1. 查看当前内核版本${NC}"
    echo -e "${GREEN}2. 列出所有已安装内核${NC}"
    echo -e "${GREEN}3. 删除旧内核${NC}"
    echo -e "${GREEN}4. 检查内核更新${NC}"
    echo -e "${GREEN}0. 返回主菜单${NC}"
    echo -e "${CYAN}==============================================${NC}"
    local choice
    choice=$(safe_read "请输入选项 [0-4]" "0")
    case "$choice" in
        1) show_kernel_version ;;
        2) list_installed_kernels ;;
        3) remove_old_kernels ;;
        4) check_kernel_updates ;;
        0) main_menu; return ;;
        *) log "WARN" "无效选项"; sleep 1; kernel_management ;;
    esac
    safe_read "按回车键返回"
    kernel_management
}
show_kernel_version() {
    echo -e "${YELLOW}--- 当前内核信息 ---${NC}"
    echo -e "内核版本: ${GREEN}$(uname -r)${NC}"
    echo -e "系统架构: ${GREEN}$(uname -m)${NC}"
    echo -e "内核构建时间: ${GREEN}$(uname -v)${NC}"
}
list_installed_kernels() {
    echo -e "${YELLOW}--- 已安装的内核 ---${NC}"
    case "$OS_TYPE" in
        "ubuntu"|"debian")
            dpkg --list | grep -E '^ii\s+linux-image-[0-9]' | awk '{print $2, $3}' | column -t
            ;;
        "centos7"|"centos8")
            rpm -qa | grep '^kernel-[0-9]' | sort -V
            ;;
    esac
}
remove_old_kernels() {
    echo -e "${YELLOW}--- 删除旧内核 ---${NC}"
    local confirm
    confirm=$(safe_read "确定要删除旧内核吗？这将保留当前内核和最新的一个版本 (y/N)" "N")
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log "INFO" "操作已取消"
        return 0
    fi
    case "$OS_TYPE" in
        "ubuntu"|"debian")
            apt-get autoremove --purge -y
            ;;
        "centos7")
            if command_exists package-cleanup; then
                package-cleanup --oldkernels --count=1 -y
            else
                log "WARN" "package-cleanup 不可用，请手动删除旧内核"
            fi
            ;;
        "centos8")
            dnf autoremove -y
            ;;
    esac
}
check_kernel_updates() {
    echo -e "${YELLOW}--- 检查内核更新 ---${NC}"
    case "$OS_TYPE" in
        "ubuntu"|"debian")
            apt-get update -qq
            apt list --upgradable 2>/dev/null | grep linux-image || echo "没有可用的内核更新"
            ;;
        "centos7"|"centos8")
            local pm
            pm=$(get_package_manager)
            "$pm" check-update kernel 2>/dev/null || echo "没有可用的内核更新"
            ;;
    esac
}
change_source() {
    show_header
    echo -e "${YELLOW}====== 一键换源加速 ======${NC}"
    local mirror_options=(
        "阿里云源"
        "腾讯云源"
        "中科大源"
        "清华大学源"
        "恢复官方源"
        "返回主菜单"
    )
    echo -e "${CYAN}当前系统: $OS_TYPE${NC}"
    for i in "${!mirror_options[@]}"; do
        echo -e "${GREEN}$((i+1)). ${mirror_options[$i]}${NC}"
    done
    echo -e "${CYAN}==============================================${NC}"
    local choice
    choice=$(safe_read "请输入选项 [1-${#mirror_options[@]}]" "6")
    local confirm_msg="确定要进行此操作吗？(y/N)"
    local confirm
    case "$choice" in
        1)
            confirm=$(safe_read "$confirm_msg" "N")
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                change_to_mirror "阿里云" "http://mirrors.aliyun.com"
            fi
            ;;
        2)
            confirm=$(safe_read "$confirm_msg" "N")
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                change_to_mirror "腾讯云" "http://mirrors.tencent.com"
            fi
            ;;
        3)
            confirm=$(safe_read "$confirm_msg" "N")
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                change_to_mirror "中科大" "https://mirrors.ustc.edu.cn"
            fi
            ;;
        4)
            confirm=$(safe_read "$confirm_msg" "N")
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                change_to_mirror "清华大学" "https://mirrors.tuna.tsinghua.edu.cn"
            fi
            ;;
        5)
            confirm=$(safe_read "确定要恢复官方源吗？(y/N)" "N")
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                restore_official_source
            fi
            ;;
        6)
            main_menu
            return
            ;;
        *)
            log "WARN" "无效选项"
            ;;
    esac
    safe_read "按回车键继续"
    change_source
}
change_to_mirror() {
    local mirror_name="$1"
    local mirror_url="$2"
    case "$OS_TYPE" in
        "ubuntu"|"debian")
            if change_mirror_apt "$mirror_url" "$mirror_name"; then
                log "INFO" "源更换成功"
            else
                log "ERROR" "源更换失败"
            fi
            ;;
        "centos7")
            if change_mirror_yum "$mirror_url" "$mirror_name"; then
                log "INFO" "源更换成功"
            else
                log "ERROR" "源更换失败"
            fi
            ;;
        *)
            log "ERROR" "当前系统不支持此换源操作"
            ;;
    esac
}
restore_official_source() {
    case "$OS_TYPE" in
        "ubuntu"|"debian")
            restore_official_apt
            ;;
        "centos7")
            restore_official_yum
            ;;
        *)
            log "ERROR" "当前系统不支持恢复官方源"
            ;;
    esac
}
restore_official_apt() {
    local codename
    if ! codename=$(lsb_release -sc 2>/dev/null); then
        log "ERROR" "无法获取系统代号"
        return 1
    fi
    log "INFO" "检测到 $OS_TYPE 系统，恢复官方源..."
    local backup_file="/etc/apt/sources.list.backup.$(date +%s)"
    cp /etc/apt/sources.list "$backup_file"
    case "$OS_TYPE" in
        "ubuntu")
            cat > /etc/apt/sources.list << EOF
deb http://archive.ubuntu.com/ubuntu/ ${codename} main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ ${codename}-security main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ ${codename}-updates main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ ${codename}-backports main restricted universe multiverse
deb-src http://archive.ubuntu.com/ubuntu/ ${codename} main restricted universe multiverse
deb-src http://archive.ubuntu.com/ubuntu/ ${codename}-security main restricted universe multiverse
deb-src http://archive.ubuntu.com/ubuntu/ ${codename}-updates main restricted universe multiverse
deb-src http://archive.ubuntu.com/ubuntu/ ${codename}-backports main restricted universe multiverse
EOF
            ;;
        "debian")
            local components="main contrib non-free"
            if [[ "$codename" =~ ^(bookworm|trixie|sid)$ ]]; then
                components="main contrib non-free non-free-firmware"
            fi
            cat > /etc/apt/sources.list << EOF
deb http://deb.debian.org/debian/ ${codename} ${components}
deb-src http://deb.debian.org/debian/ ${codename} ${components}
deb http://security.debian.org/debian-security/ ${codename}-security ${components}
deb-src http://security.debian.org/debian-security/ ${codename}-security ${components}
deb http://deb.debian.org/debian/ ${codename}-updates ${components}
deb-src http://deb.debian.org/debian/ ${codename}-updates ${components}
deb http://deb.debian.org/debian/ ${codename}-backports ${components}
deb-src http://deb.debian.org/debian/ ${codename}-backports ${components}
EOF
            ;;
    esac
    if apt-get update; then
        log "INFO" "$OS_TYPE 官方源已恢复"
        return 0
    else
        log "ERROR" "官方源恢复失败，正在还原备份"
        cp "$backup_file" /etc/apt/sources.list
        return 1
    fi
}
restore_official_yum() {
    if [[ "$OS_TYPE" != "centos7" ]]; then
        log "ERROR" "此恢复官方源功能仅支持 CentOS 7 系统"
        return 1
    fi
    log "INFO" "检测到 CentOS 7 系统，正在恢复官方源..."
    local backup_dir="/etc/yum.repos.d/backup-$(date +%s)"
    mkdir -p "$backup_dir"
    cp -r /etc/yum.repos.d/*.repo "$backup_dir/" 2>/dev/null || true
    find /etc/yum.repos.d/ -name "*.repo" -delete
    local official_repos=(
        "http://vault.centos.org/centos/7/os/x86_64/CentOS-Base.repo"
        "http://vault.centos.org/centos/7/extras/x86_64/CentOS-Extras.repo"
    )
    local success=true
    for repo_url in "${official_repos[@]}"; do
        local repo_name
        repo_name=$(basename "$repo_url")
        if command_exists curl; then
            if ! curl -fsSL "$repo_url" -o "/etc/yum.repos.d/$repo_name"; then
                success=false
                break
            fi
        elif command_exists wget; then
            if ! wget -q "$repo_url" -O "/etc/yum.repos.d/$repo_name"; then
                success=false
                break
            fi
        else
            log "ERROR" "系统中未找到 curl 或 wget"
            success=false
            break
        fi
    done
    if [[ "$success" == "true" ]] && yum clean all && yum makecache; then
        log "INFO" "CentOS 7 官方源已恢复"
        return 0
    else
        log "ERROR" "官方源恢复失败，正在还原备份"
        rm -f /etc/yum.repos.d/*.repo
        cp "$backup_dir"/*.repo /etc/yum.repos.d/
        return 1
    fi
}
panel_installation() {
    show_header
    echo -e "${YELLOW}====== 面板安装 ======${NC}"
    local panel_options=(
        "宝塔面板 LTS版 稳定版"
        "1Panel 国际版 Docker优化"
        "宝塔面板 最新版"
        "1Panel 国内版"
        "aapanel 国际版"
        "返回主菜单"
    )
    for i in "${!panel_options[@]}"; do
        echo -e "${GREEN}$((i+1)). ${panel_options[$i]}${NC}"
    done
    echo -e "${CYAN}提示：1Panel侧重Docker，宝塔侧重直接部署${NC}"
    echo -e "${CYAN}==============================================${NC}"
    local choice
    choice=$(safe_read "请输入选项 [1-${#panel_options[@]}]" "6")
    case "$choice" in
        1) install_bt_lts ;;
        2) install_1_global ;;
        3) install_bt_latest ;;
        4) install_1_cn ;;
        5) install_aa_latest ;;
        6) main_menu; return ;;
        *) log "WARN" "无效选项"; sleep 1; panel_installation ;;
    esac
}
install_panel() {
    local panel_name="$1"
    local install_command="$2"
    log "INFO" "即将退出工具箱并开始安装 $panel_name..."
    log "WARN" "安装过程中请保持网络连接稳定"
    local confirm
    confirm=$(safe_read "确定要继续安装吗？(y/N)" "N")
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log "INFO" "安装已取消"
        panel_installation
        return
    fi
    sleep 2
    clear
    exec bash -c "$install_command"
}
install_bt_lts() {
    local cmd="url=https://download.bt.cn/install/install_lts.sh; if command -v curl >/dev/null; then curl -sSO \$url; else wget -O install_lts.sh \$url; fi; bash install_lts.sh ed8484bec"
    install_panel "宝塔面板 LTS版" "$cmd"
}
install_1_global() {
    local cmd="curl -sSL https://resource.1panel.pro/quick_start.sh -o quick_start.sh && bash quick_start.sh"
    install_panel "1Panel 国际版" "$cmd"
}
install_bt_latest() {
    local cmd="if command -v curl >/dev/null; then curl -sSO https://download.bt.cn/install/install_panel.sh; else wget -O install_panel.sh https://download.bt.cn/install/install_panel.sh; fi; bash install_panel.sh ed8484bec"
    install_panel "宝塔面板最新版" "$cmd"
}
install_1_cn() {
    local cmd="curl -sSL https://resource.fit2cloud.com/1panel/package/quick_start.sh -o quick_start.sh && bash quick_start.sh"
    install_panel "1Panel 国内版" "$cmd"
}
install_aa_latest() {
    local cmd="URL=https://www.aapanel.com/script/install_7.0_en.sh && if command -v curl >/dev/null; then curl -ksSO \"\$URL\"; else wget --no-check-certificate -O install_7.0_en.sh \"\$URL\"; fi; bash install_7.0_en.sh aapanel"
    install_panel "aapanel 国际版" "$cmd"
}
install_singbox_yg() {
    local cmd="bash <(curl -Ls https://raw.githubusercontent.com/yonggekkk/sing-box-yg/main/sb.sh)"
    install_panel "sing-box-yg 脚本" "$cmd"
}
toolbox_management() {
    show_header
    echo -e "${YELLOW}====== 工具箱管理 ======${NC}"
    echo -e "${GREEN}1. 安装/更新工具箱${NC}"
    echo -e "${GREEN}2. 卸载工具箱${NC}"
    echo -e "${GREEN}3. 检查版本信息${NC}"
    echo -e "${GREEN}4. 清理配置文件${NC}"
    echo -e "${GREEN}0. 返回主菜单${NC}"
    echo -e "${CYAN}==============================================${NC}"
    local choice
    choice=$(safe_read "请输入选项 [0-4]" "0")
    case "$choice" in
        1) install_toolbox ;;
        2) uninstall_toolbox ;;
        3) show_version_info ;;
        4) cleanup_config ;;
        0) main_menu; return ;;
        *) log "WARN" "无效选项"; sleep 1; toolbox_management ;;
    esac
}
show_version_info() {
    echo -e "${YELLOW}--- 工具箱版本信息 ---${NC}"
    echo -e "当前版本: ${GREEN}$SCRIPT_VERSION${NC}"
    echo -e "安装状态: ${GREEN}$([[ "$INSTALLED" == "true" ]] && echo "已安装" || echo "未安装")${NC}"
    if [[ -f "$CONFIG_FILE" ]]; then
        echo -e "配置文件: ${GREEN}存在${NC}"
        source "$CONFIG_FILE"
        [[ -n "${INSTALL_DATE:-}" ]] && echo -e "安装日期: ${GREEN}$INSTALL_DATE${NC}"
    else
        echo -e "配置文件: ${RED}不存在${NC}"
    fi
    if [[ -f "$COUNTER_FILE" ]]; then
        local count
        count=$(< "$COUNTER_FILE")
        echo -e "运行次数: ${GREEN}$count${NC}"
    fi
}
cleanup_config() {
    local confirm
    confirm=$(safe_read "确定要清理所有配置文件吗？这将重置运行计数等信息 (y/N)" "N")
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        rm -rf "$TOOLBOX_DIR"
        log "INFO" "配置文件已清理"
        init_config
    else
        log "INFO" "操作已取消"
    fi
    safe_read "按回车键返回"
    toolbox_management
}
uninstall_toolbox() {
    log "WARN" "正在卸载工具箱..."
    if [[ $EUID -ne 0 ]]; then
        log "ERROR" "此操作需要root权限"
        return 1
    fi
    local confirm
    confirm=$(safe_read "确定要卸载工具箱吗？这将删除所有相关文件 (y/N)" "N")
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log "INFO" "卸载已取消"
        safe_read "按回车键返回"
        toolbox_management
        return
    fi
    if [[ -f /usr/local/bin/toolv1 ]]; then
        rm -f /usr/local/bin/toolv1
        log "INFO" "已删除可执行文件"
    else
        log "WARN" "工具箱未安装，无需卸载"
    fi
    if [[ -d "$TOOLBOX_DIR" ]]; then
        rm -rf "$TOOLBOX_DIR"
        log "INFO" "已删除配置目录"
    fi
    log "INFO" "工具箱已成功卸载"
    log "INFO" "感谢您的使用！"
    safe_read "按回车键退出"
    exit 0
}
view_ssh_logs() {
    while true; do
        show_header
        echo -e "${YELLOW}====== 查看SSH登录日志 ======${NC}"
        echo -e "${GREEN}1. 查看成功登录记录${NC}"
        echo -e "${GREEN}2. 查看失败登录记录${NC}"
        echo -e "${GREEN}3. 查看所有登录记录${NC}"
        echo -e "${GREEN}4. 实时监控SSH登录${NC}"
        echo -e "${GREEN}0. 返回上一级菜单${NC}"
        echo -e "${CYAN}==============================================${NC}"
        local choice
        choice=$(safe_read "请输入选项 [0-4]" "0")
        case "$choice" in
            1) display_logs "success" ;;
            2) display_logs "failure" ;;
            3) display_logs "all" ;;
            4) monitor_ssh_realtime ;;
            0) break ;;
            *) log "WARN" "无效选项"; sleep 1 ;;
        esac
    done
    network_tools_menu
}
monitor_ssh_realtime() {
    show_header
    echo -e "${YELLOW}====== 实时监控SSH登录 ======${NC}"
    echo -e "${CYAN}正在监控SSH登录，按 Ctrl+C 退出...${NC}"
    local log_file
    if [[ "$OS_TYPE" == "ubuntu" || "$OS_TYPE" == "debian" ]]; then
        log_file="/var/log/auth.log"
    else
        log_file="/var/log/secure"
    fi
    if [[ ! -f "$log_file" ]]; then
        log "ERROR" "日志文件 $log_file 未找到"
        safe_read "按回车键返回"
        return 1
    fi
    tail -f "$log_file" | grep --line-buffered -E "(Accepted|Failed)" | while read -r line; do
        if echo "$line" | grep -q "Accepted"; then
            echo -e "${GREEN}[成功] $line${NC}"
        else
            echo -e "${RED}[失败] $line${NC}"
        fi
    done
}
display_logs() {
    local log_type="$1"
    local log_file
    if [[ "$OS_TYPE" == "ubuntu" || "$OS_TYPE" == "debian" ]]; then
        log_file="/var/log/auth.log"
    else
        log_file="/var/log/secure"
    fi
    if [[ ! -f "$log_file" ]]; then
        log "ERROR" "日志文件 $log_file 未找到"
        safe_read "按回车键返回"
        return 1
    fi
    local success_pattern="Accepted"
    local failure_pattern="Failed password"
    local raw_logs
    case "$log_type" in
        "success")
            raw_logs=$(grep -a "$success_pattern" "$log_file" 2>/dev/null || true)
            ;;
        "failure")
            raw_logs=$(grep -a "$failure_pattern" "$log_file" 2>/dev/null || true)
            ;;
        "all")
            raw_logs=$(grep -a -E "$success_pattern|$failure_pattern" "$log_file" 2>/dev/null || true)
            ;;
    esac
    if [[ -z "$raw_logs" ]]; then
        log "WARN" "未找到相关日志记录"
        safe_read "按回车键返回"
        return 0
    fi
    mapfile -t logs < <(echo "$raw_logs" | sort -r)
    local total_records=${#logs[@]}
    local page_size=15
    local total_pages=$(( (total_records + page_size - 1) / page_size ))
    local current_page=1
    while true; do
        show_header
        echo -e "${YELLOW}====== SSH 登录日志 ($log_type) ======${NC}"
        echo -e "${CYAN}总计: $total_records 条记录 | 页面: $current_page / $total_pages${NC}"
        printf "%-20s %-15s %-20s %-10s\n" "时间" "用户名" "来源IP" "状态"
        echo "---------------------------------------------------------------------"
        local start_index=$(( (current_page - 1) * page_size ))
        for i in $(seq 0 $((page_size - 1))); do
            local index=$((start_index + i))
            [[ $index -ge $total_records ]] && break
            local line="${logs[$index]}"
            parse_and_display_log_line "$line"
        done
        echo "---------------------------------------------------------------------"
        local options=""
        [[ $current_page -lt $total_pages ]] && options+="[n] 下一页  "
        [[ $current_page -gt 1 ]] && options+="[p] 上一页  "
        options+="[q] 返回"
        echo -e "${YELLOW}${options}${NC}"
        local nav_choice
        nav_choice=$(safe_read "请选择" "q" 10)
        case "$nav_choice" in
            "n"|"N")
                [[ $current_page -lt $total_pages ]] && ((current_page++))
                ;;
            "p"|"P")
                [[ $current_page -gt 1 ]] && ((current_page--))
                ;;
            "q"|"Q"|"")
                return 0
                ;;
        esac
    done
}
parse_and_display_log_line() {
    local line="$1"
    local parsed
    parsed=$(echo "$line" | awk '
        /Accepted/ {
            time = $1 " " $2 " " $3;
            user = $9;
            ip = $11;
            status = "成功";
            printf "%-20s %-15s %-20s %-10s\n", time, user, ip, status;
        }
        /Failed password/ {
            time = $1 " " $2 " " $3;
            if ($9 == "invalid") {
                user = "invalid_user(" $10 ")";
                ip = $12;
            } else {
                user = $9;
                ip = $11;
            }
            status = "失败";
            printf "%-20s %-15s %-20s %-10s\n", time, user, ip, status;
        }
    ')
    if [[ "$line" =~ "Accepted" ]]; then
        echo -e "${GREEN}${parsed}${NC}"
    else
        echo -e "${RED}${parsed}${NC}"
    fi
}
firewall_management() {
    local fw
    fw=$(get_active_firewall)
    if [[ "$fw" == "none" ]]; then
        install_firewall_menu
        return
    fi
    show_header
    echo -e "${YELLOW}====== 防火墙管理 ======${NC}"
    echo -e "${BLUE}当前活动防火墙: ${fw}${NC}"
    echo -e "${GREEN}1. 查看防火墙状态和规则${NC}"
    echo -e "${GREEN}2. 开放端口${NC}"
    echo -e "${GREEN}3. 关闭端口${NC}"
    echo -e "${GREEN}4. 启用/禁用防火墙${NC}"
    echo -e "${GREEN}5. 切换防火墙系统${NC}"
    echo -e "${GREEN}0. 返回网络工具菜单${NC}"
    echo -e "${CYAN}==============================================${NC}"
    local choice
    choice=$(safe_read "请输入选项 [0-5]" "0")
    case "$choice" in
        1) show_firewall_status "$fw" ;;
        2) open_firewall_port "$fw" ;;
        3) close_firewall_port "$fw" ;;
        4) toggle_firewall "$fw" ;;
        5) switch_firewall_system ;;
        0) network_tools_menu; return ;;
        *) log "WARN" "无效选项"; sleep 1 ;;
    esac
    safe_read "操作完成，按回车键返回"
    firewall_management
}
get_active_firewall() {
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        echo "firewalld"
    elif command_exists ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
        echo "ufw"
    else
        echo "none"
    fi
}
show_firewall_status() {
    local fw="$1"
    echo -e "${YELLOW}--- 防火墙状态 ---${NC}"
    case "$fw" in
        "firewalld")
            firewall-cmd --list-all 2>/dev/null || log "ERROR" "无法获取firewalld状态"
            ;;
        "ufw")
            ufw status verbose 2>/dev/null || log "ERROR" "无法获取ufw状态"
            ;;
        *)
            log "ERROR" "未检测到活动的防火墙"
            ;;
    esac
}
open_firewall_port() {
    local fw="$1"
    local port protocol
    port=$(safe_read "请输入要开放的端口号")
    if [[ ! "$port" =~ ^[0-9]+$ ]] || [[ "$port" -lt 1 || "$port" -gt 65535 ]]; then
        log "ERROR" "无效的端口号"
        return 1
    fi
    protocol=$(safe_read "请输入协议 (tcp/udp)" "tcp")
    if [[ ! "$protocol" =~ ^(tcp|udp)$ ]]; then
        log "ERROR" "无效的协议类型"
        return 1
    fi
    case "$fw" in
        "firewalld")
            if firewall-cmd --permanent --add-port="${port}/${protocol}" && firewall-cmd --reload; then
                log "INFO" "端口 ${port}/${protocol} 已开放"
            else
                log "ERROR" "开放端口失败"
            fi
            ;;
        "ufw")
            if ufw allow "${port}/${protocol}"; then
                log "INFO" "端口 ${port}/${protocol} 已开放"
            else
                log "ERROR" "开放端口失败"
            fi
            ;;
        *)
            log "ERROR" "无法操作防火墙"
            ;;
    esac
}
close_firewall_port() {
    local fw="$1"
    local port protocol
    port=$(safe_read "请输入要关闭的端口号")
    if [[ ! "$port" =~ ^[0-9]+$ ]] || [[ "$port" -lt 1 || "$port" -gt 65535 ]]; then
        log "ERROR" "无效的端口号"
        return 1
    fi
    protocol=$(safe_read "请输入协议 (tcp/udp)" "tcp")
    if [[ ! "$protocol" =~ ^(tcp|udp)$ ]]; then
        log "ERROR" "无效的协议类型"
        return 1
    fi
    case "$fw" in
        "firewalld")
            if firewall-cmd --permanent --remove-port="${port}/${protocol}" && firewall-cmd --reload; then
                log "INFO" "端口 ${port}/${protocol} 已关闭"
            else
                log "ERROR" "关闭端口失败"
            fi
            ;;
        "ufw")
            if ufw delete allow "${port}/${protocol}"; then
                log "INFO" "端口 ${port}/${protocol} 已关闭"
            else
                log "ERROR" "关闭端口失败"
            fi
            ;;
        *)
            log "ERROR" "无法操作防火墙"
            ;;
    esac
}
toggle_firewall() {
    local fw="$1"
    case "$fw" in
        "firewalld")
            if systemctl is-active --quiet firewalld; then
                local confirm
                confirm=$(safe_read "确定要禁用firewalld吗？(y/N)" "N")
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    systemctl disable --now firewalld
                    log "INFO" "Firewalld已禁用"
                fi
            else
                systemctl enable --now firewalld
                log "INFO" "Firewalld已启用"
            fi
            ;;
        "ufw")
            if ufw status | grep -q "Status: active"; then
                local confirm
                confirm=$(safe_read "确定要禁用ufw吗？(y/N)" "N")
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    ufw disable
                    log "INFO" "UFW已禁用"
                fi
            else
                yes | ufw enable
                log "INFO" "UFW已启用"
            fi
            ;;
        *)
            log "ERROR" "没有可管理的防火墙"
            ;;
    esac
}
install_firewall_menu() {
    show_header
    echo -e "${YELLOW}====== 安装防火墙 ======${NC}"
    echo -e "${YELLOW}未检测到活动的防火墙。请选择一个进行安装：${NC}"
    local install_options
    if [[ "$OS_TYPE" == "ubuntu" || "$OS_TYPE" == "debian" ]]; then
        install_options=("UFW (推荐)" "Firewalld" "返回")
    else
        install_options=("Firewalld (推荐)" "UFW" "返回")
    fi
    for i in "${!install_options[@]}"; do
        echo -e "${GREEN}$((i+1)). ${install_options[$i]}${NC}"
    done
    local choice
    choice=$(safe_read "请输入选项" "3")
    case "$choice" in
        1)
            if [[ "$OS_TYPE" == "ubuntu" || "$OS_TYPE" == "debian" ]]; then
                install_ufw
            else
                install_firewalld
            fi
            ;;
        2)
            if [[ "$OS_TYPE" == "ubuntu" || "$OS_TYPE" == "debian" ]]; then
                install_firewalld
            else
                install_ufw
            fi
            ;;
        3)
            network_tools_menu
            return
            ;;
        *)
            log "WARN" "无效选项"
            sleep 1
            install_firewall_menu
            ;;
    esac
    safe_read "操作完成，按回车键继续"
    firewall_management
}
install_ufw() {
    log "INFO" "正在安装UFW..."
    if install_package ufw; then
        if yes | ufw enable; then
            log "INFO" "UFW 安装并启用成功"
        else
            log "ERROR" "UFW 启用失败"
        fi
    else
        log "ERROR" "UFW 安装失败"
    fi
}
install_firewalld() {
    log "INFO" "正在安装Firewalld..."
    if install_package firewalld; then
        if systemctl enable --now firewalld; then
            log "INFO" "Firewalld 安装并启用成功"
        else
            log "ERROR" "Firewalld 启用失败"
        fi
    else
        log "ERROR" "Firewalld 安装失败"
    fi
}
switch_firewall_system() {
    show_header
    echo -e "${YELLOW}====== 切换防火墙系统 ======${NC}"
    echo -e "${RED}警告：切换防火墙将停用当前的防火墙并安装/启用新的防火墙！${NC}"
    echo -e "${RED}现有规则可能会丢失，请确保已备份重要配置。${NC}"
    local switch_options
    if [[ "$OS_TYPE" == "ubuntu" || "$OS_TYPE" == "debian" ]]; then
        switch_options=("切换到 Firewalld" "切换到 UFW (系统默认)" "取消")
    else
        switch_options=("切换到 Firewalld (系统默认)" "切换到 UFW" "取消")
    fi
    for i in "${!switch_options[@]}"; do
        echo -e "${GREEN}$((i+1)). ${switch_options[$i]}${NC}"
    done
    local choice
    choice=$(safe_read "请输入选择" "3")
    local confirm
    case "$choice" in
        1)
            if [[ "$OS_TYPE" == "ubuntu" || "$OS_TYPE" == "debian" ]]; then
                confirm=$(safe_read "确定要切换到 Firewalld 吗? (y/N)" "N")
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    switch_to_firewalld
                fi
            else
                confirm=$(safe_read "确定要切换到 Firewalld 吗? (y/N)" "N")
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    switch_to_firewalld
                fi
            fi
            ;;
        2)
            confirm=$(safe_read "确定要切换到 UFW 吗? (y/N)" "N")
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                switch_to_ufw
            fi
            ;;
        3)
            firewall_management
            return
            ;;
        *)
            log "WARN" "无效选项"
            ;;
    esac
    safe_read "操作完成，按回车键返回"
    firewall_management
}
switch_to_firewalld() {
    log "INFO" "正在切换到 Firewalld..."
    if command_exists ufw; then
        log "INFO" "正在禁用 UFW..."
        ufw disable &>/dev/null || true
    fi
    if ! command_exists firewall-cmd; then
        log "INFO" "正在安装 Firewalld..."
        install_package firewalld
    fi
    log "INFO" "正在启用 Firewalld..."
    systemctl enable --now firewalld
    log "INFO" "已切换到 Firewalld"
}
switch_to_ufw() {
    log "INFO" "正在切换到 UFW..."
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        log "INFO" "正在禁用 Firewalld..."
        systemctl disable --now firewalld
    fi
    if ! command_exists ufw; then
        log "INFO" "正在安装 UFW..."
        install_package ufw
    fi
    log "INFO" "正在启用 UFW..."
    yes | ufw enable
    log "INFO" "已切换到 UFW"
}
bbr_management() {
    show_header
    echo -e "${YELLOW}====== BBR网络加速管理 ======${NC}"
    echo -e "${GREEN}1. 查看BBR状态${NC}"
    echo -e "${GREEN}2. 开启BBR${NC}"
    echo -e "${GREEN}3. 关闭BBR${NC}"
    echo -e "${GREEN}4. BBR参数调优${NC}"
    echo -e "${GREEN}0. 返回网络工具菜单${NC}"
    echo -e "${CYAN}==============================================${NC}"
    local choice
    choice=$(safe_read "请输入选项 [0-4]" "0")
    case "$choice" in
        1) view_bbr_status ;;
        2) enable_bbr ;;
        3) disable_bbr ;;
        4) tune_bbr_parameters ;;
        0) network_tools_menu; return ;;
        *) log "WARN" "无效选项"; sleep 1; bbr_management ;;
    esac
    safe_read "操作完成，按回车键返回"
    bbr_management
}
view_bbr_status() {
    local status qdisc
    status=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "unknown")
    show_header
    echo -e "${YELLOW}====== BBR 状态检查 ======${NC}"
    if [[ "$status" == "bbr" ]]; then
        echo -e "BBR 状态: ${GREEN}✓ 已开启${NC}"
    else
        echo -e "BBR 状态: ${RED}✗ 未开启${NC}"
        echo -e "当前拥塞控制算法: ${YELLOW}${status}${NC}"
    fi
    if [[ "$qdisc" =~ ^(fq|fq_codel)$ ]]; then
        echo -e "队列调度算法: ${GREEN}✓ ${qdisc}${NC}"
    else
        echo -e "队列调度算法: ${YELLOW}${qdisc}${NC} (推荐: fq)"
    fi
    local kernel_version
    kernel_version=$(uname -r | cut -d. -f1-2)
    local kernel_major kernel_minor
    kernel_major=$(echo "$kernel_version" | cut -d. -f1)
    kernel_minor=$(echo "$kernel_version" | cut -d. -f2)
    if [[ $kernel_major -gt 4 ]] || [[ $kernel_major -eq 4 && $kernel_minor -ge 9 ]]; then
        echo -e "内核版本: ${GREEN}✓ ${kernel_version} (支持BBR)${NC}"
    else
        echo -e "内核版本: ${RED}✗ ${kernel_version} (不支持BBR，需要4.9+)${NC}"
    fi
    echo -e "\n${CYAN}--- 内核模块信息 ---${NC}"
    if lsmod | grep -q tcp_bbr; then
        echo -e "tcp_bbr 模块: ${GREEN}✓ 已加载${NC}"
    else
        echo -e "tcp_bbr 模块: ${YELLOW}未加载${NC}"
    fi
    echo -e "\n${CYAN}--- 网络参数 ---${NC}"
    echo "net.ipv4.tcp_congestion_control = $(sysctl -n net.ipv4.tcp_congestion_control)"
    echo "net.core.default_qdisc = $(sysctl -n net.core.default_qdisc)"
    echo "net.ipv4.tcp_notsent_lowat = $(sysctl -n net.ipv4.tcp_notsent_lowat)"
}
enable_bbr() {
    show_header
    echo -e "${YELLOW}====== 开启 BBR ======${NC}"
    local kernel_version
    kernel_version=$(uname -r | cut -d. -f1-2)
    local kernel_major kernel_minor
    kernel_major=$(echo "$kernel_version" | cut -d. -f1)
    kernel_minor=$(echo "$kernel_version" | cut -d. -f2)
    if [[ $kernel_major -lt 4 ]] || [[ $kernel_major -eq 4 && $kernel_minor -lt 9 ]]; then
        if [[ "$OS_TYPE" == "centos7" ]]; then
            log "WARN" "CentOS 7 内核版本过低，需要升级内核才能开启BBR"
            local confirm
            confirm=$(safe_read "是否现在升级内核？升级后需要重启系统 (y/N)" "N")
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                upgrade_centos7_kernel
            else
                log "INFO" "操作已取消"
                return 0
            fi
        else
            log "ERROR" "内核版本过低，无法开启BBR (需要4.9+)"
            return 1
        fi
    fi
    log "INFO" "正在配置BBR参数..."
    local backup_file="/etc/sysctl.conf.backup.$(date +%s)"
    cp /etc/sysctl.conf "$backup_file"
    log "INFO" "已备份当前配置至 $backup_file"
    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    cat >> /etc/sysctl.conf << 'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    if sysctl -p >/dev/null 2>&1; then
        log "INFO" "BBR 配置已应用"
        sleep 1
        local current_cc current_qdisc
        current_cc=$(sysctl -n net.ipv4.tcp_congestion_control)
        current_qdisc=$(sysctl -n net.core.default_qdisc)
        if [[ "$current_cc" == "bbr" && "$current_qdisc" == "fq" ]]; then
            log "INFO" "BBR 已成功开启！"
            echo -e "${GREEN}✓ 拥塞控制算法: $current_cc${NC}"
            echo -e "${GREEN}✓ 队列调度算法: $current_qdisc${NC}"
        else
            log "WARN" "BBR配置可能未完全生效，请重启系统后检查"
        fi
    else
        log "ERROR" "BBR 配置应用失败"
        cp "$backup_file" /etc/sysctl.conf
        return 1
    fi
}
disable_bbr() {
    show_header
    echo -e "${YELLOW}====== 关闭 BBR ======${NC}"
    local confirm
    confirm=$(safe_read "确定要关闭BBR吗？(y/N)" "N")
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log "INFO" "操作已取消"
        return 0
    fi
    local backup_file="/etc/sysctl.conf.backup.$(date +%s)"
    cp /etc/sysctl.conf "$backup_file"
    sed -i '/net.core.default_qdisc=fq/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_congestion_control=bbr/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_moderate_rcvbuf/d' /etc/sysctl.conf
    sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1
    sysctl -w net.core.default_qdisc=pfifo_fast >/dev/null 2>&1
    log "INFO" "BBR 已关闭，拥塞控制算法已恢复为默认值"
    log "INFO" "建议重启系统以确保配置完全生效"
}
tune_bbr_parameters() {
    show_header
    echo -e "${YELLOW}====== BBR 参数调优 ======${NC}"
    local current_cc
    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control)
    if [[ "$current_cc" != "bbr" ]]; then
        log "ERROR" "BBR未开启，请先开启BBR"
        return 1
    fi
    echo -e "${CYAN}当前网络参数：${NC}"
    echo "tcp_window_scaling = $(sysctl -n net.ipv4.tcp_window_scaling)"
    echo "tcp_timestamps = $(sysctl -n net.ipv4.tcp_timestamps)"
    echo "tcp_sack = $(sysctl -n net.ipv4.tcp_sack)"
    echo "tcp_fack = $(sysctl -n net.ipv4.tcp_fack 2>/dev/null || echo 'N/A')"
    local confirm
    confirm=$(safe_read "是否应用BBR高级优化参数？(y/N)" "N")
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        apply_bbr_tuning
    else
        log "INFO" "跳过参数调优"
    fi
}
apply_bbr_tuning() {
    log "INFO" "正在应用BBR高级优化参数..."
    local backup_file="/etc/sysctl.conf.backup.$(date +%s)"
    cp /etc/sysctl.conf "$backup_file"
    cat >> /etc/sysctl.conf << 'EOF'
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_timestamps=1
net.ipv4.tcp_sack=1
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_moderate_rcvbuf=1
net.core.rmem_default=262144
net.core.rmem_max=16777216
net.core.wmem_default=262144
net.core.wmem_max=16777216
net.core.netdev_max_backlog=5000
net.ipv4.tcp_rmem=4096 65536 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
EOF
    if sysctl -p >/dev/null 2>&1; then
        log "INFO" "BBR高级优化参数已应用"
    else
        log "ERROR" "参数应用失败，恢复备份"
        cp "$backup_file" /etc/sysctl.conf
    fi
}
upgrade_centos7_kernel() {
    log "INFO" "正在为CentOS 7升级内核..."
    if ! rpm --import https://www.elrepo.org/RPM-GPG-KEY-elrepo.org; then
        log "ERROR" "导入GPG密钥失败"
        return 1
    fi
    if ! yum install -y https://www.elrepo.org/elrepo-release-7.el7.elrepo.noarch.rpm; then
        log "ERROR" "安装ELRepo失败"
        return 1
    fi
    log "INFO" "正在安装最新主线内核，这可能需要几分钟..."
    if ! yum --enablerepo=elrepo-kernel install -y kernel-ml; then
        log "ERROR" "内核安装失败"
        return 1
    fi
    if grub2-set-default 0; then
        log "INFO" "内核升级完成！"
        log "WARN" "请立即重启系统: reboot"
        log "WARN" "重启后再次运行此脚本来开启BBR"
    else
        log "ERROR" "设置默认内核失败"
    fi
}
list_used_ports() {
    show_header
    echo -e "${YELLOW}====== 已占用端口列表 ======${NC}"
    if ! command_exists ss && ! command_exists netstat; then
        log "ERROR" "未找到 ss 或 netstat 命令"
        install_net_tools
        return 1
    fi
    echo -e "${CYAN}正在扫描已占用的端口...${NC}"
    printf "%-10s %-8s %-20s %-15s %s\n" "协议" "状态" "本地地址" "外部地址" "进程"
    echo "-------------------------------------------------------------------------"
    if command_exists ss; then
        ss -tuln | awk 'NR>1 {
            split($5, local, ":");
            port = local[length(local)];
            if (port != "*" && port ~ /^[0-9]+$/) {
                printf "%-10s %-8s %-20s %-15s %s\n", $1, $2, $5, $6, $7;
            }
        }' | sort -k3 -t: -n
    else
        netstat -tuln | awk 'NR>2 && $6=="LISTEN" {
            split($4, local, ":");
            port = local[length(local)];
            printf "%-10s %-8s %-20s %-15s %s\n", $1, "LISTEN", $4, "-", "-";
        }' | sort -k3 -t: -n
    fi
    echo
    echo -e "${CYAN}常用端口说明：${NC}"
    echo "22/tcp   - SSH"
    echo "80/tcp   - HTTP"
    echo "443/tcp  - HTTPS"
    echo "3306/tcp - MySQL"
    echo "6379/tcp - Redis"
    echo "8888/tcp - 宝塔面板"
    safe_read "按回车键返回"
    network_tools_menu
}
install_net_tools() {
    local confirm
    confirm=$(safe_read "需要安装网络工具包，是否继续？(y/N)" "Y")
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        case "$OS_TYPE" in
            "ubuntu"|"debian")
                install_package net-tools
                ;;
            "centos7"|"centos8")
                install_package net-tools
                ;;
        esac
    fi
}
main() {
    trap 'echo -e "\n${YELLOW}程序被中断${NC}"; cleanup; exit 130' INT TERM
    check_root "$@"
    detect_os
    init_config
    if [[ "${1:-}" == "--version" ]]; then
        echo "Linux 工具箱版本: $SCRIPT_VERSION"
        exit 0
    fi
    if [[ "${1:-}" == "--help" ]]; then
        show_help
        exit 0
    fi
    main_menu
}
show_help() {
    cat << EOF
Linux 工具箱 v$SCRIPT_VERSION
用法: $0 [选项]
选项:
  --help      显示此帮助信息
  --version   显示版本信息
功能:
  - 系统管理工具 (清理、用户管理、内核管理)
  - 网络与安全工具 (防火墙、BBR、日志查看)
  - 一键换源加速
  - 面板安装 (宝塔、1Panel等)
  - 工具箱管理
项目地址: https://github.com/GamblerIX/linux-toolbox
EOF
}
main "$@"