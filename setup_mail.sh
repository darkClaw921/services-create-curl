#!/usr/bin/env bash
set -e

### === ПРОВЕРКА ПРАВ ===
if [ "$(id -u)" -ne 0 ]; then
  echo "Ошибка: Требуются права sudo. Пожалуйста, запустите скрипт с sudo."
  echo "Пример: sudo bash setup_mail.sh"
  exit 1
fi

### === КОНСТАНТЫ И ПЕРЕМЕННЫЕ ===
MAIL_CONFIG_DIR="/var/lib/mail-server"
DOMAINS_LIST_FILE="${MAIL_CONFIG_DIR}/domains.list"
MAILBOXES_LIST_FILE="${MAIL_CONFIG_DIR}/mailboxes.list"
ENDPOINTS_LIST_FILE="${MAIL_CONFIG_DIR}/endpoints.list"

# Цвета для красивого вывода
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'



# Пример корректного задания цветов
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
NC=$'\033[0m'

export DEBIAN_FRONTEND=noninteractive

### === ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ ===

# Функция очистки экрана
clear_screen() {
  clear
}

# --- ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ ДЛЯ АДАПТИВНОЙ ТАБЛИЦЫ ---

# Удаляет ANSI-коды для корректного расчета длины
strip_ansi() {
  sed -r 's/\x1B\[[0-9;]*[mK]//g'
}

# Возвращает "видимую" длину строки (без ANSI-кодов)
vislen() {
  local s="$1"
  echo -n "$s" | strip_ansi | wc -m
}

# Печатает горизонтальную линию таблицы
print_hr() {
  local w1=$1 w2=$2 w3=$3 w4=$4
  printf "+-%s-+-%s-+-%s-+-%s-+\n" \
    "$(printf '%*s' "$w1" '' | tr ' ' '-')" \
    "$(printf '%*s' "$w2" '' | tr ' ' '-')" \
    "$(printf '%*s' "$w3" '' | tr ' ' '-')" \
    "$(printf '%*s' "$w4" '' | tr ' ' '-')"
}

# Печатает строку таблицы с учетом ANSI-цветов
print_row() {
  local c1="$1" c2="$2" c3="$3" c4="$4"
  local w1=$5 w2=$6 w3=$7 w4=$8

  local l1 l2 l3 l4 pad1 pad2 pad3 pad4
  l1=$(vislen "$c1"); l2=$(vislen "$c2"); l3=$(vislen "$c3"); l4=$(vislen "$c4")
  pad1=$((w1 - l1)); pad2=$((w2 - l2)); pad3=$((w3 - l3)); pad4=$((w4 - l4))

  printf "| %s%*s | %s%*s | %s%*s | %s%*s |\n" \
    "$c1" "$pad1" "" \
    "$c2" "$pad2" "" \
    "$c3" "$pad3" "" \
    "$c4" "$pad4" ""
}

# Инициализация директорий и файлов
init_mail_config() {
  if [ ! -d "$MAIL_CONFIG_DIR" ]; then
    mkdir -p "$MAIL_CONFIG_DIR"
  fi
  
  if [ ! -f "$DOMAINS_LIST_FILE" ]; then
    touch "$DOMAINS_LIST_FILE"
  fi
  
  if [ ! -f "$MAILBOXES_LIST_FILE" ]; then
    touch "$MAILBOXES_LIST_FILE"
  fi
  
  if [ ! -f "$ENDPOINTS_LIST_FILE" ]; then
    touch "$ENDPOINTS_LIST_FILE"
  fi
}

