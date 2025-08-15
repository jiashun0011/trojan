#!/usr/bin/env bash

###############################################################################
# Enhanced one-click trojan installer (optimized)
# Changes:
#  - Strict bash options & safer quoting
#  - Modular functions / reduced duplication
#  - OS detection via /etc/os-release
#  - Domain & port validation; use ss instead of netstat
#  - Non-interactive mode via flags (-d domain -p port --install|--remove)
#  - Idempotent downloads; skip if present
#  - Random password via /dev/urandom tr -dc
#  - Clear exit codes & traps
#  - Added --force / --yes for unattended uninstall
#  - Provide help (-h/--help)
###############################################################################

set -Eeuo pipefail
IFS=$'\n\t'

trap 'red "[错误] 脚本在行 $LINENO 失败 (命令: $BASH_COMMAND)"' ERR

blue()   { echo -e "\033[34m\033[01m$*\033[0m"; }
green()  { echo -e "\033[32m\033[01m$*\033[0m"; }
red()    { echo -e "\033[31m\033[01m$*\033[0m"; }
yellow() { echo -e "\033[33m\033[01m$*\033[0m"; }

require_root() {
  if [[ $EUID -ne 0 ]]; then
    red "请以 root 权限运行 (sudo su / sudo bash)."; exit 1; fi
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

OS=""; PKG_MGR=""; SYSTEMD_DIR=""; SUPPORTED=1
detect_os() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    case ${ID,,} in
      centos|rocky|alma|rhel)
        OS=centos; PKG_MGR=yum; SYSTEMD_DIR='/usr/lib/systemd/system';;
      ubuntu)
        OS=ubuntu; PKG_MGR=apt-get; SYSTEMD_DIR='/lib/systemd/system';;
      debian)
        OS=debian; PKG_MGR=apt-get; SYSTEMD_DIR='/lib/systemd/system';;
      *)
        SUPPORTED=0;
    esac
  else
    SUPPORTED=0
  fi

  if [[ $SUPPORTED -eq 0 ]]; then
    red "当前系统未被支持，请使用 CentOS / Debian / Ubuntu"; exit 1; fi

  # minimal version gates (rough checks)
  if [[ $OS == centos ]] && grep -Eq ' 6\.| 5\.' /etc/redhat-release 2>/dev/null; then
    red "CentOS 6/5 不再支持"; exit 1; fi
}

ensure_packages() {
  if [[ $PKG_MGR == apt-get ]]; then
    apt-get update -y >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y nginx wget unzip zip curl tar socat jq xz-utils >/dev/null 2>&1
  else
    $PKG_MGR -y install epel-release >/dev/null 2>&1 || true
    $PKG_MGR -y install nginx wget unzip zip curl tar socat jq xz >/dev/null 2>&1
  fi
}

disable_firewall() {
  if [[ $OS == centos ]]; then
    systemctl stop firewalld 2>/dev/null || true
    systemctl disable firewalld 2>/dev/null || true
  else
    systemctl stop ufw 2>/dev/null || true
    systemctl disable ufw 2>/dev/null || true
  fi
}

check_selinux() {
  if [[ -f /etc/selinux/config ]]; then
    local current
    current=$(grep -E '^SELINUX=' /etc/selinux/config | head -1 | cut -d= -f2 || true)
    if [[ $current == enforcing || $current == permissive ]]; then
      yellow "检测到 SELinux 处于 $current 状态，将禁用并重启 (会中断脚本)";
      sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config
      setenforce 0 2>/dev/null || true
      sleep 2
      reboot
    fi
  fi
}

validate_port() {
  local p=$1
  if ! [[ $p =~ ^[0-9]{2,5}$ ]] || (( p < 1 || p > 65535 )); then
    red "端口号不合法: $p"; exit 1; fi
  if ss -ltn | awk '{print $4}' | grep -E ":$p$" >/dev/null 2>&1; then
    red "端口 $p 已被占用"; exit 1; fi
  if ss -ltn | awk '{print $4}' | grep -E ':80$' >/dev/null 2>&1; then
    red '80 端口已被占用，无法继续'; exit 1; fi
}

resolve_domain_ip() {
  local d=$1
  # Try getent + dig fallback
  local ip
  if command_exists getent; then
    ip=$(getent ahostsv4 "$d" | awk '{print $1; exit}')
  fi
  if [[ -z ${ip:-} ]] && command_exists dig; then
    ip=$(dig +short A "$d" | head -1)
  fi
  if [[ -z ${ip:-} ]]; then
    ip=$(ping -c1 -W1 "$d" 2>/dev/null | sed '1{s/.*(//;s/).*//;q}') || true
  fi
  echo "$ip"
}

