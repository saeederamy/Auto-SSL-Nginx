#!/bin/bash

# --- Fix Backspace ^H Issue ---
stty erase ^H

# Check Root Access
if [ "$EUID" -ne 0 ]; then
  echo -e "\e[31mError: Please run this script as root (sudo).\e[0m"
  exit 1
fi

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
    rm -f /etc/nginx/sites-enabled/default
    rm -f /etc/nginx/sites-enabled/$DOMAIN
    rm -f /etc/nginx/sites-available/$DOMAIN
    
    apt update && apt install nginx curl ufw socat -y
    
    # فایل تنظیمات پایه
    cat > "/etc/nginx/sites-available/$DOMAIN" <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    client_max_body_size 0;

    location / {
        add_header Content-Type text/plain;
        return 200 "Nginx is active for $DOMAIN. Root path is working.";
    }
    #---PROXY_MARKER--- (DO NOT REMOVE)
}
EOF

    ln -sf "/etc/nginx/sites-available/$DOMAIN" "/etc/nginx/sites-enabled/"
    systemctl restart nginx

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

    location / { 
        add_header Content-Type text/plain;
        return 200 "Secure SSL Active for $DOMAIN. Root path is working.";
    }
    #---PROXY_MARKER--- (DO NOT REMOVE)
}
EOF
    fi
    
    systemctl restart nginx
    echo -e "\e[32m✔ Domain and SSL setup finished.\e[0m"
    read -p "Press Enter to continue..." 
}

# --- 2) Add Reverse Proxy Path (New Standard Method) ---
add_proxy() {
    header
    echo -e "\e[1;33m[2] Add New Reverse Proxy Path\e[0m\n"
    read -e -p "Enter Domain: " DOMAIN
    CONF_FILE="/etc/nginx/sites-available/$DOMAIN"

    if [ ! -f "$CONF_FILE" ]; then 
        echo -e "\e[31mError: Domain config not found!\e[0m"
        sleep 2; return;
    fi
    
    read -e -p "Enter Internal Port (e.g., 2053): " PORT
    read -e -p "Enter Path (e.g., ui): " PPATH
    PPATH="${PPATH#/}"
    PPATH="${PPATH%/}"

    # بررسی تکراری نبودن مسیر
    if grep -q "/$PPATH/" "$CONF_FILE"; then
        echo -e "\e[31mError: This path already exists!\e[0m"
        sleep 2; return;
    fi

    # ایجاد بلاک تنظیمات جدید
    PROXY_BLOCK="
    location ^~ /$PPATH/ {
        proxy_pass http://127.0.0.1:$PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \"upgrade\";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
        proxy_read_timeout 600s;
    }
    location = /$PPATH {
        return 301 \$scheme://\$host/\$PPATH/;
    }
    #---PROXY_MARKER---"

    # جایگزینی مارکر با بلاک جدید
    sed -i "s|#---PROXY_MARKER---|${PROXY_BLOCK}|g" "$CONF_FILE"
    
    nginx -t && systemctl restart nginx
    echo -e "\e[32m✔ Success: https://$DOMAIN/$PPATH/ -> Port $PORT\e[0m"
    echo -e "\e[1;33m⚠️  Reminder: Set Web Base Path to /$PPATH/ in x-ui settings!\e[0m"
    read -p "Press Enter to continue..." 
}

# --- 3) List Active Proxies ---
list_proxies() {
    header
    echo -e "\e[1;33m[3] List of Paths in Configs\e[0m\n"
    for f in /etc/nginx/sites-available/*; do
        [ -e "$f" ] || continue
        echo -e "\e[1;32m● Config: $(basename "$f")\e[0m"
        grep "location ^~ /" "$f" | sed -E 's/.*location \^~ \/(.*)\/ \{.*/   ➜ Path: \/\1/'
    done
    read -p "Press Enter to continue..." 
}

# --- 4) Firewall & Uninstall (Keep as before) ---
manage_ufw() {
    header
    echo -e "1) Open 80, 443, 22\n2) Disable Firewall"
    read -p "Select: " fchoice
    [ "$fchoice" == "1" ] && ufw allow 80,443,22/tcp && ufw --force enable
    [ "$fchoice" == "2" ] && ufw disable
}

uninstall_all() {
    header
    read -p "Confirm Uninstall? (y/n): " confirm
    if [ "$confirm" == "y" ]; then
        systemctl stop nginx
        apt purge nginx certbot -y
        rm -rf /etc/nginx/sites-* /etc/letsencrypt
        echo "✔ Cleaned."
        exit 0
    fi
}

while true; do
    header
    echo -e "1) Setup Domain & SSL"
    echo -e "2) Add Proxy Path"
    echo -e "3) List Active Paths"
    echo -e "4) Firewall Settings"
    echo -e "5) FULL UNINSTALL"
    echo -e "6) Exit"
    read -p " Option [1-6]: " opt
    case $opt in
        1) install_nginx_ssl ;;
        2) add_proxy ;;
        3) list_proxies ;;
        4) manage_ufw ;;
        5) uninstall_all ;;
        6) exit 0 ;;
    esac
done