# Проверка установленных пакетов
check_packages_installed() {
  local packages=("postfix" "dovecot-core" "mariadb-server" "opendkim")
  local missing=()
  
  for package in "${packages[@]}"; do
    if ! dpkg -l | grep -q "^ii  $package "; then
      missing+=("$package")
    fi
  done
  
  if [ ${#missing[@]} -eq 0 ]; then
    return 0
  else
    return 1
  fi
}

# Ввод данных для установки почтового сервера
input_mail_server_config() {
  clear_screen
  echo -e "${BOLD}${CYAN}==============================================${NC}"
  echo -e "${BOLD}${CYAN}     НАСТРОЙКА ПОЧТОВОГО СЕРВЕРА              ${NC}"
  echo -e "${BOLD}${CYAN}==============================================${NC}"
  echo ""
  
  echo -e "${YELLOW}Введите данные для настройки почтового сервера:${NC}"
  echo ""
  
  echo -n -e "${GREEN}Домен (например, example.com): ${NC}"
  read DOMAIN
  if [ -z "$DOMAIN" ]; then
    echo -e "${RED}Домен не может быть пустым!${NC}"
    return 1
  fi
  
  echo -n -e "${GREEN}Hostname FQDN (например, mail.example.com): ${NC}"
  read HOSTNAME_FQDN
  if [ -z "$HOSTNAME_FQDN" ]; then
    HOSTNAME_FQDN="mail.$DOMAIN"
    echo -e "${YELLOW}Используется значение по умолчанию: $HOSTNAME_FQDN${NC}"
  fi
  
  echo -n -e "${GREEN}Имя пользователя почты (без домена): ${NC}"
  read MAIL_USER
  if [ -z "$MAIL_USER" ]; then
    echo -e "${RED}Имя пользователя не может быть пустым!${NC}"
    return 1
  fi
  
  echo -n -e "${GREEN}Пароль для почты (или Enter для автогенерации): ${NC}"
  read -s MAIL_PASS
  echo ""
  MAIL_PASS_AUTO_GENERATED=false
  if [ -z "$MAIL_PASS" ]; then
    MAIL_PASS=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
    MAIL_PASS_AUTO_GENERATED=true
    echo -e "${YELLOW}Сгенерирован пароль для почты: ${MAIL_PASS}${NC}"
  else
    echo -n -e "${GREEN}Подтвердите пароль: ${NC}"
    read -s MAIL_PASS_CONFIRM
    echo ""
    if [ "$MAIL_PASS" != "$MAIL_PASS_CONFIRM" ]; then
      echo -e "${RED}Пароли не совпадают!${NC}"
      return 1
    fi
  fi
  
  # Значения по умолчанию для БД
  VMAIL_UID=5000
  VMAIL_GID=5000
  VMAIL_DIR="/var/mail/vhosts"
  DB_NAME="mailserver"
  DB_USER="mailuser"
  
  # Проверяем, существует ли уже конфигурационный файл с паролем БД
  if [ -f "/etc/postfix/mysql-virtual-mailbox-domains.cf" ]; then
    # Используем существующий пароль БД
    DB_PASS=$(grep "^password" /etc/postfix/mysql-virtual-mailbox-domains.cf 2>/dev/null | awk -F' = ' '{print $2}' | tr -d ' ' || echo "")
    if [ -n "$DB_PASS" ]; then
      echo -e "${YELLOW}Используется существующий пароль БД из конфигурации.${NC}"
    else
      echo -n -e "${GREEN}Пароль для базы данных (или Enter для автогенерации): ${NC}"
      read -s DB_PASS
      echo ""
      if [ -z "$DB_PASS" ]; then
        DB_PASS=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
        echo -e "${YELLOW}Сгенерирован пароль БД: ${DB_PASS:0:10}...${NC}"
      fi
    fi
  else
    echo -n -e "${GREEN}Пароль для базы данных (или Enter для автогенерации): ${NC}"
    read -s DB_PASS
    echo ""
    if [ -z "$DB_PASS" ]; then
      DB_PASS=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
      echo -e "${YELLOW}Сгенерирован пароль БД: ${DB_PASS:0:10}...${NC}"
    fi
  fi
  
  return 0
}

# Установка почтового сервера
install_mail_server() {
  local domain="$1"
  local hostname_fqdn="$2"
  local mail_user="$3"
  local mail_pass="$4"
  local db_pass="$5"
  local vmail_uid="${6:-5000}"
  local vmail_gid="${7:-5000}"
  local vmail_dir="${8:-/var/mail/vhosts}"
  local db_name="${9:-mailserver}"
  local db_user="${10:-mailuser}"
  
  echo ""
  echo -e "${YELLOW}Начинаем установку почтового сервера для домена $domain...${NC}"
  echo ""
  
  # Проверяем, установлены ли пакеты
  if ! check_packages_installed; then
    echo -e "${YELLOW}Установка необходимых пакетов...${NC}"
    apt update
    apt -y upgrade
    
    apt -y install software-properties-common
    
    # Базовые пакеты
    apt -y install \
      postfix postfix-mysql \
      dovecot-core dovecot-imapd dovecot-lmtpd dovecot-mysql \
      mariadb-server mariadb-client \
      opendkim opendkim-tools \
      ufw certbot
  else
    echo -e "${GREEN}Необходимые пакеты уже установлены.${NC}"
  fi
  
  # Установка hostname
  hostnamectl set-hostname "$hostname_fqdn"
  
  # Настройка firewall
  echo -e "${YELLOW}Настройка firewall...${NC}"
  ufw allow OpenSSH 2>/dev/null || true
  ufw allow 25 2>/dev/null || true    # SMTP
  ufw allow 587 2>/dev/null || true   # submission
  ufw allow 993 2>/dev/null || true   # IMAPS
  ufw --force enable 2>/dev/null || true
  
  # Настройка MySQL/MariaDB
  echo -e "${YELLOW}Настройка базы данных...${NC}"
  
  # Проверяем, запущен ли MySQL
  if ! systemctl is-active --quiet mariadb && ! systemctl is-active --quiet mysql; then
    echo -e "${YELLOW}Запуск сервиса MySQL/MariaDB...${NC}"
    systemctl start mariadb 2>/dev/null || systemctl start mysql 2>/dev/null || true
    sleep 2
  fi
  
  # Создаем БД
  mysql_result=$(mysql -u root <<SQL 2>&1
CREATE DATABASE IF NOT EXISTS $db_name;
SQL
)
  
  if [ $? -ne 0 ]; then
    echo -e "${RED}Ошибка при создании БД: $mysql_result${NC}"
    return 1
  fi
  
  # Проверяем, существует ли пользователь, и создаем/обновляем его
  user_exists=$(mysql -u root -Nse "SELECT COUNT(*) FROM mysql.user WHERE User='$db_user' AND Host='localhost';" 2>&1)
  
  if [ "$user_exists" = "1" ]; then
    # Пользователь существует - обновляем пароль
    echo -e "${YELLOW}Пользователь БД уже существует, обновляем пароль...${NC}"
    mysql_result=$(mysql -u root <<SQL 2>&1
ALTER USER '$db_user'@'localhost' IDENTIFIED BY '$db_pass';
GRANT ALL PRIVILEGES ON $db_name.* TO '$db_user'@'localhost';
FLUSH PRIVILEGES;
SQL
)
  else
    # Пользователь не существует - создаем нового
    echo -e "${YELLOW}Создание нового пользователя БД...${NC}"
    mysql_result=$(mysql -u root <<SQL 2>&1
CREATE USER '$db_user'@'localhost' IDENTIFIED BY '$db_pass';
GRANT ALL PRIVILEGES ON $db_name.* TO '$db_user'@'localhost';
FLUSH PRIVILEGES;
SQL
)
  fi
  
  if [ $? -ne 0 ]; then
    echo -e "${RED}Ошибка при создании/обновлении пользователя БД: $mysql_result${NC}"
    return 1
  fi
  
  # Создаем таблицы
  mysql_result=$(mysql -u root "$db_name" <<SQL 2>&1
USE $db_name;

CREATE TABLE IF NOT EXISTS virtual_domains (
  id INT NOT NULL AUTO_INCREMENT,
  name VARCHAR(50) NOT NULL,
  PRIMARY KEY (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

CREATE TABLE IF NOT EXISTS virtual_users (
  id INT NOT NULL AUTO_INCREMENT,
  domain_id INT NOT NULL,
  password VARCHAR(106) NOT NULL,
  email VARCHAR(100) NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY email (email),
  FOREIGN KEY (domain_id) REFERENCES virtual_domains(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8;
SQL
)
  
  if [ $? -ne 0 ]; then
    echo -e "${RED}Ошибка при создании таблиц: $mysql_result${NC}"
    return 1
  fi

  # Добавляем домен в БД
  mysql_result=$(mysql -u root "$db_name" <<SQL 2>&1
INSERT IGNORE INTO virtual_domains (name) VALUES ('$domain');
SET @domain_id = (SELECT id FROM virtual_domains WHERE name='$domain' LIMIT 1);
INSERT IGNORE INTO virtual_users (domain_id, password, email)
VALUES (
  @domain_id,
  ENCRYPT('$mail_pass', CONCAT('\$6\$', SUBSTRING(SHA(RAND()), -16))),
  '$mail_user@$domain'
);
SQL
)
  
  if [ $? -ne 0 ]; then
    echo -e "${RED}Ошибка при добавлении домена в БД: $mysql_result${NC}"
    return 1
  fi

  # Создание пользователя vmail
  if ! id vmail >/dev/null 2>&1; then
    groupadd -g "$vmail_gid" vmail 2>/dev/null || true
    useradd -g vmail -u "$vmail_uid" vmail -d "$vmail_dir" -m 2>/dev/null || true
  fi
  
  mkdir -p "$vmail_dir"
  chown -R vmail:vmail "$vmail_dir"
  
  # Настройка Postfix
  echo -e "${YELLOW}Настройка Postfix...${NC}"
  postconf -e "myhostname = $hostname_fqdn"
  postconf -e "myorigin = $domain"
  postconf -e "mydestination = localhost"
  postconf -e "relayhost ="
  postconf -e "inet_interfaces = all"
  postconf -e "inet_protocols = ipv4"
  postconf -e "home_mailbox = Maildir/"
  postconf -e "virtual_transport = lmtp:unix:private/dovecot-lmtp"
  postconf -e "virtual_mailbox_domains = mysql:/etc/postfix/mysql-virtual-mailbox-domains.cf"
  postconf -e "virtual_mailbox_maps = mysql:/etc/postfix/mysql-virtual-mailbox-maps.cf"
  postconf -e "virtual_alias_maps = mysql:/etc/postfix/mysql-virtual-alias-maps.cf"
  postconf -e "smtpd_sasl_type = dovecot"
  postconf -e "smtpd_sasl_path = private/auth"
  postconf -e "smtpd_sasl_auth_enable = yes"
  postconf -e "smtpd_recipient_restrictions = permit_sasl_authenticated,permit_mynetworks,reject_unauth_destination"
  postconf -e "smtpd_use_tls = yes"
  postconf -e "smtpd_tls_auth_only = yes"
  postconf -e "smtpd_tls_security_level = may"
  postconf -e "smtp_tls_security_level = may"
  postconf -e "smtp_tls_loglevel = 1"
  
  # Создание конфигурационных файлов MySQL для Postfix
  # Если файлы существуют, обновляем только пароль, иначе создаем новые
  if [ ! -f "/etc/postfix/mysql-virtual-mailbox-domains.cf" ]; then
    cat > /etc/postfix/mysql-virtual-mailbox-domains.cf <<EOF
user = $db_user
password = $db_pass
hosts = 127.0.0.1
dbname = $db_name
query = SELECT 1 FROM virtual_domains WHERE name='%s'
EOF
  else
    # Обновляем пароль в существующем файле
    sed -i "s/^password = .*/password = $db_pass/" /etc/postfix/mysql-virtual-mailbox-domains.cf
  fi

  if [ ! -f "/etc/postfix/mysql-virtual-mailbox-maps.cf" ]; then
    cat > /etc/postfix/mysql-virtual-mailbox-maps.cf <<EOF
user = $db_user
password = $db_pass
hosts = 127.0.0.1
dbname = $db_name
query = SELECT 1 FROM virtual_users WHERE email='%s'
EOF
  else
    # Обновляем пароль в существующем файле
    sed -i "s/^password = .*/password = $db_pass/" /etc/postfix/mysql-virtual-mailbox-maps.cf
  fi

  if [ ! -f "/etc/postfix/mysql-virtual-alias-maps.cf" ]; then
    cat > /etc/postfix/mysql-virtual-alias-maps.cf <<EOF
user = $db_user
password = $db_pass
hosts = 127.0.0.1
dbname = $db_name
query = SELECT email FROM virtual_users WHERE email='%s'
EOF
  else
    # Обновляем пароль в существующем файле
    sed -i "s/^password = .*/password = $db_pass/" /etc/postfix/mysql-virtual-alias-maps.cf
  fi

  chmod 640 /etc/postfix/mysql-virtual-*.cf
  chown root:postfix /etc/postfix/mysql-virtual-*.cf
  
  # Настройка submission
  postconf -M submission/inet="submission inet n       -       y       -       -       smtpd" 2>/dev/null || true
  postconf -P submission/inet/syslog_name=postfix/submission 2>/dev/null || true
  postconf -P submission/inet/smtpd_tls_security_level=encrypt 2>/dev/null || true
  postconf -P submission/inet/smtpd_sasl_auth_enable=yes 2>/dev/null || true
  postconf -P submission/inet/smtpd_client_restrictions="permit_sasl_authenticated,reject" 2>/dev/null || true
  
  # Настройка Dovecot
  echo -e "${YELLOW}Настройка Dovecot...${NC}"
  cat > /etc/dovecot/dovecot.conf <<'EOF'
!include_try /usr/share/dovecot/protocols.d/*.protocol
dict {
}
!include conf.d/*.conf
!include_try local.conf
EOF

  sed -i 's/^#*\s*disable_plaintext_auth.*/disable_plaintext_auth = yes/' /etc/dovecot/conf.d/10-auth.conf
  sed -i 's/^auth_mechanisms.*/auth_mechanisms = plain login/' /etc/dovecot/conf.d/10-auth.conf

  cat > /etc/dovecot/conf.d/10-mail.conf <<EOF
mail_location = maildir:$vmail_dir/%d/%n
mail_privileged_group = mail
namespace inbox {
  inbox = yes
}
EOF

  cat > /etc/dovecot/conf.d/10-master.conf <<EOF
service imap-login {
  inet_listener imap {
    port = 0
  }
  inet_listener imaps {
    port = 993
    ssl = yes
  }
}
service lmtp {
  unix_listener /var/spool/postfix/private/dovecot-lmtp {
    mode = 0600
    user = postfix
    group = postfix
  }
}
service auth {
  unix_listener /var/spool/postfix/private/auth {
    mode = 0660
    user = postfix
    group = postfix
  }
  user = root
}
service auth-worker {
  user = vmail
}
EOF

  cat > /etc/dovecot/conf.d/10-ssl.conf <<EOF
ssl = required
ssl_cert = </etc/ssl/certs/ssl-cert-snakeoil.pem
ssl_key = </etc/ssl/private/ssl-cert-snakeoil.key
EOF

  # Обновляем конфигурацию Dovecot только если файл не существует или нужно обновить пароль
  if [ ! -f "/etc/dovecot/dovecot-sql.conf.ext" ]; then
    cat > /etc/dovecot/dovecot-sql.conf.ext <<EOF
driver = mysql
connect = host=127.0.0.1 dbname=$db_name user=$db_user password=$db_pass
default_pass_scheme = SHA512-CRYPT
password_query = SELECT email as user, password FROM virtual_users WHERE email='%u';
user_query = SELECT '$vmail_uid' AS uid, '$vmail_gid' AS gid, '$vmail_dir/%d/%n' AS home FROM virtual_users WHERE email='%u';
EOF
    chmod 640 /etc/dovecot/dovecot-sql.conf.ext
    chown root:dovecot /etc/dovecot/dovecot-sql.conf.ext
  else
    # Обновляем только пароль в существующем файле, если он изменился
    existing_pass=$(grep "^connect" /etc/dovecot/dovecot-sql.conf.ext 2>/dev/null | grep -oP "password=\K[^ ]+" || echo "")
    if [ -n "$existing_pass" ] && [ "$existing_pass" != "$db_pass" ]; then
      sed -i "s/password=$existing_pass/password=$db_pass/" /etc/dovecot/dovecot-sql.conf.ext
    fi
  fi

  cat > /etc/dovecot/conf.d/auth-sql.conf.ext <<'EOF'
passdb {
  driver = sql
  args = /etc/dovecot/dovecot-sql.conf.ext
}
userdb {
  driver = sql
  args = /etc/dovecot/dovecot-sql.conf.ext
}
EOF

  sed -i 's/^!include auth-system.conf.ext/#!include auth-system.conf.ext/' /etc/dovecot/conf.d/10-auth.conf
  if ! grep -q "auth-sql.conf.ext" /etc/dovecot/conf.d/10-auth.conf; then
    echo "!include auth-sql.conf.ext" >> /etc/dovecot/conf.d/10-auth.conf
  fi

  chown -R vmail:vmail "$vmail_dir"
  
  # Настройка DKIM
  echo -e "${YELLOW}Настройка DKIM...${NC}"
  mkdir -p /etc/opendkim/keys/$domain
  if [ ! -f "/etc/opendkim/keys/$domain/dkim.private" ]; then
    opendkim-genkey -D /etc/opendkim/keys/$domain/ -d $domain -s dkim
  fi
  chown -R opendkim:opendkim /etc/opendkim/keys/$domain
  chmod go-rwx /etc/opendkim/keys/$domain

  # Добавляем домен в opendkim.conf если его там нет
  if ! grep -q "Domain.*$domain" /etc/opendkim.conf; then
    cat >> /etc/opendkim.conf <<EOF

Domain                  $domain
KeyFile                 /etc/opendkim/keys/$domain/dkim.private
Selector                dkim
Socket                  inet:8891@localhost
EOF
  fi

  if ! grep -q "127.0.0.1.*localhost" /etc/opendkim/TrustedHosts; then
    echo "127.0.0.1    localhost" >> /etc/opendkim/TrustedHosts
  fi

  if ! grep -q "milter_default_action" /etc/postfix/main.cf; then
    cat >> /etc/postfix/main.cf <<EOF

milter_default_action = accept
milter_protocol = 6
smtpd_milters = inet:localhost:8891
non_smtpd_milters = inet:localhost:8891
EOF
  fi

  systemctl enable opendkim 2>/dev/null || true
  systemctl restart opendkim 2>/dev/null || true
  
  # Перезапуск сервисов
  echo -e "${YELLOW}Перезапуск сервисов...${NC}"
  systemctl enable postfix dovecot 2>/dev/null || true
  systemctl restart postfix dovecot 2>/dev/null || true
  
  # Сохранение информации о домене
  echo "$domain:$hostname_fqdn:$(date '+%Y-%m-%d %H:%M:%S')" >> "$DOMAINS_LIST_FILE"
  echo "$mail_user@$domain:$domain:$mail_pass:$(date '+%Y-%m-%d %H:%M:%S')" >> "$MAILBOXES_LIST_FILE"
  
  echo ""
  echo -e "${GREEN}${BOLD}Почтовый сервер успешно установлен для домена $domain!${NC}"
  
  # Вывод DNS записей
  show_dns_records "$domain" "$hostname_fqdn" "$mail_user@$domain"
}

# Добавление нового домена/почты
add_domain_mailbox() {
  clear_screen
  echo -e "${BOLD}${CYAN}==============================================${NC}"
  echo -e "${BOLD}${CYAN}     ДОБАВЛЕНИЕ ДОМЕНА/ПОЧТОВОГО ЯЩИКА        ${NC}"
  echo -e "${BOLD}${CYAN}==============================================${NC}"
  echo ""
  
  echo -e "${YELLOW}Выберите действие:${NC}"
  echo -e "${CYAN}1.${NC} Добавить новый домен с почтовым ящиком"
  echo -e "${CYAN}2.${NC} Добавить почтовый ящик к существующему домену"
  echo -e "${CYAN}3.${NC} Вернуться в главное меню"
  echo ""
  echo -e "${YELLOW}---------------------------------------------${NC}"
  echo -n -e "${GREEN}Ваш выбор (1-3): ${NC}"
  read choice
  
  case $choice in
    1)
      if input_mail_server_config; then
        install_mail_server "$DOMAIN" "$HOSTNAME_FQDN" "$MAIL_USER" "$MAIL_PASS" "$DB_PASS"
        echo ""
        echo -e "${YELLOW}Нажмите Enter, чтобы продолжить...${NC}"
        read
      else
        echo -e "${RED}Ошибка ввода данных!${NC}"
        sleep 2
      fi
      ;;
    2)
      add_mailbox_to_existing_domain
      ;;
    3)
      return 0
      ;;
    *)
      echo -e "${RED}Некорректный выбор!${NC}"
      sleep 1
      ;;
  esac
}

# Добавление почтового ящика к существующему домену
add_mailbox_to_existing_domain() {
  clear_screen
  echo -e "${BOLD}${CYAN}==============================================${NC}"
  echo -e "${BOLD}${CYAN}     ДОБАВЛЕНИЕ ПОЧТОВОГО ЯЩИКА               ${NC}"
  echo -e "${BOLD}${CYAN}==============================================${NC}"
  echo ""
  
  # Получаем список доменов из БД
  DB_NAME="mailserver"
  DB_USER="mailuser"
  DB_PASS=$(grep "^password" /etc/postfix/mysql-virtual-mailbox-domains.cf 2>/dev/null | awk -F' = ' '{print $2}' | tr -d ' ' || echo "")
  
  if [ -z "$DB_PASS" ]; then
    echo -e "${RED}Не удалось определить пароль БД. Убедитесь, что почтовый сервер установлен.${NC}"
    sleep 2
    return 1
  fi
  
  # Получаем список доменов
  domains=($(MYSQL_PWD="$DB_PASS" mysql -u "$DB_USER" "$DB_NAME" -Nse "SELECT name FROM virtual_domains;" 2>/dev/null || echo ""))
  
  if [ ${#domains[@]} -eq 0 ]; then
    echo -e "${RED}Нет зарегистрированных доменов. Сначала установите почтовый сервер.${NC}"
    sleep 2
    return 1
  fi
  
  echo -e "${YELLOW}Существующие домены:${NC}"
  echo -e "${YELLOW}---------------------------------------------${NC}"
  for i in "${!domains[@]}"; do
    echo -e "${CYAN}$((i+1)).${NC} ${domains[$i]}"
  done
  echo -e "${YELLOW}---------------------------------------------${NC}"
  echo ""
  
  echo -n -e "${GREEN}Выберите номер домена (1-${#domains[@]}): ${NC}"
  read domain_choice
  
  if ! [[ "$domain_choice" =~ ^[0-9]+$ ]] || [ "$domain_choice" -lt 1 ] || [ "$domain_choice" -gt ${#domains[@]} ]; then
    echo -e "${RED}Некорректный выбор!${NC}"
    sleep 2
    return 1
  fi
  
  selected_domain="${domains[$((domain_choice-1))]}"
  
  echo ""
  echo -n -e "${GREEN}Имя пользователя почты (без домена): ${NC}"
  read mail_user
  if [ -z "$mail_user" ]; then
    echo -e "${RED}Имя пользователя не может быть пустым!${NC}"
    sleep 2
    return 1
  fi
  
  echo -n -e "${GREEN}Пароль для почты (или Enter для автогенерации): ${NC}"
  read -s mail_pass
  echo ""
  mail_pass_auto_generated=false
  if [ -z "$mail_pass" ]; then
    mail_pass=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
    mail_pass_auto_generated=true
    echo -e "${YELLOW}Сгенерирован пароль для почты: ${mail_pass}${NC}"
  else
    echo -n -e "${GREEN}Подтвердите пароль: ${NC}"
    read -s mail_pass_confirm
    echo ""
    if [ "$mail_pass" != "$mail_pass_confirm" ]; then
      echo -e "${RED}Пароли не совпадают!${NC}"
      sleep 2
      return 1
    fi
  fi
  
  # Добавляем почтовый ящик в БД
  MYSQL_PWD="$DB_PASS" mysql -u "$DB_USER" "$DB_NAME" <<SQL
SET @domain_id = (SELECT id FROM virtual_domains WHERE name='$selected_domain' LIMIT 1);
INSERT INTO virtual_users (domain_id, password, email)
VALUES (
  @domain_id,
  ENCRYPT('$mail_pass', CONCAT('\$6\$', SUBSTRING(SHA(RAND()), -16))),
  '$mail_user@$selected_domain'
);
SQL

  if [ $? -eq 0 ]; then
    echo "$mail_user@$selected_domain:$selected_domain:$mail_pass:$(date '+%Y-%m-%d %H:%M:%S')" >> "$MAILBOXES_LIST_FILE"
    echo ""
    echo -e "${GREEN}${BOLD}Почтовый ящик $mail_user@$selected_domain успешно добавлен!${NC}"
  else
    echo -e "${RED}Ошибка при добавлении почтового ящика!${NC}"
  fi
  
  echo ""
  echo -e "${YELLOW}Нажмите Enter, чтобы продолжить...${NC}"
  read
}

# Исправление пароля БД
fix_db_password() {
  clear_screen
  echo -e "${BOLD}${CYAN}==============================================${NC}"
  echo -e "${BOLD}${CYAN}     ИСПРАВЛЕНИЕ ПАРОЛЯ БАЗЫ ДАННЫХ         ${NC}"
  echo -e "${BOLD}${CYAN}==============================================${NC}"
  echo ""
  
  DB_NAME="mailserver"
  DB_USER="mailuser"
  DB_PASS=$(grep "^password" /etc/postfix/mysql-virtual-mailbox-domains.cf 2>/dev/null | awk -F' = ' '{print $2}' | tr -d ' ' || echo "")
  
  if [ -z "$DB_PASS" ]; then
    echo -e "${RED}Конфигурационный файл не найден.${NC}"
    echo ""
    echo -e "${YELLOW}Нажмите Enter, чтобы вернуться в главное меню...${NC}"
    read
    return 1
  fi
  
  echo -e "${YELLOW}Текущий пароль в конфигурационном файле: ${DB_PASS:0:10}...${NC}"
  echo ""
  echo -e "${YELLOW}Выберите действие:${NC}"
  echo -e "${CYAN}1.${NC} Обновить пароль пользователя БД на пароль из конфигурационного файла"
  echo -e "${CYAN}2.${NC} Ввести новый пароль и обновить везде"
  echo -e "${CYAN}3.${NC} Отмена"
  echo ""
  echo -n -e "${GREEN}Ваш выбор (1-3): ${NC}"
  read choice
  
  case $choice in
    1)
      echo ""
      echo -e "${YELLOW}Обновление пароля пользователя БД...${NC}"
      mysql_result=$(mysql -u root <<SQL 2>&1
ALTER USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
FLUSH PRIVILEGES;
SQL
)
      if [ $? -eq 0 ]; then
        echo -e "${GREEN}Пароль пользователя БД успешно обновлен!${NC}"
        echo ""
        echo -e "${YELLOW}Нажмите Enter, чтобы продолжить...${NC}"
        read
        return 0
      else
        echo -e "${RED}Ошибка при обновлении пароля: $mysql_result${NC}"
        echo ""
        echo -e "${YELLOW}Нажмите Enter, чтобы вернуться...${NC}"
        read
        return 1
      fi
      ;;
    2)
      echo ""
      echo -n -e "${GREEN}Введите новый пароль БД: ${NC}"
      read -s new_db_pass
      echo ""
      if [ -z "$new_db_pass" ]; then
        echo -e "${RED}Пароль не может быть пустым!${NC}"
        sleep 2
        return 1
      fi
      
      echo -n -e "${GREEN}Подтвердите пароль: ${NC}"
      read -s new_db_pass_confirm
      echo ""
      if [ "$new_db_pass" != "$new_db_pass_confirm" ]; then
        echo -e "${RED}Пароли не совпадают!${NC}"
        sleep 2
        return 1
      fi
      
      echo ""
      echo -e "${YELLOW}Обновление пароля пользователя БД и конфигурационных файлов...${NC}"
      
      # Обновляем пароль в БД
      mysql_result=$(mysql -u root <<SQL 2>&1
ALTER USER '$DB_USER'@'localhost' IDENTIFIED BY '$new_db_pass';
FLUSH PRIVILEGES;
SQL
)
      
      if [ $? -ne 0 ]; then
        echo -e "${RED}Ошибка при обновлении пароля в БД: $mysql_result${NC}"
        sleep 2
        return 1
      fi
      
      # Обновляем пароль в конфигурационных файлах Postfix
      sed -i "s/^password = .*/password = $new_db_pass/" /etc/postfix/mysql-virtual-mailbox-domains.cf
      sed -i "s/^password = .*/password = $new_db_pass/" /etc/postfix/mysql-virtual-mailbox-maps.cf
      sed -i "s/^password = .*/password = $new_db_pass/" /etc/postfix/mysql-virtual-alias-maps.cf
      
      # Обновляем пароль в конфигурации Dovecot
      if [ -f "/etc/dovecot/dovecot-sql.conf.ext" ]; then
        sed -i "s/password=[^ ]*/password=$new_db_pass/" /etc/dovecot/dovecot-sql.conf.ext
      fi
      
      echo -e "${GREEN}Пароль успешно обновлен везде!${NC}"
      echo ""
      echo -e "${YELLOW}Нажмите Enter, чтобы продолжить...${NC}"
      read
      return 0
      ;;
    3)
      return 0
      ;;
    *)
      echo -e "${RED}Некорректный выбор!${NC}"
      sleep 1
      return 1
      ;;
  esac
}

# Просмотр существующих доменов и почтовых ящиков
view_domains_mailboxes() {
  set +e  # Отключаем немедленный выход при ошибке для этой функции
  while true; do
    clear_screen
    echo -e "${BOLD}${CYAN}==============================================${NC}"
    echo -e "${BOLD}${CYAN}     ДОМЕНЫ И ПОЧТОВЫЕ ЯЩИКИ                  ${NC}"
    echo -e "${BOLD}${CYAN}==============================================${NC}"
    echo ""
    
    DB_NAME="mailserver"
    DB_USER="mailuser"
    DB_PASS=$(grep "^password" /etc/postfix/mysql-virtual-mailbox-domains.cf 2>/dev/null | awk -F' = ' '{print $2}' | tr -d ' ' || echo "")
    
    if [ -z "$DB_PASS" ]; then
      echo -e "${RED}Почтовый сервер не установлен или не настроен.${NC}"
      echo ""
      echo -e "${YELLOW}Нажмите Enter, чтобы вернуться в главное меню...${NC}"
      read
      set -e  # Включаем обратно перед выходом
      return 0
    fi
    
    # Проверяем подключение к БД с детальной диагностикой
    mysql_error=$(MYSQL_PWD="$DB_PASS" mysql -u "$DB_USER" "$DB_NAME" -e "SELECT 1;" 2>&1)
    mysql_exit_code=$?
    
    if [ $mysql_exit_code -ne 0 ]; then
      echo -e "${RED}Ошибка подключения к базе данных.${NC}"
      echo ""
      echo -e "${YELLOW}Детали ошибки:${NC}"
      echo "$mysql_error"
      echo ""
      
      # Проверяем, является ли это ошибкой доступа (неправильный пароль)
      if [[ "$mysql_error" =~ "Access denied" ]]; then
        echo -e "${YELLOW}Похоже, пароль в конфигурационном файле не совпадает с паролем пользователя БД.${NC}"
        echo ""
        echo -e "${YELLOW}Выберите действие:${NC}"
        echo -e "${CYAN}1.${NC} Исправить пароль БД"
        echo -e "${CYAN}2.${NC} Вернуться в главное меню"
        echo ""
        echo -n -e "${GREEN}Ваш выбор (1-2): ${NC}"
        read fix_choice
        
        case $fix_choice in
          1)
            if fix_db_password; then
              continue  # Повторяем попытку подключения
            else
              set -e
              return 0
            fi
            ;;
          2)
            set -e
            return 0
            ;;
          *)
            set -e
            return 0
            ;;
        esac
      else
        echo -e "${YELLOW}Проверьте:${NC}"
        echo -e "${CYAN}1.${NC} Запущен ли сервис MySQL/MariaDB: systemctl status mariadb"
        echo -e "${CYAN}2.${NC} Существует ли пользователь БД: mysql -u root -e \"SELECT User FROM mysql.user WHERE User='$DB_USER';\""
        echo -e "${CYAN}3.${NC} Существует ли база данных: mysql -u root -e \"SHOW DATABASES LIKE '$DB_NAME';\""
        echo -e "${CYAN}4.${NC} Правильность пароля в файле: /etc/postfix/mysql-virtual-mailbox-domains.cf"
        echo ""
        echo -e "${YELLOW}Нажмите Enter, чтобы вернуться в главное меню...${NC}"
        read
        set -e  # Включаем обратно перед выходом
        return 0
      fi
    fi
    
    # Получаем список доменов
    mysql_output=$(MYSQL_PWD="$DB_PASS" mysql -u "$DB_USER" "$DB_NAME" -Nse "SELECT name FROM virtual_domains;" 2>&1)
    mysql_query_exit=$?
    
    # Проверяем, есть ли ошибки
    if [ $mysql_query_exit -ne 0 ] || [[ "$mysql_output" =~ ^ERROR ]]; then
      echo -e "${RED}Ошибка при запросе к базе данных:${NC}"
      echo "$mysql_output"
      echo ""
      echo -e "${YELLOW}Нажмите Enter, чтобы вернуться в главное меню...${NC}"
      read
      return 0
    fi
    
    # Преобразуем вывод в массив
    if [ -z "$mysql_output" ]; then
      domains=()
    else
      readarray -t domains <<< "$mysql_output"
    fi
    
    if [ ${#domains[@]} -eq 0 ]; then
      echo -e "${YELLOW}Нет зарегистрированных доменов.${NC}"
    else
      echo -e "${YELLOW}Зарегистрированные домены:${NC}"
      echo -e "${YELLOW}---------------------------------------------${NC}"
      for domain in "${domains[@]}"; do
        echo -e "${CYAN}•${NC} $domain"
        
        # Получаем почтовые ящики для этого домена
        mailboxes_output=$(MYSQL_PWD="$DB_PASS" mysql -u "$DB_USER" "$DB_NAME" -Nse "SELECT email FROM virtual_users WHERE domain_id=(SELECT id FROM virtual_domains WHERE name='$domain' LIMIT 1);" 2>&1)
        
        if [ -z "$mailboxes_output" ] || [[ "$mailboxes_output" =~ ^ERROR ]]; then
          mailboxes=()
        else
          readarray -t mailboxes <<< "$mailboxes_output"
        fi
        
        if [ ${#mailboxes[@]} -gt 0 ]; then
          for mailbox in "${mailboxes[@]}"; do
            if [ -n "$mailbox" ]; then
              echo -e "  ${GREEN}→${NC} $mailbox"
            fi
          done
        fi
        echo ""
      done
      echo -e "${YELLOW}---------------------------------------------${NC}"
    fi
    
    echo ""
    echo -e "${YELLOW}Выберите действие:${NC}"
    echo -e "${CYAN}1.${NC} Обновить список"
    if [ ${#domains[@]} -gt 0 ]; then
      echo -e "${CYAN}2.${NC} Просмотреть детальную информацию о домене"
      echo -e "${CYAN}3.${NC} Вернуться в главное меню"
      echo ""
      echo -e "${YELLOW}---------------------------------------------${NC}"
      echo -n -e "${GREEN}Ваш выбор (1-3): ${NC}"
      read choice
      
      case $choice in
        1)
          continue
          ;;
        2)
          echo ""
          echo -e "${YELLOW}Выберите домен для просмотра детальной информации:${NC}"
          echo -e "${YELLOW}---------------------------------------------${NC}"
          for i in "${!domains[@]}"; do
            echo -e "${CYAN}$((i+1)).${NC} ${domains[$i]}"
          done
          echo -e "${YELLOW}---------------------------------------------${NC}"
          echo ""
          echo -n -e "${GREEN}Номер домена (1-${#domains[@]}): ${NC}"
          read domain_choice
          
          if ! [[ "$domain_choice" =~ ^[0-9]+$ ]] || [ "$domain_choice" -lt 1 ] || [ "$domain_choice" -gt ${#domains[@]} ]; then
            echo -e "${RED}Некорректный выбор!${NC}"
            sleep 2
            continue
          fi
          
          selected_domain="${domains[$((domain_choice-1))]}"
          show_domain_details "$selected_domain" "$DB_PASS" "$DB_USER" "$DB_NAME"
          echo ""
          echo -e "${YELLOW}Нажмите Enter, чтобы продолжить...${NC}"
          read
          ;;
        3)
          set -e  # Включаем обратно перед выходом
          return 0
          ;;
        *)
          echo -e "${RED}Некорректный выбор!${NC}"
          sleep 1
          ;;
      esac
    else
      echo -e "${CYAN}2.${NC} Вернуться в главное меню"
      echo ""
      echo -e "${YELLOW}---------------------------------------------${NC}"
      echo -n -e "${GREEN}Ваш выбор (1-2): ${NC}"
      read choice
      
      case $choice in
        1)
          continue
          ;;
        2)
          set -e  # Включаем обратно перед выходом
          return 0
          ;;
        *)
          echo -e "${RED}Некорректный выбор!${NC}"
          sleep 1
          ;;
      esac
    fi
  done
  set -e  # Включаем обратно на случай выхода из цикла
}

