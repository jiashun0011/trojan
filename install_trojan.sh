#!/bin/bash

blue() {
  echo -e "\033[34m\033[01m$1\033[0m"
}

green() {
  echo -e "\033[32m\033[01m$1\033[0m"
}

red() {
  echo -e "\033[31m\033[01m$1\033[0m"
}

yellow() {
  echo -e "\033[33m\033[01m$1\033[0m"
}

# check linux release
if [ -f /etc/redhat-release ]; then
  release='centos'
  syspkg='yum'
  syspwd='/usr/lib/systemd/system'
elif cat /etc/issue | grep -Eqi 'debian'; then
  release='debian'
  syspkg='apt-get'
  syspwd='/lib/systemd/system'
elif cat /etc/issue | grep -Eqi 'ubuntu'; then
  release='ubuntu'
  syspkg='apt-get'
  syspwd='/lib/systemd/system'
elif cat /etc/issue | grep -Eqi 'centos|red hat|redhat'; then
  release='centos'
  syspkg='yum'
  syspwd='/usr/lib/systemd/system'
elif cat /proc/version | grep -Eqi 'debian'; then
  release='debian'
  syspkg='apt-get'
  syspwd='/lib/systemd/system'
elif cat /proc/version | grep -Eqi 'ubuntu'; then
  release='ubuntu'
  syspkg='apt-get'
  syspwd='/lib/systemd/system'
elif cat /proc/version | grep -Eqi 'centos|red hat|redhat'; then
  release='centos'
  syspkg='yum'
  syspwd='/usr/lib/systemd/system'
fi

