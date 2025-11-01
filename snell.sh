#!/bin/bash
set -e

# ===== 1. 安装依赖 =====
if grep -qiE "debian|ubuntu|armbian|deepin|mint" /etc/*-release; then
    sudo apt-get update -y
    sudo apt-get install -y wget unzip
elif grep -qiE "centos|red hat|redhat" /etc/*-release; then
    sudo yum install -y wget unzip
elif grep -qiE "arch|manjaro" /etc/*-release; then
    sudo pacman -S --noconfirm wget unzip
elif grep -qiE "fedora" /etc/*-release; then
    sudo dnf install -y wget unzip
fi

# ===== 2. 开 BBR （可选）=====
echo "net.core.default_qdisc=fq" | sudo tee -a /etc/sysctl.conf >/dev/null
echo "net.ipv4.tcp_congestion_control=bbr" | sudo tee -a /etc/sysctl.conf >/dev/null
sudo sysctl -p >/dev/null
sudo sysctl net.ipv4.tcp_available_congestion_control

# ===== 3. 下载 snell =====
cd
ARCH=$(uname -m)
BASE_URL="https://dl.nssurge.com/snell/snell-server-v5.0.0-linux"
case "$ARCH" in
    x86_64)   PACKAGE="${BASE_URL}-amd64.zip" ;;
    i686|i386) PACKAGE="${BASE_URL}-i386.zip" ;;
    aarch64)  PACKAGE="${BASE_URL}-aarch64.zip" ;;
    armv7l)   PACKAGE="${BASE_URL}-armv7l.zip" ;;
    *)
        echo "Unsupported architecture: $ARCH"
        exit 1
        ;;
esac

wget -q -O snell.zip "$PACKAGE"
unzip -o snell.zip
rm -rf snell.zip
mv snell-server /usr/bin/snell-server
chmod +x /usr/bin/snell-server

# ===== 4. 生成一个可用端口 =====
find_free_port() {
    # 优先用 ss，没有就用 netstat
    for i in $(seq 1 200); do
        PORT=$((RANDOM % 39000 + 10000))   # 20000-40000 之间
        if command -v ss >/dev/null 2>&1; then
            if ! ss -tuln | awk '{print $5}' | grep -q ":$PORT\$"; then
                echo "$PORT"
                return 0
            fi
        else
            if ! netstat -tuln 2>/dev/null | awk '{print $4}' | grep -q ":$PORT\$"; then
                echo "$PORT"
                return 0
            fi
        fi
    done
    return 1
}

PORT=$(find_free_port) || { echo "没有找到空闲端口"; exit 1; }
echo "✅ 使用端口: $PORT"

# ===== 5. 生成配置文件 =====
# snell 默认第一次运行会要你输入信息，我们自己写配置就行
CONF_DIR="/etc/snell"
sudo mkdir -p "$CONF_DIR"
CONF_FILE="$CONF_DIR/snell-server.conf"

# 生成一个 psk
PSK=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)

# Snell v5 的配置格式是 key=value 的那种
sudo bash -c "cat > $CONF_FILE" <<EOF
[snell-server]
listen = 0.0.0.0:$PORT
psk = $PSK
ipv6 = false
obfs = tls
version = 5
EOF

sudo chmod 600 "$CONF_FILE"

# ===== 6. 放行防火墙 =====
open_firewall_port() {
    local port="$1"

    # firewalld
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
        sudo firewall-cmd --add-port=${port}/tcp --permanent >/dev/null 2>&1 || true
        sudo firewall-cmd --add-port=${port}/udp --permanent >/dev/null 2>&1 || true
        sudo firewall-cmd --reload >/dev/null 2>&1 || true
        echo "✅ firewalld 已放行端口 ${port}"
        return
    fi

    # ufw
    if command -v ufw >/dev/null 2>&1; then
        sudo ufw allow ${port}/tcp >/dev/null 2>&1 || true
        sudo ufw allow ${port}/udp >/dev/null 2>&1 || true
        echo "✅ ufw 已放行端口 ${port}"
        return
    fi

    # 退而求其次：iptables
    if command -v iptables >/dev/null 2>&1; then
        sudo iptables -I INPUT -p tcp --dport ${port} -j ACCEPT
        sudo iptables -I INPUT -p udp --dport ${port} -j ACCEPT
        # 这里不保存是因为各发行版命令不一样，留给你自己处理
        echo "✅ iptables 已临时放行端口 ${port}"
        return
    fi

    echo "⚠️ 没发现可用防火墙管理工具，端口 ${port} 需要你手动放行"
}

open_firewall_port "$PORT"

# ===== 7. 写 systemd =====
sudo bash -c "cat > /etc/systemd/system/snell.service" <<EOF
[Unit]
Description=Snell Server
After=network.target

[Service]
User=root
ExecStart=/usr/bin/snell-server -c /etc/snell/snell-server.conf
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now snell
sudo systemctl restart snell

# ===== 8. 打印出来给你贴 Surge/Clash =====
PUBLIC_IP=$(curl -s https://ipinfo.io/ip || curl -s https://ifconfig.me || echo "SERVER_IP")
CITY=$(curl -s https://ipinfo.io/city || echo "Snell")
echo
echo "================================================="
echo " Snell 已安装并启动"
echo " 配置文件: $CONF_FILE"
echo " 监听端口: $PORT"
echo " PSK      : $PSK"
echo
echo "Surge/Clash 可用示例："
echo "${CITY} = snell, ${PUBLIC_IP}, ${PORT}, psk=${PSK}, version=5, tfo=true"
echo "================================================="