# Просмотр детальной информации о домене
show_domain_details() {
  local domain="$1"
  local db_pass="$2"
  local db_user="$3"
  local db_name="$4"
  
  clear_screen
  
  # Получаем hostname_fqdn из файла domains.list
  local hostname_fqdn=""
  if [ -f "$DOMAINS_LIST_FILE" ]; then
    hostname_fqdn=$(grep "^${domain}:" "$DOMAINS_LIST_FILE" | head -1 | cut -d: -f2)
  fi
  
  # Если не нашли в файле, используем значение по умолчанию
  if [ -z "$hostname_fqdn" ]; then
    hostname_fqdn="mail.${domain}"
  fi
  
  # Получаем IP адрес сервера
  local server_ip=$(hostname -I | awk '{print $1}')
  
  # Получаем список почтовых ящиков для этого домена
  local mailboxes_output=$(MYSQL_PWD="$db_pass" mysql -u "$db_user" "$db_name" -Nse "SELECT email FROM virtual_users WHERE domain_id=(SELECT id FROM virtual_domains WHERE name='$domain' LIMIT 1);" 2>&1)
  
  local mailboxes=()
  if [ -n "$mailboxes_output" ] && ! [[ "$mailboxes_output" =~ ^ERROR ]]; then
    readarray -t mailboxes <<< "$mailboxes_output"
  fi
  
  # Выводим DNS записи (точно так же, как при установке)
  if [ ${#mailboxes[@]} -gt 0 ]; then
    show_dns_records "$domain" "$hostname_fqdn" "${mailboxes[0]}"
  else
    # Если нет почтовых ящиков, используем домен для DMARC
    show_dns_records "$domain" "$hostname_fqdn" "admin@${domain}"
  fi
  
  echo ""
  echo -e "${BOLD}${CYAN}==============================================${NC}"
  echo -e "${BOLD}${CYAN}     ПАРАМЕТРЫ ПОДКЛЮЧЕНИЯ                     ${NC}"
  echo -e "${BOLD}${CYAN}==============================================${NC}"
  echo ""
  
  if [ ${#mailboxes[@]} -eq 0 ]; then
    echo -e "${YELLOW}Нет почтовых ящиков для этого домена.${NC}"
    return 0
  fi
  
  # Читаем пароли из файла mailboxes.list
  declare -A mailbox_passwords
  if [ -f "$MAILBOXES_LIST_FILE" ]; then
    while IFS=: read -r email stored_domain password rest; do
      if [ "$stored_domain" = "$domain" ]; then
        mailbox_passwords["$email"]="$password"
      fi
    done < "$MAILBOXES_LIST_FILE"
  fi
  
  # Выводим параметры подключения для каждого почтового ящика
  for mailbox in "${mailboxes[@]}"; do
    if [ -z "$mailbox" ]; then
      continue
    fi
    
    local password="${mailbox_passwords[$mailbox]}"
    if [ -z "$password" ]; then
      password="${RED}(не найден в файле)${NC}"
    fi
    
    echo -e "${BOLD}${GREEN}Почтовый ящик: ${mailbox}${NC}"
    echo ""

    # Данные таблицы
    h1="Сервис"
    h2="Сервер"
    h3="Порт"
    h4="Шифрование"

    r1c1="SMTP (отправка)"
    r1c2="$hostname_fqdn"
    r1c3="${CYAN}587${NC}"
    r1c4="TLS/STARTTLS"

    r2c1="IMAP (прием)"
    r2c2="$hostname_fqdn"
    r2c3="${CYAN}993${NC}"
    r2c4="SSL/TLS"

    # Вычисляем ширины колонок по максимуму
    w1=$(printf "%s\n" "$h1" "$r1c1" "$r2c1" | strip_ansi | awk '{ if (length > max) max=length } END{ print max }')
    w2=$(printf "%s\n" "$h2" "$r1c2" "$r2c2" | strip_ansi | awk '{ if (length > max) max=length } END{ print max }')
    w3=$(printf "%s\n" "$h3" "$r1c3" "$r2c3" | strip_ansi | awk '{ if (length > max) max=length } END{ print max }')
    w4=$(printf "%s\n" "$h4" "$r1c4" "$r2c4" | strip_ansi | awk '{ if (length > max) max=length } END{ print max }')

    print_hr "$w1" "$w2" "$w3" "$w4"
    print_row "$h1" "$h2" "$h3" "$h4" "$w1" "$w2" "$w3" "$w4"
    print_hr "$w1" "$w2" "$w3" "$w4"
    print_row "$r1c1" "$r1c2" "$r1c3" "$r1c4" "$w1" "$w2" "$w3" "$w4"
    print_row "$r2c1" "$r2c2" "$r2c3" "$r2c4" "$w1" "$w2" "$w3" "$w4"
    print_hr "$w1" "$w2" "$w3" "$w4"
    echo ""
    echo -e "${YELLOW}Логин:${NC} ${CYAN}${mailbox}${NC}"
    if [ -z "${mailbox_passwords[$mailbox]}" ]; then
      echo -e "${YELLOW}Пароль:${NC} ${RED}(не найден в файле)${NC}"
    else
      echo -e "${YELLOW}Пароль:${NC} ${CYAN}${mailbox_passwords[$mailbox]}${NC}"
    fi
    echo ""
    echo -e "${YELLOW}Альтернативные параметры подключения:${NC}"
    echo -e "${CYAN}•${NC} Сервер (IP): ${server_ip}"
    echo -e "${CYAN}•${NC} SMTP порт 25 (без шифрования, не рекомендуется)"
    echo -e "${CYAN}•${NC} IMAP порт 143 (STARTTLS, не рекомендуется)"
    echo ""
    echo -e "${YELLOW}─────────────────────────────────────────────────────────${NC}"
    echo ""
  done
  
  # Меню действий
  echo ""
  echo -e "${YELLOW}Выберите действие:${NC}"
  echo -e "${CYAN}1.${NC} Отправить тестовое письмо"
  echo -e "${CYAN}2.${NC} Вернуться к списку доменов"
  echo ""
  echo -e "${YELLOW}---------------------------------------------${NC}"
  echo -n -e "${GREEN}Ваш выбор (1-2): ${NC}"
  read action_choice
  
  case $action_choice in
    1)
      send_test_email "$domain" "$hostname_fqdn" "$server_ip"
      echo ""
      echo -e "${YELLOW}Нажмите Enter, чтобы продолжить...${NC}"
      read
      ;;
    2)
      return 0
      ;;
    *)
      return 0
      ;;
  esac
}

# Исправление проблемы SMTPUTF8
fix_smtputf8_issue() {
  clear_screen
  echo -e "${BOLD}${CYAN}==============================================${NC}"
  echo -e "${BOLD}${CYAN}     ИСПРАВЛЕНИЕ ПРОБЛЕМЫ SMTPUTF8            ${NC}"
  echo -e "${BOLD}${CYAN}==============================================${NC}"
  echo ""
  echo -e "${YELLOW}Проблема:${NC} Postfix пытается использовать SMTPUTF8, но некоторые серверы"
  echo -e "${YELLOW}          (например, Yandex) не поддерживают эту функцию.${NC}"
  echo ""
  
  # Проверяем текущие настройки
  echo -e "${YELLOW}Проверка текущих настроек Postfix...${NC}"
  echo ""
  local current_smtputf8=$(postconf smtputf8_enable 2>/dev/null | awk -F' = ' '{print $2}')
  if [ -n "$current_smtputf8" ]; then
    echo -e "${CYAN}Текущее значение smtputf8_enable:${NC} ${current_smtputf8}"
  else
    echo -e "${YELLOW}Параметр smtputf8_enable не установлен (используется значение по умолчанию)${NC}"
  fi
  echo ""
  
  echo -e "${YELLOW}Решение:${NC} Отключить требование SMTPUTF8 в Postfix и Dovecot."
  echo ""
  echo -e "${YELLOW}Это действие:${NC}"
  echo -e "${CYAN}•${NC} Отключит требование SMTPUTF8 для исходящей почты (Postfix)"
  echo -e "${CYAN}•${NC} Отключит SMTPUTF8 для submission порта"
  echo -e "${CYAN}•${NC} Настроит Dovecot для работы без SMTPUTF8"
  echo -e "${CYAN}•${NC} Перезапустит Postfix и Dovecot для применения изменений"
  echo ""
  echo -n -e "${GREEN}Продолжить исправление? (y/n): ${NC}"
  read confirm
  
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo -e "${YELLOW}Исправление отменено.${NC}"
    sleep 1
    return 0
  fi
  
  echo ""
  echo -e "${YELLOW}Применение исправления...${NC}"
  echo ""
  
  # Отключаем требование SMTPUTF8 в Postfix
  # Ищем все файлы конфигурации, где может быть задано это значение
  echo -e "${YELLOW}Поиск файлов конфигурации с smtputf8_enable...${NC}"
  
  # Ищем в основных файлах конфигурации
  local config_files=(
    "/etc/postfix/main.cf"
    "/usr/share/postfix/main.cf.dist"
    "/etc/postfix/main.cf.dist"
  )
  
  # Ищем все файлы, которые могут содержать это значение
  for config_file in "${config_files[@]}"; do
    if [ -f "$config_file" ]; then
      if grep -q "smtputf8_enable" "$config_file" 2>/dev/null; then
        echo -e "${CYAN}Найдено в: ${config_file}${NC}"
        # Удаляем или комментируем строку
        sed -i 's/^smtputf8_enable/#smtputf8_enable/' "$config_file" 2>/dev/null || true
      fi
    fi
  done
  
  # Ищем в директориях с конфигурацией
  if [ -d "/etc/postfix" ]; then
    find /etc/postfix -type f -name "*.cf" 2>/dev/null | while read -r file; do
      if grep -q "smtputf8_enable" "$file" 2>/dev/null; then
        echo -e "${CYAN}Найдено в: ${file}${NC}"
        sed -i 's/^smtputf8_enable/#smtputf8_enable/' "$file" 2>/dev/null || true
      fi
    done
  fi
  
  # Теперь добавляем явное значение в конец main.cf (после всех include)
  if [ -f "/etc/postfix/main.cf" ]; then
    # Удаляем все строки с smtputf8_enable (включая закомментированные, если они есть)
    sed -i '/^[[:space:]]*smtputf8_enable/d' /etc/postfix/main.cf 2>/dev/null
    sed -i '/^[[:space:]]*#.*smtputf8_enable/d' /etc/postfix/main.cf 2>/dev/null
    
    # Добавляем в самый конец файла (после всех include)
    echo "" >> /etc/postfix/main.cf
    echo "# Force disable SMTPUTF8 for compatibility" >> /etc/postfix/main.cf
    echo "smtputf8_enable = no" >> /etc/postfix/main.cf
    echo -e "${GREEN}✓${NC} Добавлено явное значение в конец main.cf"
  fi
  
  # Устанавливаем compatibility_level = 0, чтобы smtputf8_enable стал no
  # Логика: ${{$compatibility_level} <level {1} ? {no} : {yes}}
  # Если compatibility_level < 1, то smtputf8_enable = no
  if [ -f "/etc/postfix/main.cf" ]; then
    # Удаляем старые значения compatibility_level
    sed -i '/^compatibility_level/d' /etc/postfix/main.cf 2>/dev/null
    # Добавляем compatibility_level = 0
    echo "compatibility_level = 0" >> /etc/postfix/main.cf
    echo -e "${GREEN}✓${NC} Установлен compatibility_level = 0 (это отключит SMTPUTF8)"
  fi
  
  # Применяем через postconf
  postconf -e "smtputf8_enable=no" 2>/dev/null
  postconf -e "compatibility_level=0" 2>/dev/null
  if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓${NC} Применено через postconf"
  else
    echo -e "${YELLOW}⚠${NC} postconf не применил значение (продолжаем)"
  fi
  
  # Отключаем для submission порта
  postconf -P submission/inet/smtputf8_enable=no 2>/dev/null
  if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓${NC} Отключено SMTPUTF8 для submission порта"
  else
    echo -e "${YELLOW}⚠${NC} Не удалось отключить SMTPUTF8 для submission (может быть не критично)"
  fi
  
  # Также отключаем для всех других сервисов
  postconf -M smtp/inet/smtputf8_enable=no 2>/dev/null || true
  
  # Настраиваем Dovecot для работы без SMTPUTF8
  # Проверяем наличие конфигурации Dovecot
  if [ -f "/etc/dovecot/conf.d/10-master.conf" ]; then
    # Проверяем, есть ли уже настройка для LMTP
    if ! grep -q "lmtp_utf8" /etc/dovecot/conf.d/10-master.conf 2>/dev/null; then
      # Добавляем настройку для отключения SMTPUTF8 в LMTP
      sed -i '/service lmtp {/,/}/ {
        /}/ i\
  lmtp_utf8 = no
      }' /etc/dovecot/conf.d/10-master.conf 2>/dev/null || true
      echo -e "${GREEN}✓${NC} Настроен Dovecot для работы без SMTPUTF8"
    fi
  fi
  
  # Также проверяем master.cf для submission порта
  if [ -f "/etc/postfix/master.cf" ]; then
    # Убеждаемся, что submission порт настроен правильно
    postconf -P "submission/inet/smtputf8_enable=no" 2>/dev/null || true
  fi
  
  # Проверяем настройки перед перезапуском
  echo ""
  echo -e "${YELLOW}Проверка конфигурации Postfix...${NC}"
  postfix check 2>/dev/null
  if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓${NC} Конфигурация Postfix корректна"
  else
    echo -e "${YELLOW}⚠${NC} Обнаружены предупреждения в конфигурации Postfix"
  fi
  
  # Перезапускаем Postfix
  echo ""
  echo -e "${YELLOW}Перезапуск Postfix...${NC}"
  systemctl restart postfix 2>/dev/null
  
  if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓${NC} Postfix успешно перезапущен"
  else
    echo -e "${RED}✗${NC} Ошибка при перезапуске Postfix"
    echo ""
    echo -e "${YELLOW}Попробуйте перезапустить вручную: systemctl restart postfix${NC}"
    sleep 2
    return 1
  fi
  
  # Перезапускаем Dovecot
  echo ""
  echo -e "${YELLOW}Перезапуск Dovecot...${NC}"
  
  # Проверяем статус Dovecot перед перезапуском
  if systemctl is-active --quiet dovecot 2>/dev/null; then
    systemctl restart dovecot 2>/dev/null
  else
    echo -e "${YELLOW}Dovecot не запущен, пытаемся запустить...${NC}"
    systemctl start dovecot 2>/dev/null
  fi
  
  if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓${NC} Dovecot успешно перезапущен/запущен"
    
    # Проверяем, что LMTP сокет создан
    sleep 1
    if [ -S "/var/spool/postfix/private/dovecot-lmtp" ]; then
      echo -e "${GREEN}✓${NC} LMTP сокет создан"
    else
      echo -e "${YELLOW}⚠${NC} LMTP сокет не найден, проверьте конфигурацию Dovecot"
      echo -e "${CYAN}Проверьте:${NC} systemctl status dovecot"
      echo -e "${CYAN}Логи:${NC} journalctl -u dovecot -n 50"
    fi
  else
    echo -e "${RED}✗${NC} Ошибка при перезапуске/запуске Dovecot"
    echo -e "${YELLOW}Проверьте статус:${NC} systemctl status dovecot"
    echo -e "${YELLOW}Проверьте логи:${NC} journalctl -u dovecot -n 50"
    echo -e "${YELLOW}Попробуйте запустить вручную:${NC} systemctl start dovecot"
  fi
  
  # Проверяем финальные настройки
  echo ""
  echo -e "${YELLOW}Проверка примененных настроек...${NC}"
  local final_smtputf8=$(postconf smtputf8_enable 2>/dev/null | awk -F' = ' '{print $2}')
  local final_compat=$(postconf compatibility_level 2>/dev/null | awk -F' = ' '{print $2}')
  
  echo -e "${CYAN}compatibility_level:${NC} ${final_compat:-не установлен}"
  echo -e "${CYAN}smtputf8_enable:${NC} ${final_smtputf8}"
  echo ""
  
  # Проверяем, что значение действительно "no" (не переменная)
  if echo "$final_smtputf8" | grep -qE "^(no|NO)$"; then
    echo -e "${GREEN}✓${NC} smtputf8_enable = no (применено успешно)"
  elif echo "$final_smtputf8" | grep -qE "\$\{"; then
    # Если все еще переменная, проверяем compatibility_level
    if [ "$final_compat" = "0" ] || [ "$final_compat" = "0.0" ]; then
      echo -e "${GREEN}✓${NC} compatibility_level = 0 установлен (это даст smtputf8_enable = no)"
      echo -e "${YELLOW}Примечание:${NC} Значение вычисляется динамически, но должно быть 'no'"
    else
      echo -e "${RED}✗${NC} Настройка все еще использует переменную совместимости: ${final_smtputf8}"
      echo -e "${YELLOW}compatibility_level:${NC} ${final_compat}"
      echo -e "${YELLOW}Попытка принудительного исправления...${NC}"
      # Пытаемся еще раз принудительно установить
      if [ -f "/etc/postfix/main.cf" ]; then
        sed -i '/^smtputf8_enable/d' /etc/postfix/main.cf 2>/dev/null
        sed -i '/^compatibility_level/d' /etc/postfix/main.cf 2>/dev/null
        echo "" >> /etc/postfix/main.cf
        echo "# Force disable SMTPUTF8" >> /etc/postfix/main.cf
        echo "compatibility_level = 0" >> /etc/postfix/main.cf
        echo "smtputf8_enable = no" >> /etc/postfix/main.cf
      fi
      systemctl reload postfix 2>/dev/null || systemctl restart postfix 2>/dev/null
      sleep 2
      final_smtputf8=$(postconf smtputf8_enable 2>/dev/null | awk -F' = ' '{print $2}')
      final_compat=$(postconf compatibility_level 2>/dev/null | awk -F' = ' '{print $2}')
      if echo "$final_smtputf8" | grep -qE "^(no|NO)$" || [ "$final_compat" = "0" ]; then
        echo -e "${GREEN}✓${NC} Настройка применена после принудительного исправления"
      else
        echo -e "${RED}✗${NC} Не удалось применить настройку."
        echo -e "${YELLOW}Текущие значения:${NC}"
        echo -e "${CYAN}compatibility_level:${NC} ${final_compat}"
        echo -e "${CYAN}smtputf8_enable:${NC} ${final_smtputf8}"
        echo ""
        echo -e "${YELLOW}Попробуйте вручную добавить в /etc/postfix/main.cf:${NC}"
        echo -e "${CYAN}compatibility_level = 0${NC}"
        echo -e "${CYAN}smtputf8_enable = no${NC}"
      fi
    fi
  else
    echo -e "${YELLOW}⚠${NC} Неожиданное значение: ${final_smtputf8}"
    echo -e "${YELLOW}Проверьте файл /etc/postfix/main.cf вручную${NC}"
  fi
  
  echo ""
  echo -e "${GREEN}${BOLD}Исправление завершено!${NC}"
  echo ""
  echo -e "${YELLOW}Теперь можно попробовать отправить письмо снова.${NC}"
  echo -e "${YELLOW}Если проблема сохранится, проверьте логи:${NC}"
  echo -e "${CYAN}•${NC} tail -f /var/log/syslog | grep -i postfix"
  echo ""
  echo -e "${YELLOW}Нажмите Enter, чтобы продолжить...${NC}"
  read
}

