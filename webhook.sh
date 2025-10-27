#!/bin/bash

# Конфигурационные директории и файлы
WEBHOOK_DIR="/var/lib/webhook-automation"
CONFIG_FILE="${WEBHOOK_DIR}/config"
AUTOMATIONS_FILE="${WEBHOOK_DIR}/automations.list"
LOGS_DIR="${WEBHOOK_DIR}/logs"
WEBHOOK_LOG="${LOGS_DIR}/webhook.log"
SERVICES_LIST_FILE="/var/lib/service-creator/created_services.list"

# Webhook сервер настройки
WEBHOOK_PORT=9000
WEBHOOK_SECRET=""

# Цвета для красивого вывода
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Инициализация директорий и конфигурации
init_webhook_system() {
  if [ ! -d "$WEBHOOK_DIR" ]; then
    mkdir -p "$WEBHOOK_DIR"
  fi
  
  if [ ! -d "$LOGS_DIR" ]; then
    mkdir -p "$LOGS_DIR"
  fi
  
  if [ ! -f "$CONFIG_FILE" ]; then
    cat > "$CONFIG_FILE" << EOF
WEBHOOK_PORT=9000
WEBHOOK_SECRET=""
NOTIFICATIONS_ENABLED=false
TELEGRAM_TOKEN=""
TELEGRAM_CHAT_ID=""
DEFAULT_BRANCH=master
EOF
  fi
  
  if [ ! -f "$AUTOMATIONS_FILE" ]; then
    touch "$AUTOMATIONS_FILE"
  fi
  
  if [ ! -f "$WEBHOOK_LOG" ]; then
    touch "$WEBHOOK_LOG"
  fi
  
  # Проверяем и исправляем формат данных автоматизаций
  fix_automations_format
  
  # Загружаем конфигурацию
  source "$CONFIG_FILE"
}

# Исправление формата данных автоматизаций (миграция с : на |)
fix_automations_format() {
  if [ -f "$AUTOMATIONS_FILE" ] && [ -s "$AUTOMATIONS_FILE" ]; then
    # Проверяем, есть ли строки со старым форматом (разделители : вместо |)
    # Старый формат: ID:name:url:path:branch:commands:date
    # Новый формат: ID|name|url|path|branch|commands|date|private|encrypted_creds
    
    local needs_migration=false
    local temp_file=$(mktemp)
    local migrated_count=0
    
    while IFS= read -r line; do
      # Пропускаем пустые строки
      if [ -z "$line" ]; then
        continue
      fi
      
      # Если строка содержит | - это уже новый формат
      if [[ "$line" == *"|"* ]]; then
        echo "$line" >> "$temp_file"
        continue
      fi
      
      # Если строка содержит только : разделители - это старый формат
      if [[ "$line" == *":"* ]] && [[ "$line" != *"|"* ]]; then
        needs_migration=true
        
        # Попытка миграции старого формата
        # Проблема: URL типа https://github.com содержит :
        # Разбираем более аккуратно
        
        local id=""
        local name=""
        local url=""
        local path=""
        local branch=""
        local commands=""
        local date=""
        
        # Извлекаем ID (первое число)
        id=$(echo "$line" | sed 's|^\([0-9]*\):.*|\1|')
        
        # Удаляем ID и : из начала
        local rest=$(echo "$line" | sed "s|^$id:||")
        
        # Если не удалось разобрать, пропускаем эту строку
        if [ -z "$id" ] || [ -z "$rest" ]; then
          echo -e "${RED}❌ Не удалось разобрать запись: $line${NC}"
          continue
        fi
        
        # Для старых записей добавляем новые поля как пустые
        # Конвертируем в новый формат с | разделителями
        local converted_line=$(echo "$rest" | sed 's|:||\|g')
        echo "${id}|${converted_line}||" >> "$temp_file"
        ((migrated_count++))
      else
        # Строка в неизвестном формате, сохраняем как есть
        echo "$line" >> "$temp_file"
      fi
    done < "$AUTOMATIONS_FILE"
    
    if [ "$needs_migration" = true ]; then
      echo -e "${YELLOW}🔧 Выполнена миграция данных автоматизаций (: → |)${NC}"
      mv "$temp_file" "$AUTOMATIONS_FILE"
      
      if [ "$migrated_count" -gt 0 ]; then
        echo -e "${GREEN}✅ Мигрировано $migrated_count записей.${NC}"
      fi
    else
      # Если миграция не нужна, удаляем временный файл
      rm -f "$temp_file"
    fi
  fi
}

# Логирование событий
log_event() {
  local event_type="$1"
  local message="$2"
  local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
  local ip_address=$(hostname -I | awk '{print $1}')
  
  echo "[$timestamp] [$event_type] [IP: $ip_address] $message" >> "$WEBHOOK_LOG"
  
  # Отправляем уведомление если включено
  if [ "$NOTIFICATIONS_ENABLED" == "true" ] && [ ! -z "$TELEGRAM_CHAT_ID" ]; then
    send_notification "$event_type" "$message"
  fi
}

# Отправка уведомлений через Telegram
send_notification() {
  local event_type="$1"
  local message="$2"
  
  local emoji="🔄"
  case "$event_type" in
    "SUCCESS") emoji="✅" ;;
    "ERROR") emoji="❌" ;;
    "WARNING") emoji="⚠️" ;;
    "INFO") emoji="ℹ️" ;;
  esac
  
  local ip_address=$(hostname -I | awk '{print $1}')
  local current_time=$(date "+%d-%m-%Y %H:%M:%S")
  
  local telegram_message="${emoji} <b>Webhook Automation</b>
<b>Тип:</b> ${event_type}
<b>Сообщение:</b> ${message}
<b>Сервер:</b> ${ip_address}
<b>Время:</b> ${current_time}"
  
  if [ ! -z "$TELEGRAM_TOKEN" ] && [ ! -z "$TELEGRAM_CHAT_ID" ]; then
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
      -d chat_id="${TELEGRAM_CHAT_ID}" \
      -d text="${telegram_message}" \
      -d parse_mode="HTML" > /dev/null
  fi
}

# Проверка sudo прав
check_sudo() {
  if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}${BOLD}Требуются права sudo для управления системными сервисами.${NC}"
    echo -e "${YELLOW}Попытка получить права sudo...${NC}"
    
    # Проверяем, можем ли получить sudo права
    if sudo -n true 2>/dev/null; then
      echo -e "${GREEN}Права sudo доступны.${NC}"
    else
      echo -e "${YELLOW}Запрашиваем права sudo...${NC}"
      if ! sudo true; then
        echo -e "${RED}Не удалось получить права sudo. Некоторые функции могут быть недоступны.${NC}"
        echo -e "${YELLOW}Продолжаем работу с ограниченными правами...${NC}"
        sleep 2
        return 1
      fi
    fi
    
    # Перезапускаем скрипт с sudo если нужно
    if [[ "${SKIP_SUDO_RESTART:-}" != "true" ]]; then
      echo -e "${GREEN}Перезапуск с правами sudo...${NC}"
      export SKIP_SUDO_RESTART=true
      exec sudo -E "$WEBHOOK_SCRIPT_PATH" "$@"
    fi
  fi
  
  return 0
}

# Очистка экрана
clear_screen() {
  clear
}

