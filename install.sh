#!/bin/bash

# --- Fix Backspace ^H Issue ---
stty erase ^H

# Check Root Access
if [ "$EUID" -ne 0 ]; then
  echo -e "\e[31mError: Please run this script as root (sudo).\e[0m"
  exit 1
fi

# Directories
NGINX_CONF_DIR="/etc/nginx/sites-available"
DATA_DIR="/etc/nginx/proxy_manager"
mkdir -p "$DATA_DIR"

header() {
    clear
    echo -e "\e[36m┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓\e[0m"
    echo -e "\e[36m┃\e[0m \e[1;37m        NGINX PROXY MANAGER - ULTIMATE FIX           \e[0m \e[36m┃\e[0m"
    echo -e "\e[36m┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛\e[0m"
}

# تابع بازسازی کانفیگ (قلب تپنده اسکریپت)
rebuild_config() {
    local DOMAIN=$1
    local CONF_FILE="$NGINX_CONF_DIR/$DOMAIN"
    local PATHS_FILE="$DATA_DIR/$DOMAIN.paths"
    local SSL_TYPE_FILE="$DATA_DIR/$DOMAIN.ssl"
    
    # شروع ساخت فایل
    echo "server {" > "$CONF_FILE"
    echo "    listen 80;" >> "$CONF_FILE"
    echo "    server_name $DOMAIN;" >> "$CONF_FILE"
    echo "    client_max_body_size 0;" >> "$CONF_FILE"

    # اضافه کردن پث‌ها برای پورت 80
    if [ -f "$PATHS_FILE" ]; then
        while IFS=',' read -r ppath pport; do
            echo "    location ^~ /$ppath/ { proxy_pass http://127.0.0.1:$pport; include /etc/nginx/proxy_params; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection \"upgrade\"; }" >> "$CONF_FILE"
            echo "    location = /$ppath { return 301 \$scheme://\$host/\$ppath/; }" >> "$CONF_FILE"
        done < "$PATHS_FILE"
    fi

    echo "    location / { add_header Content-Type text/plain; return 200 \"Nginx active for $DOMAIN\"; }" >> "$CONF_FILE"
    echo "}" >> "$CONF_FILE"

    # اگر SSL فعال است، بلاک 443 را هم بساز
    if [ -f "$SSL_TYPE_FILE" ]; then
        SSL_TYPE=$(cat "$SSL_TYPE_FILE")
        echo "server {" >> "$CONF_FILE"
        echo "    listen 443 ssl;" >> "$CONF_FILE"
        echo "    server_name $DOMAIN;" >> "$CONF_FILE"
        echo "    client_max_body_size 0;" >> "$CONF_FILE"
        
        if [ "$SSL_TYPE" == "certbot" ]; then
            echo "    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;" >> "$CONF_FILE"
            echo "    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;" >> "$CONF_FILE"
        else
            echo "    ssl_certificate /etc/nginx/ssl/$DOMAIN.cer;" >> "$CONF_FILE"
            echo "    ssl_certificate_key /etc/nginx/ssl/$DOMAIN.key;" >> "$CONF_FILE"
        fi

        if [ -f "$PATHS_FILE" ]; then
            while IFS=',' read -r ppath pport; do
                echo "    location ^~ /$ppath/ { proxy_pass http://127.0.0.1:$pport; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection \"upgrade\"; proxy_set_header Host \$host; proxy_set_header X-Real-IP \$remote_addr; proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for; proxy_set_header X-Forwarded-Proto \$scheme; proxy_buffering off; }" >> "$CONF_FILE"
                echo "    location = /$ppath { return 301 \$scheme://\$host/\$ppath/; }" >> "$CONF_FILE"
            done < "$PATHS_FILE"
        fi
        echo "    location / { add_header Content-Type text/plain; return 200 \"Secure SSL Active for $DOMAIN\"; }" >> "$CONF_FILE"
        echo "}" >> "$CONF_FILE"
    fi

    nginx -t && systemctl restart nginx
}

