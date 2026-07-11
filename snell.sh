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

determine_port() {
    local port

    if [[ -n "${CUSTOM_PORT}" ]]; then
        port="${CUSTOM_PORT}"

        if ! validate_port "${port}"; then
            log_error "端口无效: ${port}"
            log_error "有效范围为 1 到 65535。"
            exit 1
        fi

        if ! port_is_available "${port}"; then
            log_error "端口 ${port} 已被占用。"
            exit 1
        fi
    else
        port="$(find_free_port)" || {
            log_error "未能找到空闲端口。"
            exit 1
        }
    fi

    printf '%s\n' "${port}"
}

generate_psk() {
    local psk

    if command -v openssl >/dev/null 2>&1; then
        psk="$(openssl rand -hex 24)"
    else
        psk="$(
            od -An -N32 -tx1 /dev/urandom |
                tr -d ' \n'
        )"
    fi

    if [[ -z "${psk}" ]]; then
        log_error "生成 PSK 失败。"
        exit 1
    fi

    printf '%s\n' "${psk}"
}

backup_file() {
    local file_path="$1"

    if [[ -f "${file_path}" ]]; then
        cp -a \
            "${file_path}" \
            "${file_path}.bak.$(date '+%Y%m%d%H%M%S')"
    fi
}

write_config() {
    local port="$1"
    local psk="$2"

    mkdir -p "${CONFIG_DIR}"
    backup_file "${CONFIG_FILE}"

    cat >"${CONFIG_FILE}" <<EOF
[snell-server]
listen = 0.0.0.0:${port}
psk = ${psk}
ipv6 = false
EOF

    chown root:root "${CONFIG_FILE}"
    chmod 0600 "${CONFIG_FILE}"

    cat >"${STATE_FILE}" <<EOF
SNELL_VERSION='${SNELL_VERSION}'
SNELL_PORT='${port}'
SNELL_PSK='${psk}'
EOF

    chown root:root "${STATE_FILE}"
    chmod 0600 "${STATE_FILE}"

    log_ok "配置文件已写入 ${CONFIG_FILE}"
}

configure_bbr() {
    local congestion_controls=""
    local current_control=""

    log_info "配置 BBR..."

    modprobe tcp_bbr >/dev/null 2>&1 || true

    cat >"${SYSCTL_FILE}" <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

    chmod 0644 "${SYSCTL_FILE}"

    # 不执行 sysctl -p，避免加载 /etc/sysctl.conf 中错误的 eth1 配置。
    if sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 &&
        sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1; then
        congestion_controls="$(
            sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null ||
                true
        )"

        current_control="$(
            sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null ||
                true
        )"

        if [[ " ${congestion_controls} " == *" bbr "* &&
            "${current_control}" == "bbr" ]]; then
            log_ok "BBR 已启用。"
            return 0
        fi
    fi

    log_warn "当前内核可能不支持 BBR，Snell 仍可正常安装和运行。"
    log_warn "可用拥塞算法: ${congestion_controls:-未知}"
}

open_firewall_port() {
    local port="$1"
    local opened="false"

    log_info "检查防火墙..."

    if command -v firewall-cmd >/dev/null 2>&1 &&
        systemctl is-active --quiet firewalld; then

        firewall-cmd \
            --permanent \
            --add-port="${port}/tcp" >/dev/null

        firewall-cmd \
            --permanent \
            --add-port="${port}/udp" >/dev/null

        firewall-cmd --reload >/dev/null

        log_ok "firewalld 已放行 TCP/UDP 端口 ${port}。"
        opened="true"
    fi

    if [[ "${opened}" == "false" ]] &&
        command -v ufw >/dev/null 2>&1; then

        local ufw_status
        ufw_status="$(ufw status 2>/dev/null | head -n 1 || true)"

        if [[ "${ufw_status}" == *"active"* ]]; then
            ufw allow "${port}/tcp" >/dev/null
            ufw allow "${port}/udp" >/dev/null

            log_ok "ufw 已放行 TCP/UDP 端口 ${port}。"
            opened="true"
        fi
    fi

    if [[ "${opened}" == "false" ]] &&
        command -v nft >/dev/null 2>&1; then

        if nft list ruleset 2>/dev/null |
            grep -qE 'hook[[:space:]]+input'; then
            log_warn "检测到 nftables，但未自动修改规则。"
            log_warn "请确认 TCP/UDP 端口 ${port} 已放行。"
            opened="true"
        fi
    fi

    if [[ "${opened}" == "false" ]] &&
        command -v iptables >/dev/null 2>&1; then

        if ! iptables -C INPUT \
            -p tcp \
            --dport "${port}" \
            -j ACCEPT 2>/dev/null; then

            iptables -I INPUT \
                -p tcp \
                --dport "${port}" \
                -j ACCEPT
        fi

        if ! iptables -C INPUT \
            -p udp \
            --dport "${port}" \
            -j ACCEPT 2>/dev/null; then

            iptables -I INPUT \
                -p udp \
                --dport "${port}" \
                -j ACCEPT
        fi

        log_warn "iptables 已临时放行 TCP/UDP 端口 ${port}。"
        log_warn "重启后规则可能失效，请根据系统保存 iptables 规则。"
        opened="true"
    fi

    if [[ "${opened}" == "false" ]]; then
        log_warn "未检测到已启用的防火墙管理工具。"
        log_warn "请在云服务器安全组中放行 TCP/UDP 端口 ${port}。"
    fi
}

