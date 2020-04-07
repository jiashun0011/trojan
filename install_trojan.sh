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
  syspwd='/usr/lib/systemd/system/'
elif cat /etc/issue | grep -Eqi 'debian'; then
  release='debian'
  syspkg='apt-get'
  syspwd='/lib/systemd/system/'
elif cat /etc/issue | grep -Eqi 'ubuntu'; then
  release='ubuntu'
  syspkg='apt-get'
  syspwd='/lib/systemd/system/'
elif cat /etc/issue | grep -Eqi 'centos|red hat|redhat'; then
  release='centos'
  syspkg='yum'
  syspwd='/usr/lib/systemd/system/'
elif cat /proc/version | grep -Eqi 'debian'; then
  release='debian'
  syspkg='apt-get'
  syspwd='/lib/systemd/system/'
elif cat /proc/version | grep -Eqi 'ubuntu'; then
  release='ubuntu'
  syspkg='apt-get'
  syspwd='/lib/systemd/system/'
elif cat /proc/version | grep -Eqi 'centos|red hat|redhat'; then
  release='centos'
  syspkg='yum'
  syspwd='/usr/lib/systemd/system/'
fi

if [ ! -e '/etc/redhat-release' ]; then
  red "==============="
  red " 仅支持CentOS7"
  red "==============="
  exit
fi

if [ -n "$(grep ' 6\.' /etc/redhat-release)" ]; then
  red "==============="
  red " 仅支持CentOS7"
  red "==============="
  exit
fi


install_trojan() {
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
    
    systemctl enable nginx.service

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
    wget https://github.com/atrandys/v2ray-ws-tls/raw/master/web.zip
    unzip web.zip
    systemctl restart nginx.service

    # generate certificate for https
    mkdir /usr/src/trojan-cert
    curl https://get.acme.sh | sh
    ~/.acme.sh/acme.sh --issue -d $your_domain --webroot /usr/share/nginx/html/
    ~/.acme.sh/acme.sh --installcert -d  $your_domain \
      --key-file   /usr/src/trojan-cert/private.key \
      --fullchain-file /usr/src/trojan-cert/fullchain.cer \
      --reloadcmd  "systemctl force-reload  nginx.service"

    if [ test -s /usr/src/trojan-cert/fullchain.cer ]; then
      cd /usr/src
      #wget https://github.com/trojan-gfw/trojan/releases/download/v1.13.0/trojan-1.13.0-linux-amd64.tar.xz
      wget https://github.com/trojan-gfw/trojan/releases/download/v1.14.0/trojan-1.14.0-linux-amd64.tar.xz
      tar xf trojan-1.*
      #下载trojan客户端
      wget https://github.com/atrandys/trojan/raw/master/trojan-cli.zip
      unzip trojan-cli.zip
      cp /usr/src/trojan-cert/fullchain.cer /usr/src/trojan-cli/fullchain.cer
      trojan_passwd=$(cat /dev/urandom | head -1 | md5sum | head -c 8)

      cat > /usr/src/trojan-cli/config.json <<-EOF
{
  "run_type": "client",
  "local_addr": "127.0.0.1",
  "local_port": 1080,
  "remote_addr": "$your_domain",
  "remote_port": 443,
  "password": [
    "$trojan_passwd"
  ],
  "log_level": 1,
  "ssl": {
    "verify": true,
    "verify_hostname": true,
    "cert": "fullchain.cer",
    "cipher_tls13":"TLS_AES_128_GCM_SHA256:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_256_GCM_SHA384",
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
    "fast_open": false,
    "fast_open_qlen": 20
  }
}
EOF
      rm -rf /usr/src/trojan/server.conf

      cat > /usr/src/trojan/server.conf <<-EOF
{
  "run_type": "server",
  "local_addr": "0.0.0.0",
  "local_port": 443,
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
      cd /usr/src/trojan-cli/
      zip -q -r trojan-cli.zip /usr/src/trojan-cli/
      trojan_path=$(cat /dev/urandom | head -1 | md5sum | head -c 16)
      mkdir /usr/share/nginx/html/${trojan_path}
      mv /usr/src/trojan-cli/trojan-cli.zip /usr/share/nginx/html/${trojan_path}/
      #增加启动脚本
  
      cat > /usr/lib/systemd/system/trojan.service <<-EOF
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

      chmod +x /usr/lib/systemd/system/trojan.service
      systemctl start trojan.service
      systemctl enable trojan.service
      green "======================================================================"
      green "Trojan已安装完成，请使用以下链接下载trojan客户端，此客户端已配置好所有参数"
      green "1、复制下面的链接，在浏览器打开，下载客户端"
      blue "http://${your_domain}/$trojan_path/trojan-cli.zip"
      green "2、将下载的压缩包解压，打开文件夹，打开start.bat即打开并运行Trojan客户端"
      green "3、打开stop.bat即关闭Trojan客户端"
      green "4、Trojan客户端需要搭配浏览器插件使用，例如switchyomega等"
      green "======================================================================"
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
  rm -f /usr/lib/systemd/system/trojan.service
  yum remove -y nginx
  rm -rf /usr/src/trojan*
  rm -rf /usr/share/nginx/html/*
  green "=============="
  green "trojan删除完毕"
  green "=============="
}

start_menu() {
  clear
  green " ===================================="
  green " 介绍：一键安装trojan                "
  green " 系统：>=centos7                     "
  green " 作者：kashin                        "
  green " ===================================="
  echo
  green " 1. 安装trojan"
  red " 2. 卸载trojan"
  yellow " 0. 退出脚本"
  echo
  read -p "请输入数字:" num
  case "$num" in
    1)
      install_trojan
      ;;

    2)
      remove_trojan 
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