# Просмотр логов отправленного сообщения
view_email_logs() {
  local sender_email="$1"
  local recipient_email="$2"
  
  clear_screen
  echo -e "${BOLD}${CYAN}==============================================${NC}"
  echo -e "${BOLD}${CYAN}     ЛОГИ ОТПРАВЛЕННОГО СООБЩЕНИЯ            ${NC}"
  echo -e "${BOLD}${CYAN}==============================================${NC}"
  echo ""
  echo -e "${YELLOW}От:${NC} ${CYAN}${sender_email}${NC}"
  echo -e "${YELLOW}Кому:${NC} ${CYAN}${recipient_email}${NC}"
  echo ""
  echo -e "${YELLOW}Поиск логов Postfix...${NC}"
  echo ""
  
  # Находим файл логов
  local log_file=""
  local mail_log_files=("/var/log/mail.log" "/var/log/maillog" "/var/log/postfix.log" "/var/log/syslog")
  
  for file in "${mail_log_files[@]}"; do
    if [ -f "$file" ] && [ -r "$file" ]; then
      log_file="$file"
      break
    fi
  done
  
  if [ -z "$log_file" ]; then
    echo -e "${RED}Не удалось найти файл логов Postfix.${NC}"
    echo ""
    echo -e "${YELLOW}Попытка просмотра через journalctl...${NC}"
    echo ""
    journalctl --since "5 minutes ago" --no-pager 2>/dev/null | grep -iE "postfix.*(${sender_email}|${recipient_email})" | head -50 || echo -e "${RED}Логи не найдены.${NC}"
    echo ""
    echo -e "${YELLOW}Нажмите Enter, чтобы вернуться...${NC}"
    read
    return
  fi
  
  echo -e "${GREEN}Найден файл логов: ${log_file}${NC}"
  echo ""
  echo -e "${YELLOW}---------------------------------------------${NC}"
  echo ""
  
  # Ищем ID сообщения по адресам отправителя и получателя
  # Postfix использует формат: message-id: from=<email>, to=<email>
  local message_ids=$(grep -iE "postfix.*from=<${sender_email//./\\.}>.*to=<${recipient_email//./\\.}>" "$log_file" 2>/dev/null | grep -oE "[A-F0-9]{10,12}:" | cut -d: -f1 | sort -u | head -5)
  
  # Если не нашли по обоим адресам, ищем только по отправителю
  if [ -z "$message_ids" ]; then
    message_ids=$(grep -iE "postfix.*from=<${sender_email//./\\.}>" "$log_file" 2>/dev/null | tail -20 | grep -oE "[A-F0-9]{10,12}:" | cut -d: -f1 | sort -u | head -5)
  fi
  
  # Если все еще не нашли, ищем по получателю
  if [ -z "$message_ids" ]; then
    message_ids=$(grep -iE "postfix.*to=<${recipient_email//./\\.}>" "$log_file" 2>/dev/null | tail -20 | grep -oE "[A-F0-9]{10,12}:" | cut -d: -f1 | sort -u | head -5)
  fi
  
  # Проверяем наличие ошибки SMTPUTF8 в логах, связанных с этим письмом
  local has_smtputf8_error=false
  
  # Ищем ошибку SMTPUTF8 в логах, связанных с отправителем или получателем (за последние 10 минут)
  local recent_logs=$(grep -iE "postfix.*(${sender_email//./\\.}|${recipient_email//./\\.})" "$log_file" 2>/dev/null | tail -100)
  if echo "$recent_logs" | grep -qiE "SMTPUTF8.*required"; then
    has_smtputf8_error=true
  fi
  
  # Также проверяем последние логи на наличие ошибки SMTPUTF8 (даже без привязки к адресам)
  if tail -100 "$log_file" 2>/dev/null | grep -qiE "SMTPUTF8.*required"; then
    has_smtputf8_error=true
  fi
  
  if [ -n "$message_ids" ]; then
    echo -e "${CYAN}Найдены логи для сообщения(ий) с ID: $(echo $message_ids | tr '\n' ' ')${NC}"
    echo ""
    echo -e "${YELLOW}Полный путь обработки сообщения:${NC}"
    echo ""
    
    # Показываем все логи для найденных ID сообщений
    for msg_id in $message_ids; do
      echo -e "${BOLD}${GREEN}--- Сообщение ID: ${msg_id} ---${NC}"
      local msg_logs=$(grep -iE "postfix.*${msg_id}" "$log_file" 2>/dev/null | tail -30)
      # Проверяем наличие ошибки SMTPUTF8 в логах этого сообщения
      if echo "$msg_logs" | grep -qiE "SMTPUTF8.*required"; then
        has_smtputf8_error=true
      fi
      # Выводим логи с цветовой подсветкой
      echo "$msg_logs" | while IFS= read -r line; do
        # Выделяем важные части логов цветом
        if echo "$line" | grep -qiE "(bounced|reject|error|fail|defer|SMTPUTF8)"; then
          echo -e "${RED}${line}${NC}"
        elif echo "$line" | grep -qiE "(sent|delivered|success|relay)"; then
          echo -e "${GREEN}${line}${NC}"
        elif echo "$line" | grep -qiE "(from=|to=)"; then
          echo -e "${CYAN}${line}${NC}"
        else
          echo "$line"
        fi
      done
      echo ""
    done
  else
    # Если не нашли по ID, показываем логи по адресам
    echo -e "${CYAN}Логи, связанные с отправкой письма (последние 50 строк):${NC}"
    echo ""
    local email_logs=$(grep -iE "postfix.*(${sender_email//./\\.}|${recipient_email//./\\.})" "$log_file" 2>/dev/null | tail -50)
    
    # Проверяем наличие ошибки SMTPUTF8 в этих логах
    if echo "$email_logs" | grep -qiE "SMTPUTF8.*required"; then
      has_smtputf8_error=true
    fi
    
    # Выводим логи с цветовой подсветкой
    echo "$email_logs" | while IFS= read -r line; do
      if echo "$line" | grep -qiE "(bounced|reject|error|fail|defer|SMTPUTF8)"; then
        echo -e "${RED}${line}${NC}"
      elif echo "$line" | grep -qiE "(sent|delivered|success|relay)"; then
        echo -e "${GREEN}${line}${NC}"
      elif echo "$line" | grep -qiE "(from=|to=)"; then
        echo -e "${CYAN}${line}${NC}"
      else
        echo "$line"
      fi
    done
    
    # Если ничего не найдено, показываем последние логи Postfix
    if [ -z "$email_logs" ]; then
      echo -e "${YELLOW}Логи для конкретного письма не найдены. Показываем последние логи Postfix:${NC}"
      echo ""
      local postfix_logs=$(grep -i "postfix" "$log_file" 2>/dev/null | tail -30)
      
      # Проверяем наличие ошибки SMTPUTF8 в общих логах
      if echo "$postfix_logs" | grep -qiE "SMTPUTF8.*required"; then
        has_smtputf8_error=true
      fi
      
      echo "$postfix_logs" | while IFS= read -r line; do
        if echo "$line" | grep -qiE "(bounced|reject|error|fail|defer|SMTPUTF8)"; then
          echo -e "${RED}${line}${NC}"
        elif echo "$line" | grep -qiE "(sent|delivered|success|relay)"; then
          echo -e "${GREEN}${line}${NC}"
        else
          echo "$line"
        fi
      done
    fi
    echo ""
  fi
  
  # Финальная проверка наличия ошибки SMTPUTF8 в последних логах (на всякий случай)
  # Проверяем логи, связанные с этим письмом
  if grep -iE "postfix.*(${sender_email//./\\.}|${recipient_email//./\\.})" "$log_file" 2>/dev/null | tail -100 | grep -qiE "SMTPUTF8.*required"; then
    has_smtputf8_error=true
  fi
  # Также проверяем общие логи Postfix
  if tail -100 "$log_file" 2>/dev/null | grep -qiE "SMTPUTF8.*required"; then
    has_smtputf8_error=true
  fi
  
  echo -e "${YELLOW}---------------------------------------------${NC}"
  echo ""
  
  # Если обнаружена ошибка SMTPUTF8, предлагаем исправление
  # Дополнительная проверка перед показом меню
  if [ "$has_smtputf8_error" != true ]; then
    # Проверяем еще раз более тщательно
    if tail -200 "$log_file" 2>/dev/null | grep -qiE "SMTPUTF8.*required"; then
      has_smtputf8_error=true
    fi
  fi
  
  if [ "$has_smtputf8_error" = true ]; then
    echo -e "${RED}${BOLD}⚠ ОБНАРУЖЕНА ПРОБЛЕМА: SMTPUTF8${NC}"
    echo ""
    echo -e "${YELLOW}В логах обнаружена ошибка: \"SMTPUTF8 is required, but was not offered\"${NC}"
    echo -e "${YELLOW}Это означает, что Postfix пытается использовать SMTPUTF8, но сервер${NC}"
    echo -e "${YELLOW}получателя (например, Yandex) не поддерживает эту функцию.${NC}"
    echo ""
    echo -e "${YELLOW}Выберите действие:${NC}"
    echo -e "${CYAN}1.${NC} Исправить проблему SMTPUTF8 (отключить требование)"
    echo -e "${CYAN}2.${NC} Продолжить просмотр логов"
    echo ""
    echo -e "${YELLOW}---------------------------------------------${NC}"
    echo -n -e "${GREEN}Ваш выбор (1-2): ${NC}"
    read fix_choice
    
    case $fix_choice in
      1)
        fix_smtputf8_issue
        # После исправления возвращаемся к просмотру логов
        view_email_logs "$sender_email" "$recipient_email"
        return
        ;;
      2)
        ;;
      *)
        ;;
    esac
  fi
  
  echo -e "${YELLOW}Полезные команды для просмотра логов Postfix:${NC}"
  echo -e "${CYAN}•${NC} grep '${sender_email}\|${recipient_email}' ${log_file} (поиск по адресам)"
  echo -e "${CYAN}•${NC} tail -f ${log_file} | grep -i postfix (просмотр логов Postfix в реальном времени)"
  echo -e "${CYAN}•${NC} journalctl -t postfix -f (просмотр через journalctl в реальном времени)"
  echo -e "${CYAN}•${NC} journalctl --since '10 minutes ago' | grep -i postfix (логи за последние 10 минут)"
  echo ""
  echo -e "${YELLOW}Нажмите Enter, чтобы вернуться...${NC}"
  read
}