public_ip() {
  curl -4 -s https://ipv4.icanhazip.com || curl -4 -s https://ifconfig.co || true
}

random_string() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-8}"; }

ACME_HOME="/root/.acme.sh"
ensure_acme() {
  if [[ ! -d $ACME_HOME ]]; then
    curl -s https://get.acme.sh | sh -s email=admin@localhost >/dev/null 2>&1
  fi
}

# 确认 cron 自动续期存在；若不存在则添加 root 定时任务（每天 3:15 执行）
ensure_auto_renew() {
  local cron_exists
  cron_exists=$(crontab -l 2>/dev/null | grep -F "$ACME_HOME/acme.sh --cron" || true)
  if [[ -z $cron_exists ]]; then
    (crontab -l 2>/dev/null; echo "15 3 * * * $ACME_HOME/acme.sh --cron --home $ACME_HOME > /dev/null 2>&1") | crontab -
    green "已创建 acme.sh 续期 cron 任务 (每日 03:15)"
  else
    yellow "检测到已有 acme.sh 续期 cron 任务"
  fi
}

# 安装 systemd timer 作为替代方案（若想避免 crontab），不会删除原 cron
install_systemd_renew_timer() {
  local service=/etc/systemd/system/acme-renew.service
  local timer=/etc/systemd/system/acme-renew.timer
  cat > "$service" <<EOF
[Unit]
Description=acme.sh renew all certs

[Service]
Type=oneshot
ExecStart=$ACME_HOME/acme.sh --cron --home $ACME_HOME
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
EOF

  cat > "$timer" <<EOF
[Unit]
Description=Daily acme.sh renew run

[Timer]
OnCalendar=*-*-* 03:15:00
RandomizedDelaySec=900
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now acme-renew.timer
  green "已安装 systemd timer: acme-renew.timer (每天 03:15 ± 随机延迟)"
  yellow "查看状态: systemctl status acme-renew.timer"
  yellow "手动触发: systemctl start acme-renew.service"
}

issue_cert() {
  local domain=$1
  mkdir -p /usr/src/trojan-cert
  "$ACME_HOME"/acme.sh --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
  "$ACME_HOME"/acme.sh --issue -d "$domain" --webroot /usr/share/nginx/html/ >/dev/null
  "$ACME_HOME"/acme.sh --installcert -d "$domain" \
    --key-file       /usr/src/trojan-cert/private.key \
    --fullchain-file /usr/src/trojan-cert/fullchain.cer \
    --reloadcmd     "systemctl force-reload nginx" >/dev/null
  [[ -s /usr/src/trojan-cert/fullchain.cer ]] || { red "证书申请失败"; exit 1; }
}

prepare_nginx_conf() {
  local domain=$1
  cat > /etc/nginx/nginx.conf <<EOF
user root;
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;
events { worker_connections 1024; }
http {
  include       /etc/nginx/mime.types;
  default_type  application/octet-stream;
  log_format main '\$remote_addr - \$remote_user [\$time_local] "\$request" ' '\$status \$body_bytes_sent "\$http_referer" ' '"\$http_user_agent" "\$http_x_forwarded_for"';
  access_log  /var/log/nginx/access.log  main;
  sendfile        on;
  keepalive_timeout  120;
  server {
    listen 80;
    server_name ${domain};
    root /usr/share/nginx/html;
    index index.html index.htm;
  }
}
EOF
  systemctl enable nginx >/dev/null 2>&1
  systemctl restart nginx
}

