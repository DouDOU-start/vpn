#!/bin/bash

# Mihomo 管理脚本 (3X-UI 订阅版)
# 功能: 订阅管理、节点切换、模式切换、状态查看

CONFIG_DIR="/etc/mihomo"
CONFIG_FILE="$CONFIG_DIR/config.yaml"
SUB_FILE="$CONFIG_DIR/subscription.txt"
API_URL="http://127.0.0.1:9090"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 打印函数
info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
title() { echo -e "${CYAN}$1${NC}"; }

# 检查 root 权限
check_root() {
    [ "$EUID" -ne 0 ] && { error "请使用 root 权限运行"; exit 1; }
}

# 检查服务状态
check_status() {
    if systemctl is-active --quiet mihomo; then
        echo -e "${GREEN}● 运行中${NC}"
    else
        echo -e "${RED}○ 已停止${NC}"
    fi
}

# 获取当前模式
get_mode() {
    if [ -f "$CONFIG_FILE" ]; then
        if grep -q "tun:" "$CONFIG_FILE" && grep -q "enable: true" "$CONFIG_FILE"; then
            echo "TUN"
        else
            echo "代理"
        fi
    else
        echo "未配置"
    fi
}

# 获取当前节点
get_current_proxy() {
    local result=$(curl -s "$API_URL/proxies/代理" 2>/dev/null)
    if [ -n "$result" ]; then
        echo "$result" | grep -oP '"now"\s*:\s*"\K[^"]+' || echo "未知"
    else
        echo "无法获取"
    fi
}

# 获取节点列表
get_proxy_list() {
    curl -s "$API_URL/proxies/代理" 2>/dev/null | grep -oP '"all"\s*:\s*\[\K[^\]]+' | tr ',' '\n' | tr -d '"' | grep -v "DIRECT"
}

# 切换节点
switch_proxy() {
    local proxy_name="$1"
    curl -s -X PUT "$API_URL/proxies/代理" \
        -H "Content-Type: application/json" \
        -d "{\"name\": \"$proxy_name\"}" > /dev/null 2>&1

    if [ $? -eq 0 ]; then
        info "已切换到: $proxy_name"
    else
        error "切换失败"
    fi
}

# 切换运行模式
switch_mode() {
    local mode="$1"

    if [ ! -f "$CONFIG_FILE" ]; then
        error "配置文件不存在"
        return
    fi

    if [ "$mode" = "tun" ]; then
        # 启用 TUN 模式
        if grep -q "tun:" "$CONFIG_FILE"; then
            sed -i 's/enable: false/enable: true/' "$CONFIG_FILE"
        else
            # 在 external-controller 后添加 TUN 配置
            sed -i '/external-controller:/a\
\
# TUN 透明代理模式\
tun:\
  enable: true\
  stack: system\
  auto-route: true\
  auto-detect-interface: true\
  dns-hijack:\
    - any:53' "$CONFIG_FILE"
        fi
        info "已切换到 TUN 透明代理模式"
    else
        # 禁用 TUN 模式
        if grep -q "tun:" "$CONFIG_FILE"; then
            sed -i 's/enable: true/enable: false/' "$CONFIG_FILE"
        fi
        info "已切换到 HTTP/SOCKS5 代理模式"
    fi

    systemctl restart mihomo
    sleep 2
    info "服务已重启"
}