# Отправка тестового письма
send_test_email() {
  local domain="$1"
  local hostname_fqdn="$2"
  local server_ip="$3"
  
  clear_screen
  echo -e "${BOLD}${CYAN}==============================================${NC}"
  echo -e "${BOLD}${CYAN}     ОТПРАВКА ТЕСТОВОГО ПИСЬМА               ${NC}"
  echo -e "${BOLD}${CYAN}==============================================${NC}"
  echo ""
  echo -e "${YELLOW}Домен: ${BOLD}${domain}${NC}"
  echo ""
  
  # Получаем список почтовых ящиков для выбора отправителя
  DB_NAME="mailserver"
  DB_USER="mailuser"
  DB_PASS=$(grep "^password" /etc/postfix/mysql-virtual-mailbox-domains.cf 2>/dev/null | awk -F' = ' '{print $2}' | tr -d ' ' || echo "")
  
  if [ -z "$DB_PASS" ]; then
    echo -e "${RED}Не удалось определить пароль БД.${NC}"
    return 1
  fi
  
  local mailboxes_output=$(MYSQL_PWD="$DB_PASS" mysql -u "$DB_USER" "$DB_NAME" -Nse "SELECT email FROM virtual_users WHERE domain_id=(SELECT id FROM virtual_domains WHERE name='$domain' LIMIT 1);" 2>&1)
  
  local mailboxes=()
  if [ -n "$mailboxes_output" ] && ! [[ "$mailboxes_output" =~ ^ERROR ]]; then
    readarray -t mailboxes <<< "$mailboxes_output"
  fi
  
  if [ ${#mailboxes[@]} -eq 0 ]; then
    echo -e "${RED}Нет почтовых ящиков для этого домена.${NC}"
    return 1
  fi
  
  # Выбор отправителя
  echo -e "${YELLOW}Выберите отправителя:${NC}"
  echo -e "${YELLOW}---------------------------------------------${NC}"
  for i in "${!mailboxes[@]}"; do
    echo -e "${CYAN}$((i+1)).${NC} ${mailboxes[$i]}"
  done
  echo -e "${YELLOW}---------------------------------------------${NC}"
  echo ""
  echo -n -e "${GREEN}Номер отправителя (1-${#mailboxes[@]}): ${NC}"
  read sender_choice
  
  if ! [[ "$sender_choice" =~ ^[0-9]+$ ]] || [ "$sender_choice" -lt 1 ] || [ "$sender_choice" -gt ${#mailboxes[@]} ]; then
    echo -e "${RED}Некорректный выбор!${NC}"
    return 1
  fi
  
  local sender_email="${mailboxes[$((sender_choice-1))]}"
  
  echo ""
  echo -n -e "${GREEN}Введите адрес получателя: ${NC}"
  read recipient_email
  
  if [ -z "$recipient_email" ]; then
    echo -e "${RED}Адрес получателя не может быть пустым!${NC}"
    return 1
  fi
  
  # Проверяем формат email
  if ! [[ "$recipient_email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
    echo -e "${RED}Некорректный формат email адреса!${NC}"
    return 1
  fi
  
  echo ""
  echo -e "${YELLOW}Отправка тестового письма...${NC}"
  echo ""
  
  # Создаем временный файл для письма
  local temp_mail=$(mktemp)
  
  cat > "$temp_mail" <<EOF
From: $sender_email
To: $recipient_email
Subject: Тестовое письмо с почтового сервера $domain
Date: $(date -R)
Content-Type: text/plain; charset=UTF-8

Здравствуйте!

Это тестовое письмо с почтового сервера $domain.

Параметры сервера:
- Домен: $domain
- Hostname: $hostname_fqdn
- IP адрес: $server_ip
- Отправитель: $sender_email

Если вы получили это письмо, значит почтовый сервер настроен правильно и работает корректно.

С уважением,
Почтовый сервер $domain
EOF

  # Отправляем письмо через sendmail
  if command -v sendmail >/dev/null 2>&1; then
    sendmail -f "$sender_email" "$recipient_email" < "$temp_mail"
    send_result=$?
  elif command -v mail >/dev/null 2>&1; then
    mail -s "Тестовое письмо с почтового сервера $domain" -r "$sender_email" "$recipient_email" < "$temp_mail"
    send_result=$?
  else
    # Используем postfix напрямую
    cat "$temp_mail" | /usr/sbin/sendmail -f "$sender_email" "$recipient_email"
    send_result=$?
  fi
  
  # Удаляем временный файл
  rm -f "$temp_mail"
  
  if [ $send_result -eq 0 ]; then
    echo -e "${GREEN}${BOLD}Тестовое письмо успешно отправлено!${NC}"
    echo ""
    echo -e "${YELLOW}От:${NC} ${CYAN}${sender_email}${NC}"
    echo -e "${YELLOW}Кому:${NC} ${CYAN}${recipient_email}${NC}"
    echo ""
    echo -e "${YELLOW}Проверьте почтовый ящик получателя.${NC}"
    echo ""
    
    # Меню действий после отправки
    while true; do
      echo -e "${YELLOW}Выберите действие:${NC}"
      echo -e "${CYAN}1.${NC} Просмотреть логи отправленного сообщения"
      echo -e "${CYAN}2.${NC} Вернуться к деталям домена"
      echo ""
      echo -e "${YELLOW}---------------------------------------------${NC}"
      echo -n -e "${GREEN}Ваш выбор (1-2): ${NC}"
      read log_choice
      
      case $log_choice in
        1)
          view_email_logs "$sender_email" "$recipient_email"
          # После просмотра логов возвращаемся к меню
          clear_screen
          echo -e "${BOLD}${CYAN}==============================================${NC}"
          echo -e "${BOLD}${CYAN}     ОТПРАВКА ТЕСТОВОГО ПИСЬМА               ${NC}"
          echo -e "${BOLD}${CYAN}==============================================${NC}"
          echo ""
          echo -e "${GREEN}${BOLD}Тестовое письмо успешно отправлено!${NC}"
          echo ""
          echo -e "${YELLOW}От:${NC} ${CYAN}${sender_email}${NC}"
          echo -e "${YELLOW}Кому:${NC} ${CYAN}${recipient_email}${NC}"
          echo ""
          continue
          ;;
        2)
          return 0
          ;;
        *)
          echo -e "${RED}Некорректный выбор!${NC}"
          sleep 1
          ;;
      esac
    done
  else
    echo -e "${RED}Ошибка при отправке письма.${NC}"
    echo ""
    echo -e "${YELLOW}Проверьте:${NC}"
    echo -e "${CYAN}1.${NC} Статус сервиса Postfix: systemctl status postfix"
    echo -e "${CYAN}2.${NC} Логи Postfix: journalctl -u postfix -n 50"
    echo -e "${CYAN}3.${NC} Настройки DNS для домена $domain"
    echo ""
    echo -e "${YELLOW}Нажмите Enter, чтобы вернуться...${NC}"
    read
  fi
}

# Вывод DNS записей
show_dns_records() {
  local domain="$1"
  local hostname_fqdn="$2"
  local email="$3"
  
  # Получаем IP адрес сервера
  SERVER_IP=$(hostname -I | awk '{print $1}')
  
  # Извлекаем DKIM публичный ключ
  DKIM_FILE="/etc/opendkim/keys/$domain/dkim.txt"
  DKIM_KEY=""
  if [ -f "$DKIM_FILE" ]; then
    DKIM_KEY=$(grep -oP 'p=[^";\s)]+' "$DKIM_FILE" | sed 's/^p=//' | tr -d '\n' | tr -d ' ' | tr -d '"')
    if [ -z "$DKIM_KEY" ]; then
      DKIM_KEY=$(sed -n '/p=/p' "$DKIM_FILE" | sed 's/.*p=//' | sed 's/[^A-Za-z0-9+/=].*//' | tr -d '\n' | tr -d ' ' | tr -d '"')
    fi
  fi
  
  local mail_user=$(echo "$email" | cut -d@ -f1)
  
  echo ""
  echo -e "${BOLD}${CYAN}=====================================================${NC}"
  echo -e "${BOLD}${CYAN}DNS ЗАПИСИ ДЛЯ НАСТРОЙКИ В ПАНЕЛИ УПРАВЛЕНИЯ DNS:${NC}"
  echo -e "${BOLD}${CYAN}=====================================================${NC}"
  echo ""
  echo -e "${YELLOW}A-запись (для hostname)${NC}"
  echo "Тип: A"
  echo "Хост: mail"
  echo "Значение: $SERVER_IP"
  echo "TTL: 3600"
  echo ""
  echo -e "${YELLOW}MX-запись (приём почты)${NC}"
  echo "Тип: MX"
  echo "Хост: @ (или пусто)"
  echo "Значение: $hostname_fqdn. (с точкой в конце!)"
  echo "Приоритет: 10"
  echo ""
  echo -e "${YELLOW}SPF-запись (от спама)${NC}"
  echo "Тип: TXT"
  echo "Хост: @"
  echo "Значение: \"v=spf1 a mx ~all\" (в кавычках, ~all — мягкий отказ)"
  echo ""
  echo -e "${YELLOW}DMARC-запись${NC}"
  echo "Тип: TXT"
  echo "Хост: _dmarc"
  echo "Значение: \"v=DMARC1; p=quarantine; rua=mailto:$email\""
  echo ""
  echo -e "${YELLOW}DKIM-запись${NC}"
  echo "Тип: TXT"
  echo "Хост: dkim._domainkey (создаст подзону _domainkey → dkim)"
  if [ -n "$DKIM_KEY" ]; then
    echo "Значение: \"v=DKIM1; h=sha256; k=rsa; p=$DKIM_KEY\" (в одну строку, без переносов)"
  else
    echo "Значение: (не удалось извлечь ключ, проверьте файл $DKIM_FILE)"
    echo "Альтернативно, выполните команду для просмотра ключа:"
    echo "cat $DKIM_FILE"
  fi
  echo ""
  echo -e "${BOLD}${CYAN}=====================================================${NC}"
}

# Создание Python HTTP сервера для endpoint отправки писем
create_python_mail_endpoint_server() {
  local port="$1"
  local api_key="$2"
  local script_path="/tmp/mail_endpoint_${port}.py"
  
  cat > "$script_path" << PYTHON_SERVER_EOF
#!/usr/bin/env python3
import http.server
import socketserver
import json
import sys
import subprocess
import re
from datetime import datetime
from email.utils import formatdate

class MailEndpointHandler(http.server.BaseHTTPRequestHandler):
    def __init__(self, *args, api_key=None, **kwargs):
        self.api_key = api_key
        super().__init__(*args, **kwargs)
    
    def handle(self):
        """Переопределяем handle для обработки ошибок"""
        try:
            super().handle()
        except BrokenPipeError:
            # Игнорируем ошибки разорванного соединения
            self.log_message("Connection closed by client")
        except Exception as e:
            self.log_message(f"Error in handle: {str(e)}")
            import traceback
            self.log_message(traceback.format_exc())
    
    def log_message(self, format, *args):
        timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        message = format % args
        print(f"[{timestamp}] {message}")
        # Логируем в файл
        try:
            with open("/var/lib/mail-server/logs/endpoint.log", "a") as f:
                f.write(f"[{timestamp}] {message}\n")
        except:
            pass
    
    def log_request(self, code='-', size='-'):
        """Логируем все входящие запросы"""
        self.log_message('"%s" %s %s', self.requestline, str(code), str(size))
    
    def validate_email(self, email):
        """Валидация email адреса"""
        pattern = r'^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'
        return re.match(pattern, email) is not None
    
    def send_email(self, sender, recipient, subject, message):
        """Отправка письма через sendmail"""
        try:
            # Формируем письмо в формате RFC 2822
            email_content = f"""From: {sender}
To: {recipient}
Subject: {subject}
Date: {formatdate()}
Content-Type: text/plain; charset=UTF-8

{message}
"""
            # Отправляем через sendmail
            process = subprocess.Popen(
                ['/usr/sbin/sendmail', '-f', sender, recipient],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE
            )
            stdout, stderr = process.communicate(input=email_content.encode('utf-8'))
            
            if process.returncode == 0:
                return True, None
            else:
                return False, stderr.decode('utf-8', errors='ignore')
        except Exception as e:
            return False, str(e)
    
    def do_POST(self):
        """Обработка POST запросов"""
        self.log_message(f"POST request received: {self.path} from {self.client_address[0]}")
        
        if self.path != '/send':
            self.log_message(f"404: Path not found: {self.path}")
            self.send_response(404)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({'error': 'Endpoint not found'}).encode())
            return
        
        # Проверяем API ключ
        api_key_header = self.headers.get('X-API-Key', '')
        if not api_key_header:
            self.log_message("401: Missing X-API-Key header")
            self.send_response(401)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({'error': 'Unauthorized: Missing API key'}).encode())
            return
        
        if api_key_header != self.api_key:
            self.log_message(f"401: Invalid API key provided (expected: {self.api_key[:10]}..., got: {api_key_header[:10]}...)")
            self.send_response(401)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({'error': 'Unauthorized: Invalid API key'}).encode())
            return
        
        # Читаем тело запроса
        try:
            content_length = int(self.headers.get('Content-Length', 0))
        except (ValueError, TypeError):
            content_length = 0
        
        if content_length == 0:
            self.log_message("400: Empty request body")
            self.send_response(400)
            self.send_header('Content-type', 'application/json')
            self.send_header('Connection', 'close')
            self.end_headers()
            self.wfile.write(json.dumps({'error': 'Empty request body'}).encode())
            try:
                self.wfile.flush()
            except:
                pass
            return
        
        body_str = ""
        try:
            # Читаем тело запроса
            body = self.rfile.read(content_length)
            body_str = body.decode('utf-8')
            self.log_message(f"Request body received ({content_length} bytes): {body_str[:500]}")
            
            # Парсим JSON
            data = json.loads(body_str)
            self.log_message(f"Parsed JSON successfully. Keys: {list(data.keys())}")
            
        except json.JSONDecodeError as e:
            self.log_message(f"400: Invalid JSON - {str(e)}")
            self.log_message(f"Body was: {repr(body_str[:500])}")
            self.send_response(400)
            self.send_header('Content-type', 'application/json')
            self.send_header('Connection', 'close')
            self.end_headers()
            error_response = json.dumps({'error': f'Invalid JSON: {str(e)}', 'body_preview': body_str[:100]})
            self.wfile.write(error_response.encode())
            try:
                self.wfile.flush()
            except:
                pass
            return
        except UnicodeDecodeError as e:
            self.log_message(f"400: Invalid encoding - {str(e)}")
            self.send_response(400)
            self.send_header('Content-type', 'application/json')
            self.send_header('Connection', 'close')
            self.end_headers()
            self.wfile.write(json.dumps({'error': 'Invalid encoding in request body'}).encode())
            try:
                self.wfile.flush()
            except:
                pass
            return
        except Exception as e:
            self.log_message(f"500: Server error while reading request - {str(e)}")
            import traceback
            self.log_message(traceback.format_exc())
            self.send_response(500)
            self.send_header('Content-type', 'application/json')
            self.send_header('Connection', 'close')
            self.end_headers()
            self.wfile.write(json.dumps({'error': f'Server error: {str(e)}'}).encode())
            try:
                self.wfile.flush()
            except:
                pass
            return
        
        # Проверяем наличие обязательных полей
        required_fields = ['subject', 'message', 'from', 'to']
        missing_fields = [field for field in required_fields if field not in data]
        if missing_fields:
            self.log_message(f"400: Missing required fields: {missing_fields}")
            self.log_message(f"Received fields: {list(data.keys())}")
            self.log_message(f"Data content: {str(data)[:500]}")
            self.send_response(400)
            self.send_header('Content-type', 'application/json')
            self.send_header('Connection', 'close')
            self.end_headers()
            error_response = json.dumps({
                'error': f'Missing required field: {missing_fields[0]}',
                'missing_fields': missing_fields,
                'received_fields': list(data.keys()),
                'received_data': data
            })
            self.wfile.write(error_response.encode())
            try:
                self.wfile.flush()
            except:
                pass
            return
        
        # Валидируем email адреса
        if not self.validate_email(data['from']):
            self.send_response(400)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({'error': 'Invalid sender email address'}).encode())
            return
        
        if not self.validate_email(data['to']):
            self.send_response(400)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({'error': 'Invalid recipient email address'}).encode())
            return
        
        # Отправляем письмо
        success, error = self.send_email(
            data['from'],
            data['to'],
            data['subject'],
            data['message']
        )
        
        if success:
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            response = {
                'status': 'success',
                'message': 'Email sent successfully',
                'from': data['from'],
                'to': data['to'],
                'subject': data['subject']
            }
            self.wfile.write(json.dumps(response).encode())
            self.log_message(f"Email sent: {data['from']} -> {data['to']}, subject: {data['subject']}")
        else:
            self.send_response(500)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            response = {
                'status': 'error',
                'error': f'Failed to send email: {error}'
            }
            self.wfile.write(json.dumps(response).encode())
            self.log_message(f"Failed to send email: {error}")
    
    def do_GET(self):
        """Обработка GET запросов для проверки статуса"""
        self.log_message(f"GET request received: {self.path} from {self.client_address[0]}")
        if self.path == '/health':
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({'status': 'ok', 'service': 'mail-endpoint'}).encode())
            self.log_message("Health check: OK")
        else:
            self.log_message(f"404: GET path not found: {self.path}")
            self.send_response(404)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({'error': 'Not found'}).encode())

