#!/bin/bash

# --- Fix Backspace ^H Issue ---
stty erase ^H

# Check Root Access
if [ "$EUID" -ne 0 ]; then
  echo -e "\e[31mError: Please run this script as root (sudo).\e[0m"
  exit 1
fi

NGINX_PROXY_DIR="/etc/nginx/proxy.d"
SCRIPT_PATH=$(realpath "$0")

# --- UI Header ---
header() {
    clear
    echo -e "\e[36m┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓\e[0m"
    echo -e "\e[36m┃\e[0m \e[1;37m        NGINX MANAGER & SSL AUTO-CONFIGURATOR         \e[0m \e[36m┃\e[0m"
    echo -e "\e[36m┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛\e[0m"
}

# --- 1) Install Nginx & Setup Domain & SSL ---
install_nginx_ssl() {
    header
    echo -e "\e[1;33m[1] Setup Domain and Install SSL\e[0m\n"
    read -e -p "Enter Domain (e.g., p1.fastabotics.online): " DOMAIN
    
    echo -e "\e[34mCleaning old configs and installing Nginx...\e[0m"
    apt update && apt install nginx curl ufw socat -y
    
    rm -f /etc/nginx/sites-enabled/default
    mkdir -p "$NGINX_PROXY_DIR/$DOMAIN"
    
    # فایل تنظیمات اصلی - Include را به بالای لوکیشن اصلی بردیم
    cat > "/etc/nginx/sites-available/$DOMAIN" <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    client_max_body_size 0;

    # اولویت با فایل‌های پروکسی است
    include $NGINX_PROXY_DIR/$DOMAIN/*.conf;

    location / {
        add_header Content-Type text/plain;
        return 200 "Nginx is active for $DOMAIN. Add a path to see your service.";
    }
}
EOF

    ln -sf "/etc/nginx/sites-available/$DOMAIN" "/etc/nginx/sites-enabled/"
    nginx -t && systemctl restart nginx

    echo -e "\nChoose SSL Provider: 1) Certbot 2) Acme.sh"
    read -p "Selection (1/2): " ssl_choice

    if [ "$ssl_choice" == "1" ]; then
        apt install certbot python3-certbot-nginx -y
        certbot --nginx -d $DOMAIN --non-interactive --agree-tos --register-unsafely-without-email
    elif [ "$ssl_choice" == "2" ]; then
        curl https://get.acme.sh | sh
        ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
        ~/.acme.sh/acme.sh --issue -d $DOMAIN --nginx
        mkdir -p /etc/nginx/ssl
        ~/.acme.sh/acme.sh --install-cert -d $DOMAIN \
            --key-file /etc/nginx/ssl/$DOMAIN.key \
            --fullchain-file /etc/nginx/ssl/$DOMAIN.cer \
            --reloadcmd "systemctl reload nginx"
        
        cat > "/etc/nginx/sites-available/$DOMAIN" <<EOF
server { listen 80; server_name $DOMAIN; return 301 https://\$host\$request_uri; }
server {
    listen 443 ssl;
    server_name $DOMAIN;
    ssl_certificate /etc/nginx/ssl/$DOMAIN.cer;
    ssl_certificate_key /etc/nginx/ssl/$DOMAIN.key;
    client_max_body_size 0;

    include $NGINX_PROXY_DIR/$DOMAIN/*.conf;

    location / { 
        add_header Content-Type text/plain;
        return 200 "Secure SSL Active for $DOMAIN. Root path is working.";
    }
}
EOF
    fi
    systemctl restart nginx
    echo -e "\e[32m✔ Domain and SSL setup finished.\e[0m"
    read -p "Press Enter to continue..." 
}

# --- 2) Add Reverse Proxy Path ---
add_proxy() {
    header
    echo -e "\e[1;33m[2] Add New Reverse Proxy Path\e[0m\n"
    read -e -p "Enter Domain: " DOMAIN
    if [ ! -f "/etc/nginx/sites-available/$DOMAIN" ]; then 
        echo -e "\e[31mError: Domain config not found!\e[0m"
        sleep 2; return;
    fi
    
    read -e -p "Enter Internal Port (e.g., 2053): " PORT
    read -e -p "Enter Path (e.g., ui): " PPATH
    PPATH="${PPATH#/}"
    PPATH="${PPATH%/}"

    # ایجاد فایل کانفیگ اختصاصی با اولویت ^~
    cat > "$NGINX_PROXY_DIR/$DOMAIN/$PPATH.conf" <<EOF
location ^~ /$PPATH/ {
    proxy_pass http://127.0.0.1:$PORT;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    
    proxy_buffering off;
    proxy_read_timeout 600s;
    client_max_body_size 0;
}

location = /$PPATH {
    return 301 \$scheme://\$host/\$PPATH/;
}
EOF
    
    # پاک کردن کش احتمالی Nginx و بارگذاری مجدد
    nginx -t && systemctl restart nginx
    echo -e "\e[32m✔ Success: https://$DOMAIN/$PPATH/ -> Port $PORT\e[0m"
    echo -e "\e[1;33m⚠️  If you still see the default message, please CLEAR YOUR BROWSER CACHE or use Incognito.\e[0m"
    read -p "Press Enter to continue..." 
}

# --- 3) List & Diagnostics (برای عیب‌یابی) ---
list_proxies() {
    header
    echo -e "\e[1;33m[3] List of Active Proxies & Debug Info\e[0m\n"
    if [ ! -d "$NGINX_PROXY_DIR" ]; then echo "No configs found."; sleep 2; return; fi
    
    for d in "$NGINX_PROXY_DIR"/*; do
        [ -d "$d" ] || continue
        DOMAIN=$(basename "$d")
        echo -e "\e[1;32m● Domain: $DOMAIN\e[0m"
        
        shopt -s nullglob
        for conf in "$d"/*.conf; do
            P=$(basename "$conf" .conf)
            PORT=$(grep "proxy_pass" "$conf" | sed -E 's/.*:([0-9]+).*/\1/' | head -1)
            echo -e "   ➜ Path: /$P  -->  Port: $PORT (File: $conf)"
        done
        shopt -u nullglob
    done
    echo -e "\n\e[34mNginx Status:\e[0m $(systemctl is-active nginx)"
    read -p "Press Enter to continue..." 
}