seed_web_content() {
  rm -rf /usr/share/nginx/html/*
  mkdir -p /usr/share/nginx/html
  pushd /usr/share/nginx/html >/dev/null
  local ZIP_URL="https://github.com/kashinYing/trojan/raw/master/web.zip"
  if [[ ! -f web.zip ]]; then
    wget -q "$ZIP_URL" -O web.zip || true
  fi
  unzip -oq web.zip || echo '<h1>Welcome</h1>' > index.html
  popd >/dev/null
}

download_trojan_release() {
  pushd /usr/src >/dev/null
  if [[ ! -f latest.json ]]; then
    wget -q -O latest.json https://api.github.com/repos/trojan-gfw/trojan/releases/latest
  fi
  local latest_version
  latest_version=$(grep -m1 tag_name latest.json | awk -F '[:,"v]' '{print $6}')
  [[ -n $latest_version ]] || { red "无法解析最新版本"; exit 1; }
  if [[ ! -d trojan ]]; then
    wget -q https://github.com/trojan-gfw/trojan/releases/download/v${latest_version}/trojan-${latest_version}-linux-amd64.tar.xz
    tar xf trojan-${latest_version}-linux-amd64.tar.xz
  fi
  popd >/dev/null
}

write_server_config() {
  local port=$1 password=$2
  cat > /usr/src/trojan/server.conf <<EOF
{
  "run_type": "server",
  "local_addr": "0.0.0.0",
  "local_port": ${port},
  "remote_addr": "127.0.0.1",
  "remote_port": 80,
  "password": ["${password}"],
  "log_level": 1,
  "ssl": {
    "cert": "/usr/src/trojan-cert/fullchain.cer",
    "key": "/usr/src/trojan-cert/private.key",
    "cipher_tls13": "TLS_AES_128_GCM_SHA256:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_256_GCM_SHA384",
    "prefer_server_cipher": true,
    "alpn": ["http/1.1"],
    "reuse_session": true,
    "session_ticket": false,
    "session_timeout": 600
  },
  "tcp": {"no_delay": true, "keep_alive": true, "fast_open": false, "fast_open_qlen": 20}
}
EOF
}

# (已移除客户端打包与配置函数，用户可使用自有客户端并手动填写以下参数: 域名/端口/密码/证书验证)

create_systemd_service() {
  cat > "${SYSTEMD_DIR}/trojan.service" <<EOF
[Unit]
Description=Trojan Server
After=network.target

[Service]
Type=simple
WorkingDirectory=/usr/src/trojan
ExecStart=/usr/src/trojan/trojan -c /usr/src/trojan/server.conf
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable trojan.service >/dev/null 2>&1
  systemctl restart trojan.service
}

install_flow() {
  local domain=$1 port=$2
  validate_port "$port"
  disable_firewall
  ensure_packages
  check_selinux
  prepare_nginx_conf "$domain"
  seed_web_content
  local ip_domain ip_public
  ip_domain=$(resolve_domain_ip "$domain")
  ip_public=$(public_ip | tr -d '\r')
  if [[ -z $ip_domain || -z $ip_public ]]; then
    red "无法解析域名或获取公网 IP"; exit 1; fi
  if [[ $ip_domain != $ip_public ]]; then
    red "域名解析 IP ($ip_domain) 与 本机公网 IP ($ip_public) 不一致"; exit 1; fi
  ensure_acme
  issue_cert "$domain"
  ensure_auto_renew
  download_trojan_release
  local passwd
  passwd=$(random_string 12)
  write_server_config "$port" "$passwd"
  # 客户端请自行配置：
  # remote_addr: $domain
  # remote_port: $port
  # password: $passwd
  # TLS 需验证证书，目标 SNI 使用域名本身
  create_systemd_service
  green "================================================================================="
  green "Trojan 安装完成"
  yellow "域名: $domain"
  yellow "端口: $port"
  yellow "密码: $passwd"
  green "查看日志: journalctl -u trojan -f"
  green "================================================================================="
}

remove_trojan() {
  red "================================"
  red "即将卸载 trojan 与 nginx          "
  red "================================"
  systemctl stop trojan 2>/dev/null || true
  systemctl disable trojan 2>/dev/null || true
  rm -f "${SYSTEMD_DIR}/trojan.service"
  systemctl daemon-reload || true
  if [[ $PKG_MGR == yum ]]; then
    yum remove -y nginx >/dev/null 2>&1 || true
  else
    apt-get remove -y nginx >/dev/null 2>&1 || true
    apt-get autoremove -y >/dev/null 2>&1 || true
  fi
  rm -rf /usr/src/trojan* /usr/share/nginx/html/* /usr/src/latest* /usr/src/trojan-cert
  green "=============="
  green "trojan 删除完毕"
  green "=============="
}

bbr_boost_sh(){
  wget -q -N --no-check-certificate "https://raw.githubusercontent.com/chiakge/Linux-NetSpeed/master/tcp.sh" && chmod +x tcp.sh && bash ./tcp.sh
}

LOG_FILE=""; DEBUG_TRACE=0; DISABLE_COLOR=0

disable_color_if_needed() {
  if [[ $DISABLE_COLOR -eq 1 || ! -t 1 ]]; then
    blue()   { echo "$*"; }
    green()  { echo "$*"; }
    red()    { echo "$*"; }
    yellow() { echo "$*"; }
  fi
}

step() { green "[STEP] $*"; }

setup_install_logging() {
  [[ -n $LOG_FILE ]] || LOG_FILE="/var/log/trojan-install-$(date +%Y%m%d-%H%M%S).log"
  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE" || { red "无法写入日志文件 $LOG_FILE"; exit 1; }
  green "安装日志: $LOG_FILE"
  # Redirect all subsequent stdout/stderr
  exec > >(tee -a "$LOG_FILE") 2>&1
  [[ $DEBUG_TRACE -eq 1 ]] && set -x
}

usage() {
  cat <<EOF
用法: $0 [命令] [选项]
命令:
  --install            执行安装流程 (需 -d 与 -p)
  --remove             卸载 trojan 与 nginx
  --bbr                安装 bbr-plus
  --renew-now          立即执行证书续期 (acme.sh --cron)
  --install-renew      安装 systemd 定时续期 (可与 cron 共存)
  --menu               强制进入交互菜单 (默认: 无参数时)
  -h, --help           显示本帮助
选项:
  -d, --domain <域名>
  -p, --port   <端口>
  -y, --yes           非交互确认 (卸载)
  --log-file <路径>   指定安装日志文件 (默认 /var/log/trojan-install-时间戳.log)
  --debug              开启 bash 跟踪 (set -x)
  --no-color           关闭彩色输出
示例:
  $0 --install -d example.com -p 443
  $0 --remove -y
EOF
}

INTERACTIVE_MENU=0; ACTION=""; DOMAIN=""; PORT=""; ASSUME_YES=0
parse_args() {
  [[ $# -eq 0 ]] && INTERACTIVE_MENU=1 && return
  while [[ $# -gt 0 ]]; do
    case $1 in
      --install) ACTION=install; shift ;;
      --remove)  ACTION=remove; shift ;;
  --bbr)     ACTION=bbr; shift ;;
  --renew-now) ACTION=renew_now; shift ;;
  --install-renew) ACTION=install_renew; shift ;;
      --menu)    INTERACTIVE_MENU=1; shift ;;
      -d|--domain) DOMAIN=${2:-}; shift 2 ;;
      -p|--port)   PORT=${2:-}; shift 2 ;;
      -y|--yes)    ASSUME_YES=1; shift ;;
      --log-file) LOG_FILE=${2:-}; shift 2 ;;
      --debug) DEBUG_TRACE=1; shift ;;
      --no-color) DISABLE_COLOR=1; shift ;;
      -h|--help)   usage; exit 0 ;;
      *) red "未知参数: $1"; usage; exit 1 ;;
    esac
  done
}

start_menu() {
  clear
  green " ===================================="
  green " 介绍：一键安装 trojan (优化版)       "
  green " 作者：kashin  / 优化：脚本改进        "
  green " ===================================="
  echo
  green " 1. 安装 trojan"
  red   " 2. 卸载 trojan"
  green " 3. 安装 bbr-plus"
  yellow " 0. 退出脚本"
  echo
  read -rp "请输入数字: " num
  case "$num" in
    1)
      read -rp "请输入域名: " DOMAIN
      read -rp "请输入端口号: " PORT
  install_flow "$DOMAIN" "$PORT" ;;
    2)
      read -rp "确认卸载? (y/N): " ans; [[ ${ans,,} == y ]] && remove_trojan || green "已取消" ;;
    3)
      bbr_boost_sh ;;
    0)
      exit 0 ;;
    *)
      red "请输入正确数字"; sleep 1; start_menu ;;
  esac
}

main() {
  require_root
  detect_os
  parse_args "$@"
  disable_color_if_needed
  if [[ $INTERACTIVE_MENU -eq 1 ]]; then
    start_menu; exit 0
  fi
  case $ACTION in
    install)
      [[ -z ${DOMAIN} || -z ${PORT} ]] && { red "安装需要 --domain 与 --port"; exit 1; }
      setup_install_logging
      step "开始安装: 域名=$DOMAIN 端口=$PORT"
      install_flow "$DOMAIN" "$PORT"
      step "安装完成"
  ;;
    remove)
      if [[ $ASSUME_YES -ne 1 ]]; then
        read -rp "确认卸载 trojan? (y/N): " ok; [[ ${ok,,} == y ]] || { green "已取消"; exit 0; }
      fi
      remove_trojan ;;
    bbr)
      bbr_boost_sh ;;
    renew_now)
      ensure_acme; "$ACME_HOME"/acme.sh --cron --home "$ACME_HOME"; green "续期任务已执行 (查看上方输出)" ;;
    install_renew)
      ensure_acme; install_systemd_renew_timer ;;
    *)
      usage; exit 0 ;;
  esac
}

main "$@"
