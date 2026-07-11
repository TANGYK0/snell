#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

# ============================================================
# Snell Server Installer
# Supported:
#   Debian / Ubuntu / CentOS / RHEL / Rocky / AlmaLinux
#   Fedora / Arch Linux
#
# Usage:
#   bash snell-install.sh install
#   bash snell-install.sh install 30000
#   bash snell-install.sh status
#   bash snell-install.sh restart
#   bash snell-install.sh show
#   bash snell-install.sh uninstall
# ============================================================

readonly SCRIPT_NAME="$(basename "$0")"
readonly SNELL_VERSION="5.0.1"
readonly SNELL_BASE_URL="https://dl.nssurge.com/snell"
readonly INSTALL_PATH="/usr/local/bin/snell-server"
readonly CONFIG_DIR="/etc/snell"
readonly CONFIG_FILE="${CONFIG_DIR}/snell-server.conf"
readonly SERVICE_FILE="/etc/systemd/system/snell.service"
readonly SYSCTL_FILE="/etc/sysctl.d/99-snell-bbr.conf"
readonly STATE_FILE="${CONFIG_DIR}/install.env"

TEMP_DIR=""
PACKAGE_MANAGER=""
DOWNLOAD_TOOL=""

ACTION="${1:-install}"
CUSTOM_PORT="${2:-}"

log_info() {
    printf '\033[1;34m[INFO]\033[0m %s\n' "$*"
}

log_ok() {
    printf '\033[1;32m[OK]\033[0m %s\n' "$*"
}

log_warn() {
    printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2
}

log_error() {
    printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2
}

cleanup() {
    if [[ -n "${TEMP_DIR:-}" && -d "${TEMP_DIR}" ]]; then
        rm -rf "${TEMP_DIR}"
    fi
}

error_handler() {
    local exit_code=$?
    local line_number="${1:-unknown}"

    log_error "脚本执行失败。"
    log_error "退出代码: ${exit_code}"
    log_error "错误行号: ${line_number}"

    cleanup
    exit "${exit_code}"
}

trap 'error_handler "${LINENO}"' ERR
trap cleanup EXIT

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        log_error "请使用 root 用户运行此脚本。"
        log_error "示例: sudo bash ${SCRIPT_NAME} install"
        exit 1
    fi
}

require_systemd() {
    if ! command -v systemctl >/dev/null 2>&1; then
        log_error "当前系统未检测到 systemd，无法创建 Snell 服务。"
        exit 1
    fi

    if [[ ! -d /run/systemd/system ]]; then
        log_error "当前环境没有运行 systemd。"
        log_error "如果这是 Docker 容器，请使用支持 systemd 的容器或直接运行 snell-server。"
        exit 1
    fi
}

detect_package_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        PACKAGE_MANAGER="apt"
    elif command -v dnf >/dev/null 2>&1; then
        PACKAGE_MANAGER="dnf"
    elif command -v yum >/dev/null 2>&1; then
        PACKAGE_MANAGER="yum"
    elif command -v pacman >/dev/null 2>&1; then
        PACKAGE_MANAGER="pacman"
    elif command -v zypper >/dev/null 2>&1; then
        PACKAGE_MANAGER="zypper"
    elif command -v apk >/dev/null 2>&1; then
        PACKAGE_MANAGER="apk"
    else
        log_error "未找到支持的包管理器。"
        log_error "支持 apt-get、dnf、yum、pacman、zypper、apk。"
        exit 1
    fi

    log_info "检测到包管理器: ${PACKAGE_MANAGER}"
}

install_dependencies() {
    log_info "安装依赖..."

    case "${PACKAGE_MANAGER}" in
        apt)
            apt-get update
            DEBIAN_FRONTEND=noninteractive apt-get install -y \
                ca-certificates \
                curl \
                wget \
                unzip \
                iproute2
            ;;

        dnf)
            dnf install -y \
                ca-certificates \
                curl \
                wget \
                unzip \
                iproute
            ;;

        yum)
            yum install -y \
                ca-certificates \
                curl \
                wget \
                unzip \
                iproute
            ;;

        pacman)
            pacman -Sy --noconfirm \
                ca-certificates \
                curl \
                wget \
                unzip \
                iproute2
            ;;

        zypper)
            zypper --non-interactive refresh
            zypper --non-interactive install \
                ca-certificates \
                curl \
                wget \
                unzip \
                iproute2
            ;;

        apk)
            apk add --no-cache \
                ca-certificates \
                curl \
                wget \
                unzip \
                iproute2
            ;;

        *)
            log_error "不支持的包管理器: ${PACKAGE_MANAGER}"
            exit 1
            ;;
    esac

    update-ca-certificates >/dev/null 2>&1 || true

    if command -v curl >/dev/null 2>&1; then
        DOWNLOAD_TOOL="curl"
    elif command -v wget >/dev/null 2>&1; then
        DOWNLOAD_TOOL="wget"
    else
        log_error "curl 和 wget 均不可用。"
        exit 1
    fi

    log_ok "依赖安装完成。"
}