# 测试连接
test_connection() {
    local mode=$(get_mode)

    echo ""
    info "正在测试连接..."
    echo ""

    # 测试国内
    echo -n "  国内连接 (百度): "
    if [ "$mode" = "TUN" ]; then
        result=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 https://www.baidu.com 2>/dev/null)
    else
        result=$(curl -s -o /dev/null -w "%{http_code}" -x http://127.0.0.1:7890 --connect-timeout 5 https://www.baidu.com 2>/dev/null)
    fi
    [ "$result" = "200" ] && echo -e "${GREEN}✓ 成功${NC}" || echo -e "${RED}✗ 失败${NC}"

    # 测试国外
    echo -n "  国外连接 (Google): "
    if [ "$mode" = "TUN" ]; then
        result=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 https://www.google.com 2>/dev/null)
    else
        result=$(curl -s -o /dev/null -w "%{http_code}" -x http://127.0.0.1:7890 --connect-timeout 10 https://www.google.com 2>/dev/null)
    fi
    [ "$result" = "200" ] && echo -e "${GREEN}✓ 成功${NC}" || echo -e "${RED}✗ 失败${NC}"

    # 获取出口 IP
    echo -n "  出口 IP: "
    if [ "$mode" = "TUN" ]; then
        ip=$(curl -s --connect-timeout 10 https://api.ip.sb/ip 2>/dev/null)
    else
        ip=$(curl -s -x http://127.0.0.1:7890 --connect-timeout 10 https://api.ip.sb/ip 2>/dev/null)
    fi
    [ -n "$ip" ] && echo -e "${CYAN}$ip${NC}" || echo -e "${RED}获取失败${NC}"
    echo ""
}

# 显示状态
show_status() {
    echo ""
    title "========== Mihomo 状态 =========="
    echo ""
    echo "  服务状态: $(check_status)"
    echo "  运行模式: $(get_mode)"
    echo "  当前节点: $(get_current_proxy)"
    echo "  代理端口: 7890"
    echo "  控制面板: http://$(hostname -I | awk '{print $1}'):9090"
    echo ""
    title "================================="
    echo ""
}

# 节点选择菜单
proxy_menu() {
    echo ""
    title "========== 节点列表 =========="
    echo ""

    local current=$(get_current_proxy)
    local proxies=($(get_proxy_list))

    if [ ${#proxies[@]} -eq 0 ]; then
        warn "无法获取节点列表，请确保服务正在运行"
        return
    fi

    local i=1
    for proxy in "${proxies[@]}"; do
        if [ "$proxy" = "$current" ]; then
            echo -e "  ${GREEN}$i) $proxy ◀${NC}"
        else
            echo "  $i) $proxy"
        fi
        ((i++))
    done
    echo ""
    echo "  0) 返回主菜单"
    echo ""
    title "=============================="
    echo ""

    read -p "请选择节点 [0-$((i-1))]: " choice

    if [ "$choice" = "0" ] || [ -z "$choice" ]; then
        return
    fi

    if [ "$choice" -ge 1 ] && [ "$choice" -lt "$i" ] 2>/dev/null; then
        local selected="${proxies[$((choice-1))]}"
        switch_proxy "$selected"
    else
        error "无效选择"
    fi
}

# 模式切换菜单
mode_menu() {
    local current_mode=$(get_mode)

    echo ""
    title "========== 运行模式 =========="
    echo ""
    echo "  当前模式: $current_mode"
    echo ""
    echo "  1) TUN 透明代理 (全局流量自动代理)"
    echo "  2) HTTP/SOCKS5 代理 (需手动配置代理)"
    echo ""
    echo "  0) 返回主菜单"
    echo ""
    title "=============================="
    echo ""

    read -p "请选择模式 [0-2]: " choice

    case $choice in
        1) switch_mode "tun" ;;
        2) switch_mode "proxy" ;;
        0|"") return ;;
        *) error "无效选择" ;;
    esac
}

# 订阅管理菜单
subscription_menu() {
    echo ""
    title "========== 订阅管理 =========="
    echo ""

    if [ -f "$SUB_FILE" ]; then
        echo "  当前订阅: $(cat $SUB_FILE)"
    else
        echo "  当前订阅: 未配置"
    fi
    echo ""
    echo "  1) 添加/更新订阅"
    echo "  2) 更新当前订阅"
    echo "  3) 查看配置文件"
    echo ""
    echo "  0) 返回主菜单"
    echo ""
    title "=============================="
    echo ""

    read -p "请选择操作 [0-3]: " choice

    case $choice in
        1)
            echo ""
            read -p "请输入订阅链接: " sub_url
            if [ -n "$sub_url" ]; then
                import_subscription "$sub_url"
            fi
            ;;
        2)
            if [ -f "$SUB_FILE" ]; then
                import_subscription "$(cat $SUB_FILE)"
            else
                error "没有保存的订阅链接"
            fi
            ;;
        3)
            if [ -f "$CONFIG_FILE" ]; then
                less "$CONFIG_FILE"
            else
                error "配置文件不存在"
            fi
            ;;
        0|"") return ;;
        *) error "无效选择" ;;
    esac
}

