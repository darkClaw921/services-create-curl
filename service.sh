#!/bin/bash

# Папка для хранения списка созданных сервисов
SERVICES_LIST_DIR="/var/lib/service-creator"
SERVICES_LIST_FILE="${SERVICES_LIST_DIR}/created_services.list"

# Настройки уведомлений
NOTIFICATIONS_DIR="${SERVICES_LIST_DIR}/notifications"
NOTIFICATIONS_CONFIG="${NOTIFICATIONS_DIR}/config"
NOTIFICATIONS_ENABLED="false"
TELEGRAM_TOKEN=""
TELEGRAM_CHAT_ID=""

# Цвета для красивого вывода
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Создаем директорию и файл для хранения списка сервисов, если они не существуют
init_services_list() {
  if [ ! -d "$SERVICES_LIST_DIR" ]; then
    mkdir -p "$SERVICES_LIST_DIR"
  fi
  
  if [ ! -f "$SERVICES_LIST_FILE" ]; then
    touch "$SERVICES_LIST_FILE"
  fi
  
  # Инициализация директории для настроек уведомлений
  if [ ! -d "$NOTIFICATIONS_DIR" ]; then
    mkdir -p "$NOTIFICATIONS_DIR"
  fi
  
  # Создаем файл конфигурации уведомлений, если не существует
  if [ ! -f "$NOTIFICATIONS_CONFIG" ]; then
    echo "NOTIFICATIONS_ENABLED=false" > "$NOTIFICATIONS_CONFIG"
    echo "TELEGRAM_TOKEN=6768830134:AAFK2pxRWUQXhAKITi5QvJAhSLc0azOXqeU" >> "$NOTIFICATIONS_CONFIG"
    echo "TELEGRAM_CHAT_ID=" >> "$NOTIFICATIONS_CONFIG"
  else
    # Загружаем настройки
    source "$NOTIFICATIONS_CONFIG"
  fi
}

# Функция для отправки уведомлений через Telegram
send_notification() {
  local service_name="$1"
  local status="$2"
  
  # Определяем эмодзи в зависимости от статуса
  local emoji=""
  if [[ "$status" == *"запущен"* ]]; then
    emoji="✅"
  elif [[ "$status" == *"остановлен"* ]]; then
    emoji="🛑"
  elif [[ "$status" == *"перезапущен"* ]]; then
    emoji="🔄"
  elif [[ "$status" == *"ошибка"* ]]; then
    emoji="❌"
  else
    emoji="ℹ️"
  fi
  
  # Получаем IP сервера
  local ip_address=$(hostname -I | awk '{print $1}')
  
  # Получаем текущее время
  local current_time=$(date "+%d-%m-%Y %H:%M:%S")
  
  # Формируем сообщение
  local message="${emoji} <b>Сервис:</b> ${service_name}
<b>Статус:</b> ${status}
<b>Сервер:</b> ${ip_address}
<b>Пользователь:</b> $(whoami)
<b>Время:</b> ${current_time}"
  
  # Проверяем, включены ли уведомления
  if [ "$NOTIFICATIONS_ENABLED" != "true" ]; then
    return 0
  fi
  
  # Проверяем наличие chat_id
  if [ -z "$TELEGRAM_CHAT_ID" ]; then
    return 1
  fi
  
  # Отправляем сообщение через Telegram API
  curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
    -d chat_id="${TELEGRAM_CHAT_ID}" \
    -d text="${message}" \
    -d parse_mode="HTML" > /dev/null
  
  return 0
}

# Функция для проверки sudo прав
check_sudo() {
  if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}${BOLD}Требуются права sudo. Пожалуйста, запустите скрипт с sudo.${NC}"
    exit 1
  fi
}

# Функция для проверки наличия команды
check_command() {
  local cmd="$1"
  if ! command -v "$cmd" &> /dev/null; then
    echo -e "${RED}Команда $cmd не найдена в системе.${NC}"
    return 1
  fi
  return 0
}

# Функция очистки экрана
clear_screen() {
  clear
}