detect_architecture() {
    local machine
    machine="$(uname -m)"

    case "${machine}" in
        x86_64|amd64)
            printf '%s\n' "amd64"
            ;;

        i386|i486|i586|i686)
            printf '%s\n' "i386"
            ;;

        aarch64|arm64)
            printf '%s\n' "aarch64"
            ;;

        armv7l|armv7)
            printf '%s\n' "armv7l"
            ;;

        *)
            log_error "不支持的 CPU 架构: ${machine}"
            exit 1
            ;;
    esac
}

download_file() {
    local url="$1"
    local output_file="$2"

    if [[ "${DOWNLOAD_TOOL}" == "curl" ]]; then
        curl \
            --fail \
            --location \
            --show-error \
            --silent \
            --connect-timeout 15 \
            --retry 3 \
            --retry-delay 2 \
            --output "${output_file}" \
            "${url}"
    else
        wget \
            --quiet \
            --timeout=15 \
            --tries=3 \
            --output-document="${output_file}" \
            "${url}"
    fi
}

download_snell() {
    local architecture
    local package_name
    local package_url
    local zip_file
    local extracted_binary

    architecture="$(detect_architecture)"
    package_name="snell-server-v${SNELL_VERSION}-linux-${architecture}.zip"
    package_url="${SNELL_BASE_URL}/${package_name}"

    TEMP_DIR="$(mktemp -d)"
    zip_file="${TEMP_DIR}/snell.zip"

    log_info "CPU 架构: ${architecture}"
    log_info "下载 Snell Server v${SNELL_VERSION}..."
    log_info "下载地址: ${package_url}"

    download_file "${package_url}" "${zip_file}"

    if [[ ! -s "${zip_file}" ]]; then
        log_error "下载文件为空。"
        exit 1
    fi

    unzip -q -o "${zip_file}" -d "${TEMP_DIR}"

    extracted_binary="$(find "${TEMP_DIR}" \
        -type f \
        -name "snell-server" \
        -print \
        -quit)"

    if [[ -z "${extracted_binary}" ]]; then
        log_error "压缩包中未找到 snell-server。"
        exit 1
    fi

    if [[ -f "${INSTALL_PATH}" ]]; then
        cp -a \
            "${INSTALL_PATH}" \
            "${INSTALL_PATH}.bak.$(date '+%Y%m%d%H%M%S')"
    fi

    install \
        -o root \
        -g root \
        -m 0755 \
        "${extracted_binary}" \
        "${INSTALL_PATH}"

    if [[ ! -x "${INSTALL_PATH}" ]]; then
        log_error "Snell Server 安装失败。"
        exit 1
    fi

    log_ok "Snell Server 已安装到 ${INSTALL_PATH}"
}

validate_port() {
    local port="$1"

    if [[ ! "${port}" =~ ^[0-9]+$ ]]; then
        return 1
    fi

    if ((port < 1 || port > 65535)); then
        return 1
    fi

    return 0
}

port_is_available() {
    local port="$1"

    if command -v ss >/dev/null 2>&1; then
        if ss -H -lntu 2>/dev/null |
            awk '{print $5}' |
            grep -Eq "(^|:|\])${port}$"; then
            return 1
        fi
    elif command -v netstat >/dev/null 2>&1; then
        if netstat -lntu 2>/dev/null |
            awk '{print $4}' |
            grep -Eq "(^|:|\])${port}$"; then
            return 1
        fi
    else
        log_warn "无法检测端口占用，将直接使用端口 ${port}。"
    fi

    return 0
}

find_free_port() {
    local attempt
    local candidate

    for ((attempt = 1; attempt <= 300; attempt++)); do
        candidate="$(
            od -An -N4 -tu4 /dev/urandom |
                awk '{print 20000 + ($1 % 20001)}'
        )"

        if port_is_available "${candidate}"; then
            printf '%s\n' "${candidate}"
            return 0
        fi
    done

    return 1
}

determine_port()