class MailEndpointServer(socketserver.TCPServer):
    def __init__(self, server_address, RequestHandlerClass, api_key):
        self.api_key = api_key
        # Разрешаем переиспользование адреса
        self.allow_reuse_address = True
        # Увеличиваем размер буфера для больших запросов
        self.request_queue_size = 128
        super().__init__(server_address, RequestHandlerClass)
    
    def finish_request(self, request, client_address):
        """Переопределяем для передачи api_key в handler"""
        try:
            self.RequestHandlerClass(request, client_address, self, api_key=self.api_key)
        except Exception as e:
            import traceback
            timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            try:
                with open("/var/lib/mail-server/logs/endpoint.log", "a") as f:
                    f.write(f"[{timestamp}] [ERROR] Error in finish_request: {str(e)}\n")
                    f.write(traceback.format_exc())
            except:
                pass

def run_server(port=8080, api_key=""):
    try:
        # Создаем директорию для логов если не существует
        import os
        os.makedirs("/var/lib/mail-server/logs", exist_ok=True)
        
        # Создаем сервер с передачей api_key
        with MailEndpointServer(("0.0.0.0", port), MailEndpointHandler, api_key) as httpd:
            print(f"Mail endpoint server running on 0.0.0.0:{port}")
            timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            try:
                with open("/var/lib/mail-server/logs/endpoint.log", "a") as f:
                    f.write(f"[{timestamp}] [INFO] Mail endpoint server started on 0.0.0.0:{port}\n")
            except:
                pass
            httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nServer stopped by user")
    except Exception as e:
        print(f"Server error: {e}")
        import traceback
        traceback.print_exc()
        return 1
    return 0