# Функция для выбора режима запуска
select_runtime() {
  clear_screen
  echo -e "${BOLD}${CYAN}==============================================${NC}"
  echo -e "${BOLD}${CYAN}        ВЫБОР РЕЖИМА ЗАПУСКА СКРИПТА        ${NC}"
  echo -e "${BOLD}${CYAN}==============================================${NC}"
  echo ""
  echo -e "${YELLOW}Выберите параметр запуска:${NC}"
  echo -e "${CYAN}1.${NC} Чистый Python ${BOLD}(python3)${NC}"
  echo -e "${CYAN}2.${NC} UV менеджер ${BOLD}(uv run)${NC}"
  echo -e "${CYAN}3.${NC} Poetry ${BOLD}(poetry run python)${NC}"
  echo -e "${CYAN}4.${NC} PHP сервер ${BOLD}(php -S host:port)${NC}"
  echo -e "${CYAN}5.${NC} Shell скрипт ${BOLD}(bash/sh)${NC}"
  echo ""
  echo -e "${YELLOW}---------------------------------------------${NC}"
  echo -n -e "${GREEN}Выберите опцию (1-5): ${NC}"
  read runtime_choice
  
  if ! [[ "$runtime_choice" =~ ^[1-5]$ ]]; then
    echo -e "${RED}Некорректный выбор!${NC}"
    sleep 2
    return 1
  fi
  
  if [ "$runtime_choice" -eq 1 ]; then
    runtime_type="python"
    echo -e "${GREEN}Выбран запуск через Python${NC}"
    
    # Проверяем наличие Python
    if ! check_command "python3"; then
      echo -e "${RED}Python3 не найден в системе. Установите Python3 для использования этого режима.${NC}"
      sleep 2
      return 1
    fi
    
  elif [ "$runtime_choice" -eq 2 ]; then
    runtime_type="uv"
    echo -e "${GREEN}Выбран запуск через UV менеджер${NC}"
    
    # Проверяем наличие UV
    if ! check_command "uv"; then
      echo -e "${RED}UV менеджер не найден в системе. Установите UV для использования этого режима.${NC}"
      sleep 2
      return 1
    fi
  elif [ "$runtime_choice" -eq 4 ]; then
    runtime_type="php"
    echo -e "${GREEN}Выбран запуск через PHP сервер${NC}"
    
    # Проверяем наличие PHP
    if ! check_command "php"; then
      echo -e "${RED}PHP не найден в системе. Установите PHP для использования этого режима.${NC}"
      sleep 2
      return 1
    fi
    
    # Запрашиваем порт для запуска PHP
    echo -n -e "${GREEN}Введите хост и порт для запуска PHP (например, localhost:8000): ${NC}"
    read php_host_port
    
    # Проверяем корректность ввода
    if ! [[ "$php_host_port" =~ ^[^:]+:[0-9]+$ ]]; then
      echo -e "${RED}Некорректный формат! Требуется формат хост:порт (например, localhost:8000)${NC}"
      sleep 2
      return 1
    fi
  elif [ "$runtime_choice" -eq 5 ]; then
    runtime_type="shell"
    echo -e "${GREEN}Выбран запуск через Shell интерпретатор${NC}"
    
    # Проверяем наличие bash
    if ! check_command "bash"; then
      echo -e "${RED}Bash не найден в системе. Установите bash для использования этого режима.${NC}"
      sleep 2
      return 1
    fi
  else
    runtime_type="poetry"
    echo -e "${GREEN}Выбран запуск через Poetry${NC}"
    
    # Проверяем наличие Poetry
    if ! check_command "poetry"; then
      echo -e "${RED}Poetry не найден в системе. Установите Poetry для использования этого режима.${NC}"
      sleep 2
      return 1
    fi
    
    # Проверяем наличие pyproject.toml
    if [ ! -f "pyproject.toml" ]; then
      echo -e "${YELLOW}Предупреждение: файл pyproject.toml не найден в текущей директории.${NC}"
      echo -e "${YELLOW}Poetry может работать некорректно без файла pyproject.toml.${NC}"
      echo -n -e "${GREEN}Продолжить несмотря на это? (y/n): ${NC}"
      read continue_anyway
      if [[ "$continue_anyway" != "y" && "$continue_anyway" != "Y" ]]; then
        return 1
      fi
    fi
  fi
  
  sleep 1
  return 0
}

