#!/usr/bin/env bash
#
# install-menubar.sh — ставит SwiftBar и подключает наш плагин-тумблер VPN
# в строку меню macOS.
#
# Запуск:
#   bash scripts/install-menubar.sh
#
# Важно: чтобы кнопки вкл/выкл работали по клику без запроса пароля, должен быть
# настроен sudoers (см. docs/macos-client-setup.md, раздел "без ввода пароля").

set -euo pipefail

[[ "$(uname -s)" == "Darwin" ]] || { echo "Только для macOS."; exit 1; }

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_DIR="$DIR/menubar"

if ! command -v brew >/dev/null 2>&1; then
  echo "[!] Нужен Homebrew (https://brew.sh)."; exit 1
fi

if [[ ! -d "/Applications/SwiftBar.app" ]]; then
  echo "[*] Устанавливаю SwiftBar..."
  brew install --cask swiftbar
fi

chmod +x "$PLUGIN_DIR"/*.sh

echo "[*] Указываю SwiftBar папку с плагином: $PLUGIN_DIR"
defaults write com.ameba.SwiftBar PluginDirectory "$PLUGIN_DIR"

# Перезапускаем SwiftBar, чтобы подхватил папку и плагин
osascript -e 'quit app "SwiftBar"' >/dev/null 2>&1 || true
sleep 1
open -a SwiftBar || true

echo
echo "[OK] Готово. В строке меню появится индикатор:"
echo "     🟢 LV  — туннель включён (показывает страну выхода)"
echo "     ⚪️ off — выключен (прямой интернет)"
echo
echo "Клик по иконке → меню с кнопками Включить / Выключить / Перезапустить."
echo
echo "Если кнопки просят пароль — настрой sudoers без пароля:"
echo "  см. docs/macos-client-setup.md (раздел «Переключение без ввода пароля»)."