# 服务管理菜单
service_menu() {
    echo ""
    title "========== 服务管理 =========="
    echo ""
    echo "  服务状态: $(check_status)"
    echo ""
    echo "  1) 启动服务"
    echo "  2) 停止服务"
    echo "  3) 重启服务"
    echo "  4) 查看日志"
    echo "  5) 开机自启"
    echo "  6) 取消自启"
    echo ""
    echo "  0) 返回主菜单"
    echo ""
    title "=============================="
    echo ""

    read -p "请选择操作 [0-6]: " choice

    case $choice in
        1) systemctl start mihomo && info "服务已启动" ;;
        2) systemctl stop mihomo && info "服务已停止" ;;
        3) systemctl restart mihomo && info "服务已重启" ;;
        4) journalctl -u mihomo -f ;;
        5) systemctl enable mihomo && info "已设置开机自启" ;;
        6) systemctl disable mihomo && info "已取消开机自启" ;;
        0|"") return ;;
        *) error "无效选择" ;;
    esac
}

# ==================== 订阅导入功能 ====================

# 解析 VLESS 链接
parse_vless() {
    local link="$1"
    local params_part=$(echo "$link" | cut -d'#' -f1)

    local uuid=$(echo "$params_part" | sed 's/vless:\/\///' | cut -d'@' -f1)
    local server=$(echo "$params_part" | cut -d'@' -f2 | cut -d':' -f1)
    local port_raw=$(echo "$params_part" | cut -d'@' -f2 | cut -d':' -f2 | cut -d'?' -f1)
    local port=$(echo "$port_raw" | sed 's/[^0-9]//g')
    local name=$(echo "$link" | sed 's/.*#//' | python3 -c "import sys,urllib.parse;print(urllib.parse.unquote(sys.stdin.read().strip()))" 2>/dev/null)

    local type=$(echo "$params_part" | grep -oP 'type=\K[^&#]+' || echo "tcp")
    local security=$(echo "$params_part" | grep -oP 'security=\K[^&#]+' || echo "none")
    local path=$(echo "$params_part" | grep -oP 'path=\K[^&#]+' | python3 -c "import sys,urllib.parse;print(urllib.parse.unquote(sys.stdin.read().strip()))" 2>/dev/null)
    local sni=$(echo "$params_part" | grep -oP 'sni=\K[^&#]+')
    local host=$(echo "$params_part" | grep -oP 'host=\K[^&#]+')
    local fp=$(echo "$params_part" | grep -oP 'fp=\K[^&#]+' || echo "chrome")

    [ -z "$path" ] && path="/"
    [ -z "$name" ] && name="VLESS-$server"
    [ -z "$port" ] && port="443"
    local servername="${sni:-$server}"

    echo "  - name: \"$name\""
    echo "    type: vless"
    echo "    server: $server"
    echo "    port: $port"
    echo "    uuid: $uuid"
    echo "    network: $type"
    echo "    tls: $([ "$security" = "tls" ] && echo "true" || echo "false")"
    echo "    udp: true"
    echo "    skip-cert-verify: true"
    echo "    servername: $servername"
    echo "    client-fingerprint: $fp"

    if [ "$type" = "ws" ]; then
        echo "    ws-opts:"
        echo "      path: $path"
        echo "      headers:"
        echo "        Host: ${host:-$servername}"
    elif [ "$type" = "grpc" ]; then
        local serviceName=$(echo "$params_part" | grep -oP 'serviceName=\K[^&#]+')
        echo "    grpc-opts:"
        echo "      grpc-service-name: ${serviceName:-grpc}"
    fi
}

# 解析 VMess 链接
parse_vmess() {
    local link="$1"
    local data=$(echo "$link" | sed 's/vmess:\/\///' | base64 -d 2>/dev/null)

    local name=$(echo "$data" | grep -oP '"ps"\s*:\s*"\K[^"]+')
    local server=$(echo "$data" | grep -oP '"add"\s*:\s*"\K[^"]+')
    local port=$(echo "$data" | grep -oP '"port"\s*:\s*"?\K[0-9]+')
    local uuid=$(echo "$data" | grep -oP '"id"\s*:\s*"\K[^"]+')
    local aid=$(echo "$data" | grep -oP '"aid"\s*:\s*"?\K[0-9]+')
    local net=$(echo "$data" | grep -oP '"net"\s*:\s*"\K[^"]+')
    local host=$(echo "$data" | grep -oP '"host"\s*:\s*"\K[^"]+')
    local path=$(echo "$data" | grep -oP '"path"\s*:\s*"\K[^"]+')
    local tls=$(echo "$data" | grep -oP '"tls"\s*:\s*"\K[^"]+')

    [ -z "$name" ] && name="VMess-$server"
    [ -z "$aid" ] && aid="0"
    [ -z "$net" ] && net="tcp"
    [ -z "$port" ] && port="443"

    echo "  - name: \"$name\""
    echo "    type: vmess"
    echo "    server: $server"
    echo "    port: $port"
    echo "    uuid: $uuid"
    echo "    alterId: $aid"
    echo "    cipher: auto"
    echo "    network: $net"
    echo "    tls: $([ "$tls" = "tls" ] && echo "true" || echo "false")"
    echo "    udp: true"

    if [ "$net" = "ws" ]; then
        echo "    ws-opts:"
        echo "      path: ${path:-/}"
        [ -n "$host" ] && echo "      headers:" && echo "        Host: $host"
    fi
}

