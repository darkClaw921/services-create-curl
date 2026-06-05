#!/usr/bin/env bash
# Универсальная установка GitHub Actions self-hosted раннера.
#
# Достаточно указать ТОЛЬКО репозиторий и токен — всё остальное скрипт
# определяет сам: ОС, архитектуру, версию раннера, имя/папку, способ запуска
# как сервиса (systemd на Linux, launchd на macOS). Ставится в отдельную
# директорию и НЕ трогает другие раннеры на этой машине.
#
# Usage (любой из вариантов):
#   ./setup-runner.sh <owner/repo> <token>
#   ./setup-runner.sh --repo <owner/repo> --token <token>
#
# Доп. флаги (опционально, есть разумные дефолты):
#   --dir <path>     директория установки   (default: ~/actions-runner-<repo>)
#   --name <str>     имя раннера            (default: <repo>-<hostname>)
#   --labels <csv>   лейблы                 (default: self-hosted)
#   --version <ver>  версия раннера без 'v' (default: latest c GitHub API)
#
# Токен регистрации (одноразовый, ~1 час):
#   GitHub → репо → Settings → Actions → Runners → New self-hosted runner
#   или: gh api -X POST repos/<owner/repo>/actions/runners/registration-token --jq .token

set -euo pipefail

# ---- defaults ----
REPO=""
TOKEN=""
RUNNER_DIR=""
RUNNER_NAME=""
LABELS="self-hosted"
VERSION=""

die() { echo "ERROR: $*" >&2; exit 1; }

# ---- parse args (поддержка и флагов, и позиционных) ----
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)    REPO="$2"; shift 2 ;;
    --token)   TOKEN="$2"; shift 2 ;;
    --dir)     RUNNER_DIR="$2"; shift 2 ;;
    --name)    RUNNER_NAME="$2"; shift 2 ;;
    --labels)  LABELS="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    -h|--help) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "Unknown flag: $1" ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done