# Функция для выбора файла из текущей директории
select_file() {
  clear_screen
  echo -e "${BOLD}${CYAN}==============================================${NC}"
  echo -e "${BOLD}${CYAN}              ВЫБОР ФАЙЛА                    ${NC}"
  echo -e "${BOLD}${CYAN}==============================================${NC}"
  echo ""
  echo -e "${YELLOW}Доступные файлы в текущей директории:${NC}"
  echo ""
  
  # Получаем список файлов
  files=($(ls -p | grep -v /))
  
  if [ ${#files[@]} -eq 0 ]; then
    echo -e "${RED}В текущей директории нет файлов.${NC}"
    sleep 2
    return 1
  fi
  
  # Выводим список файлов с номерами
  for i in "${!files[@]}"; do
    echo -e "${CYAN}$((i+1)).${NC} ${files[$i]}"
  done
  
  echo ""
  echo -e "${YELLOW}---------------------------------------------${NC}"
  echo -n -e "${GREEN}Выберите номер файла для создания сервиса: ${NC}"
  read choice
  
  # Проверяем корректность ввода
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#files[@]} ]; then
    echo -e "${RED}Некорректный выбор!${NC}"
    sleep 2
    return 1
  fi
  
  selected_file="${files[$((choice-1))]}"
  echo -e "${GREEN}Выбран файл: ${BOLD}$selected_file${NC}"
  
  # Проверяем, что файл исполняемый, если нет - делаем его исполняемым
  if [ ! -x "$selected_file" ]; then
    echo -e "${YELLOW}Файл не является исполняемым. Делаем его исполняемым...${NC}"
    chmod +x "$selected_file"
  fi
  
  sleep 1
  return 0
}

# Функция для создания и установки systemd сервиса
create_service() {
  clear_screen
  local file="$1"
  local runtime="$2"
  local abs_path="$(pwd)/$file"
  local service_name="${file%.*}"
  local exec_command=""
  
  echo -e "${BOLD}${CYAN}==============================================${NC}"
  echo -e "${BOLD}${CYAN}           СОЗДАНИЕ СЕРВИСА                  ${NC}"
  echo -e "${BOLD}${CYAN}==============================================${NC}"
  echo ""
  
  # Определяем команду запуска в зависимости от выбранного режима
  if [ "$runtime" == "python" ]; then
    # Получаем полный путь к python3
    python_path=$(which python3)
    exec_command="$python_path $file"
  elif [ "$runtime" == "uv" ]; then
    # Получаем полный путь к uv
    uv_path=$(which uv)
    exec_command="$uv_path run $file"
  elif [ "$runtime" == "php" ]; then
    # Получаем полный путь к php
    php_path=$(which php)
    exec_command="$php_path -S $php_host_port $file"
  elif [ "$runtime" == "shell" ]; then
    # Получаем полный путь к bash
    bash_path=$(which bash)
    exec_command="$bash_path $file"
  elif [ "$runtime" == "poetry" ]; then
    # Получаем полный путь к poetry
    poetry_path=$(which poetry)
    exec_command="$poetry_path run python $file"
  fi
  
  # Запрашиваем описание сервиса
  echo -e "${YELLOW}Введите данные для сервиса:${NC}"
  echo ""
  echo -n -e "${GREEN}Введите описание сервиса: ${NC}"
  read description
  USER=$(whoami)
  
  # Создаем скрипт для отправки уведомлений
  local notification_script="${NOTIFICATIONS_DIR}/${service_name}_notify.sh"
  cat > "$notification_script" << EOF
#!/bin/bash

# Загружаем настройки уведомлений
source ${NOTIFICATIONS_CONFIG}

# Получаем IP-адрес сервера
IP_ADDRESS=\$(hostname -I | awk '{print \$1}')

# Получаем текущее время
CURRENT_TIME=\$(date "+%d-%m-%Y %H:%M:%S")

# Получаем имя пользователя
CURRENT_USER=\$(whoami)

# Определяем эмодзи в зависимости от статуса
EMOJI=""
if [[ "\$1" == *"запущен"* ]]; then
  EMOJI="✅"
elif [[ "\$1" == *"остановлен"* ]]; then
  EMOJI="🛑"
elif [[ "\$1" == *"перезапущен"* ]]; then
  EMOJI="🔄"
elif [[ "\$1" == *"ошибка"* ]]; then
  EMOJI="❌"
else
  EMOJI="ℹ️"
fi

# Отправляем уведомление в Telegram
if [ "\$NOTIFICATIONS_ENABLED" == "true" ] && [ ! -z "\$TELEGRAM_CHAT_ID" ]; then
  SERVICE_NAME="${service_name}"
  STATUS="\$1"
  
  # Создаем временный файл с логами
  LOG_FILE="/tmp/\${SERVICE_NAME}_log.txt"
  journalctl -u "${service_name}.service" -n 50 > "\$LOG_FILE"
  
  # Формируем сообщение с эмодзи, IP, пользователем и временем
  MESSAGE="\$EMOJI <b>Сервис:</b> \$SERVICE_NAME
<b>Статус:</b> \$STATUS
<b>Сервер:</b> \$IP_ADDRESS
<b>Пользователь:</b> \$CURRENT_USER
<b>Время:</b> \$CURRENT_TIME"

  # Сначала отправляем текстовое сообщение
  curl -s -X POST "https://api.telegram.org/bot\${TELEGRAM_TOKEN}/sendMessage" \\
    -d chat_id="\${TELEGRAM_CHAT_ID}" \\
    -d text="\${MESSAGE}" \\
    -d parse_mode="HTML" > /dev/null
  
  # Затем отправляем файл с логами
  curl -s -X POST "https://api.telegram.org/bot\${TELEGRAM_TOKEN}/sendDocument" \\
    -F chat_id="\${TELEGRAM_CHAT_ID}" \\
    -F document=@"\$LOG_FILE" \\
    -F caption="Логи сервиса \$SERVICE_NAME (\$CURRENT_TIME)" > /dev/null
  
  # Удаляем временный файл
  rm -f "\$LOG_FILE"
fi

exit 0
EOF

  # Делаем скрипт исполняемым
  chmod +x "$notification_script"
  
  # Создаем service файл
  cat > "/etc/systemd/system/${service_name}.service" << EOF
[Unit]
Description=${description:-"Service for $file"}
After=network.target

[Service]
Type=simple
User=${USER}
WorkingDirectory=$(pwd)
ExecStart=${exec_command}
ExecStartPost=${notification_script} "запущен"
ExecStop=${notification_script} "остановлен"
ExecReload=${notification_script} "перезапущен"
Environment=PATH=$PATH

Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

  echo ""
  echo -e "${GREEN}Сервисный файл создан: ${BOLD}/etc/systemd/system/${service_name}.service${NC}"
  echo -e "${BLUE}Команда запуска:${NC} ${exec_command}"
  
  # Добавляем запись о созданном сервисе
  echo "${service_name}.service:$(pwd):$(date '+%Y-%m-%d %H:%M:%S')" >> "$SERVICES_LIST_FILE"
  
  # Перезагружаем конфигурацию systemd
  echo -e "${YELLOW}Перезагрузка конфигурации systemd...${NC}"
  systemctl daemon-reload
  
  # Активируем автозапуск
  echo -e "${YELLOW}Активация автозапуска сервиса...${NC}"
  systemctl enable "${service_name}.service"
  
  # Спрашиваем, нужно ли запустить сервис сейчас
  echo ""
  echo -n -e "${GREEN}Хотите запустить сервис сейчас? (y/n): ${NC}"
  read start_now
  
  if [[ "$start_now" == "y" || "$start_now" == "Y" ]]; then
    echo -e "${YELLOW}Запуск сервиса...${NC}"
    systemctl start "${service_name}.service"
    sleep 1
    echo ""
    echo -e "${YELLOW}Статус сервиса:${NC}"
    systemctl status "${service_name}.service"
  fi
  
  echo ""
  echo -e "${GREEN}${BOLD}Сервис настроен для автозапуска после перезагрузки.${NC}"
}

# Функция для просмотра журнала сервиса
view_service_logs() {
  local service_name="$1"
  
  clear_screen
  echo -e "${BOLD}${CYAN}==============================================${NC}"
  echo -e "${BOLD}${CYAN}       ЖУРНАЛЫ СЕРВИСА $service_name         ${NC}"
  echo -e "${BOLD}${CYAN}==============================================${NC}"
  echo ""
  
  echo -e "${YELLOW}Последние 50 строк журнала:${NC}"
  echo -e "${YELLOW}---------------------------------------------${NC}"
  echo ""
  
  journalctl -u "$service_name" -n 50 --no-pager
  
  echo ""
  echo -e "${YELLOW}---------------------------------------------${NC}"
  echo -e "${YELLOW}Опции просмотра журнала:${NC}"
  echo -e "${CYAN}1.${NC} Просмотреть больше строк"
  echo -e "${CYAN}2.${NC} Наблюдать за журналом в реальном времени"
  echo -e "${CYAN}3.${NC} Вернуться назад"
  echo ""
  echo -n -e "${GREEN}Ваш выбор (1-3): ${NC}"
  read log_option
  
  case $log_option in
    1)
      clear_screen
      echo -e "${BOLD}${CYAN}==============================================${NC}"
      echo -e "${BOLD}${CYAN}       ПОЛНЫЙ ЖУРНАЛ СЕРВИСА $service_name   ${NC}"
      echo -e "${BOLD}${CYAN}==============================================${NC}"
      echo ""
      echo -e "${YELLOW}Полный журнал сервиса (нажмите q для выхода):${NC}"
      echo ""
      
      # Запускаем полный просмотр
      journalctl -u "$service_name" --no-pager | less
      ;;
    2)
      clear_screen
      echo -e "${BOLD}${CYAN}==============================================${NC}"
      echo -e "${BOLD}${CYAN}     МОНИТОРИНГ ЖУРНАЛА $service_name        ${NC}"
      echo -e "${BOLD}${CYAN}==============================================${NC}"
      echo ""
      echo -e "${YELLOW}Журнал в реальном времени (нажмите Ctrl+C для выхода):${NC}"
      echo ""
      
      # Запускаем мониторинг в реальном времени
      journalctl -u "$service_name" -f
      ;;
    *)
      # Возврат в предыдущее меню
      return 0
      ;;
  esac
  
  return 0
}