# 解析 Trojan 链接
parse_trojan() {
    local link="$1"
    local params_part=$(echo "$link" | cut -d'#' -f1)

    local password=$(echo "$params_part" | sed 's/trojan:\/\///' | cut -d'@' -f1)
    local server=$(echo "$params_part" | cut -d'@' -f2 | cut -d':' -f1)
    local port_raw=$(echo "$params_part" | cut -d'@' -f2 | cut -d':' -f2 | cut -d'?' -f1)
    local port=$(echo "$port_raw" | sed 's/[^0-9]//g')
    local name=$(echo "$link" | sed 's/.*#//' | python3 -c "import sys,urllib.parse;print(urllib.parse.unquote(sys.stdin.read().strip()))" 2>/dev/null)
    local sni=$(echo "$params_part" | grep -oP 'sni=\K[^&#]+')

    [ -z "$name" ] && name="Trojan-$server"
    [ -z "$sni" ] && sni="$server"
    [ -z "$port" ] && port="443"

    echo "  - name: \"$name\""
    echo "    type: trojan"
    echo "    server: $server"
    echo "    port: $port"
    echo "    password: \"$password\""
    echo "    sni: $sni"
    echo "    udp: true"
    echo "    skip-cert-verify: true"
}

# 解析 Hysteria2 链接
parse_hysteria2() {
    local link="$1"
    local params_part=$(echo "$link" | cut -d'#' -f1)

    local password=$(echo "$params_part" | sed 's/hysteria2:\/\//;s/hy2:\/\///' | cut -d'@' -f1)
    local server=$(echo "$params_part" | cut -d'@' -f2 | cut -d':' -f1)
    local port_raw=$(echo "$params_part" | cut -d'@' -f2 | cut -d':' -f2 | cut -d'?' -f1)
    local port=$(echo "$port_raw" | sed 's/[^0-9]//g')
    local name=$(echo "$link" | sed 's/.*#//' | python3 -c "import sys,urllib.parse;print(urllib.parse.unquote(sys.stdin.read().strip()))" 2>/dev/null)
    local sni=$(echo "$params_part" | grep -oP 'sni=\K[^&#]+')

    [ -z "$name" ] && name="Hysteria2-$server"
    [ -z "$port" ] && port="443"

    echo "  - name: \"$name\""
    echo "    type: hysteria2"
    echo "    server: $server"
    echo "    port: $port"
    echo "    password: \"$password\""
    [ -n "$sni" ] && echo "    sni: $sni"
    echo "    skip-cert-verify: true"
}

