#!/usr/bin/env bash
# ======================================================================
#  Комплексные тесты service.sh, выполняются ВНУТРИ контейнера с НАСТОЯЩИМ
#  systemd (PID 1). Реальные: systemctl, journalctl, nginx, ss, python3.
#  Мокаются только: sleep/clear (скорость), certbot и стабы рантаймов
#  uv/poetry/php (чтобы не тянуть тяжёлые пакеты).
#
#  Запускается из tests/test.sh внутри privileged-контейнера.
# ======================================================================
set -u

PASS=0; FAIL=0
ok()  { echo -e "  [\033[0;32mPASS\033[0m] $1"; PASS=$((PASS+1)); }
bad() { echo -e "  [\033[0;31mFAIL\033[0m] $1"; FAIL=$((FAIL+1)); [ -n "${2:-}" ] && echo "        $2"; }
section() { echo; echo "=== $1 ==="; }

SCRIPT="/work/service.sh"

# ---------------------------------------------------------------------
# 0. Лёгкие моки (только скорость и внешние сервисы)
# ---------------------------------------------------------------------
setup_mocks() {
  mkdir -p /usr/local/bin
  printf '#!/usr/bin/env bash\nexit 0\n' > /usr/local/bin/sleep
  printf '#!/usr/bin/env bash\nexit 0\n' > /usr/local/bin/clear
  # certbot мок: выпуск реального сертификата невозможен без домена
  printf '#!/usr/bin/env bash\necho "certbot $*" >> /tmp/mock.log\nexit 0\n' > /usr/local/bin/certbot
  # стабы рантаймов для тестов генерации unit-файлов (не запускаются реально)
  for r in uv poetry; do
    printf '#!/usr/bin/env bash\n[ "$1" = "--version" ] && echo "%s 1.0"\nexit 0\n' "$r" > "/usr/local/bin/$r"
  done
  printf '#!/usr/bin/env bash\n[ "$1" = "-v" ] && echo "PHP 8.1 (mock)"\nexit 0\n' > /usr/local/bin/php
  chmod +x /usr/local/bin/*
  hash -r
}

prepare_sourceable() { sed '/^main$/d' "$SCRIPT" > /tmp/svc.sh; }

# Песочница: чистим только то, что создаём (реальный nginx/systemd не трогаем целиком)
reset_fs() {
  rm -rf /var/lib/service-creator
  find /etc/nginx/sites-available -type f ! -name default -delete 2>/dev/null || true
  find /etc/nginx/sites-enabled   -type l ! -name default -delete 2>/dev/null || true
}

ensure_nginx_running() {
  systemctl is-active --quiet nginx || systemctl start nginx 2>/dev/null
}

# Запуск функции из svc.sh в subshell c подачей stdin
call_fn() { ( source /tmp/svc.sh >/dev/null 2>&1; "$@" ) 2>&1; }

setup_mocks
prepare_sourceable
ensure_nginx_running

# =====================================================================
section "1. Статический анализ"
# =====================================================================
if bash -n "$SCRIPT"; then ok "bash -n (синтаксис)"; else bad "bash -n"; fi
if command -v shellcheck >/dev/null; then
  if shellcheck -S error "$SCRIPT" >/tmp/sc.out 2>&1; then ok "shellcheck (error-level чисто)"; else bad "shellcheck error-level" "$(cat /tmp/sc.out)"; fi
fi

# =====================================================================
section "2. check_command"
# =====================================================================
out=$(call_fn check_command bash; echo "RC=$?")
echo "$out" | grep -q 'RC=0' && ok "check_command bash -> 0" || bad "check_command bash" "$out"
out=$(call_fn check_command definitely_no_such_cmd_xyz; echo "RC=$?")
echo "$out" | grep -q 'RC=1' && ok "check_command несуществующей -> 1" || bad "check_command missing" "$out"

# =====================================================================
section "3. init_services_list"
# =====================================================================
reset_fs
call_fn init_services_list >/dev/null
[ -d /var/lib/service-creator ] && ok "создан каталог service-creator" || bad "нет каталога"
[ -f /var/lib/service-creator/created_services.list ] && ok "создан список сервисов" || bad "нет списка"
[ -f /var/lib/service-creator/notifications/config ] && ok "создан конфиг уведомлений" || bad "нет конфига уведомлений"
grep -q 'NOTIFICATIONS_ENABLED=false' /var/lib/service-creator/notifications/config && ok "уведомления по умолчанию выключены" || bad "дефолт уведомлений неверный"

# =====================================================================
section "4. safe_nginx_reload (РЕАЛЬНЫЙ nginx)"
# =====================================================================
ensure_nginx_running
out=$(call_fn safe_nginx_reload; echo "RC=$?")
echo "$out" | grep -q 'RC=0' && ok "nginx запущен -> reload, RC=0" || bad "active reload" "$out"
systemctl is-active --quiet nginx && ok "nginx остаётся активным после reload" || bad "nginx упал после reload"

# Порт 80 занят ЧУЖИМ процессом -> отказ (реальная проверка через ss)
systemctl stop nginx 2>/dev/null
python3 -m http.server 80 >/dev/null 2>&1 &
SQUAT_PID=$!
# ждём реальной привязки к порту (sleep замокан, используем настоящий)
for _ in 1 2 3 4 5 6 7 8 9 10; do
  ss -tln 2>/dev/null | grep -q ':80 ' && break
  /bin/sleep 0.3
done
if ss -tln 2>/dev/null | grep -q ':80 '; then
  out=$( ( source /tmp/svc.sh >/dev/null 2>&1; safe_nginx_reload; echo "RC=$?" ) 2>&1 )
  if echo "$out" | grep -q 'RC=1' && echo "$out" | grep -qi 'занят'; then
    ok "порт 80 занят чужим процессом (python3) -> RC=1"
  else bad "port-busy real" "$out"; fi
else
  bad "port-busy real" "не удалось занять порт 80 для теста"
fi
kill "$SQUAT_PID" 2>/dev/null; wait "$SQUAT_PID" 2>/dev/null
ensure_nginx_running

# =====================================================================
section "5. select_runtime (валидация ввода)"
# =====================================================================
out=$(printf '9\n' | call_fn select_runtime; echo "RC=$?")
echo "$out" | grep -q 'RC=1' && ok "некорректный пункт (9) -> RC=1" || bad "select_runtime invalid" "$out"
out=$(printf '1\n' | call_fn select_runtime; echo "RC=$?")
echo "$out" | grep -q 'RC=0' && ok "Python (1) -> RC=0" || bad "select python" "$out"
out=$(printf '2\n' | call_fn select_runtime; echo "RC=$?")
echo "$out" | grep -q 'RC=0' && ok "UV (2, mock) -> RC=0" || bad "select uv" "$out"
out=$(printf '4\nbadformat\n' | call_fn select_runtime; echo "RC=$?")
echo "$out" | grep -q 'RC=1' && ok "PHP с неверным host:port -> RC=1" || bad "php badformat" "$out"
out=$(printf '4\nlocalhost:8000\n' | call_fn select_runtime; echo "RC=$?")
echo "$out" | grep -q 'RC=0' && ok "PHP с корректным host:port -> RC=0" || bad "php ok" "$out"
out=$(printf '5\n' | call_fn select_runtime; echo "RC=$?")
echo "$out" | grep -q 'RC=0' && ok "Shell (5) -> RC=0" || bad "select shell" "$out"

# =====================================================================
section "6. create_service: генерация unit-файла (без запуска)"
# =====================================================================
test_create_service() {
  local runtime="$1" file="$2" expect_exec="$3" extra_setup="$4"
  reset_fs
  call_fn init_services_list >/dev/null
  local proj=/tmp/proj_$runtime
  rm -rf "$proj"; mkdir -p "$proj"
  echo "print('hi')" > "$proj/$file"
  eval "$extra_setup"
  # description, затем "запустить сейчас?" -> n (только генерация)
  ( cd "$proj"; printf 'Desc %s\nn\n' "$runtime" | bash -c "source /tmp/svc.sh >/dev/null 2>&1; ${PHP_GLOBAL:+$PHP_GLOBAL; }create_service '$file' '$runtime'" ) >/dev/null 2>&1
  local svc="/etc/systemd/system/${file%.*}.service"
  if [ -f "$svc" ]; then
    grep -q "ExecStart=${expect_exec}" "$svc" && ok "create_service[$runtime]: ExecStart" || bad "create_service[$runtime] ExecStart" "$(grep ExecStart "$svc")"
    grep -q "WorkingDirectory=$proj" "$svc" && ok "create_service[$runtime]: WorkingDirectory" || bad "create_service[$runtime] WorkingDirectory"
    grep -q "Description=Desc $runtime" "$svc" && ok "create_service[$runtime]: Description" || bad "create_service[$runtime] Description"
    [ -f "/var/lib/service-creator/notifications/${file%.*}_notify.sh" ] && ok "create_service[$runtime]: notify-скрипт" || bad "create_service[$runtime] notify"
    grep -q "^${file%.*}.service:$proj:" /var/lib/service-creator/created_services.list && ok "create_service[$runtime]: запись в списке" || bad "create_service[$runtime] список"
  else
    bad "create_service[$runtime]: unit-файл не создан"
  fi
  systemctl disable "${file%.*}.service" 2>/dev/null || true
  rm -f "$svc"; systemctl daemon-reload 2>/dev/null || true
  unset PHP_GLOBAL
}
test_create_service python  app.py  "$(command -v python3) app.py"           ""
test_create_service uv      app.py  "$(command -v uv) run app.py"            ""
test_create_service shell   run.sh  "$(command -v bash) run.sh"              ""
test_create_service poetry  app.py  "$(command -v poetry) run python app.py" "touch \$proj/pyproject.toml"
PHP_GLOBAL='php_host_port=localhost:9000'
test_create_service php      idx.php "$(command -v php) -S localhost:9000 idx.php" ""

# =====================================================================
section "7. service_control: удаление затрагивает ТОЛЬКО один сервис"
# =====================================================================
reset_fs
call_fn init_services_list >/dev/null
LIST=/var/lib/service-creator/created_services.list
{
  echo "app.service:/opt/a:2026-01-01 10:00:00"
  echo "app2.service:/opt/b:2026-01-02 10:00:00"
  echo "appXservice:/opt/c:2026-01-03 10:00:00"
} > "$LIST"
touch /etc/systemd/system/app.service /etc/systemd/system/app2.service
printf '6\ny\n' | bash -c "source /tmp/svc.sh >/dev/null 2>&1; service_control app.service /opt/a" >/dev/null 2>&1
[ ! -f /etc/systemd/system/app.service ] && ok "файл app.service удалён" || bad "app.service не удалён"
[ -f /etc/systemd/system/app2.service ] && ok "файл app2.service СОХРАНЁН" || bad "app2.service ошибочно удалён"
grep -q '^app2.service:' "$LIST" && grep -q '^appXservice:' "$LIST" && ! grep -q '^app\.service:' "$LIST" \
  && ok "из списка убран только app.service" || bad "список после удаления неверен" "$(cat "$LIST")"
rm -f /etc/systemd/system/app2.service

# =====================================================================
section "8. nginx: list / show_info / toggle / delete (РЕАЛЬНЫЙ nginx -t/reload)"
# =====================================================================
reset_fs; ensure_nginx_running
# Конфиг с SSL — только для ПАРСИНГА show_info, НЕ включаем (иначе nginx -t
# упадёт на отсутствующем сертификате при последующих reload).
cat > /etc/nginx/sites-available/site_ssl.conf <<'C'
server {
    listen 8081;
    listen 4443 ssl;
    server_name site1.com www.site1.com;
    ssl_certificate /etc/letsencrypt/live/site1.com/fullchain.pem;
    location / {
        proxy_pass http://127.0.0.1:3000;
    }
}
C
# Простые валидные конфиги для toggle/delete/активности (реальный nginx -t)
cat > /etc/nginx/sites-available/site1.conf <<'C'
server {
    listen 8085;
    server_name site1simple.com;
    location / {
        proxy_pass http://127.0.0.1:3000;
    }
}
C
cat > /etc/nginx/sites-available/site2.conf <<'C'
server {
    listen 8082;
    server_name site2.com;
    location / {
        proxy_pass http://10.0.0.5:8080;
    }
}
C
ln -sf /etc/nginx/sites-available/site1.conf /etc/nginx/sites-enabled/site1.conf

cnt=$(call_fn list_nginx_configs | grep -c '\.conf')
[ "$cnt" -ge 3 ] && ok "list_nginx_configs нашёл >=3 конфига" || bad "list_nginx_configs cnt=$cnt"

# Парсинг SSL/портов/доменов/типа на невключённом site_ssl.conf
info=$(call_fn show_nginx_config_info /etc/nginx/sites-available/site_ssl.conf)
echo "$info" | grep -q 'site1.com' && ok "show_info: домены" || bad "show_info домены" "$info"
echo "$info" | grep -q '8081' && echo "$info" | grep -q '4443' && ok "show_info: порты" || bad "show_info порты" "$info"
echo "$info" | grep -q 'SSL: настроен' && ok "show_info: SSL определён" || bad "show_info ssl"
echo "$info" | grep -q 'Локальный' && ok "show_info: тип проксирования локальный" || bad "show_info тип"
echo "$info" | grep -q 'не активирован' && ok "show_info: невключённый -> 'не активирован'" || bad "show_info неактив"
# Активность по симлинку — на включённом site1.conf
info1=$(call_fn show_nginx_config_info /etc/nginx/sites-available/site1.conf)
echo "$info1" | grep -q 'АКТИВИРОВАН' && ok "show_info: активность по симлинку" || bad "show_info активность" "$info1"

# toggle активировать site2 (реальный reload)
printf 'y\n' | bash -c "source /tmp/svc.sh >/dev/null 2>&1; toggle_nginx_config site2.conf" >/dev/null 2>&1
[ -L /etc/nginx/sites-enabled/site2.conf ] && ok "toggle: site2 активирован" || bad "toggle активация"
systemctl is-active --quiet nginx && ok "nginx жив после активации site2" || bad "nginx упал"
# toggle отключить
printf 'y\n' | bash -c "source /tmp/svc.sh >/dev/null 2>&1; toggle_nginx_config site2.conf" >/dev/null 2>&1
[ ! -L /etc/nginx/sites-enabled/site2.conf ] && ok "toggle: site2 отключён" || bad "toggle отключение"

# delete отказ
printf 'n\n' | bash -c "source /tmp/svc.sh >/dev/null 2>&1; delete_nginx_config site2.conf" >/dev/null 2>&1
[ -f /etc/nginx/sites-available/site2.conf ] && ok "delete: отказ сохраняет конфиг" || bad "delete отказ"
# delete подтверждение
printf 'y\n' | bash -c "source /tmp/svc.sh >/dev/null 2>&1; delete_nginx_config site1.conf" >/dev/null 2>&1
[ ! -f /etc/nginx/sites-available/site1.conf ] && ok "delete: конфиг удалён" || bad "delete конфиг"
[ ! -L /etc/nginx/sites-enabled/site1.conf ] && ok "delete: симлинк удалён" || bad "delete симлинк"
[ -f /etc/nginx/sites-available/site2.conf ] && ok "delete: соседний site2 не тронут" || bad "delete сосед"

# =====================================================================
section "9. create_nginx_config (РЕАЛЬНЫЙ nginx, все ветки + валидация)"
# =====================================================================
reset_fs; ensure_nginx_running
out=$(printf '\n' | call_fn create_nginx_config; echo "RC=$?")
echo "$out" | grep -q 'RC=1' && ok "пустой домен -> RC=1" || bad "пустой домен" "$out"

reset_fs; ensure_nginx_running
printf 'local.com\n1\n8000\nn\nn\n\n' | bash -c "source /tmp/svc.sh >/dev/null 2>&1; create_nginx_config" >/dev/null 2>&1
f=/etc/nginx/sites-available/local.com.conf
if [ -f "$f" ]; then
  grep -q 'server_name local.com;' "$f" && ok "local: server_name" || bad "local server_name"
  grep -q 'proxy_pass http://127.0.0.1:8000;' "$f" && ok "local: proxy_pass" || bad "local proxy_pass"
  [ -L /etc/nginx/sites-enabled/local.com.conf ] && ok "local: активирован" || bad "local symlink"
  systemctl is-active --quiet nginx && ok "local: nginx жив после реального reload" || bad "local nginx down"
else bad "local: конфиг не создан"; fi

reset_fs; ensure_nginx_running
out=$(printf 'ext.com\n2\nhost:999999\n' | call_fn create_nginx_config; echo "RC=$?")
echo "$out" | grep -q 'RC=1' && ok "external: порт >65535 -> RC=1" || bad "external bad port" "$out"

reset_fs; ensure_nginx_running
printf 'ext.com\n2\n10.0.0.9:8080\nn\nn\n\n' | bash -c "source /tmp/svc.sh >/dev/null 2>&1; create_nginx_config" >/dev/null 2>&1
grep -q 'proxy_pass https://10.0.0.9:8080;' /etc/nginx/sites-available/ext.com.conf 2>/dev/null && ok "external: proxy_pass https" || bad "external proxy_pass"

reset_fs; ensure_nginx_running
printf '*.wild.com\n1\n3000\nn\nn\n\n' | bash -c "source /tmp/svc.sh >/dev/null 2>&1; create_nginx_config" >/dev/null 2>&1
grep -q 'server_name \*.wild.com wild.com;' /etc/nginx/sites-available/wild.com.conf 2>/dev/null && ok "wildcard: server_name + имя файла по базе" || bad "wildcard"

reset_fs; ensure_nginx_running
printf 'ws.com\n1\n5000\ny\nn\n\n' | bash -c "source /tmp/svc.sh >/dev/null 2>&1; create_nginx_config" >/dev/null 2>&1
f=/etc/nginx/sites-available/ws.com.conf
grep -q 'proxy_set_header Upgrade' "$f" 2>/dev/null && grep -q 'Connection "upgrade"' "$f" 2>/dev/null && ok "websocket: заголовки Upgrade/Connection" || bad "websocket"

reset_fs; ensure_nginx_running; mkdir -p /tmp/phproot
printf 'php.com\n3\n/tmp/phproot\nn\n\nn\n\n' | bash -c "source /tmp/svc.sh >/dev/null 2>&1; create_nginx_config" >/dev/null 2>&1
f=/etc/nginx/sites-available/php.com.conf
if [ -f "$f" ]; then
  grep -q 'root /tmp/phproot;' "$f" && ok "php: root" || bad "php root"
  grep -q 'fastcgi_pass 127.0.0.1:9000;' "$f" && ok "php: fastcgi_pass TCP" || bad "php fastcgi"
else bad "php: конфиг не создан"; fi

reset_fs; ensure_nginx_running
echo "old" > /etc/nginx/sites-available/dup.com.conf
out=$(printf 'dup.com\n1\n8000\nn\n' | call_fn create_nginx_config; echo "RC=$?")
echo "$out" | grep -q 'RC=1' && grep -q 'old' /etc/nginx/sites-available/dup.com.conf && ok "перезапись: отказ -> RC=1, файл цел" || bad "overwrite decline" "$out"

# =====================================================================
section "10. manage_notifications + send_notification"
# =====================================================================
reset_fs; call_fn init_services_list >/dev/null
printf '1\n5\n' | bash -c "source /tmp/svc.sh >/dev/null 2>&1; manage_notifications" >/dev/null 2>&1
grep -q 'NOTIFICATIONS_ENABLED=true' /var/lib/service-creator/notifications/config && ok "notifications: тумблер сохранил enabled=true" || bad "notifications toggle"

reset_fs; call_fn init_services_list >/dev/null
out=$( ( source /tmp/svc.sh >/dev/null 2>&1
         NOTIFICATIONS_ENABLED=false
         curl() { echo "CURL_CALLED" >&2; }
         send_notification "svc" "запущен"; echo "RC=$?" ) 2>&1 )
echo "$out" | grep -q 'RC=0' && ! echo "$out" | grep -q 'CURL_CALLED' && ok "send_notification выключено: RC=0 без curl" || bad "send off" "$out"

out=$( ( source /tmp/svc.sh >/dev/null 2>&1
         NOTIFICATIONS_ENABLED=true; TELEGRAM_CHAT_ID=123; TELEGRAM_TOKEN=tok
         curl() { echo "CURL_CALLED $*" >&2; }
         send_notification "svc" "запущен"; echo "RC=$?" ) 2>&1 )
echo "$out" | grep -q 'CURL_CALLED' && echo "$out" | grep -q 'api.telegram.org' && ok "send_notification включено: вызывает Telegram API" || bad "send on" "$out"

# =====================================================================
section "11. create_github_runner (валидация, скачивание, очистка)"
# =====================================================================
runner_test() {
  ( source /tmp/svc.sh >/dev/null 2>&1
    TMP_RUNNER="/tmp/_mock_runner_$$.sh"
    mktemp() { echo "$TMP_RUNNER"; }
    curl() {
      if [ "$RMODE" = "ok" ]; then
        local out=""; while [ $# -gt 0 ]; do [ "$1" = "-o" ] && out="$2"; shift; done
        printf '#!/usr/bin/env bash\necho "RUNNER_CALLED args: $*"\nexit 0\n' > "$out"; return 0
      else return 7; fi
    }
    create_github_runner; echo "RC=$?"
    [ -f "$TMP_RUNNER" ] && echo "TMPLEFT=yes" || echo "TMPLEFT=no"
  ) 2>&1
}
out=$(RMODE=ok   runner_test <<<"badrepo");                echo "$out" | grep -q 'RC=1' && ! echo "$out" | grep -q RUNNER_CALLED && ok "runner: невалидный repo -> RC=1" || bad "runner badrepo" "$out"
out=$(RMODE=ok   runner_test <<<$'owner/repo\n\n');        echo "$out" | grep -q 'RC=1' && ! echo "$out" | grep -q RUNNER_CALLED && ok "runner: пустой токен -> RC=1" || bad "runner empty token" "$out"
out=$(RMODE=ok   runner_test <<<$'owner/repo\ntok\n\n');   echo "$out" | grep -q 'RUNNER_CALLED args: owner/repo tok' && echo "$out" | grep -q 'TMPLEFT=no' && ok "runner: валидно -> запуск + очистка" || bad "runner valid" "$out"
out=$(RMODE=ok   runner_test <<<$'owner/repo\ntok\ngpu,linux\n'); echo "$out" | grep -q 'RUNNER_CALLED args: owner/repo tok --labels gpu,linux' && ok "runner: лейблы -> --labels" || bad "runner labels" "$out"
out=$(RMODE=fail runner_test <<<$'owner/repo\ntok\n\n');   echo "$out" | grep -q 'RC=1' && echo "$out" | grep -q 'TMPLEFT=no' && ! echo "$out" | grep -q RUNNER_CALLED && ok "runner: сбой curl -> RC=1, tmp удалён" || bad "runner curl fail" "$out"

# =====================================================================
section "12. Согласованность главного меню"
# =====================================================================
grep -q 'GitHub Actions runner (установка / управление)' "$SCRIPT" && ok "пункт раннера в меню" || bad "нет пункта раннера"
grep -q 'Nginx (создание / управление)' "$SCRIPT" && ok "пункт nginx в меню" || bad "нет пункта nginx"
grep -q 'Ваш выбор (1-6)' "$SCRIPT" && ok "приглашение главного меню (1-6)" || bad "приглашение не (1-6)"
grep -q 'github_runner_menu' "$SCRIPT" && ok "вызов github_runner_menu" || bad "нет github_runner_menu"
grep -q 'nginx_menu' "$SCRIPT" && ok "вызов nginx_menu" || bad "нет nginx_menu"
grep -q 'create_github_runner' "$SCRIPT" && ok "функция create_github_runner присутствует" || bad "нет create_github_runner"
# nginx_menu маршрутизирует на обе функции
awk '/^nginx_menu\(\)/,/^}/' "$SCRIPT" | grep -q 'create_nginx_config' && \
awk '/^nginx_menu\(\)/,/^}/' "$SCRIPT" | grep -q 'manage_nginx_configs' && \
  ok "nginx_menu вызывает create_nginx_config и manage_nginx_configs" || bad "nginx_menu маршрутизация"

# ---- компактная панель сайтов ----
reset_fs; ensure_nginx_running
cat > /etc/nginx/sites-available/shop.com.conf <<'C'
server {
    listen 8090;
    server_name shop.com www.shop.com;
    location / {
        proxy_pass http://127.0.0.1:8000;
    }
}
C
cat > /etc/nginx/sites-available/api.com.conf <<'C'
server {
    listen 8091;
    server_name api.com;
    location / {
        proxy_pass http://10.0.0.7:9000;
    }
}
C
ln -sf /etc/nginx/sites-available/shop.com.conf /etc/nginx/sites-enabled/shop.com.conf
panel=$(call_fn nginx_compact_list | sed 's/\x1b\[[0-9;]*m//g')
echo "$panel" | grep -q 'shop.com → 127.0.0.1:8000' && ok "compact: домен → проксирование" || bad "compact target" "$panel"
echo "$panel" | grep -q '\[:8090\]' && ok "compact: порт прослушивания" || bad "compact port" "$panel"
echo "$panel" | grep -qE '✓ .*shop.com' && ok "compact: включённый помечен ✓" || bad "compact enabled mark" "$panel"
echo "$panel" | grep -qE '· .*api.com' && ok "compact: выключенный помечен ·" || bad "compact disabled mark" "$panel"
# print_two_col выравнивает с учётом ANSI
tc=$(call_fn print_two_col "$(printf '\033[0;36mLEFT\033[0m')" "RIGHT" 10)
echo "$tc" | grep -q 'LEFT' && echo "$tc" | grep -q 'RIGHT' && ok "print_two_col: обе колонки в строке" || bad "print_two_col" "$tc"
# Выравнивание с КИРИЛЛИЦЕЙ: видимая ширина левой колонки до правой = w+2
tc=$(call_fn print_two_col "Создать" "MARK" 20)
prefix="${tc%%MARK*}"
vis=$(( $(printf '%s' "$prefix" | wc -c) - $(printf '%s' "$prefix" | tr -cd '\200-\277' | wc -c) ))
[ "$vis" -eq 22 ] && ok "print_two_col: кириллица выравнивается (видимая ширина=22)" || bad "print_two_col cyrillic align" "vis=$vis prefix='$prefix'"

# =====================================================================
section "13. РЕАЛЬНЫЙ жизненный цикл сервиса через systemctl"
# =====================================================================
reset_fs
call_fn init_services_list >/dev/null
PROJ=/tmp/realsvc; rm -rf "$PROJ"; mkdir -p "$PROJ"
printf '#!/usr/bin/env bash\nwhile true; do sleep 1; done\n' > "$PROJ/longrun.sh"
chmod +x "$PROJ/longrun.sh"

# Создаём и СРАЗУ запускаем (ответ y)
( cd "$PROJ"; printf 'Real lifecycle\ny\n' | bash -c "source /tmp/svc.sh >/dev/null 2>&1; create_service longrun.sh shell" ) >/dev/null 2>&1
sleep 1 2>/dev/null || /bin/sleep 1
[ -f /etc/systemd/system/longrun.service ] && ok "lifecycle: unit-файл создан" || bad "lifecycle: нет unit"
[ "$(systemctl is-active longrun 2>/dev/null)" = "active" ] && ok "lifecycle: сервис РЕАЛЬНО active после старта" || bad "lifecycle: не active" "$(systemctl status longrun --no-pager 2>&1 | head -5)"
[ "$(systemctl is-enabled longrun 2>/dev/null)" = "enabled" ] && ok "lifecycle: автозапуск enabled" || bad "lifecycle: не enabled"

# Перезапуск через service_control (опция 3, затем Enter, затем 7 выход)
printf '3\n\n7\n' | bash -c "source /tmp/svc.sh >/dev/null 2>&1; service_control longrun.service $PROJ" >/dev/null 2>&1
[ "$(systemctl is-active longrun 2>/dev/null)" = "active" ] && ok "lifecycle: active после restart" || bad "lifecycle: restart failed"

# Остановка (опция 2)
printf '2\n\n7\n' | bash -c "source /tmp/svc.sh >/dev/null 2>&1; service_control longrun.service $PROJ" >/dev/null 2>&1
[ "$(systemctl is-active longrun 2>/dev/null)" != "active" ] && ok "lifecycle: inactive после stop" || bad "lifecycle: stop failed"

# Запуск снова (опция 1)
printf '1\n\n7\n' | bash -c "source /tmp/svc.sh >/dev/null 2>&1; service_control longrun.service $PROJ" >/dev/null 2>&1
[ "$(systemctl is-active longrun 2>/dev/null)" = "active" ] && ok "lifecycle: active после повторного start" || bad "lifecycle: start failed"

# Удаление (опция 6 + подтверждение y)
printf '6\ny\n' | bash -c "source /tmp/svc.sh >/dev/null 2>&1; service_control longrun.service $PROJ" >/dev/null 2>&1
[ ! -f /etc/systemd/system/longrun.service ] && ok "lifecycle: unit-файл удалён" || bad "lifecycle: unit остался"
systemctl status longrun >/dev/null 2>&1; [ $? -ne 0 ] && ok "lifecycle: systemctl больше не знает сервис" || bad "lifecycle: сервис всё ещё известен"
systemctl daemon-reload 2>/dev/null || true

# =====================================================================
section "14. Управление GitHub раннерами (discovery + control)"
# =====================================================================
# Готовим фейковые установленные раннеры
rm -rf /root/actions-runner-* /home/u1 2>/dev/null || true
mkdir -p /root/actions-runner-myrepo /home/u1/actions-runner-other
SVC_LOG=/tmp/svc_actions.log; : > "$SVC_LOG"
make_fake_runner() {
  local d="$1" repo_url="$2"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/config.sh"; chmod +x "$d/config.sh"
  cat > "$d/svc.sh" <<SVC
#!/usr/bin/env bash
echo "svc \$1" >> $SVC_LOG
exit 0
SVC
  chmod +x "$d/svc.sh"
  printf 'actions.runner.fake.%s.service\n' "$(basename "$d")" > "$d/.service"
  [ -n "$repo_url" ] && printf '{ "gitHubUrl": "%s" }\n' "$repo_url" > "$d/.runner"
}
make_fake_runner /root/actions-runner-myrepo "https://github.com/owner/myrepo"
make_fake_runner /home/u1/actions-runner-other ""   # без .runner -> имя из каталога

# discovery
found=$(call_fn find_github_runners)
echo "$found" | grep -q '/root/actions-runner-myrepo' && ok "find_github_runners: нашёл раннер в /root" || bad "find /root" "$found"
echo "$found" | grep -q '/home/u1/actions-runner-other' && ok "find_github_runners: нашёл раннер в /home/*" || bad "find /home" "$found"

# имя сервиса
sn=$(call_fn runner_service_name /root/actions-runner-myrepo)
[ "$sn" = "actions.runner.fake.actions-runner-myrepo.service" ] && ok "runner_service_name: читает .service" || bad "runner_service_name" "$sn"

# репозиторий из .runner
rn=$(call_fn runner_repo_name /root/actions-runner-myrepo)
[ "$rn" = "owner/myrepo" ] && ok "runner_repo_name: из .runner gitHubUrl" || bad "runner_repo_name url" "$rn"
# репозиторий fallback из имени каталога
rn2=$(call_fn runner_repo_name /home/u1/actions-runner-other)
[ "$rn2" = "other" ] && ok "runner_repo_name: fallback из имени каталога" || bad "runner_repo_name fallback" "$rn2"

# control: start/stop/restart/status вызывают svc.sh
: > "$SVC_LOG"
printf '1\n\n2\n\n3\n\n4\n\n7\n' | bash -c "source /tmp/svc.sh >/dev/null 2>&1; github_runner_control /root/actions-runner-myrepo" >/dev/null 2>&1
grep -q 'svc start' "$SVC_LOG" && ok "control: запуск вызывает svc.sh start" || bad "control start" "$(cat "$SVC_LOG")"
grep -q 'svc stop'  "$SVC_LOG" && ok "control: остановка вызывает svc.sh stop" || bad "control stop"
grep -q 'svc status' "$SVC_LOG" && ok "control: статус вызывает svc.sh status" || bad "control status"

# control: логи (опция 5) используют общий просмотрщик journalctl
out=$(printf '5\n3\n7\n' | bash -c "source /tmp/svc.sh >/dev/null 2>&1; github_runner_control /root/actions-runner-myrepo" 2>&1)
echo "$out" | grep -qi 'журнал' && ok "control: просмотр логов через view_service_logs" || bad "control logs" "$out"

# control: удаление (опция 6, подтверждение сервиса y, каталога y)
printf '6\ny\ny\n' | bash -c "source /tmp/svc.sh >/dev/null 2>&1; github_runner_control /root/actions-runner-myrepo" >/dev/null 2>&1
[ ! -d /root/actions-runner-myrepo ] && ok "control: удаление убирает каталог раннера" || bad "control delete dir"
grep -q 'svc uninstall' "$SVC_LOG" && ok "control: удаление вызывает svc.sh uninstall" || bad "control uninstall" "$(cat "$SVC_LOG")"
[ -d /home/u1/actions-runner-other ] && ok "control: соседний раннер не тронут" || bad "control delete сосед"
rm -rf /home/u1 2>/dev/null || true

# =====================================================================
echo
echo "======================================================"
echo -e "  ИТОГО: \033[0;32mPASS=$PASS\033[0m  \033[0;31mFAIL=$FAIL\033[0m"
echo "======================================================"
[ "$FAIL" -eq 0 ]