# Функция редактирования файла сервиса
edit_service_file() {
  local service_name="$1"
  
  clear_screen
  echo -e "${BOLD}${CYAN}==============================================${NC}"
  echo -e "${BOLD}${CYAN}     РЕДАКТИРОВАНИЕ СЕРВИСА $service_name     ${NC}"
  echo -e "${BOLD}${CYAN}==============================================${NC}"
  echo ""
  
  # Проверка наличия текстовых редакторов
  local editor=""
  # if command -v nano &> /dev/null; then
    # editor="nano"
  if command -v vim &> /dev/null; then
    editor="vim"
  elif command -v vi &> /dev/null; then
    editor="vi"
  else
    echo -e "${RED}Не найден текстовый редактор (vim или vi).${NC}"
    sleep 2
    return 1
  fi
  
  echo -e "${YELLOW}Открываем файл сервиса в редакторе $editor...${NC}"
  sleep 1
  
  $editor "/etc/systemd/system/$service_name"
  
  # Проверка статуса выхода редактора
  if [ $? -eq 0 ]; then
    echo -e "${GREEN}Файл сервиса отредактирован.${NC}"
    
    echo -e "${YELLOW}Перезагрузка конфигурации systemd...${NC}"
    systemctl daemon-reload
    
    echo -e "${GREEN}Рекомендуется перезапустить сервис для применения изменений.${NC}"
  else
    echo -e "${RED}Редактирование файла было отменено.${NC}"
  fi
  
  sleep 2
  return 0
}

# Функция управления конкретным сервисом
service_control() {
  local service_name="$1"
  local service_path="$2"
  
  while true; do
    clear_screen
    
    # Получаем текущий статус сервиса
    local status=$(systemctl is-active "$service_name")
    local enabled=$(systemctl is-enabled "$service_name" 2>/dev/null)
    
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
    
    echo -e "${BOLD}${CYAN}==============================================${NC}"
    echo -e "${BOLD}${CYAN}     УПРАВЛЕНИЕ СЕРВИСОМ: $service_name      ${NC}"
    echo -e "${BOLD}${CYAN}==============================================${NC}"
    echo ""
    echo -e "${YELLOW}Информация о сервисе:${NC}"
    echo -e "${YELLOW}---------------------------------------------${NC}"
    echo -e "${BOLD}Имя:${NC} $service_name"
    echo -e "${BOLD}Статус:${NC} $status_text"
    echo -e "${BOLD}Автозапуск:${NC} $enabled_text"
    echo -e "${BOLD}Путь:${NC} $service_path"
    echo -e "${YELLOW}---------------------------------------------${NC}"
    echo ""
    
    echo -e "${YELLOW}Выберите действие:${NC}"
    echo -e "${CYAN}1.${NC} Запустить сервис"
    echo -e "${CYAN}2.${NC} Остановить сервис"
    echo -e "${CYAN}3.${NC} Перезапустить сервис"
    echo -e "${CYAN}4.${NC} Просмотреть журнал сервиса"
    echo -e "${CYAN}5.${NC} Редактировать файл сервиса"
    echo -e "${CYAN}6.${NC} Удалить сервис"
    echo -e "${CYAN}7.${NC} Вернуться в список сервисов"
    echo ""
    echo -e "${YELLOW}---------------------------------------------${NC}"
    echo -n -e "${GREEN}Ваш выбор (1-7): ${NC}"
    read control_option
    
    case $control_option in
      1) # Запустить
        echo -e "${YELLOW}Запуск сервиса...${NC}"
        systemctl start "$service_name"
        sleep 1
        systemctl status "$service_name" --no-pager
        echo ""
        echo -e "${YELLOW}Нажмите Enter, чтобы продолжить...${NC}"
        read
        ;;
      2) # Остановить
        echo -e "${YELLOW}Остановка сервиса...${NC}"
        systemctl stop "$service_name"
        sleep 1
        systemctl status "$service_name" --no-pager
        echo ""
        echo -e "${YELLOW}Нажмите Enter, чтобы продолжить...${NC}"
        read
        ;;
      3) # Перезапустить
        echo -e "${YELLOW}Перезапуск сервиса...${NC}"
        systemctl restart "$service_name"
        sleep 1
        systemctl status "$service_name" --no-pager
        echo ""
        echo -e "${YELLOW}Нажмите Enter, чтобы продолжить...${NC}"
        read
        ;;
      4) # Просмотр журнала
        view_service_logs "$service_name"
        ;;
      5) # Редактировать
        edit_service_file "$service_name"
        ;;
      6) # Удалить
        echo -e "${RED}${BOLD}Вы уверены, что хотите удалить сервис $service_name? (y/n): ${NC}"
        read confirm_delete
        
        if [[ "$confirm_delete" == "y" || "$confirm_delete" == "Y" ]]; then
          echo -e "${YELLOW}Удаление сервиса $service_name...${NC}"
          
          # Останавливаем сервис если он запущен
          echo -e "${YELLOW}Остановка сервиса...${NC}"
          systemctl stop "$service_name" 2>/dev/null
          
          # Отключаем автозапуск
          echo -e "${YELLOW}Отключение автозапуска...${NC}"
          systemctl disable "$service_name" 2>/dev/null
          
          # Удаляем файл сервиса
          echo -e "${YELLOW}Удаление файла сервиса...${NC}"
          rm -f "/etc/systemd/system/$service_name"
          
          # Перезагружаем конфигурацию systemd
          echo -e "${YELLOW}Перезагрузка конфигурации systemd...${NC}"
          systemctl daemon-reload
          
          # Удаляем запись из списка
          local temp_file=$(mktemp)
          grep -v "^$service_name:" "$SERVICES_LIST_FILE" > "$temp_file"
          mv "$temp_file" "$SERVICES_LIST_FILE"
          
          echo -e "${GREEN}${BOLD}Сервис $service_name успешно удален.${NC}"
          sleep 2
          return 0
        else
          echo -e "${YELLOW}Удаление отменено.${NC}"
          sleep 1
        fi
        ;;
      7) # Вернуться в список сервисов
        return 0
        ;;
      *)
        echo -e "${RED}Некорректный выбор!${NC}"
        sleep 1
        ;;
    esac
  done
}