if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    api_key = sys.argv[2] if len(sys.argv) > 2 else ""
    sys.exit(run_server(port, api_key))
PYTHON_SERVER_EOF

  echo "$script_path"
}

# Создание endpoint для отправки писем
create_mail_endpoint() {
  clear_screen
  echo -e "${BOLD}${CYAN}==============================================${NC}"
  echo -e "${BOLD}${CYAN}     СОЗДАНИЕ ENDPOINT ДЛЯ ОТПРАВКИ ПИСЕМ      ${NC}"
  echo -e "${BOLD}${CYAN}==============================================${NC}"
  echo ""
  
  # Проверяем наличие Python3
  if ! command -v python3 >/dev/null 2>&1; then
    echo -e "${RED}Python3 не установлен в системе.${NC}"
    echo -e "${YELLOW}Установите Python3 для использования этой функции.${NC}"
    echo ""
    echo -e "${YELLOW}Нажмите Enter, чтобы вернуться...${NC}"
    read
    return 1
  fi
  
  # Запрашиваем порт
  echo -e "${YELLOW}Введите данные для endpoint:${NC}"
  echo ""
  echo -n -e "${GREEN}Порт для HTTP сервера (например, 8080): ${NC}"
  read port
  
  # Проверяем корректность порта
  if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
    echo -e "${RED}Некорректный порт! Укажите число от 1 до 65535.${NC}"
    sleep 2
    return 1
  fi
  
  # Проверяем, занят ли порт
  if ss -tuln 2>/dev/null | grep -q ":${port} " || netstat -tuln 2>/dev/null | grep -q ":${port} "; then
    echo -e "${RED}Порт $port уже занят!${NC}"
    sleep 2
    return 1
  fi
  
  # Проверяем и открываем порт в firewall
  echo ""
  echo -e "${YELLOW}Проверка firewall...${NC}"
  if command -v ufw >/dev/null 2>&1; then
    if ufw status | grep -q "Status: active"; then
      if ! ufw status | grep -q "${port}"; then
        echo -e "${YELLOW}Открытие порта $port в firewall (ufw)...${NC}"
        ufw allow ${port}/tcp 2>/dev/null || true
        echo -e "${GREEN}Порт $port открыт в firewall.${NC}"
      else
        echo -e "${GREEN}Порт $port уже открыт в firewall.${NC}"
      fi
    else
      echo -e "${YELLOW}Firewall (ufw) не активен.${NC}"
    fi
  elif command -v firewall-cmd >/dev/null 2>&1; then
    echo -e "${YELLOW}Проверка firewall (firewalld)...${NC}"
    if firewall-cmd --state 2>/dev/null | grep -q "running"; then
      if ! firewall-cmd --list-ports 2>/dev/null | grep -q "${port}/tcp"; then
        echo -e "${YELLOW}Открытие порта $port в firewall (firewalld)...${NC}"
        firewall-cmd --permanent --add-port=${port}/tcp 2>/dev/null || true
        firewall-cmd --reload 2>/dev/null || true
        echo -e "${GREEN}Порт $port открыт в firewall.${NC}"
      else
        echo -e "${GREEN}Порт $port уже открыт в firewall.${NC}"
      fi
    fi
  else
    echo -e "${YELLOW}Firewall не обнаружен. Убедитесь, что порт $port открыт вручную.${NC}"
  fi
  
  # Проверяем, существует ли уже endpoint на этом порту
  if grep -q "^${port}:" "$ENDPOINTS_LIST_FILE" 2>/dev/null; then
    echo -e "${YELLOW}Endpoint на порту $port уже существует.${NC}"
    echo -n -e "${RED}Перезаписать существующий endpoint? (y/n): ${NC}"
    read overwrite
    
    if [[ "$overwrite" != "y" && "$overwrite" != "Y" ]]; then
      echo -e "${YELLOW}Создание endpoint отменено.${NC}"
      sleep 2
      return 1
    fi
    
    # Удаляем старый endpoint
    local old_service_name="mail-endpoint-${port}"
    systemctl stop "${old_service_name}.service" 2>/dev/null
    systemctl disable "${old_service_name}.service" 2>/dev/null
    rm -f "/etc/systemd/system/${old_service_name}.service"
    systemctl daemon-reload
    
    # Удаляем из списка
    local temp_file=$(mktemp)
    grep -v "^${port}:" "$ENDPOINTS_LIST_FILE" > "$temp_file" 2>/dev/null || true
    mv "$temp_file" "$ENDPOINTS_LIST_FILE"
  fi
  
  # Генерируем или запрашиваем API ключ
  echo ""
  echo -e "${YELLOW}Настройка API ключа для аутентификации:${NC}"
  echo -e "${CYAN}1.${NC} Автоматически сгенерировать ключ"
  echo -e "${CYAN}2.${NC} Ввести ключ вручную"
  echo ""
  echo -n -e "${GREEN}Ваш выбор (1-2): ${NC}"
  read key_choice
  
  if [ "$key_choice" = "2" ]; then
    echo -n -e "${GREEN}Введите API ключ: ${NC}"
    read api_key
    if [ -z "$api_key" ]; then
      echo -e "${RED}API ключ не может быть пустым!${NC}"
      sleep 2
      return 1
    fi
  else
    # Генерируем случайный ключ
    api_key=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-40)
    echo -e "${GREEN}Сгенерирован API ключ: ${api_key}${NC}"
  fi
  
  echo ""
  echo -e "${YELLOW}Создание Python HTTP сервера...${NC}"
  
  # Создаем Python скрипт
  local script_path=$(create_python_mail_endpoint_server "$port" "$api_key")
  
  if [ ! -f "$script_path" ]; then
    echo -e "${RED}Не удалось создать Python скрипт.${NC}"
    sleep 2
    return 1
  fi
  
  # Делаем скрипт исполняемым
  chmod +x "$script_path"
  
  # Проверяем синтаксис Python скрипта
  if ! python3 -m py_compile "$script_path" 2>/dev/null; then
    echo -e "${RED}Ошибка синтаксиса Python скрипта.${NC}"
    rm -f "$script_path" 2>/dev/null
    sleep 2
    return 1
  fi
  
  echo -e "${GREEN}Python скрипт создан: $script_path${NC}"
  
  # Создаем директорию для логов
  mkdir -p /var/lib/mail-server/logs
  
  # Создаем systemd сервис
  local service_name="mail-endpoint-${port}"
  local user=$(whoami)
  
  cat > "/etc/systemd/system/${service_name}.service" << EOF
[Unit]
Description=Mail Endpoint Server on port ${port}
After=network.target postfix.service

[Service]
Type=simple
User=${user}
WorkingDirectory=/tmp
ExecStart=/usr/bin/python3 ${script_path} ${port} ${api_key}
Restart=always
RestartSec=10
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF

  echo -e "${GREEN}Systemd сервис создан: ${service_name}.service${NC}"
  
  # Сохраняем информацию о endpoint
  echo "${port}:${api_key}:${service_name}:$(date '+%Y-%m-%d %H:%M:%S')" >> "$ENDPOINTS_LIST_FILE"
  
  # Перезагружаем конфигурацию systemd
  echo -e "${YELLOW}Перезагрузка конфигурации systemd...${NC}"
  systemctl daemon-reload
  
  # Активируем автозапуск
  echo -e "${YELLOW}Активация автозапуска сервиса...${NC}"
  systemctl enable "${service_name}.service"
  
  # Спрашиваем, нужно ли запустить сервис сейчас
  echo ""
  echo -n -e "${GREEN}Хотите запустить endpoint сейчас? (y/n): ${NC}"
  read start_now
  
  if [[ "$start_now" == "y" || "$start_now" == "Y" ]]; then
    echo -e "${YELLOW}Запуск endpoint...${NC}"
    systemctl start "${service_name}.service"
    sleep 2
    
    if systemctl is-active --quiet "${service_name}.service"; then
      echo -e "${GREEN}${BOLD}Endpoint успешно запущен!${NC}"
      echo ""
      local server_ip=$(hostname -I | awk '{print $1}')
      echo -e "${YELLOW}Информация о endpoint:${NC}"
      echo -e "${CYAN}Порт:${NC} ${port}"
      echo -e "${CYAN}API ключ:${NC} ${api_key}"
      echo -e "${CYAN}URL:${NC} http://${server_ip}:${port}/send"
      echo -e "${CYAN}Health check:${NC} http://${server_ip}:${port}/health"
      echo ""
      echo -e "${YELLOW}Пример использования с curl:${NC}"
      echo -e "${CYAN}curl -X POST http://${server_ip}:${port}/send \\\\${NC}"
      echo -e "${CYAN}  -H \"Content-Type: application/json\" \\\\${NC}"
      echo -e "${CYAN}  -H \"X-API-Key: ${api_key}\" \\\\${NC}"
      echo -e "${CYAN}  -d '{\"from\":\"sender@example.com\",\"to\":\"recipient@example.com\",\"subject\":\"Test\",\"message\":\"Hello\"}'${NC}"
    else
      echo -e "${RED}Ошибка при запуске endpoint.${NC}"
      echo -e "${YELLOW}Проверьте логи: journalctl -u ${service_name} -n 50${NC}"
    fi
  else
    echo -e "${GREEN}${BOLD}Endpoint настроен для автозапуска после перезагрузки.${NC}"
    echo ""
    echo -e "${YELLOW}Для запуска используйте:${NC}"
    echo -e "${CYAN}systemctl start ${service_name}.service${NC}"
  fi
  
  echo ""
  echo -e "${YELLOW}Нажмите Enter, чтобы продолжить...${NC}"
  read
}

