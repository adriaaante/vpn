#!/usr/bin/env bash
#
# vpn-proto.sh — выбор протокола «на лету» через Clash API sing-box.
# Работает БЕЗ sudo и БЕЗ перезапуска демона (живое переключение).
#
#   vpn-proto auto         авто-выбор домена-прикрытия (urltest) — по умолчанию
#   vpn-proto status       какой домен сейчас реально активен
#   vpn-proto test         пинг активного домена
#
# Multi-decoy: клиент держит несколько Reality-доменов (apple/cloudflare/google/
# mozilla) в одном urltest; работает совпавший с сервером, при отвале — failover.
# Фиксировать один домен НЕ нужно (сломается при авто-смене на сервере) — только auto.
#
# Выбор сохраняется в cache.db и переживает перезапуск/сон.

set -euo pipefail

CFG="/etc/sing-box/config.json"

CTRL="$(grep -o '"external_controller": *"[^"]*"' "$CFG" 2>/dev/null | sed 's/.*"\([^"]*\)"/\1/')"
SECRET="$(grep -o '"secret": *"[^"]*"' "$CFG" 2>/dev/null | sed 's/.*"\([^"]*\)"/\1/')"
CTRL="${CTRL:-127.0.0.1:9090}"

SDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
busy() { bash "$SDIR/vpn-busy.sh" "$1" 2>/dev/null || true; }
trap 'busy end' EXIT  # никогда не оставлять залипший спиннер

api() { curl -fsS -H "Authorization: Bearer $SECRET" "$@"; }
now_of() {  # текущий "now" для указанного селектора/urltest
  api "http://$CTRL/proxies/$1" 2>/dev/null | grep -o '"now": *"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/'
}
switch() {
  busy begin
  api -X PUT "http://$CTRL/proxies/proxy" -d "{\"name\":\"$1\"}" >/dev/null \
    && { busy end; echo "Протокол переключён на: $1"; } \
    || { busy end; echo "Не удалось обратиться к Clash API ($CTRL). Туннель запущен?"; exit 1; }
}

cmd="${1:-status}"
case "$cmd" in
  auto)              switch "auto" ;;
  reality|vless)     echo "Multi-decoy: фиксировать один домен нельзя (сломается при авто-смене). Ставлю auto."; switch "auto" ;;
  status)
    sel="$(now_of proxy)"
    echo "Выбрано: ${sel:-неизвестно}"
    if [[ "$sel" == "auto" ]]; then
      echo "Реально активен (auto): $(now_of auto)"
    fi
    ;;
  test)
    sel="$(now_of proxy)"; target="$sel"
    [[ "$sel" == "auto" ]] && target="$(now_of auto)"
    d="$(api "http://$CTRL/proxies/$target/delay?timeout=3000&url=https://www.gstatic.com/generate_204" 2>/dev/null | grep -o '"delay":[0-9]*' | sed 's/.*://')"
    echo "Пинг $target: ${d:-таймаут} ms"
    ;;
  *)
    echo "Использование: vpn-proto auto|status|test"; exit 1 ;;
esac