# Функция для отображения и управления созданными сервисами
manage_services() {
  while true; do
    clear_screen
    echo -e "${BOLD}${CYAN}==============================================${NC}"
    echo -e "${BOLD}${CYAN}       УПРАВЛЕНИЕ СЕРВИСАМИ                  ${NC}"
    echo -e "${BOLD}${CYAN}==============================================${NC}"
    echo ""
    
    if [ ! -s "$SERVICES_LIST_FILE" ]; then
      echo -e "${RED}Список созданных сервисов пуст.${NC}"
      sleep 2
      return 1
    fi
    
    echo -e "${YELLOW}Список сервисов, созданных этим скриптом:${NC}"
    echo -e "${YELLOW}---------------------------------------------${NC}"
    
    mapfile -t services < "$SERVICES_LIST_FILE"
    
    for i in "${!services[@]}"; do
      service_info=(${services[$i]//:/ })
      service_name="${service_info[0]}"
      service_path="${service_info[1]}"
      service_date="${service_info[2]} ${service_info[3]}"
      
      status=$(systemctl is-active "$service_name" 2>/dev/null)
      if [ "$status" == "active" ]; then
        status_text="${GREEN}активен${NC}"
      else
        status_text="${RED}неактивен${NC}"
      fi
      
      echo -e "${CYAN}$((i+1)).${NC} ${BOLD}$service_name${NC} (${status_text}) - создан: ${BLUE}$service_date${NC}"
      echo -e "   ${YELLOW}Путь:${NC} ${service_path}"
      echo -e "${YELLOW}---------------------------------------------${NC}"
    done
    
    echo ""
    echo -e "${YELLOW}Выберите действие:${NC}"
    echo -e "${CYAN}1.${NC} Выбрать сервис для управления"
    echo -e "${CYAN}2.${NC} Вернуться в главное меню"
    echo ""
    echo -e "${YELLOW}---------------------------------------------${NC}"
    echo -n -e "${GREEN}Ваш выбор (1-2): ${NC}"
    read action_choice
    
    if [ "$action_choice" -eq 1 ]; then
      echo ""
      echo -n -e "${GREEN}Введите номер сервиса для управления: ${NC}"
      read service_number
      
      if ! [[ "$service_number" =~ ^[0-9]+$ ]] || [ "$service_number" -lt 1 ] || [ "$service_number" -gt ${#services[@]} ]; then
        echo -e "${RED}Некорректный выбор!${NC}"
        sleep 2
        continue
      fi
      
      selected_service=(${services[$((service_number-1))]//:/ })
      service_name="${selected_service[0]}"
      service_path="${selected_service[1]}"
      
      service_control "$service_name" "$service_path"
    elif [ "$action_choice" -eq 2 ]; then
      return 0
    else
      echo -e "${RED}Некорректный выбор!${NC}"
      sleep 1
    fi
  done
}

# Функция для проверки портов в конфигурациях nginx
check_nginx_ports() {
  clear_screen
  echo -e "${BOLD}${CYAN}==============================================${NC}"
  echo -e "${BOLD}${CYAN}       ПРОВЕРКА ПОРТОВ NGINX                  ${NC}"
  echo -e "${BOLD}${CYAN}==============================================${NC}"
  echo ""
  
  local nginx_sites_dir="/etc/nginx/sites-available"
  
  if [ ! -d "$nginx_sites_dir" ]; then
    echo -e "${RED}Директория $nginx_sites_dir не найдена.${NC}"
    echo -e "${YELLOW}Убедитесь, что nginx установлен.${NC}"
    sleep 3
    return 1
  fi
  
  echo -e "${YELLOW}Анализ конфигураций nginx...${NC}"
  echo -e "${YELLOW}---------------------------------------------${NC}"
  echo ""
  
  local found_configs=false
  
  # Перебираем все файлы в sites-available
  for config_file in "$nginx_sites_dir"/*; do
    if [ -f "$config_file" ]; then
      found_configs=true
      local filename=$(basename "$config_file")
      
      # Извлекаем server_name
      local server_names=$(grep -E "^\s*server_name" "$config_file" | sed 's/^\s*server_name\s*//' | sed 's/;//' | tr '\n' ' ')
      
      # Извлекаем порты из listen директив
      local listen_ports=$(grep -E "^\s*listen" "$config_file" | grep -oE "[0-9]+" | sort -u | tr '\n' ' ')
      
      # Извлекаем proxy_pass если есть
      local proxy_passes=$(grep -E "^\s*proxy_pass" "$config_file" | sed 's/^\s*proxy_pass\s*//' | sed 's/;//' | tr '\n' ' ')
      
      echo -e "${CYAN}${BOLD}Файл:${NC} $filename"
      
      if [ ! -z "$server_names" ]; then
        echo -e "${YELLOW}  Домены:${NC} $server_names"
      fi
      
      if [ ! -z "$listen_ports" ]; then
        echo -e "${GREEN}  Порты:${NC} $listen_ports"
      else
        echo -e "${RED}  Порты: не найдены${NC}"
      fi
      
      if [ ! -z "$proxy_passes" ]; then
        echo -e "${BLUE}  Проксирование:${NC} $proxy_passes"
      fi
      
      # Проверяем активирован ли конфиг
      local enabled_link="/etc/nginx/sites-enabled/$(basename "$config_file")"
      if [ -L "$enabled_link" ]; then
        echo -e "${GREEN}  Статус: АКТИВИРОВАН${NC}"
      else
        echo -e "${RED}  Статус: не активирован${NC}"
      fi
      
      echo -e "${YELLOW}---------------------------------------------${NC}"
    fi
  done
  
  if [ "$found_configs" = false ]; then
    echo -e "${YELLOW}Конфигурационные файлы не найдены в $nginx_sites_dir${NC}"
  fi
  
  echo ""
  echo -e "${YELLOW}Нажмите Enter, чтобы вернуться в главное меню...${NC}"
  read
  return 0
}

# Функция для создания конфигурации nginx
create_nginx_config() {
  clear_screen
  echo -e "${BOLD}${CYAN}==============================================${NC}"
  echo -e "${BOLD}${CYAN}      СОЗДАНИЕ КОНФИГУРАЦИИ NGINX             ${NC}"
  echo -e "${BOLD}${CYAN}==============================================${NC}"
  echo ""
  
  # Проверяем наличие nginx
  if ! command -v nginx &> /dev/null; then
    echo -e "${RED}Nginx не установлен в системе.${NC}"
    echo -e "${YELLOW}Установите nginx для использования этой функции.${NC}"
    sleep 3
    return 1
  fi
  
  # Запрашиваем домен
  echo -e "${YELLOW}Введите данные для конфигурации nginx:${NC}"
  echo ""
  echo -n -e "${GREEN}Введите домен (например, example.com или subdomain.example.com): ${NC}"
  read domain
  
  # Проверяем корректность домена
  if [ -z "$domain" ]; then
    echo -e "${RED}Домен не может быть пустым!${NC}"
    sleep 2
    return 1
  fi
  
  # Запрашиваем порт
  echo -n -e "${GREEN}Введите порт для проксирования (например, 8000): ${NC}"
  read port
  
  # Проверяем корректность порта
  if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
    echo -e "${RED}Некорректный порт! Укажите число от 1 до 65535.${NC}"
    sleep 2
    return 1
  fi
  
  # Формируем имя файла конфигурации
  local config_filename="${domain}.conf"
  local config_path="/etc/nginx/sites-available/${config_filename}"
  
  # Проверяем, существует ли уже такой конфиг
  if [ -f "$config_path" ]; then
    echo -e "${YELLOW}Конфигурация для домена $domain уже существует.${NC}"
    echo -n -e "${RED}Перезаписать существующую конфигурацию? (y/n): ${NC}"
    read overwrite
    
    if [[ "$overwrite" != "y" && "$overwrite" != "Y" ]]; then
      echo -e "${YELLOW}Создание конфигурации отменено.${NC}"
      sleep 2
      return 1
    fi
  fi
  
  # Создаем конфигурационный файл
  echo ""
  echo -e "${YELLOW}Создание конфигурационного файла...${NC}"
  
  cat > "$config_path" << EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};

    location / {
        proxy_pass http://127.0.0.1:${port};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
  
  if [ $? -eq 0 ]; then
    echo -e "${GREEN}Конфигурационный файл создан: ${BOLD}$config_path${NC}"
  else
    echo -e "${RED}Ошибка при создании конфигурационного файла!${NC}"
    sleep 2
    return 1
  fi
  
  # Активируем конфигурацию через симлинк
  echo -e "${YELLOW}Активация конфигурации...${NC}"
  
  local enabled_path="/etc/nginx/sites-enabled/${config_filename}"
  
  # Удаляем старый симлинк если существует
  if [ -L "$enabled_path" ]; then
    rm -f "$enabled_path"
  fi
  
  # Создаем новый симлинк
  ln -s "$config_path" "$enabled_path"
  
  if [ $? -eq 0 ]; then
    echo -e "${GREEN}Конфигурация активирована: ${BOLD}$enabled_path${NC}"
  else
    echo -e "${RED}Ошибка при активации конфигурации!${NC}"
    sleep 2
    return 1
  fi
  
  # Проверяем конфигурацию nginx
  echo -e "${YELLOW}Проверка конфигурации nginx...${NC}"
  nginx -t
  
  if [ $? -ne 0 ]; then
    echo -e "${RED}Ошибка в конфигурации nginx! Проверьте настройки.${NC}"
    sleep 3
    return 1
  fi
  
  # Перезагружаем nginx
  echo -e "${YELLOW}Перезагрузка nginx...${NC}"
  systemctl reload nginx
  
  if [ $? -eq 0 ]; then
    echo -e "${GREEN}Nginx успешно перезагружен!${NC}"
  else
    echo -e "${RED}Ошибка при перезагрузке nginx!${NC}"
    sleep 2
    return 1
  fi
  
  echo ""
  echo -e "${GREEN}${BOLD}Конфигурация nginx успешно создана и активирована!${NC}"
  echo ""
  
  # Спрашиваем про SSL сертификат
  echo -n -e "${GREEN}Хотите выпустить SSL сертификат для домена $domain? (y/n): ${NC}"
  read issue_ssl
  
  if [[ "$issue_ssl" == "y" || "$issue_ssl" == "Y" ]]; then
    # Проверяем наличие certbot
    if ! command -v certbot &> /dev/null; then
      echo -e "${RED}Certbot не установлен в системе.${NC}"
      echo -e "${YELLOW}Установите certbot для выпуска SSL сертификатов.${NC}"
      echo -e "${YELLOW}Например: sudo apt install certbot python3-certbot-nginx${NC}"
      sleep 3
      return 0
    fi
    
    echo ""
    echo -e "${YELLOW}Выпуск SSL сертификата для домена $domain...${NC}"
    echo -e "${YELLOW}---------------------------------------------${NC}"
    echo ""
    
    # Запускаем certbot
    certbot --nginx -d "$domain"
    
    if [ $? -eq 0 ]; then
      echo ""
      echo -e "${GREEN}${BOLD}SSL сертификат успешно выпущен и настроен!${NC}"
    else
      echo ""
      echo -e "${RED}Ошибка при выпуске SSL сертификата.${NC}"
      echo -e "${YELLOW}Проверьте, что:${NC}"
      echo -e "${YELLOW}  1. Домен $domain указывает на IP этого сервера${NC}"
      echo -e "${YELLOW}  2. Порты 80 и 443 открыты в firewall${NC}"
      echo -e "${YELLOW}  3. Nginx работает корректно${NC}"
    fi
  else
    echo -e "${YELLOW}Выпуск SSL сертификата пропущен.${NC}"
    echo -e "${YELLOW}Вы можете выпустить сертификат позже командой:${NC}"
    echo -e "${CYAN}sudo certbot --nginx -d $domain${NC}"
  fi
  
  echo ""
  echo -e "${YELLOW}Нажмите Enter, чтобы вернуться в главное меню...${NC}"
  read
  return 0
}

# Функция для управления настройками уведомлений
manage_notifications() {
  while true; do
    clear_screen
    echo -e "${BOLD}${CYAN}==============================================${NC}"
    echo -e "${BOLD}${CYAN}          МЕНЕДЖЕР УВЕДОМЛЕНИЙ                ${NC}"
    echo -e "${BOLD}${CYAN}==============================================${NC}"
    echo ""
    
    # Получаем текущие настройки
    local status_text=""
    if [ "$NOTIFICATIONS_ENABLED" == "true" ]; then
      status_text="${GREEN}Включены${NC}"
    else
      status_text="${RED}Отключены${NC}"
    fi
    
    echo -e "${YELLOW}Текущие настройки уведомлений:${NC}"
    echo -e "${YELLOW}---------------------------------------------${NC}"
    echo -e "${BOLD}Статус:${NC} $status_text"
    echo -e "${BOLD}Telegram токен:${NC} ${TELEGRAM_TOKEN:0:10}...${TELEGRAM_TOKEN:(-5)}"
    echo -e "${BOLD}Telegram Chat ID:${NC} ${TELEGRAM_CHAT_ID:-'Не указан'}"
    echo -e "${YELLOW}---------------------------------------------${NC}"
    echo ""
    echo -e "${YELLOW}Выберите действие:${NC}"
    echo -e "${CYAN}1.${NC} Включить/выключить уведомления"
    echo -e "${CYAN}2.${NC} Настроить Telegram токен"
    echo -e "${CYAN}3.${NC} Настроить Telegram Chat ID"
    echo -e "${CYAN}4.${NC} Протестировать отправку уведомления"
    echo -e "${CYAN}5.${NC} Вернуться в главное меню"
    echo ""
    echo -e "${YELLOW}---------------------------------------------${NC}"
    echo -n -e "${GREEN}Ваш выбор (1-5): ${NC}"
    read notif_choice
    
    case $notif_choice in
      1) # Включить/выключить уведомления
        if [ "$NOTIFICATIONS_ENABLED" == "true" ]; then
          NOTIFICATIONS_ENABLED="false"
          echo -e "${YELLOW}Уведомления отключены.${NC}"
        else
          NOTIFICATIONS_ENABLED="true"
          echo -e "${GREEN}Уведомления включены.${NC}"
          
          # Проверяем, настроен ли Chat ID
          if [ -z "$TELEGRAM_CHAT_ID" ]; then
            echo -e "${YELLOW}Внимание: Telegram Chat ID не настроен. Уведомления не будут отправляться.${NC}"
            echo -e "${YELLOW}Настройте Telegram Chat ID для получения уведомлений.${NC}"
          fi
        fi
        
        # Сохраняем настройки
        echo "NOTIFICATIONS_ENABLED=$NOTIFICATIONS_ENABLED" > "$NOTIFICATIONS_CONFIG"
        echo "TELEGRAM_TOKEN=$TELEGRAM_TOKEN" >> "$NOTIFICATIONS_CONFIG"
        echo "TELEGRAM_CHAT_ID=$TELEGRAM_CHAT_ID" >> "$NOTIFICATIONS_CONFIG"
        
        sleep 2
        ;;
        
      2) # Настроить Telegram токен
        echo ""
        echo -n -e "${GREEN}Введите Telegram токен (текущий: ${TELEGRAM_TOKEN:0:10}...): ${NC}"
        read new_token
        
        if [ ! -z "$new_token" ]; then
          TELEGRAM_TOKEN="$new_token"
          echo -e "${GREEN}Токен успешно обновлен.${NC}"
          
          # Сохраняем настройки
          echo "NOTIFICATIONS_ENABLED=$NOTIFICATIONS_ENABLED" > "$NOTIFICATIONS_CONFIG"
          echo "TELEGRAM_TOKEN=$TELEGRAM_TOKEN" >> "$NOTIFICATIONS_CONFIG"
          echo "TELEGRAM_CHAT_ID=$TELEGRAM_CHAT_ID" >> "$NOTIFICATIONS_CONFIG"
        fi
        
        sleep 2
        ;;
        
      3) # Настроить Telegram Chat ID
        echo ""
        echo -e "${YELLOW}Для получения Chat ID:${NC}"
        echo -e "1. Добавьте бота @userinfobot в Telegram"
        echo -e "2. Отправьте боту сообщение /start"
        echo -e "3. Скопируйте полученный ID и вставьте его ниже"
        echo ""
        echo -n -e "${GREEN}Введите Telegram Chat ID: ${NC}"
        read new_chat_id
        
        if [ ! -z "$new_chat_id" ]; then
          TELEGRAM_CHAT_ID="$new_chat_id"
          echo -e "${GREEN}Chat ID успешно обновлен.${NC}"
          
          # Сохраняем настройки
          echo "NOTIFICATIONS_ENABLED=$NOTIFICATIONS_ENABLED" > "$NOTIFICATIONS_CONFIG"
          echo "TELEGRAM_TOKEN=$TELEGRAM_TOKEN" >> "$NOTIFICATIONS_CONFIG"
          echo "TELEGRAM_CHAT_ID=$TELEGRAM_CHAT_ID" >> "$NOTIFICATIONS_CONFIG"
        fi
        
        sleep 2
        ;;
        
      4) # Протестировать отправку уведомления
        if [ "$NOTIFICATIONS_ENABLED" != "true" ]; then
          echo -e "${YELLOW}Уведомления отключены. Включите уведомления для отправки тестового сообщения.${NC}"
          sleep 2
          continue
        fi
        
        if [ -z "$TELEGRAM_CHAT_ID" ]; then
          echo -e "${RED}Ошибка: Telegram Chat ID не настроен.${NC}"
          sleep 2
          continue
        fi
        
        echo -e "${YELLOW}Отправка тестового уведомления...${NC}"
        if send_notification "Test" "Тестовое уведомление"; then
          echo -e "${GREEN}Тестовое уведомление успешно отправлено!${NC}"
        else
          echo -e "${RED}Ошибка при отправке тестового уведомления.${NC}"
        fi
        
        sleep 2
        ;;
        
      5) # Вернуться в главное меню
        return 0
        ;;
        
      *)
        echo -e "${RED}Некорректный выбор!${NC}"
        sleep 1
        ;;
    esac
  done
}

