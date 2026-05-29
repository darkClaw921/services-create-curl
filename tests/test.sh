#!/usr/bin/env bash
# ======================================================================
#  Интеграционные тесты service.sh в контейнере с НАСТОЯЩИМ systemd.
#
#  Поднимает privileged-контейнер (systemd как PID 1), где реально
#  работают systemctl/journalctl/nginx, прогоняет tests/run_in_docker.sh
#  и удаляет контейнер. Образ кэшируется (tests/Dockerfile).
#
#  Использование:
#    ./tests/test.sh                # обычный прогон
#    REBUILD=1 ./tests/test.sh      # принудительно пересобрать образ
#
#  Требуется Docker с поддержкой privileged-контейнеров.
# ======================================================================
set -euo pipefail

IMAGE_TAG="${IMAGE_TAG:-service-sh-systemd-test}"
CONTAINER="${CONTAINER:-service-sh-test-run}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker не установлен" >&2
  exit 1
fi

cleanup() { docker rm -f "$CONTAINER" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "==> Сборка образа $IMAGE_TAG (кэшируется)..."
build_args=()
[ "${REBUILD:-0}" = "1" ] && build_args+=(--no-cache)
docker build "${build_args[@]}" -q -t "$IMAGE_TAG" -f "$REPO_DIR/tests/Dockerfile" "$REPO_DIR/tests" >/dev/null

echo "==> Запуск контейнера с systemd..."
cleanup
docker run -d --name "$CONTAINER" \
  --privileged --cgroupns=host \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  --tmpfs /run --tmpfs /run/lock \
  -v "$REPO_DIR":/work \
  "$IMAGE_TAG" >/dev/null

echo "==> Ожидание готовности systemd..."
ready=0
for _ in $(seq 1 30); do
  state="$(docker exec "$CONTAINER" systemctl is-system-running 2>/dev/null || true)"
  case "$state" in
    running|degraded) ready=1; break ;;
  esac
  sleep 1
done
if [ "$ready" != "1" ]; then
  echo "ERROR: systemd не поднялся в контейнере" >&2
  docker logs "$CONTAINER" 2>&1 | tail -20
  exit 1
fi

echo "==> systemd готов. Запуск тестов..."
echo
docker exec "$CONTAINER" bash /work/tests/run_in_docker.sh
rc=$?

exit "$rc"
