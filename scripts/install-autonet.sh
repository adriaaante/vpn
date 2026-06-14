#!/usr/bin/env bash
#
# install-autonet.sh — ставит LaunchAgent авто-режима по сети.
# Дома → «весь трафик», в чужих сетях → «только сервисы».
#
# Запуск:
#   bash scripts/install-autonet.sh
#
# Без sudo (агент уровня пользователя; смену режима делает через уже разрешённые
# в sudoers cp-команды — см. docs/macos-client-setup.md).

set -euo pipefail

[[ "$(uname -s)" == "Darwin" ]] || { echo "Только для macOS."; exit 1; }

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUTONET_SH="$DIR/scripts/vpn-autonet.sh"
PLIST_TEMPLATE="$DIR/launchd/com.user.singbox-autonet.plist"
DEST_PLIST="$HOME/Library/LaunchAgents/com.user.singbox-autonet.plist"
LABEL="com.user.singbox-autonet"
NETMAP="$HOME/.config/vpn/netmap"

chmod +x "$AUTONET_SH"

# Создаём карту сетей из примера, если её ещё нет
if [[ ! -f "$NETMAP" ]]; then
  mkdir -p "$(dirname "$NETMAP")"
  cp "$DIR/configs/netmap.example" "$NETMAP"
  echo "[*] Создан шаблон карты сетей: $NETMAP"
fi

mkdir -p "$HOME/Library/LaunchAgents"
sed "s|__AUTONET_SH__|$AUTONET_SH|g" "$PLIST_TEMPLATE" > "$DEST_PLIST"

launchctl bootout "gui/$(id -u)" "$DEST_PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$DEST_PLIST"
launchctl enable "gui/$(id -u)/$LABEL" 2>/dev/null || true

echo "[OK] Авто-режим по сети включён."
echo
echo "1) Узнай идентификатор домашней сети:  bash $AUTONET_SH whoami"
echo "2) Впиши его в $NETMAP (например:  <MAC-шлюза>  full)"
echo
echo "Снять: launchctl bootout gui/$(id -u) $DEST_PLIST"
