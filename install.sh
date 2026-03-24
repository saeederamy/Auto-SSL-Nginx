#!/bin/bash

# --- تنظیمات اولیه برای رفع مشکل Backspace ---
stty erase ^H

# بررسی دسترسی Root
if [ "$EUID" -ne 0 ]; then
  echo -e "\e[31mخطا: لطفا اسکریپت را با دسترسی root (sudo) اجرا کنید.\e[0m"
  exit 1
fi

NGINX_PROXY_DIR="/etc/nginx/proxy.d"
SCRIPT_NAME="auto-ssl"
GLOBAL_PATH="/usr/local/bin/$SCRIPT_NAME"

# --- تابع نصب دستور در سیستم ---
setup_command() {
    if [[ "$(realpath "$0")" != "$GLOBAL_PATH" ]]; then
        cp "$(realpath "$0")" "$GLOBAL_PATH"
        chmod +x "$GLOBAL_PATH"
        echo -e "\e[32m✔ دستور '$SCRIPT_NAME' در سیستم ثبت شد. از این پس فقط کافیست '$SCRIPT_NAME' را تایپ کنید.\e[0m"
    fi
}
setup_command

# --- توابع کمکی زیبایی ---
header() {
    clear
    echo -e "\e[36m┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓\e[0m"
    echo -e "\e[36m┃\e[0m \e[1;37m        مدیریت هوشمند انجینکس و گواهینامه SSL         \e[0m \e[36m┃\e[0m"
    echo -e "\e[36m┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛\e[0m"
}

# --- نصب Nginx و SSL ---
install_nginx_ssl() {
    header
    echo -e "\e[1;33m[۱] تنظیم دامنه و نصب SSL\e[0m\n"
    read -e -p "لطفا دامنه خود را وارد کنید (مثال: example.com): " DOMAIN
    
    echo -e "\e[34mدر حال نصب پیش‌نیازها...\e[0m"
    apt update && apt install nginx curl ufw -y
    mkdir -p "$NGINX_PROXY_DIR/$DOMAIN"

    echo -e "\nانتخاب صادرکننده گواهی:"
    echo "1) Certbot (استاندارد و خودکار)"
    echo "2) Acme.sh (سبک و حرفه‌ای)"
    read -p "کدام مورد؟ (1/2): " ssl_choice

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
    fi
    systemctl reload nginx
    echo -e "\e[32m✔ نصب با موفقیت انجام شد.\e[0m"
    read -p "اینتر بزنید..." 
}

# --- افزودن پروکسی جدید ---
add_proxy() {
    header
    echo -e "\e[1;33m[۲] افزودن مسیر ریورس پروکسی جدید\e[0m\n"
    read -e -p "دامنه (قبلا باید تعریف شده باشد): " DOMAIN
    if [ ! -d "$NGINX_PROXY_DIR/$DOMAIN" ]; then echo "خطا: این دامنه یافت نشد."; sleep 2; return; fi
    
    read -e -p "پورت داخلی سرویس شما (مثلا 8080): " PORT
    read -e -p "مسیر دلخواه (مثلا panel): " PPATH
    PPATH="${PPATH#/}"

    cat > "$NGINX_PROXY_DIR/$DOMAIN/$PPATH.conf" <<EOF
location /$PPATH/ {
    proxy_pass http://127.0.0.1:$PORT/;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
}
EOF
    nginx -t && systemctl reload nginx
    echo -e "\e[32m✔ مسیر https://$DOMAIN/$PPATH فعال شد.\e[0m"
    read -p "اینتر بزنید..." 
}

# --- لیست کردن و نمایش کلیدها ---
list_proxies() {
    header
    echo -e "\e[1;33m[۳] لیست پورت‌ها، مسیرها و کلیدهای SSL\e[0m\n"
    if [ ! -d "$NGINX_PROXY_DIR" ]; then echo "تنظیماتی یافت نشد."; sleep 2; return; fi
    
    for domain_path in "$NGINX_PROXY_DIR"/*; do
        DOMAIN=$(basename "$domain_path")
        echo -e "\e[1;32m● Domain: $DOMAIN\e[0m"
        
        # نمایش مسیر کلیدها
        if [ -d "/etc/letsencrypt/live/$DOMAIN" ]; then
            echo -e "   \e[90mPrivate Key:\e[0m /etc/letsencrypt/live/$DOMAIN/privkey.pem"
            echo -e "   \e[90mPublic Key: \e[0m /etc/letsencrypt/live/$DOMAIN/fullchain.pem"
        elif [ -f "/etc/nginx/ssl/$DOMAIN.key" ]; then
            echo -e "   \e[90mPrivate Key:\e[0m /etc/nginx/ssl/$DOMAIN.key"
            echo -e "   \e[90mPublic Key: \e[0m /etc/nginx/ssl/$DOMAIN.cer"
        fi

        for conf in "$domain_path"/*.conf; do
            [ -e "$conf" ] || continue
            PATH_NAME=$(basename "$conf" .conf)
            PORT=$(grep "proxy_pass" "$conf" | sed -E 's/.*:([0-9]+)\/.*/\1/')
            echo -e "   \e[36m➜ Path: /$PATH_NAME\e[0m  (Internal Port: $PORT)"
        done
        echo "----------------------------------------------------"
    done
    read -p "اینتر بزنید..." 
}