# --- بقیه توابع بدون تغییر ---
delete_path() {
    header
    read -e -p "Enter Domain: " DOMAIN
    files=("$NGINX_PROXY_DIR/$DOMAIN"/*.conf)
    if [ ${#files[@]} -eq 0 ]; then echo "No paths found."; sleep 2; return; fi
    i=1
    for f in "${files[@]}"; do echo "$i) $(basename "$f" .conf)"; let i++; done
    read -p "Choice: " choice
    rm "${files[$((choice-1))]}"
    systemctl restart nginx
    echo "✔ Deleted."
    sleep 1
}

manage_ufw() {
    header
    echo -e "1) Open 80, 443, 22\n2) Disable Firewall"
    read -p "Select: " fchoice
    case $fchoice in
        1) ufw allow 80,443,22/tcp && ufw --force enable ;;
        2) ufw disable ;;
    esac
}

uninstall_all() {
    header
    read -p "Confirm Uninstall? (y/n): " confirm
    if [ "$confirm" == "y" ]; then
        systemctl stop nginx
        apt purge nginx certbot -y
        rm -rf /etc/nginx/proxy.d /etc/nginx/ssl /etc/letsencrypt
        echo "✔ Cleaned."
        exit 0
    fi
}

while true; do
    header
    echo -e "1) Setup Domain & SSL"
    echo -e "2) Add Proxy Path"
    echo -e "3) List & Debug"
    echo -e "4) Delete Path"
    echo -e "5) Firewall"
    echo -e "6) FULL UNINSTALL"
    echo -e "7) Exit"
    read -p " Option [1-7]: " opt
    case $opt in
        1) install_nginx_ssl ;;
        2) add_proxy ;;
        3) list_proxies ;;
        4) delete_path ;;
        5) manage_ufw ;;
        6) uninstall_all ;;
        7) exit 0 ;;
    esac
done
