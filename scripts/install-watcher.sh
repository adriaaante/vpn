#!/usr/bin/env bash
#
# install-watcher.sh — ставит LaunchAgent, который раз в ~20 сек проверяет
# активный протокол и шлёт уведомление при автоматическом переключении (failover).
#
# Запуск:
#   bash scripts/install-watcher.sh
#
# Работает без sudo (LaunchAgent уровня пользователя, обращается к локальному
# Clash API). Снять: launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.user.singbox-watch.plist

set -euo pipefail

[[ "$(uname -s)" == "Darwin" ]] || { echo "Только для macOS."; exit 1; }

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WATCH_SH="$DIR/scripts/vpn-watch.sh"
PLIST_TEMPLATE="$DIR/launchd/com.user.singbox-watch.plist"
DEST_PLIST="$HOME/Library/LaunchAgents/com.user.singbox-watch.plist"
LABEL="com.user.singbox-watch"

chmod +x "$WATCH_SH"
mkdir -p "$HOME/Library/LaunchAgents"

sed "s|__WATCH_SH__|$WATCH_SH|g" "$PLIST_TEMPLATE" > "$DEST_PLIST"

launchctl bootout "gui/$(id -u)" "$DEST_PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$DEST_PLIST"
launchctl enable "gui/$(id -u)/$LABEL" 2>/dev/null || true

echo "[OK] Watcher установлен. При автоматическом переключении протокола придёт"
echo "     системное уведомление (с именами 'было' → 'стало')."
echo
echo "Проверка: вручную запусти  bash $WATCH_SH  (тихо, если смены нет)."
echo "Снять:    launchctl bootout gui/$(id -u) $DEST_PLIST"
