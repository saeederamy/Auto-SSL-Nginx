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
    echo -e "\e[36m┃\e[0m \e[1;37m        NGINX PROXY MANAGER & SSL CONFIGURATOR        \e[0m \e[36m┃\e[0m"
    echo -e "\e[36m┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛\e[0m"
}

# --- تابع بازسازی هوشمند کانفیگ ---
rebuild_config() {
    local DOMAIN=$1
    local CONF_FILE="$NGINX_CONF_DIR/$DOMAIN"
    local PATHS_FILE="$DATA_DIR/$DOMAIN.paths"
    local SSL_TYPE_FILE="$DATA_DIR/$DOMAIN.ssl"
    
    # ساخت بدنه اصلی پورت 80
    cat > "$CONF_FILE" <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    client_max_body_size 0;

EOF

    # اضافه کردن پث‌ها به پورت 80
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
    location / { add_header Content-Type text/plain; return 200 "Nginx active for $DOMAIN"; }
}
EOF

    # اگر SSL فعال است، بلاک 443 را بساز
    if [ -f "$SSL_TYPE_FILE" ]; then
        SSL_TYPE=$(cat "$SSL_TYPE_FILE")
        cat >> "$CONF_FILE" <<EOF
server {
    listen 443 ssl;
    server_name $DOMAIN;
    client_max_body_size 0;
EOF
        if [ "$SSL_TYPE" == "certbot" ]; then
            cat >> "$CONF_FILE" <<EOF
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
EOF
        else
            cat >> "$CONF_FILE" <<EOF
    ssl_certificate /etc/nginx/ssl/$DOMAIN.cer;
    ssl_certificate_key /etc/nginx/ssl/$DOMAIN.key;
EOF
        fi

        # اضافه کردن پث‌ها به پورت 443
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
    location / { add_header Content-Type text/plain; return 200 "Secure SSL Active for $DOMAIN"; }
}
EOF
    fi

    ln -sf "$CONF_FILE" "/etc/nginx/sites-enabled/"
    nginx -t && systemctl restart nginx
}

# --- 1) Setup Domain & SSL ---
install_nginx_ssl() {
    header
    read -e -p "Enter Domain (e.g., p1.fastabotics.online): " DOMAIN
    
    rm -f /etc/nginx/sites-enabled/default
    apt update && apt install nginx curl certbot python3-certbot-nginx ufw socat -y
    
    rebuild_config "$DOMAIN"
    
    echo -e "\nChoose SSL Provider: 1) Certbot 2) Acme.sh"
    read -p "Selection (1/2): " ssl_choice
    if [ "$ssl_choice" == "1" ]; then
        certbot --nginx -d $DOMAIN --non-interactive --agree-tos --register-unsafely-without-email --force-renewal
        echo "certbot" > "$DATA_DIR/$DOMAIN.ssl"
    elif [ "$ssl_choice" == "2" ]; then
        curl https://get.acme.sh | sh
        ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
        ~/.acme.sh/acme.sh --issue -d $DOMAIN --nginx
        mkdir -p /etc/nginx/ssl
        ~/.acme.sh/acme.sh --install-cert -d $DOMAIN --key-file /etc/nginx/ssl/$DOMAIN.key --fullchain-file /etc/nginx/ssl/$DOMAIN.cer
        echo "acme" > "$DATA_DIR/$DOMAIN.ssl"
    fi
    
    rebuild_config "$DOMAIN"
    echo -e "\e[32m✔ SSL Setup Complete.\e[0m"
    read -p "Press Enter to continue..."
}

# --- 2) Add Proxy Path ---
add_proxy() {
    header
    read -e -p "Enter Domain: " DOMAIN
    if [ ! -f "$NGINX_CONF_DIR/$DOMAIN" ]; then echo -e "\e[31mError: Domain not found!\e[0m"; sleep 2; return; fi
    
    read -e -p "Enter Internal Port (e.g., 2053): " PORT
    read -e -p "Enter Path (e.g., ui): " PPATH
    PPATH="${PPATH#/}"
    PPATH="${PPATH%/}"

    # ذخیره در فایل دیتا
    echo "$PPATH,$PORT" >> "$DATA_DIR/$DOMAIN.paths"
    
    rebuild_config "$DOMAIN"
    echo -e "\e[32m✔ Success: https://$DOMAIN/$PPATH/\e[0m"
    read -p "Press Enter to continue..."
}

# --- 3) List Active Proxies ---
list_proxies() {
    header
    echo -e "\e[1;33m[3] Active Proxies & Paths\e[0m\n"
    for f in "$DATA_DIR"/*.paths; do
        [ -e "$f" ] || continue
        DOMAIN=$(basename "$f" .paths)
        echo -e "\e[1;32m● Domain: $DOMAIN\e[0m"
        while IFS=',' read -r ppath pport; do
            echo "   ➜ https://$DOMAIN/$ppath/  -->  Port: $pport"
        done < "$f"
    done
    read -p "Press Enter to continue..."
}

# --- 4) Delete a Specific Path ---
delete_path() {
    header
    read -e -p "Enter Domain: " DOMAIN
    PATHS_FILE="$DATA_DIR/$DOMAIN.paths"
    if [ ! -f "$PATHS_FILE" ]; then echo "No paths found."; sleep 2; return; fi
    
    echo "Select path to delete:"
    cat -n "$PATHS_FILE"
    read -p "Choice (Number): " choice
    sed -i "${choice}d" "$PATHS_FILE"
    
    rebuild_config "$DOMAIN"
    echo "✔ Deleted and Config Rebuilt."
    sleep 2
}

# --- 5) Firewall Management ---
manage_ufw() {
    header
    echo -e "1) Open 80, 443, 22\n2) Block a Port\n3) Disable Firewall"
    read -p "Select: " fchoice
    case $fchoice in
        1) ufw allow 80,443,22/tcp && ufw --force enable ;;
        2) read -p "Port: " p && ufw deny $p ;;
        3) ufw disable ;;
    esac
}

# --- 6) FULL UNINSTALL ---
uninstall_all() {
    header
    read -p "Confirm Full Uninstall? (y/n): " confirm
    if [ "$confirm" == "y" ]; then
        systemctl stop nginx
        apt purge nginx certbot -y
        apt autoremove -y
        rm -rf "$DATA_DIR" /etc/nginx/ssl /etc/letsencrypt
        echo "✔ Cleaned. Deleting script..."
        rm -- "$0"
        exit 0
    fi
}

# --- Main Loop ---
while true; do
    header
    echo -e "1) Setup Domain & SSL"
    echo -e "2) Add Proxy Path"
    echo -e "3) List Active Proxies"
    echo -e "4) Delete a Specific Path"
    echo -e "5) Firewall (UFW)"
    echo -e "6) FULL UNINSTALL"
    echo -e "7) Exit"
    echo -e "\e[36m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓\e[0m"
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
