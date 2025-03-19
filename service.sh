#!/bin/bash

# Папка для хранения списка созданных сервисов
SERVICES_LIST_DIR="/var/lib/service-creator"
SERVICES_LIST_FILE="${SERVICES_LIST_DIR}/created_services.list"

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
  echo ""
  echo -e "${YELLOW}---------------------------------------------${NC}"
  echo -n -e "${GREEN}Выберите опцию (1-2): ${NC}"
  read runtime_choice
  
  if ! [[ "$runtime_choice" =~ ^[1-2]$ ]]; then
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
    
  else
    runtime_type="uv"
    echo -e "${GREEN}Выбран запуск через UV менеджер${NC}"
    
    # Проверяем наличие UV
    if ! check_command "uv"; then
      echo -e "${RED}UV менеджер не найден в системе. Установите UV для использования этого режима.${NC}"
      sleep 2
      return 1
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
  else
    # Получаем полный путь к uv
    uv_path=$(which uv)
    exec_command="$uv_path run $file"
  fi
  
  # Запрашиваем описание сервиса
  echo -e "${YELLOW}Введите данные для сервиса:${NC}"
  echo ""
  echo -n -e "${GREEN}Введите описание сервиса: ${NC}"
  read description
  USER=$(whoami)
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
    echo -e "${CYAN}3.${NC} Завершить работу скрипта"
    echo ""
    echo -e "${YELLOW}---------------------------------------------${NC}"
    echo -n -e "${GREEN}Ваш выбор (1-3): ${NC}"
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
    if [ "$main_choice" != "3" ]; then
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