install_trojan() {
  myport=$1
  systemctl stop nginx
  $syspkg -y install net-tools socat
  Port80=`netstat -tlpn | awk -F '[: ]+' '$1=="tcp"{print $5}' | grep -w 80`
  PortMyport=`netstat -tlpn | awk -F '[: ]+' '$1=="tcp"{print $5}' | grep -w $myport`

  # check if port 80 and myport are being used
  if [ -n "$Port80" ]; then
      process80=`netstat -tlpn | awk -F '[: ]+' '$5=="80"{print $9}'`
      red "==========================================================="
      red "检测到80端口被占用，占用进程为：${process80}，本次安装结束"
      red "==========================================================="
      exit 1
  fi

  if [ -n "$PortMyport" ]; then
      processMyport=`netstat -tlpn | awk -F '[: ]+' '$5=="$myport"{print $9}'`
      red "============================================================="
      red "检测到$myport端口被占用，占用进程为：${processMyport}，本次安装结束"
      red "============================================================="
      exit 1
  fi

  if [ "$release" == "centos" ]; then
    if  [ -n "$(grep ' 6\.' /etc/redhat-release)" ] ;then
      red "================"
      red "当前系统不受支持"
      red "================"
      exit
    fi

    if  [ -n "$(grep ' 5\.' /etc/redhat-release)" ] ;then
      red "================"
      red "当前系统不受支持"
      red "================"
      exit
    fi
    
    systemctl stop firewalld
    systemctl disable firewalld
    rpm -Uvh http://nginx.org/packages/centos/7/noarch/RPMS/nginx-release-centos-7-0.el7.ngx.noarch.rpm
  elif [ "$release" == "ubuntu" ]; then
    if  [ -n "$(grep ' 14\.' /etc/os-release)" ] ;then
      red "================"
      red "当前系统不受支持"
      red "================"
      exit
    fi

    if  [ -n "$(grep ' 12\.' /etc/os-release)" ] ;then
      red "================"
      red "当前系统不受支持"
      red "================"
      exit
    fi

    systemctl stop ufw
    systemctl disable ufw
    apt-get update
  elif [ "$release" == "debian" ]; then
    apt-get update
  fi

  # disable Security-Enhanced Linux
  # cat /etc/selinux/config
  # # This file controls the state of SELinux on the system.
  # # SELINUX= can take one of these three values:
  # #     enforcing - SELinux security policy is enforced.
  # #     permissive - SELinux prints warnings instead of enforcing.
  # #     disabled - No SELinux policy is loaded.
  # SELINUX=disabled
  # # SELINUXTYPE= can take one of three two values:
  # #     targeted - Targeted processes are protected,
  # #     minimum - Modification of targeted policy. Only selected processes are protected.
  # #     mls - Multi Level Security protection.
  # SELINUXTYPE=targeted

  CHECK=$(grep 'SELINUX=' /etc/selinux/config | grep -v "#")

  if [ "$CHECK" == "SELINUX=enforcing" ]; then
    red "===================================================================="
    red "检测到SELinux为开启状态，为防止申请证书失败，重启VPS后，再执行本脚本"
    red "===================================================================="
    sed -i 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config
    setenforce 0
    echo -e "VPS 重启中..."
    reboot
  fi

  if [ "$CHECK" == "SELINUX=permissive" ]; then
    red "===================================================================="
    red "检测到SELinux为开启状态，为防止申请证书失败，重启VPS后，再执行本脚本"
    red "===================================================================="
    sed -i 's/SELINUX=permissive/SELINUX=disabled/g' /etc/selinux/config
    setenforce 0
    echo -e "VPS 重启中..."
    reboot
  fi

  $syspkg -y install nginx wget unzip zip curl tar >/dev/null 2>&1

  green "========================"
  yellow "请输入绑定到本VPS的域名"
  green "========================"
  read your_domain
  real_addr=`ping ${your_domain} -c 1 | sed '1{s/[^(]*(//;s/).*//;q}'`
  local_addr=`curl ipv4.icanhazip.com`

  if [ $real_addr == $local_addr ]; then
    green "=========================================="
    green "域名解析正常，开启安装nginx并申请https证书"
    green "=========================================="
    sleep 1s
    
    systemctl enable nginx

    # config nginx
    cat <<EOF >/etc/nginx/nginx.conf 
user root;
worker_processes 1;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;
events {
  worker_connections 1024;
}
http {
  include /etc/nginx/mime.types;
  default_type application/octet-stream;
  log_format main '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                  '\$status \$body_bytes_sent "\$http_referer" '
                  '"\$http_user_agent" "\$http_x_forwarded_for"';
  access_log /var/log/nginx/access.log main;
  sendfile on;
  #tcp_nopush on;
  keepalive_timeout 120;
  client_max_body_size 20m;
  #gzip on;
  server {
    listen 80;
    server_name $your_domain;
    root /usr/share/nginx/html;
    index index.php index.html index.htm;
  }
}
EOF

    # mock website
    rm -rf /usr/share/nginx/html/*
    cd /usr/share/nginx/html/
    wget https://github.com/kashinYing/trojan/raw/master/web.zip
    unzip web.zip
    systemctl restart nginx
    sleep 5

    # generate certificate for https
    mkdir /usr/src/trojan-cert
    curl https://get.acme.sh | sh
    ~/.acme.sh/acme.sh --issue -d $your_domain --webroot /usr/share/nginx/html/
    ~/.acme.sh/acme.sh --installcert -d  $your_domain \
      --key-file   /usr/src/trojan-cert/private.key \
      --fullchain-file /usr/src/trojan-cert/fullchain.cer \
      --reloadcmd  "systemctl force-reload nginx"

    if test -s /usr/src/trojan-cert/fullchain.cer; then
      cd /usr/src
      wget https://api.github.com/repos/trojan-gfw/trojan/releases/latest
      latest_version=`grep tag_name latest| awk -F '[:,"v]' '{print $6}'`

      # download trojan server
      wget https://github.com/trojan-gfw/trojan/releases/download/v${latest_version}/trojan-${latest_version}-linux-amd64.tar.xz
      tar xf trojan-${latest_version}-linux-amd64.tar.xz

      # download trojan client for mac
      wget -P /usr/src/trojan-macos https://github.com/trojan-gfw/trojan/releases/download/v${latest_version}/trojan-${latest_version}-macos.zip
      unzip /usr/src/trojan-macos/trojan-${latest_version}-macos.zip -d /usr/src/trojan-macos/

      # generate random password
      trojan_passwd=$(cat /dev/urandom | head -1 | md5sum | head -c 8)

      # configuration for trojan mac client
      cat <<EOF >/usr/src/trojan-macos/trojan/config.json
{
  "run_type": "client",
  "local_addr": "127.0.0.1",
  "local_port": 1080,
  "remote_addr": "$your_domain",
  "remote_port": $myport,
  "password": [
    "$trojan_passwd"
  ],
  "log_level": 1,
  "ssl": {
    "verify": true,
    "verify_hostname": true,
    "cert": "",
    "cipher": "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES256-SHA:ECDHE-ECDSA-AES128-SHA:ECDHE-RSA-AES128-SHA:ECDHE-RSA-AES256-SHA:DHE-RSA-AES128-SHA:DHE-RSA-AES256-SHA:AES128-SHA:AES256-SHA:DES-CBC3-SHA",
    "cipher_tls13": "TLS_AES_128_GCM_SHA256:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_256_GCM_SHA384",
    "sni": "",
    "alpn": [
      "h2",
      "http/1.1"
    ],
    "reuse_session": true,
    "session_ticket": false,
    "curves": ""
  },
  "tcp": {
    "no_delay": true,
    "keep_alive": true,
    "reuse_port": false,
    "fast_open": false,
    "fast_open_qlen": 20
  }
}
EOF

      rm -rf /usr/src/trojan/server.conf
      cat <<EOF >/usr/src/trojan/server.conf
{
  "run_type": "server",
  "local_addr": "0.0.0.0",
  "local_port": $myport,
  "remote_addr": "127.0.0.1",
  "remote_port": 80,
  "password": [
    "$trojan_passwd"
  ],
  "log_level": 1,
  "ssl": {
    "cert": "/usr/src/trojan-cert/fullchain.cer",
    "key": "/usr/src/trojan-cert/private.key",
    "key_password": "",
    "cipher_tls13":"TLS_AES_128_GCM_SHA256:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_256_GCM_SHA384",
    "prefer_server_cipher": true,
    "alpn": [
      "http/1.1"
    ],
    "reuse_session": true,
    "session_ticket": false,
    "session_timeout": 600,
    "plain_http_response": "",
    "curves": "",
    "dhparam": ""
  },
  "tcp": {
    "no_delay": true,
    "keep_alive": true,
    "fast_open": false,
    "fast_open_qlen": 20
  },
  "mysql": {
    "enabled": false,
    "server_addr": "127.0.0.1",
    "server_port": 3306,
    "database": "trojan",
    "username": "trojan",
    "password": ""
  }
}
EOF
      
      # package client trojan
      cd /usr/src/trojan-macos/
      zip -q -r -j trojan-mac.zip /usr/src/trojan-macos/trojan
      trojan_path=$(cat /dev/urandom | head -1 | md5sum | head -c 16)
      mkdir /usr/share/nginx/html/${trojan_path}
      mv /usr/src/trojan-macos/trojan-mac.zip /usr/share/nginx/html/${trojan_path}/
      
      # add autostart script
      cat <<EOF >${syspwd}/trojan.service
[Unit]  
Description=trojan  
After=network.target  
   
[Service]  
Type=simple  
PIDFile=/usr/src/trojan/trojan/trojan.pid
ExecStart=/usr/src/trojan/trojan -c "/usr/src/trojan/server.conf"  
ExecReload=  
ExecStop=/usr/src/trojan/trojan  
PrivateTmp=true  
   
[Install]  
WantedBy=multi-user.target
EOF

      mkdir /usr/share/nginx/html/mellow
      # create mellow.conf
      cat <<EOF >/usr/share/nginx/html/mellow/mellow.conf
[Endpoint]
; tag, parser, parser-specific params...
Direct, builtin, freedom, domainStrategy=UseIP
Reject, builtin, blackhole
Dns-Out, builtin, dns
Trojan-out, builtin, socks, address=127.0.0.1, port=1080

[EndpointGroup]
Group-1, Trojan-out, latency, interval=300, timeout=6

[RoutingRule]
DOMAIN-KEYWORD, geosite:category-ads-all, Reject
IP-CIDR, 223.5.5.5/32, Direct
IP-CIDR, 8.8.8.8/32, Group-1
IP-CIDR, 8.8.4.4/32, Group-1
PROCESS-NAME, trojan, Direct
PROCESS-NAME, ssh, Direct
GEOIP, cn, Direct
GEOIP, private, Direct
DOMAIN-KEYWORD, geosite:cn, Direct
; DOMAIN, www.google.com, Group-1
; DOMAIN-FULL, www.google.com, Group-1
; DOMAIN-SUFFIX, google.com, Group-1
FINAL, Group-1

[Dns]
; hijack = dns endpoint tag
hijack = Dns-Out
; cliengIp = ip
clientIp = 114.114.114.114

[DnsServer]
; address, port, tag
localhost
223.5.5.5
8.8.8.8, 53, Remote
8.8.4.4

[DnsRule]
; type, filter, dns server tag
DOMAIN-KEYWORD, geosite:geolocation-!cn, Remote
DOMAIN-SUFFIX, google.com, Remote

[DnsHost]
; domain = ip
doubleclick.net = 127.0.0.1

[Log]
loglevel = warning
EOF

      chmod +x ${syspwd}/trojan.service
      systemctl enable trojan.service
      systemctl start trojan.service

      green "================================================================================="
      green "Trojan已安装完成，请使用以下链接下载trojan客户端，此客户端已配置好所有参数"
      green "1. 复制下面的链接，在浏览器打开，下载客户端"
      blue "2. MacOS客户端下载：http://$your_domain/$trojan_path/trojan-mac.zip"
      green "3. MacOS将下载的客户端解压，打开文件夹，打开start.command即打开并运行Trojan客户端"
      green "4. Trojan推荐使用 Mellow 工具代理（WIN/MAC通用）下载地址如下："
      green "   https://github.com/mellow-io/mellow/releases  (exe为Win客户端,dmg为Mac客户端)"
      green "   配置文件参考：http://$your_domain/mellow/mellow.conf"
      green "================================================================================="
    else
      red "==================================="
      red "https证书没有申请成果，本次安装失败"
      red "==================================="
    fi
  
  else
    red "================================"
    red "域名解析地址与本VPS IP地址不一致"
    red "本次安装失败，请确保域名解析正常"
    red "================================"
  fi
}

remove_trojan() {
  red "================================"
  red "即将卸载trojan                  "
  red "同时卸载安装的nginx             "
  red "================================"
  systemctl stop trojan
  systemctl disable trojan
  rm -f ${syspwd}/trojan.service
  if [ "$release" == "centos" ]; then
    yum remove -y nginx
  else
    apt autoremove -y nginx
  fi
  rm -rf /usr/src/trojan*
  rm -rf /usr/share/nginx/html/*
  rm -rf /usr/src/latest*
  green "=============="
  green "trojan删除完毕"
  green "=============="
}

bbr_boost_sh(){
  wget -N --no-check-certificate "https://raw.githubusercontent.com/chiakge/Linux-NetSpeed/master/tcp.sh" && chmod +x tcp.sh && ./tcp.sh
}

start_menu() {
  clear
  green " ===================================="
  green " 介绍：一键安装trojan                "
  green " 作者：kashin                        "
  green " ===================================="
  echo
  green " 1. 安装trojan"
  red " 2. 卸载trojan"
  green " 3. 安装bbr-plus"
  yellow " 0. 退出脚本"
  echo
  read -p "请输入数字:" num
  case "$num" in
    1)
      read -p "请输入端口号:" myport
      install_trojan $myport
      ;;

    2)
      remove_trojan
      ;;

    3)
      bbr_boost_sh
      ;;

    0)
      exit 1
      ;;

    *)
      clear
      red "请输入正确数字"
      sleep 1s
      start_menu
      ;;
  esac
}

start_menu
