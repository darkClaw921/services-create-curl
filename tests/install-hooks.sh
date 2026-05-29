#!/usr/bin/env bash
# Включает git-хуки из tests/githooks для этого репозитория.
# Запустить один раз после клонирования: ./tests/install-hooks.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

chmod +x tests/githooks/* 2>/dev/null || true
git config core.hooksPath tests/githooks

echo "✅ Хуки активированы (core.hooksPath = tests/githooks)."
echo "   Теперь перед каждым 'git commit' автоматически запускаются тесты."
echo "   Пропустить разово: SKIP_TESTS=1 git commit ...  или  git commit --no-verify"