# Управление endpoint'ами для отправки писем
manage_mail_endpoints() {
  while true; do
    clear_screen
    echo -e "${BOLD}${CYAN}==============================================${NC}"
    echo -e "${BOLD}${CYAN}     УПРАВЛЕНИЕ ENDPOINT ДЛЯ ОТПРАВКИ ПИСЕМ   ${NC}"
    echo -e "${BOLD}${CYAN}==============================================${NC}"
    echo ""
    
    if [ ! -s "$ENDPOINTS_LIST_FILE" ]; then
      echo -e "${YELLOW}Список созданных endpoint пуст.${NC}"
      echo ""
      echo -e "${YELLOW}Нажмите Enter, чтобы вернуться...${NC}"
      read
      return 0
    fi
    
    echo -e "${YELLOW}Список созданных endpoint:${NC}"
    echo -e "${YELLOW}---------------------------------------------${NC}"
    
    mapfile -t endpoints < "$ENDPOINTS_LIST_FILE"
    
    for i in "${!endpoints[@]}"; do
      endpoint_info=(${endpoints[$i]//:/ })
      endpoint_port="${endpoint_info[0]}"
      endpoint_api_key="${endpoint_info[1]}"
      endpoint_service="${endpoint_info[2]}"
      endpoint_date="${endpoint_info[3]} ${endpoint_info[4]}"
      
      status=$(systemctl is-active "$endpoint_service" 2>/dev/null || echo "inactive")
      if [ "$status" == "active" ]; then
        status_text="${GREEN}активен${NC}"
      else
        status_text="${RED}неактивен${NC}"
      fi
      
      echo -e "${CYAN}$((i+1)).${NC} ${BOLD}Порт: ${endpoint_port}${NC} (${status_text})"
      echo -e "   ${YELLOW}Сервис:${NC} ${endpoint_service}"
      echo -e "   ${YELLOW}API ключ:${NC} ${endpoint_api_key:0:10}...${endpoint_api_key:(-5)}"
      echo -e "   ${YELLOW}Создан:${NC} ${endpoint_date}"
      echo -e "${YELLOW}---------------------------------------------${NC}"
    done
    
    echo ""
    echo -e "${YELLOW}Выберите действие:${NC}"
    echo -e "${CYAN}1.${NC} Выбрать endpoint для управления"
    echo -e "${CYAN}2.${NC} Создать новый endpoint"
    echo -e "${CYAN}3.${NC} Вернуться в главное меню"
    echo ""
    echo -e "${YELLOW}---------------------------------------------${NC}"
    echo -n -e "${GREEN}Ваш выбор (1-3): ${NC}"
    read action_choice
    
    if [ "$action_choice" -eq 1 ]; then
      echo ""
      echo -n -e "${GREEN}Введите номер endpoint для управления: ${NC}"
      read endpoint_number
      
      if ! [[ "$endpoint_number" =~ ^[0-9]+$ ]] || [ "$endpoint_number" -lt 1 ] || [ "$endpoint_number" -gt ${#endpoints[@]} ]; then
        echo -e "${RED}Некорректный выбор!${NC}"
        sleep 2
        continue
      fi
      
      selected_endpoint=(${endpoints[$((endpoint_number-1))]//:/ })
      endpoint_port="${selected_endpoint[0]}"
      endpoint_api_key="${selected_endpoint[1]}"
      endpoint_service="${selected_endpoint[2]}"
      
      # Меню управления endpoint
      while true; do
        clear_screen
        echo -e "${BOLD}${CYAN}==============================================${NC}"
        echo -e "${BOLD}${CYAN}   УПРАВЛЕНИЕ: Порт ${endpoint_port}              ${NC}"
        echo -e "${BOLD}${CYAN}==============================================${NC}"
        echo ""
        
        local status=$(systemctl is-active "$endpoint_service" 2>/dev/null || echo "inactive")
        local enabled=$(systemctl is-enabled "$endpoint_service" 2>/dev/null || echo "disabled")
        
        local status_text=""
        if [ "$status" == "active" ]; then
          status_text="${GREEN}Активен${NC}"
        else
          status_text="${RED}Неактивен${NC}"
        fi
        
        local enabled_text=""
        if [ "$enabled" == "enabled" ]; then
          enabled_text="${GREEN}Да${NC}"
        else
          enabled_text="${RED}Нет${NC}"
        fi
        
        echo -e "${YELLOW}Информация о endpoint:${NC}"
        echo -e "${YELLOW}---------------------------------------------${NC}"
        echo -e "${BOLD}Порт:${NC} ${endpoint_port}"
        echo -e "${BOLD}Статус:${NC} ${status_text}"
        echo -e "${BOLD}Автозапуск:${NC} ${enabled_text}"
        echo -e "${BOLD}Сервис:${NC} ${endpoint_service}"
        echo -e "${BOLD}API ключ:${NC} ${endpoint_api_key}"
        echo -e "${YELLOW}---------------------------------------------${NC}"
        echo ""
        
        echo -e "${YELLOW}Выберите действие:${NC}"
        echo -e "${CYAN}1.${NC} Запустить endpoint"
        echo -e "${CYAN}2.${NC} Остановить endpoint"
        echo -e "${CYAN}3.${NC} Перезапустить endpoint"
        echo -e "${CYAN}4.${NC} Просмотреть журнал endpoint"
        echo -e "${CYAN}5.${NC} Показать пример использования"
        echo -e "${CYAN}6.${NC} Удалить endpoint"
        echo -e "${CYAN}7.${NC} Вернуться к списку endpoint"
        echo ""
        echo -e "${YELLOW}---------------------------------------------${NC}"
        echo -n -e "${GREEN}Ваш выбор (1-7): ${NC}"
        read control_option
        
        case $control_option in
          1) # Запустить
            echo -e "${YELLOW}Запуск endpoint...${NC}"
            systemctl start "$endpoint_service"
            sleep 1
            if systemctl is-active --quiet "$endpoint_service"; then
              echo -e "${GREEN}Endpoint успешно запущен!${NC}"
            else
              echo -e "${RED}Ошибка при запуске endpoint.${NC}"
              echo -e "${YELLOW}Проверьте логи: journalctl -u ${endpoint_service} -n 50${NC}"
            fi
            echo ""
            echo -e "${YELLOW}Нажмите Enter, чтобы продолжить...${NC}"
            read
            ;;
          2) # Остановить
            echo -e "${YELLOW}Остановка endpoint...${NC}"
            systemctl stop "$endpoint_service"
            sleep 1
            echo -e "${GREEN}Endpoint остановлен.${NC}"
            echo ""
            echo -e "${YELLOW}Нажмите Enter, чтобы продолжить...${NC}"
            read
            ;;
          3) # Перезапустить
            echo -e "${YELLOW}Перезапуск endpoint...${NC}"
            systemctl restart "$endpoint_service"
            sleep 1
            if systemctl is-active --quiet "$endpoint_service"; then
              echo -e "${GREEN}Endpoint успешно перезапущен!${NC}"
            else
              echo -e "${RED}Ошибка при перезапуске endpoint.${NC}"
            fi
            echo ""
            echo -e "${YELLOW}Нажмите Enter, чтобы продолжить...${NC}"
            read
            ;;
          4) # Просмотр журнала
            clear_screen
            echo -e "${BOLD}${CYAN}==============================================${NC}"
            echo -e "${BOLD}${CYAN}       ЖУРНАЛ ENDPOINT ${endpoint_service}         ${NC}"
            echo -e "${BOLD}${CYAN}==============================================${NC}"
            echo ""
            echo -e "${YELLOW}Последние 50 строк журнала:${NC}"
            echo -e "${YELLOW}---------------------------------------------${NC}"
            echo ""
            journalctl -u "$endpoint_service" -n 50 --no-pager
            echo ""
            echo -e "${YELLOW}---------------------------------------------${NC}"
            echo ""
            echo -e "${YELLOW}Нажмите Enter, чтобы вернуться...${NC}"
            read
            ;;
          5) # Показать пример использования
            clear_screen
            local server_ip=$(hostname -I | awk '{print $1}')
            echo -e "${BOLD}${CYAN}==============================================${NC}"
            echo -e "${BOLD}${CYAN}     ПРИМЕР ИСПОЛЬЗОВАНИЯ ENDPOINT            ${NC}"
            echo -e "${BOLD}${CYAN}==============================================${NC}"
            echo ""
            echo -e "${YELLOW}URL:${NC} http://${server_ip}:${endpoint_port}/send"
            echo -e "${YELLOW}Метод:${NC} POST"
            echo -e "${YELLOW}Заголовки:${NC}"
            echo -e "  ${CYAN}Content-Type:${NC} application/json"
            echo -e "  ${CYAN}X-API-Key:${NC} ${endpoint_api_key}"
            echo ""
            echo -e "${YELLOW}Тело запроса (JSON):${NC}"
            echo -e "${CYAN}{${NC}"
            echo -e "${CYAN}  \"from\": \"sender@example.com\",${NC}"
            echo -e "${CYAN}  \"to\": \"recipient@example.com\",${NC}"
            echo -e "${CYAN}  \"subject\": \"Тема письма\",${NC}"
            echo -e "${CYAN}  \"message\": \"Текст сообщения\"${NC}"
            echo -e "${CYAN}}${NC}"
            echo ""
            echo -e "${YELLOW}Пример с curl:${NC}"
            echo -e "${CYAN}curl -X POST http://${server_ip}:${endpoint_port}/send \\\\${NC}"
            echo -e "${CYAN}  -H \"Content-Type: application/json\" \\\\${NC}"
            echo -e "${CYAN}  -H \"X-API-Key: ${endpoint_api_key}\" \\\\${NC}"
            echo -e "${CYAN}  -d '{\"from\":\"sender@example.com\",\"to\":\"recipient@example.com\",\"subject\":\"Test\",\"message\":\"Hello\"}'${NC}"
            echo ""
            echo -e "${YELLOW}Health check:${NC}"
            echo -e "${CYAN}curl http://${server_ip}:${endpoint_port}/health${NC}"
            echo ""
            echo -e "${YELLOW}Нажмите Enter, чтобы вернуться...${NC}"
            read
            ;;
          6) # Удалить
            echo -e "${RED}${BOLD}Вы уверены, что хотите удалить endpoint на порту ${endpoint_port}? (y/n): ${NC}"
            read confirm_delete
            
            if [[ "$confirm_delete" == "y" || "$confirm_delete" == "Y" ]]; then
              echo -e "${YELLOW}Удаление endpoint...${NC}"
              
              # Останавливаем сервис
              systemctl stop "$endpoint_service" 2>/dev/null
              systemctl disable "$endpoint_service" 2>/dev/null
              
              # Удаляем файл сервиса
              rm -f "/etc/systemd/system/${endpoint_service}.service"
              
              # Перезагружаем конфигурацию systemd
              systemctl daemon-reload
              
              # Удаляем запись из списка
              local temp_file=$(mktemp)
              grep -v "^${endpoint_port}:" "$ENDPOINTS_LIST_FILE" > "$temp_file" 2>/dev/null || true
              mv "$temp_file" "$ENDPOINTS_LIST_FILE"
              
              # Удаляем Python скрипт
              rm -f "/tmp/mail_endpoint_${endpoint_port}.py"
              
              echo -e "${GREEN}${BOLD}Endpoint успешно удален.${NC}"
              sleep 2
              break
            else
              echo -e "${YELLOW}Удаление отменено.${NC}"
              sleep 1
            fi
            ;;
          7) # Вернуться к списку
            break
            ;;
          *)
            echo -e "${RED}Некорректный выбор!${NC}"
            sleep 1
            ;;
        esac
      done
    elif [ "$action_choice" -eq 2 ]; then
      create_mail_endpoint
    elif [ "$action_choice" -eq 3 ]; then
      return 0
    else
      echo -e "${RED}Некорректный выбор!${NC}"
      sleep 1
    fi
  done
}

# Очистка всех данных, созданных скриптом
cleanup_all() {
  clear_screen
  echo -e "${BOLD}${RED}==============================================${NC}"
  echo -e "${BOLD}${RED}     ОЧИСТКА ВСЕХ ДАННЫХ ПОЧТОВОГО СЕРВЕРА    ${NC}"
  echo -e "${BOLD}${RED}==============================================${NC}"
  echo ""
  echo -e "${RED}${BOLD}ВНИМАНИЕ! Это действие удалит:${NC}"
  echo -e "${YELLOW}• Все домены и почтовые ящики из базы данных${NC}"
  echo -e "${YELLOW}• Все конфигурационные файлы Postfix и Dovecot${NC}"
  echo -e "${YELLOW}• Все DKIM ключи${NC}"
  echo -e "${YELLOW}• Файлы со списками доменов и почтовых ящиков${NC}"
  echo -e "${YELLOW}• Пользователя vmail и его директорию${NC}"
  echo ""
  echo -e "${RED}${BOLD}Это действие НЕОБРАТИМО!${NC}"
  echo ""
  echo -n -e "${GREEN}Введите 'YES' для подтверждения удаления: ${NC}"
  read confirmation
  
  if [ "$confirmation" != "YES" ]; then
    echo -e "${YELLOW}Очистка отменена.${NC}"
    sleep 2
    return 0
  fi
  
  echo ""
  echo -e "${YELLOW}Начинаем очистку...${NC}"
  echo ""
  
  # Получаем данные БД
  DB_NAME="mailserver"
  DB_USER="mailuser"
  DB_PASS=$(grep "^password" /etc/postfix/mysql-virtual-mailbox-domains.cf 2>/dev/null | awk -F' = ' '{print $2}' | tr -d ' ' || echo "")
  
  # Удаляем данные из БД
  if [ -n "$DB_PASS" ]; then
    echo -e "${YELLOW}Удаление данных из базы данных...${NC}"
    MYSQL_PWD="$DB_PASS" mysql -u "$DB_USER" "$DB_NAME" <<SQL 2>/dev/null || true
DELETE FROM virtual_users;
DELETE FROM virtual_domains;
SQL
    echo -e "${GREEN}Данные из БД удалены.${NC}"
  else
    echo -e "${YELLOW}Не удалось определить пароль БД. Пропускаем очистку БД.${NC}"
  fi
  
  # Удаляем конфигурационные файлы Postfix
  echo -e "${YELLOW}Удаление конфигурационных файлов Postfix...${NC}"
  rm -f /etc/postfix/mysql-virtual-mailbox-domains.cf
  rm -f /etc/postfix/mysql-virtual-mailbox-maps.cf
  rm -f /etc/postfix/mysql-virtual-alias-maps.cf
  echo -e "${GREEN}Конфигурационные файлы Postfix удалены.${NC}"
  
  # Удаляем конфигурационный файл Dovecot
  echo -e "${YELLOW}Удаление конфигурационного файла Dovecot...${NC}"
  rm -f /etc/dovecot/dovecot-sql.conf.ext
  rm -f /etc/dovecot/conf.d/auth-sql.conf.ext
  echo -e "${GREEN}Конфигурационный файл Dovecot удален.${NC}"
  
  # Удаляем DKIM ключи
  echo -e "${YELLOW}Удаление DKIM ключей...${NC}"
  if [ -d "/etc/opendkim/keys" ]; then
    rm -rf /etc/opendkim/keys/*
    echo -e "${GREEN}DKIM ключи удалены.${NC}"
  fi
  
  # Очищаем opendkim.conf от записей доменов
  if [ -f "/etc/opendkim.conf" ]; then
    echo -e "${YELLOW}Очистка конфигурации OpenDKIM...${NC}"
    sed -i '/^Domain/d' /etc/opendkim.conf
    sed -i '/^KeyFile/d' /etc/opendkim.conf
    sed -i '/^Selector/d' /etc/opendkim.conf
    sed -i '/^Socket/d' /etc/opendkim.conf
    echo -e "${GREEN}Конфигурация OpenDKIM очищена.${NC}"
  fi
  
  # Удаляем endpoint'ы
  echo -e "${YELLOW}Удаление endpoint'ов для отправки писем...${NC}"
  if [ -f "$ENDPOINTS_LIST_FILE" ] && [ -s "$ENDPOINTS_LIST_FILE" ]; then
    while IFS=: read -r port api_key service_name rest; do
      if [ -n "$service_name" ]; then
        systemctl stop "${service_name}.service" 2>/dev/null || true
        systemctl disable "${service_name}.service" 2>/dev/null || true
        rm -f "/etc/systemd/system/${service_name}.service"
        rm -f "/tmp/mail_endpoint_${port}.py"
      fi
    done < "$ENDPOINTS_LIST_FILE"
    echo -e "${GREEN}Endpoint'ы удалены.${NC}"
  fi
  
  # Удаляем файлы со списками
  echo -e "${YELLOW}Удаление файлов со списками...${NC}"
  rm -f "$DOMAINS_LIST_FILE"
  rm -f "$MAILBOXES_LIST_FILE"
  rm -f "$ENDPOINTS_LIST_FILE"
  echo -e "${GREEN}Файлы со списками удалены.${NC}"
  
  # Удаляем пользователя vmail и его директорию
  echo -e "${YELLOW}Удаление пользователя vmail...${NC}"
  if id vmail >/dev/null 2>&1; then
    VMAIL_DIR=$(getent passwd vmail | cut -d: -f6)
    if [ -n "$VMAIL_DIR" ] && [ -d "$VMAIL_DIR" ]; then
      rm -rf "$VMAIL_DIR"/*
    fi
    userdel vmail 2>/dev/null || true
    groupdel vmail 2>/dev/null || true
    echo -e "${GREEN}Пользователь vmail удален.${NC}"
  fi
  
  # Перезапускаем сервисы для применения изменений
  echo -e "${YELLOW}Перезапуск сервисов...${NC}"
  systemctl restart postfix dovecot opendkim 2>/dev/null || true
  echo -e "${GREEN}Сервисы перезапущены.${NC}"
  
  echo ""
  echo -e "${GREEN}${BOLD}Очистка завершена успешно!${NC}"
  echo ""
  echo -e "${YELLOW}Нажмите Enter, чтобы вернуться в главное меню...${NC}"
  read
}

# Главное меню
show_main_menu() {
  while true; do
    clear_screen
    echo -e "${BOLD}${CYAN}==============================================${NC}"
    echo -e "${BOLD}${CYAN}        УПРАВЛЕНИЕ ПОЧТОВЫМ СЕРВЕРОМ         ${NC}"
    echo -e "${BOLD}${CYAN}==============================================${NC}"
    echo ""
    echo -e "${YELLOW}Выберите действие:${NC}"
    echo -e "${CYAN}1.${NC} Установить почтовый сервер"
    echo -e "${CYAN}2.${NC} Добавить домен/почтовый ящик"
    echo -e "${CYAN}3.${NC} Просмотреть домены и почтовые ящики"
    echo -e "${CYAN}4.${NC} Создать endpoint для отправки писем"
    echo -e "${CYAN}5.${NC} Управление endpoint для отправки писем"
    echo -e "${CYAN}6.${NC} Очистить все данные почтового сервера"
    echo -e "${CYAN}7.${NC} Завершить работу скрипта"
    echo ""
    echo -e "${YELLOW}---------------------------------------------${NC}"
    echo -n -e "${GREEN}Ваш выбор (1-7): ${NC}"
    read main_choice
    
    case $main_choice in
      1)
        if input_mail_server_config; then
          install_mail_server "$DOMAIN" "$HOSTNAME_FQDN" "$MAIL_USER" "$MAIL_PASS" "$DB_PASS"
          echo ""
          echo -e "${YELLOW}Нажмите Enter, чтобы вернуться в главное меню...${NC}"
          read
        else
          echo -e "${RED}Ошибка ввода данных!${NC}"
          sleep 2
        fi
        ;;
      2)
        add_domain_mailbox
        ;;
      3)
        view_domains_mailboxes
        ;;
      4)
        create_mail_endpoint
        ;;
      5)
        manage_mail_endpoints
        ;;
      6)
        cleanup_all
        ;;
      7)
        clear_screen
        echo -e "${GREEN}${BOLD}Завершение работы скрипта. До свидания!${NC}"
        return 0
        ;;
      *)
        echo -e "${RED}Некорректный выбор!${NC}"
        sleep 1
        ;;
    esac
  done
}

# Основная функция
main() {
  init_mail_config
  show_main_menu
}

# Запуск основной функции
main