# 导入订阅
import_subscription() {
    local sub_url="$1"

    mkdir -p $CONFIG_DIR

    info "正在获取订阅..."

    local raw_content=$(curl -sS --connect-timeout 10 "$sub_url" 2>/dev/null)

    if [ -z "$raw_content" ]; then
        error "获取订阅失败"
        return 1
    fi

    local nodes=$(echo "$raw_content" | base64 -d 2>/dev/null)

    if [ -z "$nodes" ]; then
        if [[ "$raw_content" == *"://"* ]]; then
            nodes="$raw_content"
        else
            error "订阅解码失败"
            return 1
        fi
    fi

    info "解析到以下节点:"
    echo "$nodes" | while read -r line; do
        if [[ -n "$line" ]]; then
            name=$(echo "$line" | sed 's/.*#//' | python3 -c "import sys,urllib.parse;print(urllib.parse.unquote(sys.stdin.read().strip()))" 2>/dev/null)
            echo "  - $name"
        fi
    done
    echo ""

    # 获取当前模式
    local current_mode=$(get_mode)
    local tun_enabled="false"
    [ "$current_mode" = "TUN" ] && tun_enabled="true"

    # 生成配置文件
    info "正在生成配置..."

    cat > $CONFIG_FILE << EOF
# Mihomo 配置文件 - 由 3X-UI 订阅生成
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')

mixed-port: 7890
allow-lan: true
bind-address: "*"
mode: rule
log-level: info
external-controller: 0.0.0.0:9090

# TUN 透明代理模式
tun:
  enable: $tun_enabled
  stack: system
  auto-route: true
  auto-detect-interface: true
  dns-hijack:
    - any:53

dns:
  enable: true
  listen: 0.0.0.0:1053
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  fake-ip-filter:
    - "*.lan"
    - "*.local"
  default-nameserver:
    - 223.5.5.5
    - 119.29.29.29
  nameserver:
    - https://dns.alidns.com/dns-query
    - https://doh.pub/dns-query

proxies:
EOF

    # 收集节点名称
    local node_names=()

    while IFS= read -r line; do
        [ -z "$line" ] && continue

        if [[ "$line" == vless://* ]]; then
            parse_vless "$line" >> $CONFIG_FILE
            name=$(echo "$line" | sed 's/.*#//' | python3 -c "import sys,urllib.parse;print(urllib.parse.unquote(sys.stdin.read().strip()))" 2>/dev/null)
            node_names+=("$name")
        elif [[ "$line" == vmess://* ]]; then
            parse_vmess "$line" >> $CONFIG_FILE
            data=$(echo "$line" | sed 's/vmess:\/\///' | base64 -d 2>/dev/null)
            name=$(echo "$data" | grep -oP '"ps"\s*:\s*"\K[^"]+')
            node_names+=("$name")
        elif [[ "$line" == trojan://* ]]; then
            parse_trojan "$line" >> $CONFIG_FILE
            name=$(echo "$line" | sed 's/.*#//' | python3 -c "import sys,urllib.parse;print(urllib.parse.unquote(sys.stdin.read().strip()))" 2>/dev/null)
            node_names+=("$name")
        elif [[ "$line" == hysteria2://* ]] || [[ "$line" == hy2://* ]]; then
            parse_hysteria2 "$line" >> $CONFIG_FILE
            name=$(echo "$line" | sed 's/.*#//' | python3 -c "import sys,urllib.parse;print(urllib.parse.unquote(sys.stdin.read().strip()))" 2>/dev/null)
            node_names+=("$name")
        fi
    done <<< "$nodes"

    # 添加代理组
    cat >> $CONFIG_FILE << 'EOF'

proxy-groups:
  - name: 代理
    type: select
    proxies:
EOF

    for name in "${node_names[@]}"; do
        [ -n "$name" ] && echo "      - \"$name\"" >> $CONFIG_FILE
    done
    echo "      - DIRECT" >> $CONFIG_FILE

    # AI服务组
    cat >> $CONFIG_FILE << 'EOF'

  - name: AI服务
    type: select
    proxies:
EOF
    for name in "${node_names[@]}"; do
        [ -n "$name" ] && echo "      - \"$name\"" >> $CONFIG_FILE
    done
    echo "      - 代理" >> $CONFIG_FILE

    # 流媒体组
    cat >> $CONFIG_FILE << 'EOF'

  - name: 流媒体
    type: select
    proxies:
EOF
    for name in "${node_names[@]}"; do
        [ -n "$name" ] && echo "      - \"$name\"" >> $CONFIG_FILE
    done
    echo "      - 代理" >> $CONFIG_FILE

    # 广告拦截组
    cat >> $CONFIG_FILE << 'EOF'

  - name: 广告拦截
    type: select
    proxies:
      - REJECT
      - DIRECT

EOF

    # 添加规则
    cat >> $CONFIG_FILE << 'EOF'
rules:
  # 本地直连
  - DOMAIN-SUFFIX,local,DIRECT
  - IP-CIDR,127.0.0.0/8,DIRECT
  - IP-CIDR,192.168.0.0/16,DIRECT
  - IP-CIDR,10.0.0.0/8,DIRECT
  - IP-CIDR,172.16.0.0/12,DIRECT

  # 广告拦截
  - DOMAIN-SUFFIX,googleads.com,广告拦截
  - DOMAIN-SUFFIX,googlesyndication.com,广告拦截
  - DOMAIN-SUFFIX,doubleclick.net,广告拦截

  # AI 服务
  - DOMAIN-SUFFIX,openai.com,AI服务
  - DOMAIN-SUFFIX,chatgpt.com,AI服务
  - DOMAIN-SUFFIX,anthropic.com,AI服务
  - DOMAIN-SUFFIX,claude.ai,AI服务
  - DOMAIN-SUFFIX,gemini.google.com,AI服务
  - DOMAIN-SUFFIX,perplexity.ai,AI服务
  - DOMAIN-SUFFIX,poe.com,AI服务

  # 流媒体
  - DOMAIN-SUFFIX,netflix.com,流媒体
  - DOMAIN-SUFFIX,youtube.com,流媒体
  - DOMAIN-SUFFIX,spotify.com,流媒体
  - DOMAIN-SUFFIX,twitch.tv,流媒体

  # Google
  - DOMAIN-SUFFIX,google.com,代理
  - DOMAIN-SUFFIX,googleapis.com,代理
  - DOMAIN-SUFFIX,gstatic.com,代理
  - DOMAIN-KEYWORD,google,代理

  # 社交媒体
  - DOMAIN-SUFFIX,twitter.com,代理
  - DOMAIN-SUFFIX,x.com,代理
  - DOMAIN-SUFFIX,facebook.com,代理
  - DOMAIN-SUFFIX,instagram.com,代理
  - DOMAIN-SUFFIX,telegram.org,代理
  - DOMAIN-SUFFIX,t.me,代理
  - DOMAIN-SUFFIX,discord.com,代理
  - DOMAIN-SUFFIX,reddit.com,代理

  # 开发工具
  - DOMAIN-SUFFIX,github.com,代理
  - DOMAIN-SUFFIX,githubusercontent.com,代理
  - DOMAIN-SUFFIX,docker.com,代理
  - DOMAIN-SUFFIX,npmjs.com,代理

  # 国内直连
  - DOMAIN-SUFFIX,cn,DIRECT
  - DOMAIN-SUFFIX,baidu.com,DIRECT
  - DOMAIN-SUFFIX,qq.com,DIRECT
  - DOMAIN-SUFFIX,weixin.com,DIRECT
  - DOMAIN-SUFFIX,bilibili.com,DIRECT
  - DOMAIN-SUFFIX,zhihu.com,DIRECT
  - DOMAIN-SUFFIX,taobao.com,DIRECT
  - DOMAIN-SUFFIX,jd.com,DIRECT
  - DOMAIN-SUFFIX,aliyun.com,DIRECT

  # 兜底规则
  - GEOIP,CN,DIRECT
  - MATCH,代理
EOF

    # 保存订阅链接
    echo "$sub_url" > $SUB_FILE

    # 重启服务
    info "正在重启服务..."
    systemctl restart mihomo
    sleep 2

    if systemctl is-active --quiet mihomo; then
        echo ""
        echo -e "${GREEN}========================================${NC}"
        echo -e "${GREEN}          订阅导入成功！${NC}"
        echo -e "${GREEN}========================================${NC}"
        echo ""
        show_status
    else
        error "服务启动失败，请检查日志: journalctl -u mihomo -f"
        return 1
    fi
}

# ==================== 主菜单 ====================

main_menu() {
    clear
    echo ""
    title "╔════════════════════════════════════════╗"
    title "║       Mihomo 管理面板 (3X-UI)          ║"
    title "╚════════════════════════════════════════╝"
    echo ""
    echo "  状态: $(check_status)  模式: $(get_mode)  节点: $(get_current_proxy)"
    echo ""
    title "──────────────────────────────────────────"
    echo ""
    echo "  1) 查看状态"
    echo "  2) 切换节点"
    echo "  3) 切换模式 (TUN/代理)"
    echo "  4) 测试连接"
    echo "  5) 订阅管理"
    echo "  6) 服务管理"
    echo ""
    echo "  0) 退出"
    echo ""
    title "──────────────────────────────────────────"
    echo ""
}

# 主程序
main() {
    check_root
    mkdir -p $CONFIG_DIR

    # 如果有参数，直接导入订阅
    if [ -n "$1" ]; then
        import_subscription "$1"
        exit 0
    fi

    # 交互式菜单
    while true; do
        main_menu
        read -p "  请选择操作 [0-6]: " choice

        case $choice in
            1) show_status; read -p "按 Enter 继续..." ;;
            2) proxy_menu ;;
            3) mode_menu ;;
            4) test_connection; read -p "按 Enter 继续..." ;;
            5) subscription_menu ;;
            6) service_menu ;;
            0) echo ""; info "再见！"; exit 0 ;;
            *) error "无效选择" ;;
        esac
    done
}

main "$@"