# позиционные: <repo> <token>
[[ -z "$REPO"  && ${#POSITIONAL[@]} -ge 1 ]] && REPO="${POSITIONAL[0]}"
[[ -z "$TOKEN" && ${#POSITIONAL[@]} -ge 2 ]] && TOKEN="${POSITIONAL[1]}"

# ---- validate required ----
[[ -n "$REPO"  ]] || die "не указан репозиторий. Пример: $0 owner/repo <token>"
[[ -n "$TOKEN" ]] || die "не указан токен. Получи: Settings → Actions → Runners → New self-hosted runner"
[[ "$REPO" =~ ^[^/]+/[^/]+$ ]] || die "репозиторий должен быть в формате owner/repo (получено: '$REPO')"

# ---- check prerequisites ----
for bin in curl tar uname; do
  command -v "$bin" >/dev/null 2>&1 || die "не найдена утилита '$bin' — установи её и повтори"
done

# ---- detect OS ----
case "$(uname -s)" in
  Linux)  OS="linux";  PKG="tar.gz" ;;
  Darwin) OS="osx";    PKG="tar.gz" ;;
  *) die "неподдерживаемая ОС: $(uname -s) (поддерживаются Linux и macOS)" ;;
esac

# ---- detect arch ----
case "$(uname -m)" in
  x86_64|amd64)  ARCH="x64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  armv7l)        ARCH="arm" ;;
  *) die "неподдерживаемая архитектура: $(uname -m)" ;;
esac

# ---- derive name/dir from repo ----
REPO_SLUG="${REPO#*/}"                       # часть после owner/
REPO_SLUG="${REPO_SLUG//[^a-zA-Z0-9_-]/-}"   # безопасное имя для папки
[[ -n "$RUNNER_DIR"  ]] || RUNNER_DIR="$HOME/actions-runner-${REPO_SLUG}"
[[ -n "$RUNNER_NAME" ]] || RUNNER_NAME="${REPO_SLUG}-$(hostname -s 2>/dev/null || hostname)"

# ---- resolve runner version ----
if [[ -z "$VERSION" ]]; then
  echo "==> определяю последнюю версию раннера…"
  VERSION="$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest \
    | grep -oE '"tag_name": *"v[0-9.]+"' | grep -oE '[0-9.]+' | head -n1 || true)"
  [[ -n "$VERSION" ]] || die "не удалось определить версию (rate limit GitHub API?). Передай --version X.Y.Z"
fi

echo "==> ОС: $OS, arch: $ARCH, версия раннера: v$VERSION"
echo "==> репозиторий: $REPO"
echo "==> раннер: '$RUNNER_NAME' (labels: $LABELS)"
echo "==> директория: $RUNNER_DIR"

# ---- guard: не перезатирать уже настроенный раннер ----
if [[ -f "$RUNNER_DIR/.runner" ]]; then
  die "в $RUNNER_DIR уже сконфигурирован раннер. Удали его: \
cd '$RUNNER_DIR' && sudo ./svc.sh uninstall 2>/dev/null; ./config.sh remove --token <TOKEN>"
fi

# ---- download & extract ----
mkdir -p "$RUNNER_DIR"
cd "$RUNNER_DIR"
TARBALL="actions-runner-${OS}-${ARCH}-${VERSION}.${PKG}"
URL="https://github.com/actions/runner/releases/download/v${VERSION}/${TARBALL}"

# Считаем распаковку полной, если на месте ключевые файлы из архива.
# ВАЖНО: svc.sh в архиве НЕТ — его создаёт config.sh при конфигурации,
# поэтому здесь его проверять нельзя (иначе любая установка «упадёт»).
if [[ ! -f "./config.sh" || ! -f "./run.sh" ]]; then
  echo "==> скачиваю $URL"
  curl -fsSL -o "$TARBALL" "$URL" || die "не удалось скачать раннер с $URL"
  echo "==> распаковываю…"
  tar xzf "$TARBALL" || die "не удалось распаковать $TARBALL (повреждён?) — удалите $RUNNER_DIR и повторите"
  rm -f "$TARBALL"
  # проверяем, что распаковка действительно дала рабочий комплект
  for f in config.sh run.sh; do
    [[ -f "./$f" ]] || die "после распаковки нет ./$f — архив повреждён, удалите $RUNNER_DIR и повторите"
  done
else
  echo "==> бинарники уже распакованы, пропускаю скачивание"
fi

# ---- configure (non-interactive) ----
# config.sh (и run.sh) раннера отказываются работать под root без этой переменной
# (выдают «Must not run with sudo» и выходят). Переменная влияет только при uid=0,
# для обычного пользователя безвредна. Сам сервис под systemd работает штатно.
export RUNNER_ALLOW_RUNASROOT=1
echo "==> конфигурирую раннер…"
./config.sh \
  --unattended \
  --url "https://github.com/$REPO" \
  --token "$TOKEN" \
  --name "$RUNNER_NAME" \
  --labels "$LABELS" \
  --work "_work" \
  --replace

# ---- run as a service (или fallback) ----
RUN_USER="$(whoami)"
if command -v sudo >/dev/null 2>&1; then
  echo "==> устанавливаю сервис ($OS) от пользователя '$RUN_USER'…"
  sudo ./svc.sh install "$RUN_USER"
  sudo ./svc.sh start
  echo "==> статус сервиса:"
  sudo ./svc.sh status || true
  SERVICE_MODE="service"
elif [[ "$RUN_USER" == "root" ]]; then
  echo "==> запущено под root, ставлю сервис без sudo…"
  ./svc.sh install
  ./svc.sh start
  ./svc.sh status || true
  SERVICE_MODE="service"
else
  echo "⚠ sudo недоступен — сервис не установлен."
  echo "  Запусти раннер вручную (в фоне):  cd '$RUNNER_DIR' && nohup ./run.sh &"
  SERVICE_MODE="manual"
fi

echo
echo "✅ Раннер '$RUNNER_NAME' зарегистрирован для $REPO."
echo "   Директория: $RUNNER_DIR"
if [[ "$SERVICE_MODE" == "service" ]]; then
  echo "   Запущен как сервис (автостарт при перезагрузке)."
fi
echo "   Проверь в GitHub: репо → Settings → Actions → Runners — статус должен быть 'Idle'."
echo "   Другие раннеры на этой машине НЕ затронуты (отдельная папка + отдельный сервис)."
