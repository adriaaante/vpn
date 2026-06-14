#!/usr/bin/env bash
#
# vpn-proto.sh — выбор протокола «на лету» через Clash API sing-box.
# Работает БЕЗ sudo и БЕЗ перезапуска демона (живое переключение).
#
#   vpn-proto auto         автоматический выбор (urltest) — по умолчанию
#   vpn-proto reality      принудительно VLESS+Reality (TCP)
#   vpn-proto hysteria2    принудительно Hysteria2 (UDP)
#   vpn-proto status       что выбрано и какой протокол реально активен
#
# Выбор сохраняется в cache.db и переживает перезапуск/сон.

set -euo pipefail

CFG="/etc/sing-box/config.json"

CTRL="$(grep -o '"external_controller": *"[^"]*"' "$CFG" 2>/dev/null | sed 's/.*"\([^"]*\)"/\1/')"
SECRET="$(grep -o '"secret": *"[^"]*"' "$CFG" 2>/dev/null | sed 's/.*"\([^"]*\)"/\1/')"
CTRL="${CTRL:-127.0.0.1:9090}"

api() { curl -fsS -H "Authorization: Bearer $SECRET" "$@"; }
now_of() {  # текущий "now" для указанного селектора/urltest
  api "http://$CTRL/proxies/$1" 2>/dev/null | grep -o '"now":"[^"]*"' | head -1 | sed 's/.*:"//;s/"//'
}
switch() {
  api -X PUT "http://$CTRL/proxies/proxy" -d "{\"name\":\"$1\"}" >/dev/null \
    && echo "Протокол переключён на: $1" \
    || { echo "Не удалось обратиться к Clash API ($CTRL). Туннель запущен?"; exit 1; }
}

cmd="${1:-status}"
case "$cmd" in
  auto)              switch "auto" ;;
  reality|vless)     switch "vless-reality" ;;
  hysteria2|hy2)     switch "hysteria2" ;;
  status)
    sel="$(now_of proxy)"
    echo "Выбрано: ${sel:-неизвестно}"
    if [[ "$sel" == "auto" ]]; then
      echo "Реально активен (auto): $(now_of auto)"
    fi
    ;;
  *)
    echo "Использование: vpn-proto auto|reality|hysteria2|status"; exit 1 ;;
esac