write_systemd_service() {
    backup_file "${SERVICE_FILE}"

    cat >"${SERVICE_FILE}" <<EOF
[Unit]
Description=Snell Proxy Server
Documentation=https://kb.nssurge.com/surge-knowledge-base/release-notes/snell
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
ExecStart=${INSTALL_PATH} -c ${CONFIG_FILE}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
ReadWritePaths=${CONFIG_DIR}

[Install]
WantedBy=multi-user.target
EOF

    chmod 0644 "${SERVICE_FILE}"

    systemctl daemon-reload
    systemctl enable snell.service >/dev/null
    systemctl restart snell.service

    sleep 2

    if ! systemctl is-active --quiet snell.service; then
        log_error "Snell 服务启动失败。"
        systemctl status snell.service --no-pager -l || true
        journalctl -u snell.service -n 50 --no-pager || true
        exit 1
    fi

    log_ok "Snell 服务已启动。"
}

get_public_ipv4() {
    local services=(
        "https://api.ipify.org"
        "https://ifconfig.me/ip"
        "https://icanhazip.com"
        "https://ipinfo.io/ip"
    )

    local service
    local ip=""

    for service in "${services[@]}"; do
        if command -v curl >/dev/null 2>&1; then
            ip="$(
                curl \
                    -4 \
                    --fail \
                    --silent \
                    --show-error \
                    --connect-timeout 5 \
                    --max-time 8 \
                    "${service}" 2>/dev/null ||
                    true
            )"
        else
            ip="$(
                wget \
                    -qO- \
                    --timeout=8 \
                    "${service}" 2>/dev/null ||
                    true
            )"
        fi

        ip="$(printf '%s' "${ip}" | tr -d '[:space:]')"

        if [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            printf '%s\n' "${ip}"
            return 0
        fi
    done

    printf '%s\n' "SERVER_IP"
}

get_city() {
    local city="Snell"

    if command -v curl >/dev/null 2>&1; then
        city="$(
            curl \
                --fail \
                --silent \
                --show-error \
                --connect-timeout 5 \
                --max-time 8 \
                "https://ipinfo.io/city" 2>/dev/null ||
                true
        )"
    fi

    city="$(printf '%s' "${city}" | tr -d '\r\n')"

    if [[ -z "${city}" ]]; then
        city="Snell"
    fi

    printf '%s\n' "${city}"
}

verify_listening_port() {
    local port="$1"

    if command -v ss >/dev/null 2>&1; then
        if ss -H -lntup 2>/dev/null |
            grep -Eq "(^|:|\])${port}([[:space:]]|$)"; then
            log_ok "检测到 Snell 正在监听端口 ${port}。"
            return 0
        fi
    fi

    log_warn "暂未从 ss 输出中确认监听端口，请检查服务日志。"
    return 0
}