# Функция для отображения главного меню
show_main_menu() {
  while true; do
    clear_screen
    echo -e "${BOLD}${CYAN}==============================================${NC}"
    echo -e "${BOLD}${CYAN}            УПРАВЛЕНИЕ СЕРВИСАМИ              ${NC}"
    echo -e "${BOLD}${CYAN}==============================================${NC}"
    echo ""
    echo -e "${YELLOW}Выберите действие:${NC}"
    echo -e "${CYAN}1.${NC} Создать новый сервис"
    echo -e "${CYAN}2.${NC} Просмотреть и управлять существующими сервисами"
    echo -e "${CYAN}3.${NC} Менеджер уведомлений"
    echo -e "${CYAN}4.${NC} Проверить порты nginx конфигураций"
    echo -e "${CYAN}5.${NC} Создать конфигурацию nginx"
    echo -e "${CYAN}6.${NC} Завершить работу скрипта"
    echo ""
    echo -e "${YELLOW}---------------------------------------------${NC}"
    echo -n -e "${GREEN}Ваш выбор (1-6): ${NC}"
    read main_choice
    
    case $main_choice in
      1)
        if select_runtime; then
          if select_file; then
            create_service "$selected_file" "$runtime_type"
          fi
        fi
        ;;
      2)
        manage_services
        ;;
      3)
        manage_notifications
        ;;
      4)
        check_nginx_ports
        ;;
      5)
        create_nginx_config
        ;;
      6)
        clear_screen
        echo -e "${GREEN}${BOLD}Завершение работы скрипта. До свидания!${NC}"
        return 0
        ;;
      *)
        echo -e "${RED}Некорректный выбор!${NC}"
        sleep 1
        ;;
    esac
    
    # Пауза перед возвратом в главное меню
    if [ "$main_choice" != "6" ]; then
      echo ""
      echo -e "${YELLOW}Нажмите Enter, чтобы вернуться в главное меню...${NC}"
      read
    fi
  done
}

# Основная функция
main() {
  check_sudo
  init_services_list
  show_main_menu
}


# Запуск основной функции
main