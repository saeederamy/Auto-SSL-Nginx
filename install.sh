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
    echo -e "\e[36m┃\e[0m \e[1;37m        NGINX PROXY MANAGER - RESCUE EDITION         \e[0m \e[36m┃\e[0m"
    echo -e "\e[36m┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛\e[0m"
}

# --- تابع بازسازی کانفیگ با چک کردن فیزیکی فایل‌های SSL ---
rebuild_config() {
    local DOMAIN=$1
    local CONF_FILE="$NGINX_CONF_DIR/$DOMAIN"
    local PATHS_FILE="$DATA_DIR/$DOMAIN.paths"
    local SSL_TYPE_FILE="$DATA_DIR/$DOMAIN.ssl"
    
    # شروع ساخت فایل پورت 80
    cat > "$CONF_FILE" <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    client_max_body_size 0;

EOF
    # افزودن مسیرها به پورت 80
    if [ -f "$PATHS_FILE" ]; then
        while IFS=',' read -r ppath pport; do
            [ -z "$ppath" ] && continue
            cat >> "$CONF_FILE" <<EOF
    location ^~ /$ppath/ {
        proxy_pass http://127.0.0.1:$pport;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }
    location = /$ppath { return 301 \$scheme://\$host/\$ppath/; }
EOF
        done < "$PATHS_FILE"
    fi
    cat >> "$CONF_FILE" <<EOF
    location / { add_header Content-Type text/plain; return 200 "Nginx is active on Port 80 for $DOMAIN"; }
}
EOF

    # چک کردن هوشمند گواهینامه قبل از ساخت بلاک SSL
    if [ -f "$SSL_TYPE_FILE" ]; then
        SSL_TYPE=$(cat "$SSL_TYPE_FILE")
        CERT_PATH=""
        KEY_PATH=""
        
        if [ "$SSL_TYPE" == "certbot" ]; then
            CERT_PATH="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
            KEY_PATH="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
        else
            CERT_PATH="/etc/nginx/ssl/$DOMAIN.cer"
            KEY_PATH="/etc/nginx/ssl/$DOMAIN.key"
        fi

        # فقط اگر فایل‌های گواهینامه واقعاً در سرور موجود باشند، بلاک 443 را بنویس
        if [ -f "$CERT_PATH" ] && [ -f "$KEY_PATH" ]; then
            cat >> "$CONF_FILE" <<EOF
server {
    listen 443 ssl;
    server_name $DOMAIN;
    ssl_certificate $CERT_PATH;
    ssl_certificate_key $KEY_PATH;
    client_max_body_size 0;
EOF
            if [ -f "$PATHS_FILE" ]; then
                while IFS=',' read -r ppath pport; do
                    [ -z "$ppath" ] && continue
                    cat >> "$CONF_FILE" <<EOF
    location ^~ /$ppath/ {
        proxy_pass http://127.0.0.1:$pport;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
    }
    location = /$ppath { return 301 \$scheme://\$host/\$ppath/; }
EOF
                done < "$PATHS_FILE"
            fi
            cat >> "$CONF_FILE" <<EOF
    location / { add_header Content-Type text/plain; return 200 "Secure SSL (HTTPS) Active for $DOMAIN"; }
}
EOF
        else
            # اگر فایل گواهینامه نیست، اطلاعات SSL را از دیتابیس حذف کن
            rm -f "$SSL_TYPE_FILE"
        fi
    fi

    ln -sf "$CONF_FILE" "/etc/nginx/sites-enabled/"
    nginx -t && systemctl restart nginx
}

# --- 1) Setup Domain & SSL ---
install_nginx_ssl() {
    header
    read -e -p "Enter Domain: " DOMAIN
    
    # گام اول: پاکسازی تمام فایل‌های خراب قبلی برای اجازه دادن به Nginx برای استارت
    echo -e "\e[34m[!] Cleaning up broken Nginx configs...\e[0m"
    rm -f "/etc/nginx/sites-enabled/$DOMAIN"
    rm -f "/etc/nginx/sites-available/$DOMAIN"
    rm -f "/etc/nginx/sites-enabled/default"
    
    # تلاش برای تعمیر نصب‌های ناقص
    apt --fix-broken install -y
    apt update && apt install nginx curl ufw socat certbot python3-certbot-nginx -y
    
    # ایجاد یک کانفیگ موقت روی پورت 80
    rebuild_config "$DOMAIN"
    
    echo -e "\e[1;33m\nChoose SSL Method (Let's Encrypt is Limited, try ZeroSSL):\e[0m"
    echo -e "1) Certbot (Let's Encrypt)\n2) Acme.sh (ZeroSSL - Best to bypass limits)"
    read -p "Selection (1/2): " ssl_choice
    
    if [ "$ssl_choice" == "1" ]; then
        if certbot --nginx -d $DOMAIN --non-interactive --agree-tos --register-unsafely-without-email; then
            echo "certbot" > "$DATA_DIR/$DOMAIN.ssl"
        else
            echo -e "\e[31m[!] Certbot failed. Check Rate Limits.\e[0m"
        fi
    else
        # نصب Acme.sh و استفاده از ZeroSSL
        curl https://get.acme.sh | sh
        ~/.acme.sh/acme.sh --set-default-ca --server zerossl
        ~/.acme.sh/acme.sh --issue -d $DOMAIN --nginx
        mkdir -p /etc/nginx/ssl
        if ~/.acme.sh/acme.sh --install-cert -d $DOMAIN --key-file /etc/nginx/ssl/$DOMAIN.key --fullchain-file /etc/nginx/ssl/$DOMAIN.cer; then
            echo "acme" > "$DATA_DIR/$DOMAIN.ssl"
        else
            echo -e "\e[31m[!] Acme.sh failed.\e[0m"
        fi
    fi
    
    rebuild_config "$DOMAIN"
    echo -e "\e[32m✔ Domain Setup Completed.\e[0m"
    read -p "Press Enter to continue..."
}

# --- 2) Add Proxy Path ---
add_proxy() {
    header
    read -e -p "Enter Domain: " DOMAIN
    if [ ! -f "$NGINX_CONF_DIR/$DOMAIN" ]; then echo "Error: Domain not found!"; sleep 2; return; fi
    read -e -p "Enter Internal Port (e.g., 2053): " PORT
    read -e -p "Enter Path (e.g., ui): " PPATH
    PPATH="${PPATH#/}"
    PPATH="${PPATH%/}"

    echo "$PPATH,$PORT" >> "$DATA_DIR/$DOMAIN.paths"
    rebuild_config "$DOMAIN"
    echo -e "\e[32m✔ Success: https://$DOMAIN/$PPATH/\e[0m"
    read -p "Press Enter to continue..."
}

# --- سایر گزینه‌ها ---
list_proxies() {
    header
    for f in "$DATA_DIR"/*.paths; do
        [ -e "$f" ] && echo -e "\e[1;32m● $(basename "$f" .paths)\e[0m" && cat "$f" | sed 's/,/ -> /'
    done
    read -p "Press Enter..."
}

delete_data() {
    header
    read -e -p "Enter Domain to delete: " DOMAIN
    rm -f "$NGINX_CONF_DIR/$DOMAIN" "/etc/nginx/sites-enabled/$DOMAIN" "$DATA_DIR/$DOMAIN"*
    systemctl restart nginx
    echo "✔ Deleted." && sleep 2
}

uninstall_all() {
    header
    read -p "Full Uninstall? (y/n): " confirm
    if [ "$confirm" == "y" ]; then
        systemctl stop nginx
        apt purge nginx certbot -y
        rm -rf "$DATA_DIR" /etc/nginx/ssl /etc/letsencrypt
        echo "✔ Cleaned."
        exit 0
    fi
}

# --- Main Loop ---
while true; do
    header
    echo -e "1) Setup Domain & SSL"
    echo -e "2) Add Proxy Path"
    echo -e "3) List Active Proxies"
    echo -e "4) Delete Domain Data"
    echo -e "5) Firewall (UFW)"
    echo -e "6) FULL UNINSTALL"
    echo -e "7) Exit"
    read -p " Option: " opt
    case $opt in
        1) install_nginx_ssl ;; 2) add_proxy ;; 3) list_proxies ;;
        4) delete_data ;; 5) ufw allow 80,443,22/tcp && ufw --force enable ;; 6) uninstall_all ;; 7) exit 0 ;;
    esac
done