# --- 1) Setup Domain & SSL ---
install_nginx_ssl() {
    header
    read -e -p "Enter Domain: " DOMAIN
    apt update && apt install nginx curl certbot python3-certbot-nginx -y
    rm -f /etc/nginx/sites-enabled/default
    
    # ایجاد دامنه بدون SSL ابتدا
    rebuild_config "$DOMAIN"
    ln -sf "$NGINX_CONF_DIR/$DOMAIN" "/etc/nginx/sites-enabled/"
    
    echo -e "\nChoose SSL Provider: 1) Certbot 2) Acme.sh"
    read -p "Selection: " ssl_choice
    if [ "$ssl_choice" == "1" ]; then
        certbot --nginx -d $DOMAIN --non-interactive --agree-tos --register-unsafely-without-email
        echo "certbot" > "$DATA_DIR/$DOMAIN.ssl"
    else
        curl https://get.acme.sh | sh
        ~/.acme.sh/acme.sh --issue -d $DOMAIN --nginx
        mkdir -p /etc/nginx/ssl
        ~/.acme.sh/acme.sh --install-cert -d $DOMAIN --key-file /etc/nginx/ssl/$DOMAIN.key --fullchain-file /etc/nginx/ssl/$DOMAIN.cer
        echo "acme" > "$DATA_DIR/$DOMAIN.ssl"
    fi
    
    rebuild_config "$DOMAIN"
    echo -e "\e[32m✔ SSL Setup Complete.\e[0m"
    read -p "Press Enter..."
}

# --- 2) Add Proxy Path ---
add_proxy() {
    header
    read -e -p "Enter Domain: " DOMAIN
    [ ! -f "$NGINX_CONF_DIR/$DOMAIN" ] && echo "Domain not found!" && sleep 2 && return
    
    read -e -p "Enter Internal Port: " PORT
    read -e -p "Enter Path (e.g. ui): " PPATH
    PPATH="${PPATH#/}"
    PPATH="${PPATH%/}"

    # ذخیره در دیتابیس کوچک اسکریپت
    echo "$PPATH,$PORT" >> "$DATA_DIR/$DOMAIN.paths"
    
    # بازسازی کامل کانفیگ
    rebuild_config "$DOMAIN"
    
    echo -e "\e[32m✔ Success: https://$DOMAIN/$PPATH/\e[0m"
    read -p "Press Enter..."
}

# --- 3) Delete Domain or Paths ---
delete_data() {
    header
    echo "1) Delete a Path"
    echo "2) Delete a Domain"
    read -p "Choice: " dopt
    if [ "$dopt" == "1" ]; then
        read -e -p "Enter Domain: " DOMAIN
        [ ! -f "$DATA_DIR/$DOMAIN.paths" ] && return
        cat -n "$DATA_DIR/$DOMAIN.paths"
        read -p "Line number to delete: " line
        sed -i "${line}d" "$DATA_DIR/$DOMAIN.paths"
        rebuild_config "$DOMAIN"
    else
        read -e -p "Enter Domain: " DOMAIN
        rm -f "$NGINX_CONF_DIR/$DOMAIN" "/etc/nginx/sites-enabled/$DOMAIN" "$DATA_DIR/$DOMAIN"*
        systemctl restart nginx
    fi
}

while true; do
    header
    echo -e "1) Setup Domain & SSL"
    echo -e "2) Add Proxy Path"
    echo -e "3) Delete Path/Domain"
    echo -e "4) Firewall (UFW)"
    echo -e "5) Exit"
    read -p " Option: " opt
    case $opt in
        1) install_nginx_ssl ;;
        2) add_proxy ;;
        3) delete_data ;;
        4) ufw allow 80,443,22/tcp && ufw --force enable ;;
        5) exit 0 ;;
    esac
done