show_configuration() {
    local port=""
    local psk=""
    local public_ip
    local city

    if [[ -f "${STATE_FILE}" ]]; then
        # shellcheck disable=SC1090
        source "${STATE_FILE}"
        port="${SNELL_PORT:-}"
        psk="${SNELL_PSK:-}"
    fi

    if [[ -z "${port}" || -z "${psk}" ]] &&
        [[ -f "${CONFIG_FILE}" ]]; then

        port="$(
            awk -F':' \
                '/^[[:space:]]*listen[[:space:]]*=/{print $NF}' \
                "${CONFIG_FILE}" |
                tr -d '[:space:]'
        )"

        psk="$(
            awk -F'=' \
                '/^[[:space:]]*psk[[:space:]]*=/{print $2}' \
                "${CONFIG_FILE}" |
                xargs
        )"
    fi

    if [[ -z "${port}" || -z "${psk}" ]]; then
        log_error "未找到 Snell 配置信息。"
        exit 1
    fi

    public_ip="$(get_public_ipv4)"
    city="$(get_city)"

    printf '\n'
    printf '%s\n' "============================================================"
    printf '%s\n' " Snell Server 配置信息"
    printf '%s\n' "============================================================"
    printf ' 版本      : %s\n' "${SNELL_VERSION}"
    printf ' 服务状态  : %s\n' "$(
        systemctl is-active snell.service 2>/dev/null ||
            printf '%s' "unknown"
    )"
    printf ' 配置文件  : %s\n' "${CONFIG_FILE}"
    printf ' 公网 IP   : %s\n' "${public_ip}"
    printf ' 监听端口  : %s\n' "${port}"
    printf ' PSK       : %s\n' "${psk}"
    printf '\n'
    printf '%s\n' "Surge 配置："
    printf '%s = snell, %s, %s, psk=%s, version=5, tfo=true\n' \
        "${city}" \
        "${public_ip}" \
        "${port}" \
        "${psk}"
    printf '\n'
    printf '%s\n' "兼容 v4 客户端配置："
    printf '%s = snell, %s, %s, psk=%s, version=4, tfo=true\n' \
        "${city}" \
        "${public_ip}" \
        "${port}" \
        "${psk}"
    printf '%s\n' "============================================================"
    printf '\n'

    log_warn "还需要在云服务商安全组中放行 TCP/UDP 端口 ${port}。"
}

install_snell() {
    local port
    local psk

    require_root
    require_systemd
    detect_package_manager
    install_dependencies

    port="$(determine_port)"
    psk="$(generate_psk)"

    log_info "使用端口: ${port}"

    download_snell
    write_config "${port}" "${psk}"
    configure_bbr
    open_firewall_port "${port}"
    write_systemd_service
    verify_listening_port "${port}"
    show_configuration
}

show_status() {
    require_root
    require_systemd

    systemctl status snell.service --no-pager -l || true

    printf '\n'
    journalctl \
        -u snell.service \
        -n 30 \
        --no-pager || true
}

restart_snell() {
    require_root
    require_systemd

    systemctl restart snell.service

    if systemctl is-active --quiet snell.service; then
        log_ok "Snell 服务已重启。"
    else
        log_error "Snell 服务重启失败。"
        systemctl status snell.service --no-pager -l || true
        exit 1
    fi
}

uninstall_snell() {
    local port=""

    require_root
    require_systemd

    if [[ -f "${STATE_FILE}" ]]; then
        # shellcheck disable=SC1090
        source "${STATE_FILE}"
        port="${SNELL_PORT:-}"
    fi

    log_warn "即将删除以下内容："
    log_warn "服务文件: ${SERVICE_FILE}"
    log_warn "程序文件: ${INSTALL_PATH}"
    log_warn "配置目录: ${CONFIG_DIR}"
    log_warn "BBR 配置: ${SYSCTL_FILE}"

    read -r -p "确认卸载 Snell？输入 YES 继续: " confirmation

    if [[ "${confirmation}" != "YES" ]]; then
        log_info "已取消卸载。"
        exit 0
    fi

    systemctl disable --now snell.service >/dev/null 2>&1 || true

    rm -f "${SERVICE_FILE}"
    rm -f "${INSTALL_PATH}"
    rm -f "${SYSCTL_FILE}"
    rm -rf "${CONFIG_DIR}"

    systemctl daemon-reload
    systemctl reset-failed >/dev/null 2>&1 || true

    log_ok "Snell 已卸载。"

    if [[ -n "${port}" ]]; then
        log_warn "未自动删除防火墙规则。"
        log_warn "原 Snell 端口为 ${port}，请按需手动关闭。"
    fi
}

show_help() {
    cat <<EOF
用法：

  bash ${SCRIPT_NAME} install
      自动选择 20000 到 40000 之间的空闲端口并安装。

  bash ${SCRIPT_NAME} install 30000
      使用指定端口 30000 安装。

  bash ${SCRIPT_NAME} status
      查看服务状态及最近日志。

  bash ${SCRIPT_NAME} restart
      重启 Snell 服务。

  bash ${SCRIPT_NAME} show
      显示当前 Snell 和 Surge 配置信息。

  bash ${SCRIPT_NAME} uninstall
      卸载 Snell。

  bash ${SCRIPT_NAME} help
      显示帮助。
EOF
}

main() {
    case "${ACTION}" in
        install)
            install_snell
            ;;

        status)
            show_status
            ;;

        restart)
            restart_snell
            ;;

        show)
            require_root
            require_systemd
            show_configuration
            ;;

        uninstall)
            uninstall_snell
            ;;

        help|-h|--help)
            show_help
            ;;

        *)
            log_error "未知操作: ${ACTION}"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