# --- حذف انتخابی مسیرها ---
delete_proxy_interactive() {
    header
    echo -e "\e[1;31m[۴] حذف انتخابی یک مسیر پروکسی\e[0m\n"
    read -e -p "دامنه را وارد کنید: " DOMAIN
    if [ ! -d "$NGINX_PROXY_DIR/$DOMAIN" ]; then echo "دامنه یافت نشد."; sleep 2; return; fi
    
    files=("$NGINX_PROXY_DIR/$DOMAIN"/*.conf)
    if [ ! -e "${files[0]}" ]; then echo "هیچ مسیری برای این دامنه تعریف نشده است."; sleep 2; return; fi
    
    echo "لیست مسیرهای فعال:"
    i=1
    for f in "${files[@]}"; do
        PATH_NAME=$(basename "$f" .conf)
        PORT=$(grep "proxy_pass" "$f" | sed -E 's/.*:([0-9]+)\/.*/\1/')
        echo "$i) Path: /$PATH_NAME  (Port: $PORT)"
        let i++
    done
    
    read -p "شماره مورد نظر برای حذف را وارد کنید: " choice
    target_file="${files[$((choice-1))]}"
    
    if [ -f "$target_file" ]; then
        rm "$target_file"
        systemctl reload nginx
        echo -e "\e[32m✔ مسیر با موفقیت حذف شد.\e[0m"
    else
        echo "انتخاب نامعتبر."
    fi
    sleep 2
}

# --- مدیریت فایروال ---
firewall_menu() {
    header
    echo -e "\e[1;33m[۵] مدیریت فایروال (UFW)\e[0m\n"
    echo "1) باز کردن پورت‌های ضروری (80, 443, 22)"
    echo "2) بستن یک پورت خاص (بستن دسترسی مستقیم به پروکسی‌ها)"
    echo "3) باز کردن یک پورت خاص"
    echo "4) غیرفعال کردن فایروال"
    read -p "انتخاب کنید: " fw
    case $fw in
        1) ufw allow 22/tcp && ufw allow 80/tcp && ufw allow 443/tcp && ufw --force enable ;;
        2) read -p "Port: " p && ufw deny $p ;;
        3) read -p "Port: " p && ufw allow $p ;;
        4) ufw disable ;;
    esac
}

# --- حذف کامل و پاک‌سازی ---
uninstall_all() {
    header
    echo -e "\e[1;31m!!! هشدار: این گزینه تمام تنظیمات، انجینکس و SSL را پاک می‌کند !!!\e[0m"
    read -p "آیا مطمئن هستید؟ (y/n): " confirm
    if [ "$confirm" == "y" ]; then
        systemctl stop nginx
        apt purge nginx certbot -y
        apt autoremove -y
        rm -rf /etc/nginx /etc/letsencrypt ~/.acme.sh "$GLOBAL_PATH"
        echo -e "\e[32m✔ تمام تنظیمات پاک شد.\e[0m"
        echo -e "\e[33mحذف خودکار اسکریپت در ۳ ثانیه...\e[0m"
        sleep 3
        rm -- "$0"
        exit
    fi
}

# --- حلقه اصلی منو ---
while true; do
    header
    echo -e "\e[1;32m۱)\e[0m نصب انجینکس و دریافت SSL برای دامنه جدید"
    echo -e "\e[1;32m۲)\e[0m ایجاد مسیر ریورس پروکسی (Port -> Path)"
    echo -e "\e[1;32m۳)\e[0m مشاهده تمام پروکسی‌ها، پورت‌ها و کلیدهای SSL"
    echo -e "\e[1;32m۴)\e[0m حذف انتخابی یک مسیر (بر اساس لیست پورت)"
    echo -e "\e[1;32m۵)\e[0m مدیریت فایروال UFW (بستن/باز کردن پورت)"
    echo -e "\e[1;31m۶)\e[0m پاک‌سازی کامل (حذف انجینکس، SSL و این اسکریپت)"
    echo -e "\e[1;37m۷)\e[0m خروج"
    echo -e "\e[36m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓\e[0m"
    read -p " گزینه مورد نظر [1-7]: " main_choice

    case $main_choice in
        1) install_nginx_ssl ;;
        2) add_proxy ;;
        3) list_proxies ;;
        4) delete_proxy_interactive ;;
        5) firewall_menu ;;
        6) uninstall_all ;;
        7) exit 0 ;;
        *) echo "انتخاب اشتباه."; sleep 1 ;;
    esac
done