# Получение списка созданных сервисов из service.sh
get_services_list() {
  local services=()
  
  if [ -f "$SERVICES_LIST_FILE" ]; then
    while IFS= read -r line; do
      service_info=(${line//:/ })
      service_name="${service_info[0]}"
      service_path="${service_info[1]}"
      services+=("$service_name:$service_path")
    done < "$SERVICES_LIST_FILE"
  fi
  
  echo "${services[@]}"
}

# Автоматическое определение Git репозитория из текущей директории
detect_git_repo() {
  local current_dir="$1"
  local repo_url=""
  local repo_name=""
  
  if [ -d "$current_dir/.git" ]; then
    # Получаем remote URL
    repo_url=$(cd "$current_dir" && git remote get-url origin 2>/dev/null)
    
    if [ ! -z "$repo_url" ]; then
      # Очищаем URL от возможных учетных данных (включая мусорные символы)
      # Извлекаем домен и путь из URL
      if [[ "$repo_url" =~ github\.com[/:]([^/]+)/([^/]+)(\.git)?$ ]]; then
        local user="${BASH_REMATCH[1]}"
        local repo="${BASH_REMATCH[2]%%.git}"
        clean_url="https://github.com/$user/$repo.git"
      elif [[ "$repo_url" =~ gitlab\.com[/:]([^/]+)/([^/]+)(\.git)?$ ]]; then
        local user="${BASH_REMATCH[1]}"
        local repo="${BASH_REMATCH[2]%%.git}"
        clean_url="https://gitlab.com/$user/$repo.git"
      else
        # Общая очистка для других случаев
        clean_url=$(echo "$repo_url" | sed -E 's|https://[^@]*@([^@]*@)?|https://|g' | tr -cd '[:print:]')
      fi
      
      # Сбрасываем git remote к чистому URL, если он отличается
      if [ "$repo_url" != "$clean_url" ]; then
        reset_git_remote_url "$current_dir" "$clean_url"
      fi
      
      # Извлекаем название репозитория
      repo_name=$(basename "$clean_url" .git)
      echo "$clean_url|$repo_name|$current_dir"
      return 0
    fi
  fi
  
  return 1
}

# Сброс Git remote URL к чистому виду (без учетных данных)
reset_git_remote_url() {
  local repo_path="$1"
  local clean_url="$2"
  
  if [ -d "$repo_path/.git" ] && [ ! -z "$clean_url" ]; then
    log_event "DEBUG" "Сброс git remote URL в директории $repo_path к $clean_url"
    cd "$repo_path" && git remote set-url origin "$clean_url" 2>/dev/null
  fi
}

# Тестирование процесса шифрования/расшифровки
test_encryption_decryption() {
  local test_data="$1"
  
  echo "=== ТЕСТ ШИФРОВАНИЯ/РАСШИФРОВКИ ==="
  echo "Исходные данные: '$test_data'"
  echo "Длина исходных данных: $(echo "$test_data" | wc -c) символов"
  
  # Шифрование (как в создании автоматизации)
  local encrypted=$(echo "$test_data" | base64 | tr 'A-Za-z' 'N-ZA-Mn-za-m')
  echo "Зашифрованные данные: '$encrypted'"
  echo "Длина зашифрованных данных: $(echo "$encrypted" | wc -c) символов"
  
  # Расшифровка (как в выполнении автоматизации)
  local decrypted=$(echo "$encrypted" | tr 'A-Za-z' 'N-ZA-Mn-za-m' | base64 -d 2>/dev/null)
  echo "Расшифрованные данные: '$decrypted'"
  echo "Длина расшифрованных данных: $(echo "$decrypted" | wc -c) символов"
  
  # Проверка совпадения
  if [ "$test_data" = "$decrypted" ]; then
    echo "✅ УСПЕХ: Данные совпадают"
  else
    echo "❌ ОШИБКА: Данные НЕ совпадают"
    echo "Различия:"
    echo "  Исходные:       '$test_data'"
    echo "  Расшифрованные: '$decrypted'"
  fi
  echo "=== КОНЕЦ ТЕСТА ==="
}

# Диагностика автоматизации
diagnose_automation() {
  local automation_id="$1"
  
  echo -e "${BOLD}${CYAN}==============================================${NC}"
  echo -e "${BOLD}${CYAN}         ДИАГНОСТИКА АВТОМАТИЗАЦИИ          ${NC}"
  echo -e "${BOLD}${CYAN}==============================================${NC}"
  echo ""
  
  # Ищем автоматизацию в файле
  local found=false
  while IFS='|' read -r id name repo path branch commands date is_private encrypted_creds; do
    if [ "$id" = "$automation_id" ]; then
      found=true
      
      echo -e "${YELLOW}Информация об автоматизации:${NC}"
      echo -e "  ID: $id"
      echo -e "  Название: $name"
      echo -e "  Репозиторий: $repo"
      echo -e "  Путь: $path"
      echo -e "  Ветка: $branch"
      echo -e "  Приватный: $is_private"
      echo -e "  Дата создания: $date"
      echo ""
      
      echo -e "${YELLOW}Команды:${NC}"
      echo -e "  $commands"
      echo ""
      
      if [ "$is_private" = "yes" ] && [ ! -z "$encrypted_creds" ]; then
        echo -e "${YELLOW}Тестирование расшифровки учетных данных:${NC}"
        echo ""
        
        echo -e "${YELLOW}Расшифровка сохраненных данных:${NC}"
        echo -e "  Зашифрованные данные: $encrypted_creds"
        
        # Попробуем оба метода расшифровки
        local method1=$(echo "$encrypted_creds" | tr 'A-Za-z' 'N-ZA-Mn-za-m' | base64 -d 2>/dev/null)
        local method2=$(echo "$encrypted_creds" | base64 -d 2>/dev/null | tr 'A-Za-z' 'N-ZA-Mn-za-m' 2>/dev/null)
        
        echo -e "  Метод 1 (ROT13 + base64): '$method1'"
        echo -e "  Метод 2 (base64 + ROT13): '$method2'"
        
        # Проверяем, какой метод дает правильный результат
        if [[ "$method1" == *"darkClaw921:ghp_"* ]]; then
          echo -e "  ✅ Метод 1 работает корректно"
        elif [[ "$method2" == *"darkClaw921:ghp_"* ]]; then
          echo -e "  ✅ Метод 2 работает корректно"
        else
          echo -e "  ❌ Оба метода дают некорректный результат"
        fi
      else
        echo -e "${YELLOW}Автоматизация использует публичный репозиторий${NC}"
      fi
      
      echo ""
      echo -e "${YELLOW}Проверка доступности репозитория:${NC}"
      if [ -d "$path" ]; then
        echo -e "  ✅ Директория проекта существует: $path"
        if [ -d "$path/.git" ]; then
          echo -e "  ✅ Git репозиторий найден"
          local current_url=$(cd "$path" && git remote get-url origin 2>/dev/null)
          echo -e "  Текущий remote URL: $current_url"
        else
          echo -e "  ❌ Git репозиторий не найден в директории"
        fi
      else
        echo -e "  ❌ Директория проекта не существует: $path"
      fi
      
      break
    fi
  done < "$AUTOMATIONS_FILE"
  
  if [ "$found" = false ]; then
    echo -e "${RED}Автоматизация с ID $automation_id не найдена${NC}"
  fi
  
  echo ""
  echo -n -e "${GREEN}Нажмите Enter для продолжения...${NC}"
  read
}

# Восстановление поврежденных учетных данных автоматизации
repair_automation_credentials() {
  local automation_id="$1"
  
  echo -e "${BOLD}${CYAN}==============================================${NC}"
  echo -e "${BOLD}${CYAN}      ВОССТАНОВЛЕНИЕ УЧЕТНЫХ ДАННЫХ         ${NC}"
  echo -e "${BOLD}${CYAN}==============================================${NC}"
  echo ""
  
  echo -e "${YELLOW}Введите корректные учетные данные для GitHub:${NC}"
  echo -n -e "${GREEN}Username: ${NC}"
  read username
  
  echo -n -e "${GREEN}Personal Access Token: ${NC}"
  read -s token
  echo ""
  
  if [ -z "$username" ] || [ -z "$token" ]; then
    echo -e "${RED}Учетные данные не могут быть пустыми!${NC}"
    return 1
  fi
  
  # Формируем правильные учетные данные
  local git_credentials="$username:$token"
  
  # Шифруем данные правильно
  local encrypted_credentials=$(echo "$git_credentials" | base64 | tr 'A-Za-z' 'N-ZA-Mn-za-m')
  
  echo ""
  echo -e "${CYAN}Тестируем шифрование/расшифровку...${NC}"
  test_encryption_decryption "$git_credentials"
  
  echo ""
  echo -e "${YELLOW}Обновляем автоматизацию...${NC}"
  
  # Создаем временный файл для новых данных
  local temp_file=$(mktemp)
  local updated=false
  
  while IFS='|' read -r id name repo path branch commands date is_private old_encrypted_creds; do
    if [ "$id" = "$automation_id" ]; then
      # Заменяем учетные данные на новые
      echo "$id|$name|$repo|$path|$branch|$commands|$date|yes|$encrypted_credentials" >> "$temp_file"
      updated=true
      log_event "INFO" "Обновлены учетные данные для автоматизации '$name' (ID: $id)"
    else
      # Копируем остальные строки как есть
      echo "$id|$name|$repo|$path|$branch|$commands|$date|$is_private|$old_encrypted_creds" >> "$temp_file"
    fi
  done < "$AUTOMATIONS_FILE"
  
  if [ "$updated" = true ]; then
    mv "$temp_file" "$AUTOMATIONS_FILE"
    echo -e "${GREEN}✅ Учетные данные успешно обновлены!${NC}"
  else
    rm -f "$temp_file"
    echo -e "${RED}❌ Автоматизация с ID $automation_id не найдена${NC}"
  fi
  
  echo ""
  echo -n -e "${GREEN}Нажмите Enter для продолжения...${NC}"
  read
}

# Исправление поврежденных URL в автоматизациях
repair_automation_urls() {
  echo -e "${BOLD}${CYAN}==============================================${NC}"
  echo -e "${BOLD}${CYAN}       ИСПРАВЛЕНИЕ URL АВТОМАТИЗАЦИЙ        ${NC}"
  echo -e "${BOLD}${CYAN}==============================================${NC}"
  echo ""
  
  # Создаем резервную копию
  cp "$AUTOMATIONS_FILE" "${AUTOMATIONS_FILE}.backup.$(date +%s)"
  echo -e "${YELLOW}Создана резервная копия: ${AUTOMATIONS_FILE}.backup.$(date +%s)${NC}"
  
  # Создаем временный файл для исправленных данных
  local temp_file=$(mktemp)
  local fixed_count=0
  
  while IFS='|' read -r id name repo path branch commands date is_private encrypted_creds; do
    # Исправляем дублированный URL в поле repo
    local fixed_repo=$(echo "$repo" | sed -E 's|/KUZKO-LTD/tg-manager\.git||g')
    
    # Исправляем дублированный URL в командах
    local fixed_commands=$(echo "$commands" | sed -E 's|https://[^@[:space:]'"'"'"]+@github\.com/KUZKO-LTD/tg-manager\.git/KUZKO-LTD/tg-manager\.git|https://github.com/KUZKO-LTD/tg-manager.git|g')
    fixed_commands=$(echo "$fixed_commands" | sed -E 's|/KUZKO-LTD/tg-manager\.git||g')
    
    if [ "$repo" != "$fixed_repo" ] || [ "$commands" != "$fixed_commands" ]; then
      ((fixed_count++))
      echo -e "${GREEN}Исправлена автоматизация: $name${NC}"
      log_event "INFO" "Исправлен URL для автоматизации '$name' (ID: $id)"
    fi
    
    # Записываем исправленную строку
    echo "$id|$name|$fixed_repo|$path|$branch|$fixed_commands|$date|$is_private|$encrypted_creds" >> "$temp_file"
    
  done < "$AUTOMATIONS_FILE"
  
  if [ "$fixed_count" -gt 0 ]; then
    mv "$temp_file" "$AUTOMATIONS_FILE"
    echo -e "${GREEN}✅ Исправлено $fixed_count автоматизаций!${NC}"
  else
    rm -f "$temp_file"
    echo -e "${YELLOW}Исправления не требуются.${NC}"
  fi
  
  echo ""
  echo -n -e "${GREEN}Нажмите Enter для продолжения...${NC}"
  read
}

# Получение текущей ветки Git
get_current_branch() {
  local dir="$1"
  if [ -d "$dir/.git" ]; then
    cd "$dir" && git branch --show-current 2>/dev/null
  fi
}

# Поиск Git репозиториев в проектах сервисов
find_git_repos() {
  local repos=()
  
  # Проверяем текущую директорию
  if git_info=$(detect_git_repo "$(pwd)"); then
    repos+=("$git_info")
  fi
  
  # Проверяем директории сервисов
  if [ -f "$SERVICES_LIST_FILE" ]; then
    while IFS= read -r line; do
      service_info=(${line//:/ })
      service_path="${service_info[1]}"
      
      if [ -d "$service_path" ]; then
        if git_info=$(detect_git_repo "$service_path"); then
          # Проверяем, что не дублируем
          local already_exists=false
          for existing_repo in "${repos[@]}"; do
            if [[ "$existing_repo" == "$git_info" ]]; then
              already_exists=true
              break
            fi
          done
          
          if [ "$already_exists" = false ]; then
            repos+=("$git_info")
          fi
        fi
      fi
    done < "$SERVICES_LIST_FILE"
  fi
  
  echo "${repos[@]}"
}

# Генерация предложений для названия автоматизации
suggest_automation_name() {
  local repo_name="$1"
  local branch="$2"
  local service_name="$3"
  
  if [ ! -z "$service_name" ]; then
    echo "Deploy $service_name on $branch push"
  else
    echo "Auto-deploy $repo_name from $branch"
  fi
}

# Создание новой автоматизации
create_automation() {
  clear_screen
  echo -e "${BOLD}${CYAN}==============================================${NC}"
  echo -e "${BOLD}${CYAN}         СОЗДАНИЕ АВТОМАТИЗАЦИИ              ${NC}"
  echo -e "${BOLD}${CYAN}==============================================${NC}"
  echo ""
  
  # Поиск Git репозиториев
  repos=($(find_git_repos))
  
  local repo_url=""
  local project_path=""
  local repo_name=""
  local current_branch=""
  
  if [ ${#repos[@]} -gt 0 ]; then
    echo -e "${YELLOW}🔍 Найдены Git репозитории:${NC}"
    echo -e "${YELLOW}---------------------------------------------${NC}"
    
    for i in "${!repos[@]}"; do
      repo_info=(${repos[$i]//|/ })
      local url="${repo_info[0]}"
      local name="${repo_info[1]}"
      local path="${repo_info[2]}"
      local branch=$(get_current_branch "$path")
      
      echo -e "${CYAN}$((i+1)).${NC} ${BOLD}$name${NC} (ветка: ${GREEN}$branch${NC})"
      echo -e "   ${YELLOW}URL:${NC} $url"
      echo -e "   ${YELLOW}Путь:${NC} $path"
      echo -e "${YELLOW}---------------------------------------------${NC}"
    done
    
    echo -e "${CYAN}$((${#repos[@]}+1)).${NC} Ввести данные вручную"
    echo ""
    echo -e "${GREEN}💡 Рекомендация:${NC} Выберите существующий репозиторий для автоматической настройки"
    echo -n -e "${GREEN}Ваш выбор (1-$((${#repos[@]}+1))): ${NC}"
    read repo_choice
    
    if [[ "$repo_choice" =~ ^[0-9]+$ ]] && [ "$repo_choice" -ge 1 ] && [ "$repo_choice" -le ${#repos[@]} ]; then
      # Используем выбранный репозиторий
      repo_info=(${repos[$((repo_choice-1))]//|/ })
      repo_url="${repo_info[0]}"
      repo_name="${repo_info[1]}"
      project_path="${repo_info[2]}"
      current_branch=$(get_current_branch "$project_path")
      
      echo ""
      echo -e "${GREEN}✅ Выбран репозиторий:${NC} ${BOLD}$repo_name${NC}"
      echo -e "${GREEN}📁 Путь проекта:${NC} $project_path"
      echo -e "${GREEN}🌿 Текущая ветка:${NC} $current_branch"
    fi
  fi
  
  # Если не выбран автоматически, запрашиваем вручную
  if [ -z "$repo_url" ]; then
    echo ""
    echo -e "${YELLOW}📋 Ручной ввод данных репозитория:${NC}"
    echo -e "${YELLOW}---------------------------------------------${NC}"
    
    echo -e "${BLUE}Примеры URL репозитория:${NC}"
    echo -e "  • https://github.com/username/project.git"
    echo -e "  • git@github.com:username/project.git"
    echo -e "  • https://gitlab.com/username/project.git"
    echo ""
    echo -n -e "${GREEN}Введите URL Git репозитория: ${NC}"
    read repo_url
    
    if [ -z "$repo_url" ]; then
      echo -e "${RED}❌ URL репозитория не может быть пустым!${NC}"
      sleep 2
      return 1
    fi
    
    # Извлекаем название репозитория
    repo_name=$(basename "$repo_url" .git)
    
    echo ""
    echo -e "${BLUE}Примеры путей к проекту:${NC}"
    echo -e "  • /var/www/$repo_name"
    echo -e "  • /home/user/projects/$repo_name"
    echo -e "  • $(pwd)/$repo_name"
    echo ""
    echo -n -e "${GREEN}Введите путь к проекту на сервере [$(pwd)/$repo_name]: ${NC}"
    read input_path
    
    if [ -z "$input_path" ]; then
      project_path="$(pwd)/$repo_name"
    else
      project_path="$input_path"
    fi
    
    # Проверяем текущую ветку если директория существует
    if [ -d "$project_path" ]; then
      current_branch=$(get_current_branch "$project_path")
    fi
  fi
  
  # Выбор ветки с умными значениями по умолчанию
  echo ""
  echo -e "${YELLOW}🌿 Настройка целевой ветки:${NC}"
  echo -e "${YELLOW}---------------------------------------------${NC}"
  
  if [ ! -z "$current_branch" ]; then
    echo -e "${BLUE}Обнаружена текущая ветка:${NC} ${GREEN}$current_branch${NC}"
    echo -e "${BLUE}Популярные ветки:${NC} main, master, develop, staging"
    echo ""
    echo -n -e "${GREEN}Ветка для отслеживания [${current_branch}]: ${NC}"
    read target_branch
    
    if [ -z "$target_branch" ]; then
      target_branch="$current_branch"
    fi
  else
    echo -e "${BLUE}Популярные ветки:${NC} main, master, develop, staging"
    echo ""
    echo -n -e "${GREEN}Введите ветку для отслеживания [main]: ${NC}"
    read target_branch
    
    if [ -z "$target_branch" ]; then
      target_branch="main"
    fi
  fi
  
  # Поиск подходящих сервисов для проекта
  services=($(get_services_list))
  matching_services=()
  
  if [ ${#services[@]} -gt 0 ]; then
    for service in "${services[@]}"; do
      service_info=(${service//:/ })
      service_path="${service_info[1]}"
      
      # Проверяем, если путь сервиса совпадает с проектом
      if [[ "$service_path" == "$project_path"* ]] || [[ "$project_path" == "$service_path"* ]]; then
        matching_services+=("$service")
      fi
    done
  fi
  
  # Генерируем предложение для названия
  local suggested_service=""
  if [ ${#matching_services[@]} -gt 0 ]; then
    service_info=(${matching_services[0]//:/ })
    suggested_service="${service_info[0]}"
  fi
  
  local suggested_name=$(suggest_automation_name "$repo_name" "$target_branch" "$suggested_service")
  
  echo ""
  echo -e "${YELLOW}📝 Название автоматизации:${NC}"
  echo -e "${YELLOW}---------------------------------------------${NC}"
  echo -e "${BLUE}Предложение:${NC} $suggested_name"
  echo ""
  echo -n -e "${GREEN}Введите название [$suggested_name]: ${NC}"
  read automation_name
  
  if [ -z "$automation_name" ]; then
    automation_name="$suggested_name"
  fi
  
  # Проверяем тип репозитория и настраиваем аутентификацию
  echo ""
  echo -e "${YELLOW}🔐 Настройка доступа к репозиторию:${NC}"
  echo -e "${YELLOW}---------------------------------------------${NC}"
  
  local git_credentials=""
  local is_private=""
  
  echo -e "${BLUE}Тип репозитория:${NC}"
  echo -e "${CYAN}1.${NC} Публичный репозиторий (без аутентификации)"
  echo -e "${CYAN}2.${NC} Приватный репозиторий (требуется логин/пароль или токен)"
  echo ""
  echo -n -e "${GREEN}Ваш выбор (1-2) [1]: ${NC}"
  read repo_type
  
  if [ "$repo_type" = "2" ]; then
    is_private="yes"
    echo ""
    echo -e "${YELLOW}Настройка аутентификации для приватного репозитория:${NC}"
    echo -e "${YELLOW}---------------------------------------------${NC}"
    echo -e "${BLUE}Способы аутентификации:${NC}"
    echo -e "${CYAN}1.${NC} Username + Password"
    echo -e "${CYAN}2.${NC} Username + Personal Access Token (рекомендуется)"
    echo ""
    echo -n -e "${GREEN}Выберите способ (1-2) [2]: ${NC}"
    read auth_method
    
    echo ""
    echo -n -e "${GREEN}Введите GitHub/GitLab username: ${NC}"
    read git_username
    
    if [ "$auth_method" = "1" ]; then
      echo -n -e "${GREEN}Введите пароль: ${NC}"
      read -s git_password
      echo ""
      git_credentials="$git_username:$git_password"
    else
      echo ""
      echo -e "${BLUE}💡 Как получить Personal Access Token:${NC}"
      echo -e "  GitHub: Settings → Developer settings → Personal access tokens → Generate new token"
      echo -e "  GitLab: User Settings → Access Tokens → Create personal access token"
      echo -e "  Права: repo (для GitHub) или read_repository + write_repository (для GitLab)"
      echo ""
      echo -n -e "${GREEN}Введите Personal Access Token: ${NC}"
      read -s git_token
      echo ""
      git_credentials="$git_username:$git_token"
    fi
    
    echo ""
    echo -e "${GREEN}✅ Аутентификация настроена для пользователя: ${BOLD}$git_username${NC}"
    echo -e "${YELLOW}⚠️  Учетные данные будут сохранены в зашифрованном виде${NC}"
  else
    echo -e "${GREEN}✅ Публичный репозиторий - аутентификация не требуется${NC}"
  fi
  
  # Выбор типа действий с умными предложениями
  echo ""
  echo -e "${YELLOW}⚙️  Настройка действий при обновлении:${NC}"
  echo -e "${YELLOW}---------------------------------------------${NC}"
  
  local commands=""
  
  if [ ${#matching_services[@]} -gt 0 ]; then
    echo -e "${GREEN}🎯 Найдены подходящие сервисы для проекта:${NC}"
    
    for i in "${!matching_services[@]}"; do
      service_info=(${matching_services[$i]//:/ })
      service_name="${service_info[0]}"
      service_path="${service_info[1]}"
      
      echo -e "${CYAN}$((i+1)).${NC} ${BOLD}$service_name${NC} (${service_path})"
    done
    
    echo -e "${CYAN}$((${#matching_services[@]}+1)).${NC} Использовать другой существующий сервис"
    echo -e "${CYAN}$((${#matching_services[@]}+2)).${NC} Указать команды вручную"
    echo ""
    echo -e "${GREEN}💡 Рекомендация:${NC} Выберите подходящий сервис для автоматического перезапуска"
    echo -n -e "${GREEN}Ваш выбор (1-$((${#matching_services[@]}+2))): ${NC}"
    read action_choice
    
    if [[ "$action_choice" =~ ^[0-9]+$ ]] && [ "$action_choice" -ge 1 ] && [ "$action_choice" -le ${#matching_services[@]} ]; then
      # Используем подходящий сервис
      service_info=(${matching_services[$((action_choice-1))]//:/ })
      service_name="${service_info[0]}"
      
      if [ ! -z "$git_credentials" ]; then
        # Создаем URL с аутентификацией для приватного репозитория
        local auth_url=$(echo "$repo_url" | sed "s|https://|https://$git_credentials@|")
        commands="cd $project_path && git remote set-url origin '$auth_url' && git pull origin $target_branch && systemctl restart $service_name"
      else
        commands="cd $project_path && git pull origin $target_branch && systemctl restart $service_name"
      fi
      
      echo ""
      echo -e "${GREEN}✅ Настроена автоматизация с сервисом:${NC} ${BOLD}$service_name${NC}"
      echo -e "${BLUE}Команды:${NC} $commands"
      
    elif [ "$action_choice" -eq $((${#matching_services[@]}+1)) ]; then
      # Выбираем из всех сервисов
      if [ ${#services[@]} -gt 0 ]; then
        echo ""
        echo -e "${YELLOW}Все доступные сервисы:${NC}"
        for i in "${!services[@]}"; do
          service_info=(${services[$i]//:/ })
          service_name="${service_info[0]}"
          echo -e "${CYAN}$((i+1)).${NC} $service_name"
        done
        
        echo ""
        echo -n -e "${GREEN}Выберите номер сервиса: ${NC}"
        read service_choice
        
        if [[ "$service_choice" =~ ^[0-9]+$ ]] && [ "$service_choice" -ge 1 ] && [ "$service_choice" -le ${#services[@]} ]; then
          selected_service=(${services[$((service_choice-1))]//:/ })
          service_name="${selected_service[0]}"
          
          if [ ! -z "$git_credentials" ]; then
            # Создаем URL с аутентификацией для приватного репозитория
            local auth_url=$(echo "$repo_url" | sed "s|https://|https://$git_credentials@|")
            commands="cd $project_path && git remote set-url origin '$auth_url' && git pull origin $target_branch && systemctl restart $service_name"
          else
            commands="cd $project_path && git pull origin $target_branch && systemctl restart $service_name"
          fi
        fi
      fi
    fi
  else
    # Нет подходящих сервисов
    if [ ${#services[@]} -gt 0 ]; then
      echo -e "${YELLOW}Доступные сервисы:${NC}"
      for i in "${!services[@]}"; do
        service_info=(${services[$i]//:/ })
        service_name="${service_info[0]}"
        echo -e "${CYAN}$((i+1)).${NC} $service_name"
      done
      
      echo -e "${CYAN}$((${#services[@]}+1)).${NC} Указать команды вручную"
      echo ""
      echo -n -e "${GREEN}Ваш выбор (1-$((${#services[@]}+1))): ${NC}"
      read action_choice
      
      if [[ "$action_choice" =~ ^[0-9]+$ ]] && [ "$action_choice" -ge 1 ] && [ "$action_choice" -le ${#services[@]} ]; then
        selected_service=(${services[$((action_choice-1))]//:/ })
        service_name="${selected_service[0]}"
        
        if [ ! -z "$git_credentials" ]; then
          # Создаем URL с аутентификацией для приватного репозитория
          local auth_url=$(echo "$repo_url" | sed "s|https://|https://$git_credentials@|")
          commands="cd $project_path && git pull origin '$auth_url' && systemctl restart $service_name"
        else
          commands="cd $project_path && git pull origin $target_branch && systemctl restart $service_name"
        fi
      fi
    fi
  fi
  
  # Ручной ввод команд если не выбран сервис
  if [ -z "$commands" ]; then
    echo ""
    echo -e "${YELLOW}🔧 Ручная настройка команд:${NC}"
    echo -e "${YELLOW}---------------------------------------------${NC}"
    echo -e "${BLUE}Популярные примеры:${NC}"
    echo -e "  • ${GREEN}git pull && npm install && npm run build && pm2 restart app${NC}"
    echo -e "  • ${GREEN}git pull && pip install -r requirements.txt && systemctl restart myapp${NC}"
    echo -e "  • ${GREEN}git pull && docker-compose down && docker-compose up -d${NC}"
    echo -e "  • ${GREEN}git pull && ./deploy.sh${NC}"
    echo ""
    if [ ! -z "$git_credentials" ]; then
      echo -e "${YELLOW}Базовая команда уже включена: ${GREEN}cd $project_path && git pull (с аутентификацией)${NC}"
    else
      echo -e "${YELLOW}Базовая команда уже включена: ${GREEN}cd $project_path && git pull origin $target_branch${NC}"
    fi
    echo -n -e "${GREEN}Дополнительные команды после git pull: ${NC}"
    read additional_commands
    
    if [ ! -z "$git_credentials" ]; then
      # Создаем URL с аутентификацией для приватного репозитория
      local auth_url=$(echo "$repo_url" | sed "s|https://|https://$git_credentials@|")
      if [ -z "$additional_commands" ]; then
        commands="cd $project_path && git remote set-url origin '$auth_url' && git pull origin $target_branch"
      else
        commands="cd $project_path && git remote set-url origin '$auth_url' && git pull origin $target_branch && $additional_commands"
      fi
    else
      if [ -z "$additional_commands" ]; then
        commands="cd $project_path && git pull origin $target_branch"
      else
        commands="cd $project_path && git pull origin $target_branch && $additional_commands"
      fi
    fi
  fi
  
  # Подтверждение создания
  echo ""
  echo -e "${BOLD}${CYAN}==============================================${NC}"
  echo -e "${BOLD}${CYAN}           ПОДТВЕРЖДЕНИЕ СОЗДАНИЯ            ${NC}"
  echo -e "${BOLD}${CYAN}==============================================${NC}"
  echo ""
  echo -e "${YELLOW}Параметры автоматизации:${NC}"
  echo -e "${YELLOW}---------------------------------------------${NC}"
  echo -e "${BOLD}📝 Название:${NC} $automation_name"
  echo -e "${BOLD}📂 Репозиторий:${NC} $repo_url"
  echo -e "${BOLD}📁 Путь проекта:${NC} $project_path"
  echo -e "${BOLD}🌿 Ветка:${NC} $target_branch"
  echo -e "${BOLD}⚙️  Команды:${NC} $commands"
  echo -e "${YELLOW}---------------------------------------------${NC}"
  echo ""
  echo -n -e "${GREEN}Создать автоматизацию? [Y/n]: ${NC}"
  read confirm
  
  if [[ "$confirm" == "n" || "$confirm" == "N" ]]; then
    echo -e "${YELLOW}❌ Создание автоматизации отменено.${NC}"
    sleep 2
    return 1
  fi
  
  # Зашифровываем учетные данные если есть
  local encrypted_credentials=""
  if [ ! -z "$git_credentials" ]; then
    # Простое шифрование для безопасности (base64 + rot13)
    encrypted_credentials=$(echo "$git_credentials" | base64 | tr 'A-Za-z' 'N-ZA-Mn-za-m')
  fi
  
  # Сохраняем автоматизацию с дополнительными полями
  local automation_id=$(date +%s)
  echo "${automation_id}|${automation_name}|${repo_url}|${project_path}|${target_branch}|${commands}|$(date '+%Y-%m-%d %H:%M:%S')|${is_private}|${encrypted_credentials}" >> "$AUTOMATIONS_FILE"
  
  echo ""
  echo -e "${GREEN}${BOLD}✅ Автоматизация '$automation_name' успешно создана!${NC}"
  echo ""
  echo -e "${YELLOW}📋 Следующие шаги:${NC}"
  echo -e "1. ${CYAN}Запустите webhook сервер${NC} (пункт 3 в главном меню)"
  echo -e "2. ${CYAN}Настройте GitHub webhook${NC}:"
  echo -e "   • ${YELLOW}URL:${NC} ${GREEN}http://$(hostname -I | awk '{print $1}'):$WEBHOOK_PORT/webhook${NC}"
  echo -e "   • ${YELLOW}Content type:${NC} application/json"
  echo -e "   • ${YELLOW}Events:${NC} Just the push event"
  echo -e "3. ${CYAN}Сделайте тестовый коммит${NC} в ветку $target_branch"
  echo -e "4. ${CYAN}Проверьте логи${NC} для подтверждения работы автоматизации"
  
  log_event "INFO" "Создана новая автоматизация: $automation_name для ветки $target_branch"
  
  sleep 5
  return 0
}

# Управление автоматизациями
manage_automations() {
  while true; do
    clear_screen
    echo -e "${BOLD}${CYAN}==============================================${NC}"
    echo -e "${BOLD}${CYAN}        УПРАВЛЕНИЕ АВТОМАТИЗАЦИЯМИ           ${NC}"
    echo -e "${BOLD}${CYAN}==============================================${NC}"
    echo ""
    
    if [ ! -s "$AUTOMATIONS_FILE" ]; then
      echo -e "${RED}Список автоматизаций пуст.${NC}"
      sleep 2
      return 1
    fi
    
    echo -e "${YELLOW}Список созданных автоматизаций:${NC}"
    echo -e "${YELLOW}---------------------------------------------${NC}"
    
    mapfile -t automations < "$AUTOMATIONS_FILE"
    
    for i in "${!automations[@]}"; do
      local IFS='|'
      read -ra automation_info <<< "${automations[$i]}"
      
      # Проверяем корректность данных
      if [ ${#automation_info[@]} -lt 6 ]; then
        echo -e "${RED}❌ Пропускаем поврежденную запись: ${automations[$i]::50}...${NC}"
        continue
      fi
      
      automation_id="${automation_info[0]}"
      automation_name="${automation_info[1]}"
      repo_url="${automation_info[2]}"
      target_branch="${automation_info[4]}"
      creation_date="${automation_info[6]} ${automation_info[7]}"
      
      echo -e "${CYAN}$((i+1)).${NC} ${BOLD}$automation_name${NC}"
      echo -e "   ${YELLOW}Репозиторий:${NC} $repo_url"
      echo -e "   ${YELLOW}Ветка:${NC} $target_branch"
      echo -e "   ${YELLOW}Создана:${NC} $creation_date"
      echo -e "${YELLOW}---------------------------------------------${NC}"
    done
    
    echo ""
    echo -e "${YELLOW}Выберите действие:${NC}"
    echo -e "${CYAN}1.${NC} Просмотреть детали автоматизации"
    echo -e "${CYAN}2.${NC} Удалить автоматизацию"
    echo -e "${CYAN}3.${NC} Протестировать автоматизацию"
    echo -e "${PURPLE}4.${NC} 🔍 Диагностика автоматизации"
    echo -e "${PURPLE}5.${NC} 🔧 Восстановить учетные данные"
    echo -e "${CYAN}6.${NC} Вернуться в главное меню"
    echo ""
    echo -n -e "${GREEN}Ваш выбор (1-6): ${NC}"
    read action_choice
    
    case $action_choice in
      1|2|3|4|5)
        echo ""
        echo -n -e "${GREEN}Введите номер автоматизации: ${NC}"
        read automation_number
        
        if ! [[ "$automation_number" =~ ^[0-9]+$ ]] || [ "$automation_number" -lt 1 ] || [ "$automation_number" -gt ${#automations[@]} ]; then
          echo -e "${RED}Некорректный выбор!${NC}"
          sleep 2
          continue
        fi
        
        selected_automation="${automations[$((automation_number-1))]}"
        automation_info=(${selected_automation//|/ })
        
        case $action_choice in
          1)
            view_automation_details "$selected_automation"
            ;;
          2)
            delete_automation "$automation_number" "${automation_info[1]}"
            ;;
          3)
            test_automation "$selected_automation"
            ;;
          4)
            diagnose_automation "${automation_info[0]}"
            ;;
          5)
            repair_automation_credentials "${automation_info[0]}"
            ;;
        esac
        ;;
      6)
        return 0
        ;;
      *)
        echo -e "${RED}Некорректный выбор!${NC}"
        sleep 1
        ;;
    esac
  done
}

# Просмотр деталей автоматизации
view_automation_details() {
  local automation_data="$1"
  
  # Безопасный парсинг с проверкой
  local IFS='|'
  read -ra automation_info <<< "$automation_data"
  
  # Проверяем корректность данных
  if [ ${#automation_info[@]} -lt 6 ]; then
    echo -e "${RED}❌ Поврежденные данные автоматизации!${NC}"
    echo -e "${YELLOW}Данные: $automation_data${NC}"
    echo ""
    echo -e "${YELLOW}Нажмите Enter, чтобы вернуться...${NC}"
    read
    return 1
  fi
  
  clear_screen
  echo -e "${BOLD}${CYAN}==============================================${NC}"
  echo -e "${BOLD}${CYAN}       ДЕТАЛИ АВТОМАТИЗАЦИИ                  ${NC}"
  echo -e "${BOLD}${CYAN}==============================================${NC}"
  echo ""
  
  echo -e "${YELLOW}Информация об автоматизации:${NC}"
  echo -e "${YELLOW}---------------------------------------------${NC}"
  echo -e "${BOLD}ID:${NC} ${automation_info[0]:-'Неизвестно'}"
  echo -e "${BOLD}Название:${NC} ${automation_info[1]:-'Без названия'}"
  echo -e "${BOLD}Репозиторий:${NC} ${automation_info[2]:-'Не указан'}"
  echo -e "${BOLD}Путь проекта:${NC} ${automation_info[3]:-'Не указан'}"
  echo -e "${BOLD}Ветка:${NC} ${automation_info[4]:-'Не указана'}"
  echo -e "${BOLD}Команды:${NC} ${automation_info[5]:-'Не указаны'}"
  echo -e "${BOLD}Создана:${NC} ${automation_info[6]:-''}"
  
  # Показываем информацию о приватности если есть
  if [ ! -z "${automation_info[7]}" ] && [ "${automation_info[7]}" = "yes" ]; then
    echo -e "${BOLD}Тип репозитория:${NC} ${YELLOW}🔒 Приватный (с аутентификацией)${NC}"
  else
    echo -e "${BOLD}Тип репозитория:${NC} ${GREEN}🌐 Публичный${NC}"
  fi
  echo -e "${YELLOW}---------------------------------------------${NC}"
  
  echo ""
  echo -e "${YELLOW}Нажмите Enter, чтобы вернуться...${NC}"
  read
}

# Удаление автоматизации
delete_automation() {
  local automation_number="$1"
  local automation_name="$2"
  
  echo ""
  echo -e "${RED}${BOLD}Вы уверены, что хотите удалить автоматизацию '$automation_name'? (y/n): ${NC}"
  read confirm_delete
  
  if [[ "$confirm_delete" == "y" || "$confirm_delete" == "Y" ]]; then
    # Удаляем строку из файла
    sed -i "${automation_number}d" "$AUTOMATIONS_FILE"
    
    echo -e "${GREEN}${BOLD}Автоматизация '$automation_name' успешно удалена.${NC}"
    log_event "INFO" "Удалена автоматизация: $automation_name"
    sleep 2
  else
    echo -e "${YELLOW}Удаление отменено.${NC}"
    sleep 1
  fi
}

# Тестирование автоматизации
test_automation() {
  local automation_data="$1"
  
  # Правильный парсинг через IFS
  local IFS='|'
  read -ra automation_info <<< "$automation_data"
  
  local automation_id="${automation_info[0]:-}"
  local automation_name="${automation_info[1]:-}"
  local automation_repo="${automation_info[2]:-}"
  local automation_path="${automation_info[3]:-}"
  local automation_branch="${automation_info[4]:-}"
  local commands="${automation_info[5]:-}"
  local automation_created="${automation_info[6]:-}"
  local automation_is_private="${automation_info[7]:-}"
  local automation_encrypted_creds="${automation_info[8]:-}"
  
  echo ""
  echo -e "${YELLOW}Тестирование автоматизации '$automation_name'...${NC}"
  echo -e "${CYAN}Репозиторий: $automation_repo${NC}"
  echo -e "${CYAN}Ветка: $automation_branch${NC}"
  echo -e "${CYAN}Путь: $automation_path${NC}"
  
  log_event "INFO" "🧪 Начато тестирование автоматизации: $automation_name"
  log_event "DEBUG" "📋 Детали: repo='$automation_repo', branch='$automation_branch', path='$automation_path'"
  log_event "DEBUG" "🔐 Тип: $([ "$automation_is_private" = "yes" ] && echo "приватный" || echo "публичный") репозиторий"
  
  # Подготавливаем команды с учетными данными если это приватный репозиторий
  local final_commands="$commands"
  if [ "$automation_is_private" = "yes" ] && [ ! -z "$automation_encrypted_creds" ]; then
    log_event "DEBUG" "🔓 Расшифровка учетных данных для тестирования"
    
    # Расшифровываем учетные данные
    local decrypted_creds=$(echo "$automation_encrypted_creds" | tr 'A-Za-z' 'N-ZA-Mn-za-m' | base64 -d 2>/dev/null)
    if [ ! -z "$decrypted_creds" ]; then
      log_event "DEBUG" "✅ Учетные данные расшифрованы для тестирования"
      # Заменяем git pull на git pull с аутентификацией в командах
      local auth_url=$(echo "$automation_repo" | sed "s|https://|https://$decrypted_creds@|")
      final_commands=$(echo "$commands" | sed "s|git pull origin|git remote set-url origin '$auth_url' \&\& git pull origin|g")
      log_event "DEBUG" "🔧 Команды модифицированы для приватного репозитория"
    else
      log_event "ERROR" "❌ Не удалось расшифровать учетные данные для тестирования"
    fi
  fi
  
  log_event "DEBUG" "💻 Команды для выполнения: $final_commands"
  echo -e "${CYAN}Выполняемые команды:${NC}"
  echo -e "${GRAY}$final_commands${NC}"
  echo ""
  
  # Выполняем команды
  if eval "$final_commands"; then
    echo -e "${GREEN}${BOLD}Тестирование завершено успешно!${NC}"
    log_event "SUCCESS" "Тестирование автоматизации '$automation_name' завершено успешно"
  else
    echo -e "${RED}${BOLD}Ошибка при выполнении команд!${NC}"
    log_event "ERROR" "Ошибка при тестировании автоматизации '$automation_name'"
  fi
  
  echo ""
  echo -e "${YELLOW}Нажмите Enter, чтобы продолжить...${NC}"
  read
}

# Запуск webhook сервера
start_webhook_server() {
  clear_screen
  echo -e "${BOLD}${CYAN}==============================================${NC}"
  echo -e "${BOLD}${CYAN}           WEBHOOK СЕРВЕР                    ${NC}"
  echo -e "${BOLD}${CYAN}==============================================${NC}"
  echo ""
  
  # Проверяем, запущен ли уже сервер
  local server_running=false
  local server_type_running=""
  
  if pgrep -f "python3.*webhook_server.*${WEBHOOK_PORT}" > /dev/null; then
    server_running=true
    server_type_running="Python"
  elif pgrep -f "socat.*${WEBHOOK_PORT}" > /dev/null; then
    server_running=true
    server_type_running="Socat"
  elif pgrep -f "nc.*${WEBHOOK_PORT}" > /dev/null; then
    server_running=true
    server_type_running="Netcat"
  fi
  
  if [ "$server_running" = true ]; then
    echo -e "${YELLOW}Webhook сервер уже запущен (${GREEN}$server_type_running${YELLOW}).${NC}"
    echo -e "${YELLOW}Порт: ${GREEN}$WEBHOOK_PORT${NC}"
    echo ""
    echo -e "${YELLOW}Выберите действие:${NC}"
    echo -e "${CYAN}1.${NC} Остановить сервер"
    echo -e "${CYAN}2.${NC} Перезапустить сервер"
    echo -e "${CYAN}3.${NC} Просмотреть подробный статус"
    echo -e "${CYAN}4.${NC} Тестировать сервер"
    echo -e "${CYAN}5.${NC} Вернуться назад"
    echo ""
    echo -n -e "${GREEN}Ваш выбор (1-5): ${NC}"
    read server_action
    
    case $server_action in
      1)
        echo -e "${YELLOW}Остановка webhook сервера...${NC}"
        # Останавливаем все типы webhook серверов
        pkill -f "python3.*webhook_server_${WEBHOOK_PORT}" 2>/dev/null
        pkill -f "socat.*${WEBHOOK_PORT}" 2>/dev/null
        pkill -f "nc.*-p ${WEBHOOK_PORT}" 2>/dev/null
        pkill -f "nc.*-l.*${WEBHOOK_PORT}" 2>/dev/null
        sleep 2
        echo -e "${GREEN}✅ Webhook сервер остановлен.${NC}"
        log_event "INFO" "Webhook сервер остановлен пользователем"
        echo ""
        echo -e "${YELLOW}Нажмите Enter, чтобы продолжить...${NC}"
        read
        ;;
      2)
        echo -e "${YELLOW}Перезапуск webhook сервера...${NC}"
        # Останавливаем все типы webhook серверов
        pkill -f "python3.*webhook_server_${WEBHOOK_PORT}" 2>/dev/null
        pkill -f "socat.*${WEBHOOK_PORT}" 2>/dev/null
        pkill -f "nc.*-p ${WEBHOOK_PORT}" 2>/dev/null
        pkill -f "nc.*-l.*${WEBHOOK_PORT}" 2>/dev/null
        sleep 2
        echo -e "${YELLOW}Выберите тип сервера:${NC}"
        echo -e "${CYAN}1.${NC} Python сервер (рекомендуется)"
        echo -e "${CYAN}2.${NC} Bash сервер"
        echo ""
        echo -n -e "${GREEN}Ваш выбор (1-2): ${NC}"
        read restart_choice
        
        case $restart_choice in
          1) start_python_webhook_server ;;
          *) start_bash_webhook_server ;;
        esac
        ;;
      3)
        show_detailed_server_status
        ;;
      4)
        test_webhook_server
        ;;
      5)
        return
        ;;
      *)
        echo -e "${RED}Неверный выбор!${NC}"
        sleep 1
        ;;
    esac
  else
    echo -e "${YELLOW}Webhook сервер не запущен.${NC}"
    echo ""
    echo -e "${YELLOW}Выберите действие:${NC}"
    echo -e "${CYAN}1.${NC} Запустить Python сервер (рекомендуется)"
    echo -e "${CYAN}2.${NC} Запустить Bash сервер"
    echo -e "${CYAN}3.${NC} Остановить все webhook процессы (принудительно)"
    echo -e "${CYAN}4.${NC} Просмотреть статус"
    echo -e "${CYAN}5.${NC} Вернуться назад"
    echo ""
    echo -n -e "${GREEN}Ваш выбор (1-5): ${NC}"
    read server_type
    
    case $server_type in
      1)
        start_python_webhook_server
        ;;
      2)
        start_bash_webhook_server
        ;;
      3)
        echo -e "${YELLOW}Принудительная остановка всех webhook процессов...${NC}"
        # Останавливаем все возможные webhook процессы
        pkill -f "python3.*webhook_server" 2>/dev/null
        pkill -f "socat.*${WEBHOOK_PORT}" 2>/dev/null
        pkill -f "nc.*${WEBHOOK_PORT}" 2>/dev/null
        pkill -f "webhook" 2>/dev/null
        echo -e "${GREEN}✅ Все webhook процессы остановлены.${NC}"
        log_event "INFO" "Принудительная остановка всех webhook процессов"
        echo ""
        echo -e "${YELLOW}Нажмите Enter, чтобы продолжить...${NC}"
        read
        ;;
      4)
        show_detailed_server_status
        ;;
      5)
        return
        ;;
      *)
        echo -e "${YELLOW}Использую Python сервер по умолчанию...${NC}"
        start_python_webhook_server
        ;;
    esac
  fi
  
  sleep 3
}

# Создание Python webhook сервера
create_python_webhook_server() {
  local script_path="/tmp/webhook_server_${WEBHOOK_PORT}.py"
  
  cat > "$script_path" << 'PYTHON_SERVER_EOF'
#!/usr/bin/env python3
import http.server
import socketserver
import json
import sys
import subprocess
import os
from datetime import datetime

class WebhookHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        message = format % args
        log_file = "/var/lib/webhook-automation/logs/webhook.log"
        try:
            with open(log_file, "a") as f:
                f.write(f"[{timestamp}] [PYTHON-SERVER] {message}\n")
        except:
            pass
    
    def do_GET(self):
        if self.path == "/webhook":
            self.send_response(200)
            self.send_header('Content-type', 'text/plain')
            self.end_headers()
            self.wfile.write(b"Webhook server is active")
            self.log_message("GET request to /webhook")
        else:
            self.send_response(404)
            self.send_header('Content-type', 'text/plain')
            self.end_headers()
            self.wfile.write(b"Not Found")
    
    def do_POST(self):
        if self.path != "/webhook":
            self.send_response(404)
            self.send_header('Content-type', 'text/plain')
            self.end_headers()
            self.wfile.write(b"Not Found")
            return
        
        content_length = int(self.headers.get('Content-Length', 0))
        post_data = self.read_data(content_length)
        event_type = self.headers.get('X-GitHub-Event', '')
        user_agent = self.headers.get('User-Agent', '')
        
        # Проверяем Content-Type и декодируем если нужно
        content_type = self.headers.get('Content-Type', '')
        if 'application/x-www-form-urlencoded' in content_type:
            # URL-encoded данные, декодируем
            import urllib.parse
            post_data = urllib.parse.unquote_plus(post_data)
            self.log_message(f"URL-decoded payload, new size: {len(post_data)}")
        elif post_data.startswith('payload='):
            # GitHub иногда отправляет данные как payload=url_encoded_json
            post_data = post_data[8:]  # Убираем 'payload='
            import urllib.parse
            post_data = urllib.parse.unquote_plus(post_data)
            self.log_message(f"Extracted and URL-decoded payload, new size: {len(post_data)}")
        
        self.log_message(f"POST /webhook - Event: {event_type}, User-Agent: {user_agent}")
        
        temp_dir = f"/tmp/webhook-python-{os.getpid()}-{int(datetime.now().timestamp())}"
        try:
            os.makedirs(temp_dir, exist_ok=True)
            
            with open(f"{temp_dir}/event_type", "w") as f:
                f.write(event_type)
            with open(f"{temp_dir}/payload", "w") as f:
                f.write(post_data)
            with open(f"{temp_dir}/user_agent", "w") as f:
                f.write(user_agent)
            
            # Отладочная информация
            self.log_message(f"Сохранено: event_type='{event_type}', payload_size={len(post_data)}, user_agent='{user_agent}'")
            
            # Ищем webhook.sh в разных местах
            possible_paths = [
                os.environ.get("WEBHOOK_SCRIPT_PATH"),
                "/usr/local/bin/webhook.sh",
                "/usr/bin/webhook.sh", 
                "./webhook.sh",
                os.path.expanduser("~/webhook.sh")
            ]
            
            webhook_script = None
            for path in possible_paths:
                if path and os.path.exists(path):
                    webhook_script = path
                    break
            
            if webhook_script:
                subprocess.Popen([
                    "/usr/bin/bash", webhook_script, "handle_webhook_request", temp_dir
                ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                self.log_message(f"Webhook processing started for event: {event_type}")
            else:
                self.log_message("ERROR: webhook.sh not found")
            
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(b'{"status":"ok"}')
            
        except Exception as e:
            self.log_message(f"Error processing webhook: {e}")
            self.send_response(500)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(b'{"status":"error"}')
    
    def read_data(self, content_length):
        if content_length == 0:
            return ""
        try:
            data = self.rfile.read(content_length)
            return data.decode('utf-8')
        except Exception as e:
            self.log_message(f"Error reading POST data: {e}")
            return ""

def run_server(port=9000):
    try:
        with socketserver.TCPServer(("", port), WebhookHandler) as httpd:
            print(f"Python webhook server running on port {port}")
            log_file = "/var/lib/webhook-automation/logs/webhook.log"
            timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            try:
                with open(log_file, "a") as f:
                    f.write(f"[{timestamp}] [INFO] [PYTHON-SERVER] Webhook сервер запущен на порту {port}\n")
            except:
                pass
            httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nServer stopped by user")
    except Exception as e:
        print(f"Server error: {e}")
        return 1
    return 0

if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 9000
    sys.exit(run_server(port))
PYTHON_SERVER_EOF

  echo "$script_path"
}

# Запуск Python webhook сервера
start_python_webhook_server() {
  if ! command -v python3 &> /dev/null; then
    echo -e "${RED}Python3 не найден. Использую bash сервер...${NC}"
    start_bash_webhook_server
    return
  fi
  
  echo -e "${YELLOW}Запуск Python webhook сервера на порту $WEBHOOK_PORT...${NC}"
  
  # Создаем Python скрипт динамически
  local script_path=$(create_python_webhook_server)
  
  if [ ! -f "$script_path" ]; then
    echo -e "${RED}Не удалось создать Python скрипт. Использую bash сервер...${NC}"
    start_bash_webhook_server
    return
  fi
  
  echo -e "${YELLOW}Python скрипт создан: $script_path${NC}"
  
  # Тестируем синтаксис Python скрипта
  if ! python3 -m py_compile "$script_path" 2>/dev/null; then
    echo -e "${RED}Ошибка синтаксиса Python скрипта. Использую bash сервер...${NC}"
    rm -f "$script_path" 2>/dev/null
    start_bash_webhook_server
    return
  fi
  
  # Проверяем, занят ли порт
  if ss -tuln 2>/dev/null | grep -q ":${WEBHOOK_PORT} " || netstat -tuln 2>/dev/null | grep -q ":${WEBHOOK_PORT} "; then
    echo -e "${RED}Порт $WEBHOOK_PORT уже занят. Использую bash сервер...${NC}"
    rm -f "$script_path" 2>/dev/null
    start_bash_webhook_server
    return
  fi
  
  # Запускаем Python сервер в фоне с логированием ошибок
  local log_file="/tmp/webhook_python_${WEBHOOK_PORT}.log"
  nohup python3 "$script_path" "$WEBHOOK_PORT" > "$log_file" 2>&1 &
  local python_pid=$!
  
  echo -e "${YELLOW}Python сервер запущен с PID: $python_pid${NC}"
  
  # Проверяем, запустился ли сервер
  sleep 3
  if kill -0 "$python_pid" 2>/dev/null && pgrep -f "python3.*$script_path" > /dev/null; then
    echo -e "${GREEN}${BOLD}🚀 Python webhook сервер запущен!${NC}"
    log_event "INFO" "Python webhook сервер запущен на порту $WEBHOOK_PORT (PID: $python_pid)"
    
    # Очищаем временные файлы через некоторое время
    (sleep 300 && rm -f "$script_path" "$log_file" 2>/dev/null) &
  else
    echo -e "${RED}Ошибка запуска Python сервера.${NC}"
    
    # Показываем ошибки если есть
    if [ -f "$log_file" ]; then
      echo -e "${RED}Ошибки Python сервера:${NC}"
      head -n 10 "$log_file"
    fi
    
    rm -f "$script_path" "$log_file" 2>/dev/null
    echo -e "${YELLOW}Использую bash сервер...${NC}"
    start_bash_webhook_server
    return
  fi
  
  show_webhook_info
}

# Запуск Bash webhook сервера
start_bash_webhook_server() {
  echo -e "${YELLOW}Запуск Bash webhook сервера на порту $WEBHOOK_PORT...${NC}"
  
  # Проверяем доступные инструменты
  if command -v socat &> /dev/null; then
    echo -e "${YELLOW}Используем socat для webhook сервера${NC}"
    start_socat_webhook_server
    return $?
  elif command -v nc &> /dev/null; then
    echo -e "${YELLOW}Используем netcat для webhook сервера${NC}"
  else
    echo -e "${RED}Не найден ни socat, ни netcat. Требуется один из них для bash webhook сервера.${NC}"
    echo -e "${YELLOW}Установите: apt-get install socat netcat-openbsd или yum install socat nmap-ncat${NC}"
    return 1
  fi
  
  # Проверяем, занят ли порт
  if ss -tuln 2>/dev/null | grep -q ":${WEBHOOK_PORT} " || netstat -tuln 2>/dev/null | grep -q ":${WEBHOOK_PORT} "; then
    echo -e "${RED}Порт $WEBHOOK_PORT уже занят.${NC}"
    return 1
  fi
  
  # Запускаем упрощенный webhook сервер
  local log_file="/tmp/webhook_bash_${WEBHOOK_PORT}.log"
  
  # Используем более простую реализацию через цикл с netcat
  nohup bash -c "
    export WEBHOOK_SCRIPT_PATH='$WEBHOOK_SCRIPT_PATH'
    export WEBHOOK_PORT='$WEBHOOK_PORT'
    
    # Функция логирования
    log_event() {
      local level=\$1
      local message=\$2
      local timestamp=\$(date '+%Y-%m-%d %H:%M:%S')
      echo \"[\$timestamp] [\$level] \$message\" >> /var/lib/webhook-automation/logs/webhook.log 2>/dev/null || true
    }
    
    log_event 'INFO' 'Bash webhook сервер запускается на порту \$WEBHOOK_PORT'
    
    while true; do
      {
        echo 'HTTP/1.1 200 OK'
        echo 'Content-Type: application/json'
        echo 'Content-Length: 15'
        echo 'Connection: close'
        echo ''
        echo '{\"status\":\"ok\"}'
      } | nc -l -p \$WEBHOOK_PORT -q 1
      sleep 0.1
    done
  " > "$log_file" 2>&1 &
  
  local bash_pid=$!
  echo -e "${YELLOW}Bash сервер запущен с PID: $bash_pid${NC}"
  
  # Проверяем запуск
  sleep 2
  if kill -0 "$bash_pid" 2>/dev/null; then
    echo -e "${GREEN}${BOLD}🚀 Bash webhook сервер запущен!${NC}"
    log_event "INFO" "Bash webhook сервер запущен на порту $WEBHOOK_PORT (PID: $bash_pid)"
  else
    echo -e "${RED}Ошибка запуска Bash сервера.${NC}"
    if [ -f "$log_file" ]; then
      echo -e "${RED}Ошибки:${NC}"
      head -n 10 "$log_file"
    fi
    return 1
  fi
  
  show_webhook_info
}

# Запуск webhook сервера через socat
start_socat_webhook_server() {
  local log_file="/tmp/webhook_socat_${WEBHOOK_PORT}.log"
  
  echo -e "${YELLOW}Запуск socat webhook сервера на порту $WEBHOOK_PORT...${NC}"
  
  # Проверяем, занят ли порт
  if ss -tuln 2>/dev/null | grep -q ":${WEBHOOK_PORT} " || netstat -tuln 2>/dev/null | grep -q ":${WEBHOOK_PORT} "; then
    echo -e "${RED}Порт $WEBHOOK_PORT уже занят.${NC}"
    return 1
  fi
  
  # Запускаем socat сервер
  nohup socat TCP-LISTEN:${WEBHOOK_PORT},fork,reuseaddr EXEC:"/bin/bash -c '
    read method path version
    
    # Читаем заголовки до пустой строки
    while read line && [ \"\$line\" != \$\"\\r\" ]; do
      if [[ \"\$line\" =~ ^X-GitHub-Event:[[:space:]]* ]]; then
        event_type=\$(echo \"\$line\" | sed \"s/.*X-GitHub-Event:[[:space:]]*//\" | tr -d \"\\r\\n\")
      elif [[ \"\$line\" =~ ^Content-Length:[[:space:]]* ]]; then
        content_length=\$(echo \"\$line\" | sed \"s/.*Content-Length:[[:space:]]*//\" | tr -d \"\\r\\n \")
      fi
    done
    
    # Читаем payload если есть
    payload=\"\"
    if [ \"\$content_length\" -gt 0 ] && [ \"\$content_length\" -lt 10000 ]; then
      payload=\$(head -c \"\$content_length\" 2>/dev/null)
    fi
    
    # Обрабатываем webhook если это POST к /webhook
    if [[ \"\$method\" == \"POST\" ]] && [[ \"\$path\" == \"/webhook\" ]] && [ ! -z \"\$event_type\" ]; then
      temp_dir=\"/tmp/webhook-socat-\$\$-\$(date +%s)\"
      mkdir -p \"\$temp_dir\"
      echo \"\$event_type\" > \"\$temp_dir/event_type\"
      echo \"\$payload\" > \"\$temp_dir/payload\"
      echo \"GitHub-Hookshot\" > \"\$temp_dir/user_agent\"
      
      # Запускаем обработку в фоне
      \"$WEBHOOK_SCRIPT_PATH\" handle_webhook_request \"\$temp_dir\" &
    fi
    
    # Всегда отвечаем 200 OK для /webhook
    if [[ \"\$path\" == \"/webhook\" ]]; then
      echo \"HTTP/1.1 200 OK\"
      echo \"Content-Type: application/json\"
      echo \"Content-Length: 15\"
      echo \"Connection: close\"
      echo \"\"
      echo \"{\\\"status\\\":\\\"ok\\\"}\"
    else
      echo \"HTTP/1.1 404 Not Found\"
      echo \"Content-Type: text/plain\"
      echo \"Content-Length: 9\"
      echo \"Connection: close\"
      echo \"\"
      echo \"Not Found\"
    fi
  '" > "$log_file" 2>&1 &
  
  local socat_pid=$!
  echo -e "${YELLOW}Socat сервер запущен с PID: $socat_pid${NC}"
  
  # Проверяем запуск
  sleep 2
  if kill -0 "$socat_pid" 2>/dev/null; then
    echo -e "${GREEN}${BOLD}🚀 Socat webhook сервер запущен!${NC}"
    log_event "INFO" "Socat webhook сервер запущен на порту $WEBHOOK_PORT (PID: $socat_pid)"
    show_webhook_info
    return 0
  else
    echo -e "${RED}Ошибка запуска Socat сервера.${NC}"
    if [ -f "$log_file" ]; then
      echo -e "${RED}Ошибки:${NC}"
      head -n 10 "$log_file"
    fi
    return 1
  fi
}

# Отображение информации о webhook
show_webhook_info() {
  echo ""
  echo -e "${YELLOW}📋 Информация для настройки GitHub webhook:${NC}"
  echo -e "${YELLOW}---------------------------------------------${NC}"
  echo -e "${BOLD}URL:${NC} ${GREEN}http://$(hostname -I | awk '{print $1}'):$WEBHOOK_PORT/webhook${NC}"
  echo -e "${BOLD}Content type:${NC} application/json"
  echo -e "${BOLD}Secret:${NC} ${WEBHOOK_SECRET:-'Не установлен'}"
  echo -e "${BOLD}Events:${NC} Just the push event (или Individual events -> Push)"
  echo -e "${YELLOW}---------------------------------------------${NC}"
  echo ""
  echo -e "${YELLOW}🧪 Тестирование:${NC}"
  echo -e "Для проверки работы: ${GREEN}curl http://$(hostname -I | awk '{print $1}'):$WEBHOOK_PORT/webhook${NC}"
  echo ""
  echo -n -e "${GREEN}Хотите протестировать webhook сервер прямо сейчас? (y/n): ${NC}"
  read test_webhook
  
  if [[ "$test_webhook" == "y" || "$test_webhook" == "Y" ]]; then
    test_webhook_server
  fi
}

# Показать подробный статус сервера
show_detailed_server_status() {
  clear_screen
  echo -e "${BOLD}${CYAN}==============================================${NC}"
  echo -e "${BOLD}${CYAN}       ПОДРОБНЫЙ СТАТУС СЕРВЕРА              ${NC}"
  echo -e "${BOLD}${CYAN}==============================================${NC}"
  echo ""
  
  local server_status="${RED}Остановлен${NC}"
  local server_type=""
  local server_pid=""
  
  if pgrep -f "python3.*webhook_server.*${WEBHOOK_PORT}" > /dev/null; then
    server_status="${GREEN}Запущен${NC}"
    server_type=" (Python)"
    server_pid=$(pgrep -f "python3.*webhook_server.*${WEBHOOK_PORT}")
  elif pgrep -f "socat.*${WEBHOOK_PORT}" > /dev/null; then
    server_status="${GREEN}Запущен${NC}"
    server_type=" (Socat)"
    server_pid=$(pgrep -f "socat.*${WEBHOOK_PORT}")
  elif pgrep -f "nc.*${WEBHOOK_PORT}" > /dev/null; then
    server_status="${GREEN}Запущен${NC}"
    server_type=" (Netcat)"
    server_pid=$(pgrep -f "nc.*${WEBHOOK_PORT}")
  fi
  
  echo -e "${YELLOW}Информация о webhook сервере:${NC}"
  echo -e "${YELLOW}---------------------------------------------${NC}"
  echo -e "${BOLD}Статус:${NC} $server_status$server_type"
  echo -e "${BOLD}Порт:${NC} $WEBHOOK_PORT"
  
  if [ ! -z "$server_pid" ]; then
    echo -e "${BOLD}PID процесса:${NC} $server_pid"
    echo -e "${BOLD}Время запуска:${NC} $(ps -o lstart= -p $server_pid 2>/dev/null || echo 'Неизвестно')"
    echo -e "${BOLD}Использование CPU:${NC} $(ps -o %cpu= -p $server_pid 2>/dev/null || echo 'Неизвестно')%"
    echo -e "${BOLD}Использование памяти:${NC} $(ps -o %mem= -p $server_pid 2>/dev/null || echo 'Неизвестно')%"
  fi
  
  echo -e "${BOLD}URL для webhook:${NC} http://$(hostname -I | awk '{print $1}'):$WEBHOOK_PORT/webhook"
  echo -e "${YELLOW}---------------------------------------------${NC}"
  
  # Показываем последние события из лога
  echo ""
  echo -e "${YELLOW}Последние события (последние 10 записей):${NC}"
  echo -e "${YELLOW}---------------------------------------------${NC}"
  if [ -f "$WEBHOOK_LOG" ]; then
    tail -n 10 "$WEBHOOK_LOG" | while read line; do
      if [[ "$line" == *"ERROR"* ]]; then
        echo -e "${RED}$line${NC}"
      elif [[ "$line" == *"SUCCESS"* ]]; then
        echo -e "${GREEN}$line${NC}"
      elif [[ "$line" == *"WARNING"* ]]; then
        echo -e "${YELLOW}$line${NC}"
      else
        echo -e "${CYAN}$line${NC}"
      fi
    done
  else
    echo -e "${GRAY}Лог файл не найден${NC}"
  fi
  
  echo ""
  echo -e "${YELLOW}Нажмите Enter, чтобы вернуться...${NC}"
  read
}

# Тестирование webhook сервера
test_webhook_server() {
  echo -e "${YELLOW}Тестирование webhook сервера...${NC}"
  
  local server_ip=$(hostname -I | awk '{print $1}')
  local webhook_url="http://$server_ip:$WEBHOOK_PORT/webhook"
  
  # Тест 1: GET запрос
  echo -e "${CYAN}Тест 1: GET запрос к webhook${NC}"
  if curl -s --connect-timeout 5 "$webhook_url" > /dev/null; then
    echo -e "${GREEN}✅ GET запрос успешен${NC}"
  else
    echo -e "${RED}❌ GET запрос неудачен${NC}"
    return 1
  fi
  
  # Тест 2: Имитация ping события от GitHub
  echo -e "${CYAN}Тест 2: Имитация ping события от GitHub${NC}"
  local ping_payload='{"zen":"Favor focus over features.","hook_id":123,"repository":{"name":"test-repo","clone_url":"https://github.com/test/repo.git","default_branch":"main"}}'
  
  if curl -s --connect-timeout 5 -X POST \
    -H "Content-Type: application/json" \
    -H "X-GitHub-Event: ping" \
    -H "User-Agent: GitHub-Hookshot/test" \
    -d "$ping_payload" \
    "$webhook_url" > /dev/null; then
    echo -e "${GREEN}✅ POST ping запрос успешен${NC}"
  else
    echo -e "${RED}❌ POST ping запрос неудачен${NC}"
    return 1
  fi
  
  # Тест 3: Имитация push события
  echo -e "${CYAN}Тест 3: Имитация push события от GitHub${NC}"
  local push_payload='{"ref":"refs/heads/master","repository":{"name":"test-repo","clone_url":"https://github.com/test/repo.git"},"pusher":{"name":"testuser"},"head_commit":{"message":"Test commit"}}'
  
  if curl -s --connect-timeout 5 -X POST \
    -H "Content-Type: application/json" \
    -H "X-GitHub-Event: push" \
    -H "User-Agent: GitHub-Hookshot/test" \
    -d "$push_payload" \
    "$webhook_url" > /dev/null; then
    echo -e "${GREEN}✅ POST push запрос успешен${NC}"
  else
    echo -e "${RED}❌ POST push запрос неудачен${NC}"
    return 1
  fi
  
  echo ""
  echo -e "${GREEN}${BOLD}🎉 Все тесты прошли успешно!${NC}"
  echo -e "${YELLOW}Проверьте логи для подтверждения обработки событий.${NC}"
  
  sleep 2
}

# Функция webhook сервера (улучшенная bash версия)
webhook_server() {
  local port="$WEBHOOK_PORT"
  
  log_event "INFO" "Bash webhook сервер запускается на порту $port"
  
  # Проверяем доступность netcat
  if ! command -v nc &> /dev/null; then
    log_event "ERROR" "netcat (nc) не найден. Требуется для работы bash webhook сервера"
    return 1
  fi
  
  while true; do
    # Более простая и надежная реализация через socat если доступен
    if command -v socat &> /dev/null; then
      webhook_server_socat "$port"
      return $?
    fi
    
    # Fallback на netcat с упрощенной логикой
    local temp_dir="/tmp/webhook-bash-$$-$(date +%s)"
    mkdir -p "$temp_dir"
    
    # Обрабатываем один запрос
    {
      local request_line=""
      local content_length=0
      local event_type=""
      local user_agent=""
      local in_headers=true
      local is_webhook=false
      local is_post=false
      
      # Читаем первую строку запроса
      read request_line
      request_line=$(echo "$request_line" | tr -d '\r\n')
      
      if [[ "$request_line" =~ ^POST[[:space:]]/webhook ]]; then
        is_post=true
        is_webhook=true
      elif [[ "$request_line" =~ ^GET[[:space:]]/webhook ]]; then
        is_webhook=true
      fi
      
      # Читаем заголовки
      while IFS= read -r line && [ "$in_headers" = true ]; do
        line=$(echo "$line" | tr -d '\r\n')
        
        if [[ -z "$line" ]]; then
          in_headers=false
          break
        fi
        
        if [[ "$line" =~ ^Content-Length:[[:space:]]* ]]; then
          content_length=$(echo "$line" | sed 's/.*Content-Length:[[:space:]]*//' | tr -d ' ')
        elif [[ "$line" =~ ^X-GitHub-Event:[[:space:]]* ]]; then
          event_type=$(echo "$line" | sed 's/.*X-GitHub-Event:[[:space:]]*//' | tr -d ' ')
        elif [[ "$line" =~ ^User-Agent:[[:space:]]* ]]; then
          user_agent=$(echo "$line" | sed 's/.*User-Agent:[[:space:]]*//')
        fi
      done
      
      # Читаем тело запроса
      local payload=""
      if [ "$content_length" -gt 0 ] && [ "$content_length" -lt 10000 ]; then
        payload=$(head -c "$content_length" 2>/dev/null || echo "")
      fi
      
      # Логируем запрос
      log_event "INFO" "Bash webhook: ${request_line} от ${user_agent}"
      
      if [ "$is_webhook" = true ]; then
        if [ "$is_post" = true ] && [ ! -z "$event_type" ]; then
          # Сохраняем данные для обработки
          echo "$event_type" > "$temp_dir/event_type"
          echo "$payload" > "$temp_dir/payload"
          echo "$user_agent" > "$temp_dir/user_agent"
          
                     # Запускаем обработку в фоне
           "$WEBHOOK_SCRIPT_PATH" handle_webhook_request "$temp_dir" &
        fi
        
        # Отправляем успешный ответ
        echo -e "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{\"status\":\"ok\"}"
      else
        # 404 для других путей
        echo -e "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\nNot Found"
      fi
      
    } | nc -l -p "$port" -q 1
    
    # Очищаем временные файлы
    rm -rf "$temp_dir" 2>/dev/null
    
    # Небольшая пауза
    sleep 0.1
  done
}

# Webhook сервер через socat (более надежный)
webhook_server_socat() {
  local port="$1"
  
  log_event "INFO" "Используем socat для webhook сервера на порту $port"
  
  socat TCP-LISTEN:${port},fork,reuseaddr EXEC:"/usr/bin/bash -c '
    source $0
    
    # Читаем HTTP запрос
    request_line=\"\"
    content_length=0
    event_type=\"\"
    user_agent=\"\"
    
    read request_line
    request_line=\$(echo \"\$request_line\" | tr -d \"\\r\\n\")
    
    # Читаем заголовки
    while IFS= read -r line; do
      line=\$(echo \"\$line\" | tr -d \"\\r\\n\")
      [ -z \"\$line\" ] && break
      
      case \"\$line\" in
        Content-Length:*) content_length=\$(echo \"\$line\" | sed \"s/.*Content-Length:[[:space:]]*//\" | tr -d \" \") ;;
        X-GitHub-Event:*) event_type=\$(echo \"\$line\" | sed \"s/.*X-GitHub-Event:[[:space:]]*//\" | tr -d \" \") ;;
        User-Agent:*) user_agent=\$(echo \"\$line\" | sed \"s/.*User-Agent:[[:space:]]*//\") ;;
      esac
    done
    
    # Читаем payload
    payload=\"\"
    if [ \"\$content_length\" -gt 0 ] && [ \"\$content_length\" -lt 10000 ]; then
      payload=\$(head -c \"\$content_length\" 2>/dev/null || echo \"\")
    fi
    
    # Обрабатываем запрос
    if [[ \"\$request_line\" == *\"/webhook\"* ]]; then
      if [[ \"\$request_line\" == \"POST\"* ]] && [ ! -z \"\$event_type\" ]; then
        temp_dir=\"/tmp/webhook-socat-\$\$-\$(date +%s)\"
        mkdir -p \"\$temp_dir\"
        echo \"\$event_type\" > \"\$temp_dir/event_type\"
        echo \"\$payload\" > \"\$temp_dir/payload\"
        echo \"\$user_agent\" > \"\$temp_dir/user_agent\"
                 \"\$WEBHOOK_SCRIPT_PATH\" handle_webhook_request \"\$temp_dir\" &
      fi
      echo -e \"HTTP/1.1 200 OK\\r\\nContent-Type: application/json\\r\\nConnection: close\\r\\n\\r\\n{\\\"status\\\":\\\"ok\\\"}\"
    else
      echo -e \"HTTP/1.1 404 Not Found\\r\\nContent-Type: text/plain\\r\\nConnection: close\\r\\n\\r\\nNot Found\"
    fi
  '"
}

# Обработка webhook запроса
handle_webhook_request() {
  local temp_dir="$1"
  
  if [ -z "$temp_dir" ] || [ ! -d "$temp_dir" ]; then
    log_event "ERROR" "Некорректные данные webhook запроса"
    return 1
  fi
  
  local event_type=""
  local payload=""
  
  # Читаем сохраненные данные
  if [ -f "$temp_dir/event_type" ]; then
    event_type=$(cat "$temp_dir/event_type")
  fi
  
  if [ -f "$temp_dir/payload" ]; then
    payload=$(cat "$temp_dir/payload")
    log_event "DEBUG" "Payload файл существует, размер: $(wc -c < "$temp_dir/payload" 2>/dev/null) байт"
    
    # Проверяем, не является ли payload URL-encoded (для bash серверов)
    if [[ "$payload" == *"%"* ]] || [[ "$payload" == payload=* ]]; then
      log_event "DEBUG" "Payload в URL-encoded формате, декодируем..."
      
      # Убираем префикс payload= если есть
      if [[ "$payload" == payload=* ]]; then
        payload=${payload#payload=}
        log_event "DEBUG" "Убран префикс payload="
      fi
      
      # Декодируем URL-encoded payload
      if command -v python3 >/dev/null 2>&1; then
        payload=$(echo "$payload" | python3 -c "import sys, urllib.parse; print(urllib.parse.unquote_plus(sys.stdin.read().strip()))")
        log_event "DEBUG" "Payload декодирован через Python"
      else
        # Fallback декодирование через sed (основные символы)
        payload=$(echo "$payload" | sed 's/%22/"/g; s/%7B/{/g; s/%7D/}/g; s/%3A/:/g; s/%2C/,/g; s/%20/ /g; s/+/ /g')
        log_event "DEBUG" "Payload декодирован через sed (частично)"
      fi
      
      log_event "DEBUG" "Декодированный payload, первые 100 символов: $(echo "$payload" | head -c 100)"
    fi
  else
    log_event "ERROR" "Файл payload не найден: $temp_dir/payload"
  fi
  
  log_event "INFO" "Получен webhook событие: '$event_type'"
  
  # Дополнительная отладка содержимого
  if [ ! -z "$payload" ]; then
    log_event "DEBUG" "Payload загружен, первые 100 символов: $(echo "$payload" | head -c 100)"
  else
    log_event "ERROR" "Payload пуст после чтения из файла"
  fi
  
  # Обрабатываем разные типы событий
  log_event "DEBUG" "🎯 Определен тип события: '$event_type'"
  
  case "$event_type" in
    "ping")
      log_event "DEBUG" "📡 Обрабатываем ping событие"
      handle_ping_event "$payload"
      ;;
    "push")
      log_event "DEBUG" "🚀 Обрабатываем push событие"
      handle_push_event "$payload"
      ;;
    "pull_request")
      log_event "INFO" "📋 Получено событие pull_request (пропускаем)"
      ;;
    *)
      log_event "WARNING" "❓ Неизвестный тип события: '$event_type'"
      ;;
  esac
  
  log_event "DEBUG" "✅ Обработка webhook события '$event_type' завершена"
  
  # Очищаем временные файлы
  rm -rf "$temp_dir" 2>/dev/null
}

# Обработка ping события от GitHub
handle_ping_event() {
  local payload="$1"
  
  # Логируем полученный payload для отладки
  log_event "DEBUG" "Ping payload размер: $(echo "$payload" | wc -c) символов"
  
  # Проверяем валидность JSON
  if command -v jq >/dev/null 2>&1; then
    if echo "$payload" | jq . >/dev/null 2>&1; then
      log_event "DEBUG" "JSON валиден"
    else
      log_event "ERROR" "JSON невалиден или поврежден"
      # Показываем первые 200 символов для отладки
      local payload_sample=$(echo "$payload" | head -c 200)
      log_event "DEBUG" "Первые 200 символов payload: $payload_sample"
      return 1
    fi
  fi
  
  # Извлекаем информацию о репозитории из ping события
  local repo_name=""
  local repo_url=""
  local default_branch=""
  
  if command -v jq >/dev/null 2>&1; then
    # Используем jq если доступен
    repo_name=$(echo "$payload" | jq -r '.repository.name // empty' 2>/dev/null)
    repo_url=$(echo "$payload" | jq -r '.repository.clone_url // empty' 2>/dev/null)
    default_branch=$(echo "$payload" | jq -r '.repository.default_branch // empty' 2>/dev/null)
    
    log_event "DEBUG" "jq парсинг ping: repo_name='$repo_name', repo_url='$repo_url', default_branch='$default_branch'"
    
    # Если jq не смог извлечь данные, показываем структуру JSON для отладки
    if [ -z "$repo_name" ] && [ -z "$repo_url" ]; then
      log_event "DEBUG" "jq не извлек данные, анализируем структуру JSON..."
      # Показываем ключи верхнего уровня
      local top_keys=$(echo "$payload" | jq -r 'keys[]' 2>/dev/null | head -5 | tr '\n' ' ')
      log_event "DEBUG" "Ключи верхнего уровня JSON: '$top_keys'"
      
      # Проверяем есть ли вообще repository
      local has_repo=$(echo "$payload" | jq -r 'has("repository")' 2>/dev/null)
      log_event "DEBUG" "Есть ключ repository: '$has_repo'"
      
      # Если ключи пустые, попробуем простой поиск в тексте
      if [ -z "$top_keys" ]; then
        log_event "DEBUG" "jq не может прочитать структуру, пробуем простой текстовый поиск..."
        if echo "$payload" | grep -q '"repository"'; then
          log_event "DEBUG" "Найден текст 'repository' в payload"
        else
          log_event "DEBUG" "Текст 'repository' НЕ найден в payload"
        fi
      fi
      
      if [ "$has_repo" = "true" ]; then
        local repo_keys=$(echo "$payload" | jq -r '.repository | keys[]' 2>/dev/null | head -5 | tr '\n' ' ')
        log_event "DEBUG" "Ключи repository: $repo_keys"
      fi
    fi
  else
    # Улучшенный парсинг без jq для ping события
    # Используем более простые паттерны
    repo_name=$(echo "$payload" | grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
    repo_url=$(echo "$payload" | grep -o '"clone_url"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"clone_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
    default_branch=$(echo "$payload" | grep -o '"default_branch"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"default_branch"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
    
    log_event "DEBUG" "sed парсинг ping: repo_name='$repo_name', repo_url='$repo_url', default_branch='$default_branch'"
  fi
  
  # Если все еще пусто, попробуем альтернативные поля и методы
  if [ -z "$repo_name" ] || [ -z "$repo_url" ]; then
    log_event "DEBUG" "Основной парсинг не сработал, пробуем альтернативные методы..."
    
    if command -v jq >/dev/null 2>&1; then
      # Попробуем другие возможные пути в JSON
      if [ -z "$repo_name" ]; then
        # Пробуем full_name и извлекаем название репозитория
        local full_name=$(echo "$payload" | jq -r '.repository.full_name // empty' 2>/dev/null)
        if [ ! -z "$full_name" ]; then
          repo_name=$(echo "$full_name" | cut -d'/' -f2)
          log_event "DEBUG" "Извлечено repo_name из full_name: '$full_name' -> '$repo_name'"
        fi
      fi
      
      if [ -z "$repo_url" ]; then
        # Пробуем разные URL поля
        repo_url=$(echo "$payload" | jq -r '.repository.html_url // .repository.ssh_url // .repository.git_url // empty' 2>/dev/null)
        log_event "DEBUG" "Извлечен альтернативный URL: '$repo_url'"
        
        # Конвертируем в clone_url если нужно
        if [[ "$repo_url" == *"github.com"* ]] && [[ "$repo_url" != *".git" ]]; then
          repo_url="${repo_url}.git"
          log_event "DEBUG" "Сконвертирован URL в clone_url: '$repo_url'"
        fi
      fi
    else
      # Парсинг без jq для альтернативных полей
      if [ -z "$repo_name" ]; then
        local full_name=$(echo "$payload" | grep -o '"full_name"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"full_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
        if [ ! -z "$full_name" ]; then
          repo_name=$(echo "$full_name" | cut -d'/' -f2)
          log_event "DEBUG" "sed: извлечено repo_name из full_name: '$full_name' -> '$repo_name'"
        fi
      fi
      
      if [ -z "$repo_url" ]; then
        repo_url=$(echo "$payload" | grep -o '"html_url"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"html_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
        if [[ "$repo_url" == *"github.com"* ]] && [[ "$repo_url" != *".git" ]]; then
          repo_url="${repo_url}.git"
        fi
        log_event "DEBUG" "sed: извлечен альтернативный URL: '$repo_url'"
      fi
    fi
    
    log_event "DEBUG" "Результат альтернативного парсинга: repo_name='$repo_name', repo_url='$repo_url'"
    
    # Если все методы не сработали, попробуем грубый текстовый поиск
    if [ -z "$repo_name" ] && [ -z "$repo_url" ]; then
      log_event "DEBUG" "Все методы парсинга не сработали, пробуем грубый поиск..."
      
      # Ищем любые GitHub URL в тексте
      local found_urls=$(echo "$payload" | grep -o 'https://github\.com/[^"[:space:]]*' | head -3)
      if [ ! -z "$found_urls" ]; then
        log_event "DEBUG" "Найденные GitHub URLs: $found_urls"
        
        # Берем первый URL и пробуем извлечь данные
        repo_url=$(echo "$found_urls" | head -1)
        if [[ "$repo_url" != *".git" ]]; then
          repo_url="${repo_url}.git"
        fi
        
        # Извлекаем название репозитория из URL
        repo_name=$(basename "$repo_url" .git)
        
        log_event "DEBUG" "Извлечено через грубый поиск: repo_name='$repo_name', repo_url='$repo_url'"
      fi
    fi
  fi
  
  log_event "SUCCESS" "Webhook успешно настроен для репозитория '$repo_name' (ветка по умолчанию: '$default_branch')"
  
  # Проверяем, есть ли автоматизации для этого репозитория
  local matching_automations=0
  local found_automations=""
  
  if [ -f "$AUTOMATIONS_FILE" ] && [ ! -z "$repo_name" ]; then
    while IFS= read -r automation; do
      # Правильный парсинг через IFS
      local IFS='|'
      read -ra automation_info <<< "$automation"
      
      local automation_name="${automation_info[1]:-}"
      local automation_repo="${automation_info[2]:-}"
      
      log_event "DEBUG" "Проверяем автоматизацию '$automation_name' с repo='$automation_repo'"
      
      # Улучшенная логика сопоставления репозиториев
      local repo_match=false
      local match_reason=""
      
      # Извлекаем название репозитория для сравнения
      local automation_repo_name=$(basename "$automation_repo" .git)
      
      if [[ "$automation_repo" == "$repo_url" ]]; then
        repo_match=true
        match_reason="точное совпадение URL"
      elif [[ "$automation_repo" == *"$repo_name"* ]]; then
        repo_match=true
        match_reason="совпадение по названию репозитория"
      elif [[ "$repo_url" == *"$automation_repo_name"* ]]; then
        repo_match=true
        match_reason="совпадение по базовому названию"
      elif [[ "$automation_repo_name" == "$repo_name" ]]; then
        repo_match=true
        match_reason="совпадение базовых названий"
      fi
      
      if [ "$repo_match" = true ]; then
        ((matching_automations++))
        found_automations="$found_automations'$automation_name' "
        log_event "DEBUG" "Найдена автоматизация '$automation_name' ($match_reason)"
      fi
    done < "$AUTOMATIONS_FILE"
  fi
  
  if [ "$matching_automations" -gt 0 ]; then
    log_event "INFO" "Найдено $matching_automations автоматизаций для репозитория '$repo_name': $found_automations"
    log_event "INFO" "💡 Ping события не запускают автоматизацию. Сделайте push в ветку для тестирования."
    
    # Предлагаем протестировать автоматизацию
    log_event "INFO" "🧪 Для немедленного тестирования можно использовать функцию 'Тестировать автоматизацию' в меню"
  else
    if [ ! -z "$repo_name" ]; then
      log_event "WARNING" "Автоматизации для репозитория '$repo_name' не найдены"
      if [ -f "$AUTOMATIONS_FILE" ]; then
        local total_automations=$(wc -l < "$AUTOMATIONS_FILE" 2>/dev/null || echo "0")
        log_event "INFO" "Всего автоматизаций в системе: $total_automations"
      fi
    else
      log_event "ERROR" "Не удалось извлечь название репозитория из ping события"
    fi
  fi
}

# Обработка push события от GitHub
handle_push_event() {
  local payload="$1"
  
  log_event "DEBUG" "=== НАЧАЛО ОБРАБОТКИ PUSH СОБЫТИЯ ==="
  log_event "DEBUG" "Push payload размер: $(echo "$payload" | wc -c) символов"
  
  local branch=""
  local repo_url=""
  local repo_name=""
  local commit_message=""
  local pusher=""
  
  # Логируем полученный payload для отладки
  log_event "DEBUG" "Push payload размер: $(echo "$payload" | wc -c) символов"
  
  if command -v jq >/dev/null 2>&1; then
    # Используем jq если доступен
    branch=$(echo "$payload" | jq -r '.ref // empty' | sed 's|refs/heads/||')
    repo_url=$(echo "$payload" | jq -r '.repository.clone_url // empty')
    repo_name=$(echo "$payload" | jq -r '.repository.name // empty')
    commit_message=$(echo "$payload" | jq -r '.head_commit.message // empty' | head -c 100)
    pusher=$(echo "$payload" | jq -r '.pusher.name // empty')
    
    log_event "DEBUG" "jq парсинг: branch='$branch', repo_url='$repo_url', repo_name='$repo_name'"
  else
    # Улучшенный парсинг без jq
    branch=$(echo "$payload" | sed -n 's/.*"ref"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | sed 's|refs/heads/||')
    repo_url=$(echo "$payload" | sed -n 's/.*"clone_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    repo_name=$(echo "$payload" | sed -n 's/.*"repository"[^}]*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    commit_message=$(echo "$payload" | sed -n 's/.*"head_commit"[^}]*"message"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -c 100)
    pusher=$(echo "$payload" | sed -n 's/.*"pusher"[^}]*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    
    log_event "DEBUG" "sed парсинг: branch='$branch', repo_url='$repo_url', repo_name='$repo_name'"
  fi
  
  if [ -z "$branch" ] || [ -z "$repo_url" ]; then
    log_event "ERROR" "❌ Не удалось извлечь данные из push события"
    log_event "ERROR" "branch='$branch', repo_url='$repo_url', repo_name='$repo_name'"
    log_event "DEBUG" "Первые 500 символов payload: $(echo "$payload" | head -c 500)"
    return 1
  fi
  
  log_event "DEBUG" "✅ Данные push события извлечены успешно"
  
  log_event "INFO" "=== НОВОЕ PUSH СОБЫТИЕ ==="
  log_event "INFO" "Репозиторий: '$repo_name' ($repo_url)"
  log_event "INFO" "Ветка: '$branch'"
  log_event "INFO" "Автор: '$pusher'"
  log_event "INFO" "Коммит: '$commit_message'"
  
  local automations_executed=0
  
  # Ищем подходящие автоматизации
  log_event "DEBUG" "🔍 Начинаем поиск автоматизаций в файле: $AUTOMATIONS_FILE"
  
  if [ -f "$AUTOMATIONS_FILE" ]; then
    local total_lines=$(wc -l < "$AUTOMATIONS_FILE" 2>/dev/null || echo "0")
    log_event "DEBUG" "Файл автоматизаций найден, строк: $total_lines"
    
    local line_number=0
    while IFS= read -r automation; do
      ((line_number++))
      
      # Пропускаем пустые строки
      if [ -z "$automation" ]; then
        log_event "DEBUG" "Строка #$line_number: пустая, пропускаем"
        continue
      fi
      
      log_event "DEBUG" "Строка #$line_number: обрабатываем автоматизацию"
      # Правильный парсинг через IFS
      local IFS='|'
      read -ra automation_info <<< "$automation"
      
      local automation_name="${automation_info[1]:-}"
      local automation_repo="${automation_info[2]:-}"
      local automation_branch="${automation_info[4]:-}"
      local automation_commands="${automation_info[5]:-}"
      local automation_is_private="${automation_info[7]:-}"
      local automation_encrypted_creds="${automation_info[8]:-}"
      
      log_event "DEBUG" "  📋 Автоматизация: name='$automation_name', repo='$automation_repo', branch='$automation_branch'"
      
      # Проверяем соответствие репозитория и ветки
      local repo_match=false
      local match_reason=""
      
      # Извлекаем название репозитория для сравнения
      local automation_repo_name=$(basename "$automation_repo" .git)
      
      if [[ "$automation_repo" == "$repo_url" ]]; then
        repo_match=true
        match_reason="точное совпадение URL"
      elif [[ "$automation_repo" == *"$repo_name"* ]]; then
        repo_match=true
        match_reason="совпадение по названию репозитория"
      elif [[ "$repo_url" == *"$automation_repo_name"* ]]; then
        repo_match=true
        match_reason="совпадение по базовому названию"
      fi
      
      log_event "DEBUG" "  🔍 Сопоставление: repo_match=$repo_match ($match_reason), branch_match=${automation_branch}==${branch}"
      
      if [ "$repo_match" = true ] && [[ "$automation_branch" == "$branch" ]]; then
        log_event "DEBUG" "  ✅ ПОЛНОЕ СОВПАДЕНИЕ найдено!"
        log_event "INFO" "🚀 ЗАПУСК автоматизации '$automation_name' для ветки '$branch'"
        
        # Подготавливаем команды с учетными данными если это приватный репозиторий
        log_event "DEBUG" "  🔐 Подготовка команд: is_private='$automation_is_private', has_creds=$([ ! -z "$automation_encrypted_creds" ] && echo "yes" || echo "no")"
        
        local final_commands="$automation_commands"
        if [ "$automation_is_private" = "yes" ] && [ ! -z "$automation_encrypted_creds" ]; then
          log_event "DEBUG" "  🔓 Расшифровка учетных данных для приватного репозитория"
          log_event "DEBUG" "  Зашифрованные данные (первые 50 символов): $(echo "$automation_encrypted_creds" | head -c 50)..."
          
          # Расшифровываем учетные данные (обратный порядок шифрования: ROT13, потом base64)
          local decrypted_creds=$(echo "$automation_encrypted_creds" | tr 'A-Za-z' 'N-ZA-Mn-za-m' | base64 -d 2>/dev/null)
          
          # Дополнительная проверка - попробуем обратный порядок, если первый не сработал
          if [ -z "$decrypted_creds" ] || [[ "$decrypted_creds" == *$'\0'* ]]; then
            log_event "DEBUG" "  Первый метод расшифровки не сработал, пробуем альтернативный"
            decrypted_creds=$(echo "$automation_encrypted_creds" | base64 -d 2>/dev/null | tr 'A-Za-z' 'N-ZA-Mn-za-m' 2>/dev/null)
          fi
          
          # Проверяем корректность расшифрованных данных
          if [ ! -z "$decrypted_creds" ]; then
            log_event "DEBUG" "  Расшифрованные данные (первые 20 символов): $(echo "$decrypted_creds" | head -c 20)..."
            
            # Проверяем, что данные выглядят как валидные учетные данные
            if [[ "$decrypted_creds" =~ ^[a-zA-Z0-9_-]+:ghp_[a-zA-Z0-9_-]+$ ]]; then
              log_event "DEBUG" "  ✅ Учетные данные валидны (длина: $(echo "$decrypted_creds" | wc -c) символов)"
            else
              log_event "ERROR" "  ❌ Расшифрованные данные повреждены или имеют неверный формат"
              log_event "DEBUG" "  Данные: '$decrypted_creds'"
              decrypted_creds=""  # Сбрасываем для использования без аутентификации
            fi
          fi
          
          if [ ! -z "$decrypted_creds" ]; then
            # Создаем правильный URL с аутентификацией (хардкод для исправления)
            local auth_url="https://$decrypted_creds@github.com/KUZKO-LTD/tg-manager.git"
            log_event "DEBUG" "  Сформированный auth URL: $auth_url"
            
            # Заменяем все URL в командах, убирая дублирование
            final_commands=$(echo "$automation_commands" | sed -E "s|https://[^[:space:]'\"]+|$auth_url|g")
            
            # Если нет команды set-url, добавляем ее
            if [[ "$final_commands" != *"git remote set-url origin"* ]]; then
              final_commands=$(echo "$final_commands" | sed "s|git pull origin|git remote set-url origin '$auth_url' \&\& git pull origin|g")
            fi
            log_event "DEBUG" "  🔧 Команды модифицированы для приватного репозитория"
          else
            log_event "ERROR" "  ❌ Не удалось расшифровать учетные данные"
          fi
        else
          log_event "DEBUG" "  📝 Используем команды без модификации (публичный репозиторий или поврежденные учетные данные)"
          # Исправляем дублированный URL для публичного доступа
          final_commands=$(echo "$automation_commands" | sed -E "s|https://[^[:space:]'\"]+|https://github.com/KUZKO-LTD/tg-manager.git|g")
        fi
        
        log_event "DEBUG" "  💻 Финальные команды: $final_commands"
        
        # Выполняем команды в фоне с логированием
        log_event "INFO" "  🚀 НАЧИНАЕМ ВЫПОЛНЕНИЕ команд..."
        
        # Выполняем команды синхронно для лучшего контроля и логирования
        log_event "INFO" "=== ВЫПОЛНЕНИЕ АВТОМАТИЗАЦИИ '$automation_name' ==="
        log_event "INFO" "Команды: $final_commands"
        
        # Создаем временный файл для вывода команд
        local temp_output=$(mktemp)
        
        # Выполняем команды с подробным логированием
        (
          set -e  # Останавливаться при ошибке
          cd / # Переходим в корень для безопасности
          
          # Логируем начало выполнения
          echo "[$(date '+%Y-%m-%d %H:%M:%S')] СТАРТ: Выполнение автоматизации '$automation_name'"
          echo "[$(date '+%Y-%m-%d %H:%M:%S')] КОМАНДЫ: $final_commands"
          echo "[$(date '+%Y-%m-%d %H:%M:%S')] ---"
          
          # Выполняем команды
          eval "$final_commands" 2>&1
          
          echo "[$(date '+%Y-%m-%d %H:%M:%S')] ---"
          echo "[$(date '+%Y-%m-%d %H:%M:%S')] ФИНИШ: Автоматизация '$automation_name' завершена успешно"
        ) > "$temp_output" 2>&1
        
        local exit_code=$?
        
        # Добавляем вывод в основной лог
        cat "$temp_output" >> "$WEBHOOK_LOG"
        
        # Логируем результат
        if [ $exit_code -eq 0 ]; then
          log_event "SUCCESS" "✅ Автоматизация '$automation_name' выполнена успешно (exit code: 0)"
        else
          log_event "ERROR" "❌ Ошибка при выполнении автоматизации '$automation_name' (exit code: $exit_code)"
          # Показываем последние строки вывода для диагностики
          log_event "ERROR" "Последние строки вывода: $(tail -n 5 "$temp_output" | tr '\n' '; ')"
        fi
        
        # Очищаем временный файл
        rm -f "$temp_output"
        
        log_event "INFO" "=== ЗАВЕРШЕНИЕ АВТОМАТИЗАЦИИ '$automation_name' ==="
        
        ((automations_executed++))
      else
        log_event "DEBUG" "  ❌ Автоматизация '$automation_name' НЕ подходит (repo_match=$repo_match, branch_match=${automation_branch}==${branch})"
      fi
    done < "$AUTOMATIONS_FILE"
    
    log_event "DEBUG" "📊 Обработано строк: $line_number"
  else
    log_event "ERROR" "❌ Файл автоматизаций не найден: $AUTOMATIONS_FILE"
  fi
  
  log_event "DEBUG" "🎯 Результат поиска: найдено $automations_executed подходящих автоматизаций"
  
  if [ "$automations_executed" -eq 0 ]; then
    log_event "WARNING" "⚠️  Не найдено автоматизаций для ветки '$branch' репозитория '$repo_name'"
    log_event "INFO" "💡 Проверьте настройки автоматизации в меню 'Управление автоматизациями'"
  else
    log_event "INFO" "🚀 Запущено $automations_executed автоматизаций для push в '$branch'"
  fi
  
  log_event "DEBUG" "=== ЗАВЕРШЕНИЕ ОБРАБОТКИ PUSH СОБЫТИЯ ==="
}

# Принудительное тестирование автоматизации
test_automation_manual() {
  clear_screen
  echo -e "${BOLD}${CYAN}==============================================${NC}"
  echo -e "${BOLD}${CYAN}         ТЕСТИРОВАНИЕ АВТОМАТИЗАЦИИ         ${NC}"
  echo -e "${BOLD}${CYAN}==============================================${NC}"
  echo ""
  
  if [ ! -f "$AUTOMATIONS_FILE" ] || [ ! -s "$AUTOMATIONS_FILE" ]; then
    echo -e "${RED}Нет настроенных автоматизаций для тестирования.${NC}"
    sleep 2
    return 1
  fi
  
  echo -e "${YELLOW}Доступные автоматизации:${NC}"
  echo ""
  
  local automation_count=0
  local automation_names=()
  local automation_ids=()
  
  while IFS='|' read -r id name repo path branch commands date is_private encrypted_creds; do
    if [ ! -z "$id" ] && [ ! -z "$name" ]; then
      ((automation_count++))
      automation_names+=("$name")
      automation_ids+=("$id")
      echo -e "${CYAN}$automation_count.${NC} $name (Репозиторий: $(basename "$repo" .git))"
    fi
  done < "$AUTOMATIONS_FILE"
  
  if [ "$automation_count" -eq 0 ]; then
    echo -e "${RED}Нет корректных автоматизаций для тестирования.${NC}"
    sleep 2
    return 1
  fi
  
  echo ""
  echo -n -e "${GREEN}Выберите автоматизацию для тестирования (1-$automation_count): ${NC}"
  read selected_index
  
  if ! [[ "$selected_index" =~ ^[0-9]+$ ]] || [ "$selected_index" -lt 1 ] || [ "$selected_index" -gt "$automation_count" ]; then
    echo -e "${RED}Некорректный выбор.${NC}"
    sleep 2
    return 1
  fi
  
  # Получаем выбранную автоматизацию (индексы массива начинаются с 0)
  local selected_name="${automation_names[$((selected_index-1))]}"
  local selected_id="${automation_ids[$((selected_index-1))]}"
  
  echo ""
  echo -e "${YELLOW}Тестируем автоматизацию: ${BOLD}$selected_name${NC}"
  echo ""
  echo -e "${RED}⚠️  ВНИМАНИЕ: Это выполнит реальные команды автоматизации!${NC}"
  echo -n -e "${GREEN}Продолжить? (y/N): ${NC}"
  read confirm
  
  if [[ ! "$confirm" =~ ^[yY]$ ]]; then
    echo -e "${YELLOW}Тестирование отменено.${NC}"
    sleep 1
    return 1
  fi
  
  echo ""
  echo -e "${CYAN}🚀 Запускаем тестирование автоматизации '$selected_name'...${NC}"
  
  # Находим и выполняем выбранную автоматизацию
  while IFS='|' read -r id name repo path branch commands date is_private encrypted_creds; do
    if [ "$id" = "$selected_id" ]; then
      log_event "INFO" "🧪 ПРИНУДИТЕЛЬНОЕ ТЕСТИРОВАНИЕ автоматизации '$name' (ID: $id)"
      
      # Подготавливаем команды с учетными данными если это приватный репозиторий
      local final_commands="$commands"
      if [ "$is_private" = "yes" ] && [ ! -z "$encrypted_creds" ]; then
        log_event "DEBUG" "🔓 Расшифровка учетных данных для приватного репозитория"
        log_event "DEBUG" "Зашифрованные данные (первые 50 символов): $(echo "$encrypted_creds" | head -c 50)..."
        
        # Расшифровываем учетные данные (обратный порядок шифрования: ROT13, потом base64)
        local decrypted_creds=$(echo "$encrypted_creds" | tr 'A-Za-z' 'N-ZA-Mn-za-m' | base64 -d 2>/dev/null)
        
        # Дополнительная проверка - попробуем обратный порядок, если первый не сработал
        if [ -z "$decrypted_creds" ] || [[ "$decrypted_creds" == *$'\0'* ]]; then
          log_event "DEBUG" "Первый метод расшифровки не сработал, пробуем альтернативный"
          decrypted_creds=$(echo "$encrypted_creds" | base64 -d 2>/dev/null | tr 'A-Za-z' 'N-ZA-Mn-za-m' 2>/dev/null)
        fi
        
        # Проверяем корректность расшифрованных данных
        if [ ! -z "$decrypted_creds" ]; then
          log_event "DEBUG" "Расшифрованные данные (первые 20 символов): $(echo "$decrypted_creds" | head -c 20)..."
          
          # Проверяем, что данные выглядят как валидные учетные данные
          if [[ "$decrypted_creds" =~ ^[a-zA-Z0-9_-]+:ghp_[a-zA-Z0-9_-]+$ ]]; then
            log_event "DEBUG" "✅ Учетные данные валидны (длина: $(echo "$decrypted_creds" | wc -c) символов)"
          else
            log_event "ERROR" "❌ Расшифрованные данные повреждены или имеют неверный формат"
            log_event "DEBUG" "Данные: '$decrypted_creds'"
            decrypted_creds=""  # Сбрасываем для использования без аутентификации
          fi
        fi
        
        if [ ! -z "$decrypted_creds" ]; then
          # Создаем правильный URL с аутентификацией (хардкод для исправления)
          local auth_url="https://$decrypted_creds@github.com/KUZKO-LTD/tg-manager.git"
          log_event "DEBUG" "Сформированный auth URL: $auth_url"
          
          # Заменяем все URL в командах, убирая дублирование
          final_commands=$(echo "$commands" | sed -E "s|https://[^[:space:]'\"]+|$auth_url|g")
          
          # Если нет команды set-url, добавляем ее
          if [[ "$final_commands" != *"git remote set-url origin"* ]]; then
            final_commands=$(echo "$commands" | sed "s|git pull origin|git remote set-url origin '$auth_url' \&\& git pull origin|g")
          fi
          log_event "DEBUG" "🔧 Команды модифицированы для приватного репозитория"
        else
          log_event "ERROR" "❌ Не удалось расшифровать учетные данные"
          # Исправляем дублированный URL для публичного доступа
          final_commands=$(echo "$commands" | sed -E "s|https://[^[:space:]'\"]+|https://github.com/KUZKO-LTD/tg-manager.git|g")
        fi
      else
        log_event "DEBUG" "📝 Используем команды без модификации (публичный репозиторий)"
        # Исправляем дублированный URL для публичного доступа
        final_commands=$(echo "$commands" | sed -E "s|https://[^[:space:]'\"]+|https://github.com/KUZKO-LTD/tg-manager.git|g")
      fi
      
      # Выполняем команды
      log_event "INFO" "=== ТЕСТОВОЕ ВЫПОЛНЕНИЕ АВТОМАТИЗАЦИИ '$name' ==="
      log_event "INFO" "Команды: $final_commands"
      
      # Создаем временный файл для вывода команд
      local temp_output=$(mktemp)
      
      echo -e "${CYAN}Выполняем команды...${NC}"
      
      # Выполняем команды с подробным логированием
      (
        set -e
        cd /
        
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ТЕСТОВЫЙ СТАРТ: Выполнение автоматизации '$name'"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] КОМАНДЫ: $final_commands"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ---"
        
        eval "$final_commands" 2>&1
        
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ---"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ТЕСТОВЫЙ ФИНИШ: Автоматизация '$name' завершена успешно"
      ) > "$temp_output" 2>&1
      
      local exit_code=$?
      
      # Показываем вывод пользователю
      echo ""
      echo -e "${YELLOW}--- ВЫВОД КОМАНД ---${NC}"
      cat "$temp_output"
      echo -e "${YELLOW}--- КОНЕЦ ВЫВОДА ---${NC}"
      echo ""
      
      # Добавляем вывод в основной лог
      cat "$temp_output" >> "$WEBHOOK_LOG"
      
      # Логируем результат
      if [ $exit_code -eq 0 ]; then
        log_event "SUCCESS" "✅ ТЕСТОВОЕ выполнение автоматизации '$name' завершено успешно (exit code: 0)"
        echo -e "${GREEN}✅ Автоматизация выполнена успешно!${NC}"
      else
        log_event "ERROR" "❌ Ошибка при ТЕСТОВОМ выполнении автоматизации '$name' (exit code: $exit_code)"
        echo -e "${RED}❌ Ошибка при выполнении автоматизации! (exit code: $exit_code)${NC}"
      fi
      
      # Очищаем временный файл
      rm -f "$temp_output"
      
      log_event "INFO" "=== ЗАВЕРШЕНИЕ ТЕСТОВОГО ВЫПОЛНЕНИЯ '$name' ==="
      
      break
    fi
  done < "$AUTOMATIONS_FILE"
  
  echo ""
  echo -n -e "${GREEN}Нажмите Enter для продолжения...${NC}"
  read
}

# Эмуляция push события для тестирования
simulate_push_event() {
  clear_screen
  echo -e "${BOLD}${CYAN}==============================================${NC}"
  echo -e "${BOLD}${CYAN}         ЭМУЛЯЦИЯ PUSH СОБЫТИЯ              ${NC}"
  echo -e "${BOLD}${CYAN}==============================================${NC}"
  echo ""
  
  if [ ! -f "$AUTOMATIONS_FILE" ] || [ ! -s "$AUTOMATIONS_FILE" ]; then
    echo -e "${RED}Нет настроенных автоматизаций для тестирования.${NC}"
    sleep 2
    return 1
  fi
  
  echo -e "${YELLOW}Доступные автоматизации:${NC}"
  echo ""
  
  local automation_count=0
  local automation_repos=()
  local automation_branches=()
  local automation_names=()
  
  while IFS='|' read -r id name repo path branch commands date is_private encrypted_creds; do
    if [ ! -z "$id" ] && [ ! -z "$name" ]; then
      ((automation_count++))
      automation_names+=("$name")
      automation_repos+=("$repo")
      automation_branches+=("$branch")
      echo -e "${CYAN}$automation_count.${NC} $name - $(basename "$repo" .git) (ветка: $branch)"
    fi
  done < "$AUTOMATIONS_FILE"
  
  if [ "$automation_count" -eq 0 ]; then
    echo -e "${RED}Нет корректных автоматизаций для тестирования.${NC}"
    sleep 2
    return 1
  fi
  
  echo ""
  echo -n -e "${GREEN}Выберите автоматизацию для эмуляции push (1-$automation_count): ${NC}"
  read selected_index
  
  if ! [[ "$selected_index" =~ ^[0-9]+$ ]] || [ "$selected_index" -lt 1 ] || [ "$selected_index" -gt "$automation_count" ]; then
    echo -e "${RED}Некорректный выбор.${NC}"
    sleep 2
    return 1
  fi
  
  # Получаем выбранную автоматизацию (индексы массива начинаются с 0)
  local selected_name="${automation_names[$((selected_index-1))]}"
  local selected_repo="${automation_repos[$((selected_index-1))]}"
  local selected_branch="${automation_branches[$((selected_index-1))]}"
  
  echo ""
  echo -e "${YELLOW}Эмулируем push для:${NC}"
  echo -e "  Автоматизация: ${BOLD}$selected_name${NC}"
  echo -e "  Репозиторий: ${BOLD}$(basename "$selected_repo" .git)${NC}"
  echo -e "  Ветка: ${BOLD}$selected_branch${NC}"
  echo ""
  echo -e "${RED}⚠️  ВНИМАНИЕ: Это выполнит реальные команды автоматизации!${NC}"
  echo -n -e "${GREEN}Продолжить? (y/N): ${NC}"
  read confirm
  
  if [[ ! "$confirm" =~ ^[yY]$ ]]; then
    echo -e "${YELLOW}Эмуляция отменена.${NC}"
    sleep 1
    return 1
  fi
  
  echo ""
  echo -e "${CYAN}🚀 Создаем эмулированное push событие...${NC}"
  
  # Создаем фиктивный payload для push события
  local repo_name=$(basename "$selected_repo" .git)
  local push_payload="{
  \"ref\": \"refs/heads/$selected_branch\",
  \"repository\": {
    \"name\": \"$repo_name\",
    \"clone_url\": \"$selected_repo\"
  },
  \"pusher\": {
    \"name\": \"test-automation\"
  },
  \"head_commit\": {
    \"message\": \"Тестовый коммит для автоматизации\"
  }
}"
  
  log_event "INFO" "🧪 ЭМУЛЯЦИЯ PUSH СОБЫТИЯ для автоматизации '$selected_name'"
  log_event "DEBUG" "Эмулированный payload: $push_payload"
  
  echo -e "${CYAN}Обрабатываем эмулированное push событие...${NC}"
  
  # Вызываем обработчик push события
  handle_push_event "$push_payload"
  
  echo ""
  echo -e "${GREEN}✅ Эмуляция push события завершена.${NC}"
  echo -e "${YELLOW}Проверьте логи для получения подробной информации о выполнении.${NC}"
  echo ""
  echo -n -e "${GREEN}Нажмите Enter для продолжения...${NC}"
  read
}

# Просмотр логов
view_logs() {
  clear_screen
  echo -e "${BOLD}${CYAN}==============================================${NC}"
  echo -e "${BOLD}${CYAN}            ЖУРНАЛ СОБЫТИЙ                   ${NC}"
  echo -e "${BOLD}${CYAN}==============================================${NC}"
  echo ""
  
  if [ ! -f "$WEBHOOK_LOG" ] || [ ! -s "$WEBHOOK_LOG" ]; then
    echo -e "${RED}Журнал событий пуст.${NC}"
    sleep 2
    return 1
  fi
  
  echo -e "${YELLOW}Последние 50 записей:${NC}"
  echo -e "${YELLOW}---------------------------------------------${NC}"
  echo ""
  
  tail -n 50 "$WEBHOOK_LOG"
  
  echo ""
  echo -e "${YELLOW}---------------------------------------------${NC}"
  echo -e "${YELLOW}Опции просмотра журнала:${NC}"
  echo -e "${CYAN}1.${NC} Просмотреть полный журнал"
  echo -e "${CYAN}2.${NC} Очистить журнал"
  echo -e "${CYAN}3.${NC} Вернуться назад"
  echo ""
  echo -n -e "${GREEN}Ваш выбор (1-3): ${NC}"
  read log_option
  
  case $log_option in
    1)
      less "$WEBHOOK_LOG"
      ;;
    2)
      echo -e "${RED}${BOLD}Вы уверены, что хотите очистить журнал? (y/n): ${NC}"
      read confirm_clear
      
      if [[ "$confirm_clear" == "y" || "$confirm_clear" == "Y" ]]; then
        > "$WEBHOOK_LOG"
        echo -e "${GREEN}Журнал очищен.${NC}"
        log_event "INFO" "Журнал событий очищен"
        sleep 1
      fi
      ;;
  esac
}

# Настройки системы
manage_settings() {
  while true; do
    clear_screen
    echo -e "${BOLD}${CYAN}==============================================${NC}"
    echo -e "${BOLD}${CYAN}             НАСТРОЙКИ СИСТЕМЫ               ${NC}"
    echo -e "${BOLD}${CYAN}==============================================${NC}"
    echo ""
    
    echo -e "${YELLOW}Текущие настройки:${NC}"
    echo -e "${YELLOW}---------------------------------------------${NC}"
    echo -e "${BOLD}Порт webhook:${NC} $WEBHOOK_PORT"
    echo -e "${BOLD}Webhook secret:${NC} ${WEBHOOK_SECRET:-'Не установлен'}"
    echo -e "${BOLD}Уведомления:${NC} ${NOTIFICATIONS_ENABLED}"
    echo -e "${BOLD}Telegram токен:${NC} ${TELEGRAM_TOKEN:0:10}...${TELEGRAM_TOKEN:(-5)}"
    echo -e "${BOLD}Telegram Chat ID:${NC} ${TELEGRAM_CHAT_ID:-'Не указан'}"
    echo -e "${YELLOW}---------------------------------------------${NC}"
    echo ""
    
    echo -e "${YELLOW}Выберите настройку для изменения:${NC}"
    echo -e "${CYAN}1.${NC} Изменить порт webhook"
    echo -e "${CYAN}2.${NC} Настроить webhook secret"
    echo -e "${CYAN}3.${NC} Настроить уведомления"
    echo -e "${CYAN}4.${NC} Вернуться в главное меню"
    echo ""
    echo -n -e "${GREEN}Ваш выбор (1-4): ${NC}"
    read settings_choice
    
    case $settings_choice in
      1)
        echo ""
        echo -n -e "${GREEN}Введите новый порт webhook (текущий: $WEBHOOK_PORT): ${NC}"
        read new_port
        
        if [[ "$new_port" =~ ^[0-9]+$ ]] && [ "$new_port" -ge 1024 ] && [ "$new_port" -le 65535 ]; then
          WEBHOOK_PORT="$new_port"
          save_config
          echo -e "${GREEN}Порт webhook изменен на $WEBHOOK_PORT.${NC}"
        else
          echo -e "${RED}Некорректный порт! Используйте число от 1024 до 65535.${NC}"
        fi
        sleep 2
        ;;
      2)
        echo ""
        echo -n -e "${GREEN}Введите webhook secret: ${NC}"
        read -s new_secret
        echo ""
        
        WEBHOOK_SECRET="$new_secret"
        save_config
        echo -e "${GREEN}Webhook secret установлен.${NC}"
        sleep 2
        ;;
      3)
        manage_notification_settings
        ;;
      4)
        return 0
        ;;
      *)
        echo -e "${RED}Некорректный выбор!${NC}"
        sleep 1
        ;;
    esac
  done
}

# Настройки уведомлений
manage_notification_settings() {
  while true; do
    clear_screen
    echo -e "${BOLD}${CYAN}==============================================${NC}"
    echo -e "${BOLD}${CYAN}          НАСТРОЙКИ УВЕДОМЛЕНИЙ              ${NC}"
    echo -e "${BOLD}${CYAN}==============================================${NC}"
    echo ""
    
    echo -e "${YELLOW}Выберите действие:${NC}"
    echo -e "${CYAN}1.${NC} Включить/выключить уведомления"
    echo -e "${CYAN}2.${NC} Настроить Telegram токен"
    echo -e "${CYAN}3.${NC} Настроить Telegram Chat ID"
    echo -e "${CYAN}4.${NC} Протестировать уведомления"
    echo -e "${CYAN}5.${NC} Вернуться назад"
    echo ""
    echo -n -e "${GREEN}Ваш выбор (1-5): ${NC}"
    read notif_choice
    
    case $notif_choice in
      1)
        if [ "$NOTIFICATIONS_ENABLED" == "true" ]; then
          NOTIFICATIONS_ENABLED="false"
          echo -e "${YELLOW}Уведомления отключены.${NC}"
        else
          NOTIFICATIONS_ENABLED="true"
          echo -e "${GREEN}Уведомления включены.${NC}"
        fi
        save_config
        sleep 2
        ;;
      2)
        echo ""
        echo -n -e "${GREEN}Введите Telegram токен: ${NC}"
        read new_token
        
        TELEGRAM_TOKEN="$new_token"
        save_config
        echo -e "${GREEN}Telegram токен обновлен.${NC}"
        sleep 2
        ;;
      3)
        echo ""
        echo -n -e "${GREEN}Введите Telegram Chat ID: ${NC}"
        read new_chat_id
        
        TELEGRAM_CHAT_ID="$new_chat_id"
        save_config
        echo -e "${GREEN}Telegram Chat ID обновлен.${NC}"
        sleep 2
        ;;
      4)
        echo -e "${YELLOW}Отправка тестового уведомления...${NC}"
        send_notification "INFO" "Тестовое уведомление из системы webhook автоматизации"
        echo -e "${GREEN}Тестовое уведомление отправлено.${NC}"
        sleep 2
        ;;
      5)
        return 0
        ;;
      *)
        echo -e "${RED}Некорректный выбор!${NC}"
        sleep 1
        ;;
    esac
  done
}

# Сохранение конфигурации
save_config() {
  cat > "$CONFIG_FILE" << EOF
WEBHOOK_PORT=$WEBHOOK_PORT
WEBHOOK_SECRET=$WEBHOOK_SECRET
NOTIFICATIONS_ENABLED=$NOTIFICATIONS_ENABLED
TELEGRAM_TOKEN=$TELEGRAM_TOKEN
TELEGRAM_CHAT_ID=$TELEGRAM_CHAT_ID
DEFAULT_BRANCH=$DEFAULT_BRANCH
EOF
}

# Очистка поврежденных данных
clean_corrupted_data() {
  clear_screen
  echo -e "${BOLD}${CYAN}==============================================${NC}"
  echo -e "${BOLD}${CYAN}      ОЧИСТКА ПОВРЕЖДЕННЫХ ДАННЫХ           ${NC}"
  echo -e "${BOLD}${CYAN}==============================================${NC}"
  echo ""
  
  if [ ! -f "$AUTOMATIONS_FILE" ] || [ ! -s "$AUTOMATIONS_FILE" ]; then
    echo -e "${YELLOW}Файл автоматизаций пуст или не существует.${NC}"
    sleep 2
    return 0
  fi
  
  echo -e "${YELLOW}Анализ файла автоматизаций...${NC}"
  echo ""
  
  local total_lines=0
  local corrupted_lines=0
  local valid_lines=0
  
  while IFS= read -r line; do
    ((total_lines++))
    
    # Проверяем количество полей
    local field_count=$(echo "$line" | tr '|' '\n' | wc -l)
    
    if [ "$field_count" -lt 6 ]; then
      echo -e "${RED}❌ Поврежденная запись #${total_lines}: ${line::80}...${NC}"
      ((corrupted_lines++))
    else
      ((valid_lines++))
    fi
  done < "$AUTOMATIONS_FILE"
  
  echo ""
  echo -e "${YELLOW}Результаты анализа:${NC}"
  echo -e "${YELLOW}---------------------------------------------${NC}"
  echo -e "${BOLD}Всего записей:${NC} $total_lines"
  echo -e "${BOLD}Корректных записей:${NC} ${GREEN}$valid_lines${NC}"
  echo -e "${BOLD}Поврежденных записей:${NC} ${RED}$corrupted_lines${NC}"
  echo -e "${YELLOW}---------------------------------------------${NC}"
  
  if [ "$corrupted_lines" -eq 0 ]; then
    echo -e "${GREEN}✅ Все данные корректны!${NC}"
    sleep 2
    return 0
  fi
  
  echo ""
  echo -e "${YELLOW}Выберите действие:${NC}"
  echo -e "${CYAN}1.${NC} Удалить только поврежденные записи"
  echo -e "${CYAN}2.${NC} Очистить весь файл автоматизаций"
  echo -e "${CYAN}3.${NC} Создать резервную копию и очистить"
  echo -e "${PURPLE}4.${NC} 🔧 Исправить дублированные URL"
  echo -e "${CYAN}5.${NC} Отмена"
  echo ""
  echo -n -e "${GREEN}Ваш выбор (1-5): ${NC}"
  read clean_choice
  
  case $clean_choice in
    1)
      echo -e "${YELLOW}Удаление поврежденных записей...${NC}"
      local temp_file=$(mktemp)
      local removed_count=0
      
      while IFS= read -r line; do
        local field_count=$(echo "$line" | tr '|' '\n' | wc -l)
        
        if [ "$field_count" -ge 6 ]; then
          echo "$line" >> "$temp_file"
        else
          ((removed_count++))
        fi
      done < "$AUTOMATIONS_FILE"
      
      mv "$temp_file" "$AUTOMATIONS_FILE"
      echo -e "${GREEN}✅ Удалено $removed_count поврежденных записей.${NC}"
      log_event "INFO" "Очистка поврежденных данных: удалено $removed_count записей"
      ;;
    2)
      echo -e "${RED}${BOLD}Вы уверены, что хотите удалить ВСЕ автоматизации? (y/n): ${NC}"
      read confirm_clear_all
      
      if [[ "$confirm_clear_all" == "y" || "$confirm_clear_all" == "Y" ]]; then
        > "$AUTOMATIONS_FILE"
        echo -e "${GREEN}✅ Все автоматизации удалены.${NC}"
        log_event "INFO" "Полная очистка файла автоматизаций"
      else
        echo -e "${YELLOW}Операция отменена.${NC}"
      fi
      ;;
    3)
      local backup_file="${AUTOMATIONS_FILE}.backup.$(date +%s)"
      cp "$AUTOMATIONS_FILE" "$backup_file"
      > "$AUTOMATIONS_FILE"
      echo -e "${GREEN}✅ Создана резервная копия: $backup_file${NC}"
      echo -e "${GREEN}✅ Файл автоматизаций очищен.${NC}"
      log_event "INFO" "Создана резервная копия и очищен файл автоматизаций"
      ;;
    4)
      repair_automation_urls
      ;;
    5)
      echo -e "${YELLOW}Операция отменена.${NC}"
      ;;
    *)
      echo -e "${RED}Некорректный выбор!${NC}"
      ;;
  esac
  
  sleep 2
}

# Главное меню
show_main_menu() {
  while true; do
    clear_screen
    echo -e "${BOLD}${CYAN}==============================================${NC}"
    echo -e "${BOLD}${CYAN}          WEBHOOK АВТОМАТИЗАЦИЯ              ${NC}"
    echo -e "${BOLD}${CYAN}==============================================${NC}"
    echo ""
    
    # Проверяем статус webhook сервера
    local server_status=""
    local server_type=""
    
    if pgrep -f "python3.*webhook_server.*${WEBHOOK_PORT}" > /dev/null; then
      server_status="${GREEN}Запущен${NC}"
      server_type=" (Python)"
    elif pgrep -f "socat.*${WEBHOOK_PORT}" > /dev/null; then
      server_status="${GREEN}Запущен${NC}"
      server_type=" (Socat)"
    elif pgrep -f "nc.*${WEBHOOK_PORT}\|webhook-server" > /dev/null; then
      server_status="${GREEN}Запущен${NC}"
      server_type=" (Netcat)"
    else
      server_status="${RED}Остановлен${NC}"
      server_type=""
    fi
    
    echo -e "${YELLOW}Статус webhook сервера: $server_status$server_type${NC}"
    echo -e "${YELLOW}---------------------------------------------${NC}"
    echo ""
    
    echo -e "${YELLOW}Выберите действие:${NC}"
    echo -e "${CYAN}1.${NC} Создать новую автоматизацию"
    echo -e "${CYAN}2.${NC} Управление автоматизациями"
    echo -e "${CYAN}3.${NC} Управление webhook сервером"
    echo -e "${CYAN}4.${NC} Просмотр журнала событий"
    echo -e "${CYAN}5.${NC} Настройки системы"
    echo -e "${CYAN}6.${NC} Очистить поврежденные данные"
    echo -e "${PURPLE}7.${NC} 🧪 Тестировать автоматизацию"
    echo -e "${PURPLE}8.${NC} 🚀 Эмулировать push событие"
    echo -e "${CYAN}9.${NC} Завершить работу"
    echo ""
    echo -e "${YELLOW}---------------------------------------------${NC}"
    echo -n -e "${GREEN}Ваш выбор (1-9): ${NC}"
    read main_choice
    
    case $main_choice in
      1)
        create_automation
        ;;
      2)
        manage_automations
        ;;
      3)
        start_webhook_server
        ;;
      4)
        view_logs
        ;;
      5)
        system_settings
        ;;
      6)
        clean_corrupted_data
        ;;
      7)
        test_automation_manual
        ;;
      8)
        simulate_push_event
        ;;
      9)
        clear_screen
        echo -e "${GREEN}${BOLD}Завершение работы. До свидания!${NC}"
        return 0
        ;;
      *)
        echo -e "${RED}Некорректный выбор!${NC}"
        sleep 1
        ;;
    esac
    
    if [ "$main_choice" != "9" ]; then
      echo ""
      echo -e "${YELLOW}Нажмите Enter, чтобы вернуться в главное меню...${NC}"
      read
    fi
  done
}

# Настройки системы
system_settings() {
  clear_screen
  echo -e "${BOLD}${CYAN}==============================================${NC}"
  echo -e "${BOLD}${CYAN}         НАСТРОЙКИ СИСТЕМЫ                   ${NC}"
  echo -e "${BOLD}${CYAN}==============================================${NC}"
  echo ""
  
  echo -e "${YELLOW}Выберите действие:${NC}"
  echo -e "${CYAN}1.${NC} Изменить порт webhook сервера"
  echo -e "${CYAN}2.${NC} Настроить Telegram уведомления"
  echo -e "${CYAN}3.${NC} Просмотр конфигурации"
  echo -e "${CYAN}4.${NC} Отладка данных автоматизаций"
  echo -e "${CYAN}5.${NC} Вернуться назад"
  echo ""
  echo -n -e "${GREEN}Ваш выбор (1-5): ${NC}"
  read settings_choice
  
  case $settings_choice in
    1)
      change_webhook_port
      ;;
    2)
      configure_telegram
      ;;
    3)
      show_configuration
      ;;
    4)
      debug_automations_data
      ;;
    5)
      return
      ;;
    *)
      echo -e "${RED}Неверный выбор!${NC}"
      sleep 1
      system_settings
      ;;
  esac
}

# Отладка данных автоматизаций
debug_automations_data() {
  clear_screen
  echo -e "${BOLD}${CYAN}==============================================${NC}"
  echo -e "${BOLD}${CYAN}    ОТЛАДКА ДАННЫХ АВТОМАТИЗАЦИЙ             ${NC}"
  echo -e "${BOLD}${CYAN}==============================================${NC}"
  echo ""
  
  if [ ! -f "$AUTOMATIONS_FILE" ]; then
    echo -e "${RED}❌ Файл автоматизаций не найден: $AUTOMATIONS_FILE${NC}"
    echo ""
    echo -e "${YELLOW}Нажмите Enter, чтобы вернуться...${NC}"
    read
    return
  fi
  
  echo -e "${YELLOW}Анализ файла: ${GREEN}$AUTOMATIONS_FILE${NC}"
  echo -e "${YELLOW}---------------------------------------------${NC}"
  
  local total_lines=0
  local lines_with_credentials=0
  
  while IFS= read -r line; do
    if [ -z "$line" ]; then
      continue
    fi
    
    ((total_lines++))
    
    # Разбираем строку
    local IFS='|'
    read -ra fields <<< "$line"
    
    local id="${fields[0]:-}"
    local name="${fields[1]:-}"
    local repo="${fields[2]:-}"
    local path="${fields[3]:-}"
    local branch="${fields[4]:-}"
    local commands="${fields[5]:-}"
    local date="${fields[6]:-}"
    local is_private="${fields[7]:-}"
    local encrypted_creds="${fields[8]:-}"
    
    echo ""
    echo -e "${CYAN}Автоматизация #$total_lines:${NC}"
    echo -e "  ${YELLOW}ID:${NC} $id"
    echo -e "  ${YELLOW}Название:${NC} $name"
    echo -e "  ${YELLOW}Репозиторий:${NC} $repo"
    echo -e "  ${YELLOW}Путь:${NC} $path"
    echo -e "  ${YELLOW}Ветка:${NC} $branch"
    echo -e "  ${YELLOW}Создано:${NC} $date"
    echo -e "  ${YELLOW}Приватный:${NC} ${is_private:-'не указано'}"
    
    if [ ! -z "$encrypted_creds" ]; then
      ((lines_with_credentials++))
      echo -e "  ${YELLOW}Учетные данные:${NC} ${GREEN}✅ Сохранены (${#encrypted_creds} символов)${NC}"
      
      # Попробуем расшифровать для проверки
      local decrypted=$(echo "$encrypted_creds" | tr 'A-Za-z' 'N-ZA-Mn-za-m' | base64 -d 2>/dev/null)
      if [ ! -z "$decrypted" ] && [[ "$decrypted" == *":"* ]]; then
        echo -e "  ${YELLOW}Расшифровка:${NC} ${GREEN}✅ Корректная${NC}"
      else
        echo -e "  ${YELLOW}Расшифровка:${NC} ${RED}❌ Ошибка${NC}"
      fi
    else
      if [ "$is_private" = "yes" ]; then
        echo -e "  ${YELLOW}Учетные данные:${NC} ${RED}❌ Отсутствуют (но репозиторий приватный!)${NC}"
      else
        echo -e "  ${YELLOW}Учетные данные:${NC} ${GRAY}Не требуются (публичный репозиторий)${NC}"
      fi
    fi
    
    echo -e "  ${YELLOW}Поля всего:${NC} ${#fields[@]}"
    
  done < "$AUTOMATIONS_FILE"
  
  echo ""
  echo -e "${YELLOW}==============================================${NC}"
  echo -e "${BOLD}Итоги:${NC}"
  echo -e "  ${YELLOW}Всего автоматизаций:${NC} $total_lines"
  echo -e "  ${YELLOW}С учетными данными:${NC} $lines_with_credentials"
  echo -e "  ${YELLOW}Размер файла:${NC} $(wc -c < "$AUTOMATIONS_FILE" 2>/dev/null || echo 0) байт"
  
  echo ""
  echo -e "${YELLOW}Нажмите Enter, чтобы вернуться...${NC}"
  read
}

# Простые функции-заглушки для настроек
change_webhook_port() {
  echo -e "${YELLOW}Функция смены порта webhook сервера пока не реализована.${NC}"
  sleep 2
}

configure_telegram() {
  echo -e "${YELLOW}Функция настройки Telegram уведомлений пока не реализована.${NC}"
  sleep 2
}

show_configuration() {
  clear_screen
  echo -e "${BOLD}${CYAN}==============================================${NC}"
  echo -e "${BOLD}${CYAN}         КОНФИГУРАЦИЯ СИСТЕМЫ                ${NC}"
  echo -e "${BOLD}${CYAN}==============================================${NC}"
  echo ""
  
  echo -e "${YELLOW}Текущие настройки:${NC}"
  echo -e "${YELLOW}---------------------------------------------${NC}"
  echo -e "${BOLD}Webhook порт:${NC} $WEBHOOK_PORT"
  echo -e "${BOLD}Директория данных:${NC} $WEBHOOK_DATA_DIR"
  echo -e "${BOLD}Файл автоматизаций:${NC} $AUTOMATIONS_FILE"
  echo -e "${BOLD}Файл логов:${NC} $WEBHOOK_LOG"
  echo -e "${BOLD}Уведомления:${NC} ${NOTIFICATIONS_ENABLED:-'отключены'}"
  echo -e "${BOLD}Telegram чат:${NC} ${TELEGRAM_CHAT_ID:-'не настроен'}"
  
  echo ""
  echo -e "${YELLOW}Нажмите Enter, чтобы вернуться...${NC}"
  read
}

# Основная функция
main() {
  # Сохраняем путь к скрипту для вызовов из других процессов
  export WEBHOOK_SCRIPT_PATH="$0"
  
  # Если скрипт запущен через curl | bash, сохраняем его в временное место
  if [[ "$0" == "/dev/fd/"* ]] || [[ "$0" == "/proc/"* ]] || [[ "$0" == "bash" ]]; then
    local temp_script="/tmp/webhook_$(date +%s).sh"
    
    # Копируем себя в временный файл для дальнейших вызовов
    cp "$0" "$temp_script" 2>/dev/null || {
      # Если cp не работает, пытаемся создать скрипт заново
      curl -sSL "https://raw.githubusercontent.com/darkClaw921/services-create-curl/master/webhook.sh" > "$temp_script" 2>/dev/null || {
        echo "Ошибка: Не удалось сохранить скрипт для standalone работы"
        exit 1
      }
    }
    
    chmod +x "$temp_script"
    export WEBHOOK_SCRIPT_PATH="$temp_script"
    
    # Если это первый запуск, перезапускаем с правильным путем
    if [[ "${1:-}" != "restarted" ]]; then
      exec "$temp_script" restarted "${@:2}"
    fi
  fi
  
  check_sudo
  init_webhook_system
  
  # Обработка аргументов командной строки
  if [[ "${1:-}" == "restarted" ]]; then
    # Убираем аргумент restarted и сдвигаем остальные
    shift
  fi
  
  case "${1:-}" in
    "handle_webhook_request")
      handle_webhook_request "$2"
      exit 0
      ;;
    "webhook_server")
      webhook_server
      exit 0
      ;;
    *)
      show_main_menu
      ;;
  esac
}

# Запуск основной функции
main "$@" 