#!/usr/bin/env bash
#
# vpn-watch.sh — одноразовая проверка активного протокола; шлёт macOS-уведомление,
# если клиент САМ (в режиме «авто») переключился на другой протокол (failover).
# Запускается периодически через LaunchAgent (см. scripts/install-watcher.sh).
#
# Ручные переключения протокола не считаются failover и не уведомляются.

set -uo pipefail

CFG="/etc/sing-box/config.json"
STATE="$HOME/.cache/vpn-active-proto"
mkdir -p "$(dirname "$STATE")"

# Туннель выключен — нечего отслеживать
pgrep -x sing-box >/dev/null 2>&1 || exit 0

CTRL="$(grep -o '"external_controller": *"[^"]*"' "$CFG" 2>/dev/null | sed 's/.*"\([^"]*\)"/\1/')"
SECRET="$(grep -o '"secret": *"[^"]*"' "$CFG" 2>/dev/null | sed 's/.*"\([^"]*\)"/\1/')"
CTRL="${CTRL:-127.0.0.1:9090}"
now_of() { curl -fsS --max-time 3 -H "Authorization: Bearer $SECRET" "http://$CTRL/proxies/$1" 2>/dev/null | grep -o '"now":"[^"]*"' | head -1 | sed 's/.*:"//;s/"//'; }

name() {
  case "$1" in
    vless-reality) echo "VLESS+Reality (TCP)";;
    hysteria2)     echo "Hysteria2 (UDP)";;
    *)             echo "$1";;
  esac
}

sel="$(now_of proxy)"

# Протокол зафиксирован вручную — failover не отслеживаем, сбрасываем базу
if [[ "$sel" != "auto" ]]; then
  echo "manual:$sel" > "$STATE"
  exit 0
fi

cur="$(now_of auto)"
[[ -z "$cur" ]] && exit 0

prev="$(cat "$STATE" 2>/dev/null || true)"
echo "$cur" > "$STATE"

# Не уведомляем на первом запуске или сразу после ручного режима
case "$prev" in
  ""|manual:*) exit 0 ;;
esac

if [[ "$cur" != "$prev" ]]; then
  osascript -e "display notification \"Теперь активен: $(name "$cur")\" with title \"VPN: смена протокола\" subtitle \"было: $(name "$prev")\" sound name \"Submarine\"" >/dev/null 2>&1 || true
fi
