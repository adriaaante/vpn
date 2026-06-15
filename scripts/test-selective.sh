#!/usr/bin/env bash
#
# test-selective.sh — проверка режима «Только сервисы» (selective):
# показывает, какие домены идут через Латвию (vless/proxy), какие напрямую
# (direct), какие блокируются. По окончании возвращает прежний режим.
#
#   bash scripts/test-selective.sh

set -uo pipefail
SDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="/etc/sing-box/config.json"
PREV="$(cat /etc/sing-box/mode 2>/dev/null || echo full)"

echo "Текущий режим: $PREV  →  переключаю в selective для теста…"
bash "$SDIR/vpn-mode.sh" selective >/dev/null 2>&1
sleep 3

SECRET="$(grep -o '"secret": *"[^"]*"' "$CFG" 2>/dev/null | sed 's/.*"\([^"]*\)"/\1/')"

# Фоновый трафик, чтобы соединения были «живыми» в момент опроса API
curl -s --max-time 10 https://www.youtube.com/ >/dev/null &
curl -s --max-time 10 https://example.com/   >/dev/null &
curl -s --max-time 10 https://ya.ru/         >/dev/null &
sleep 2

echo
echo "=== Маршрут по доменам (vless/proxy = Латвия, direct = напрямую) ==="
curl -s -H "Authorization: Bearer $SECRET" http://127.0.0.1:9090/connections | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: print("  нет данных от Clash API"); sys.exit()
seen = set()
for c in d.get("connections", []):
    md = c.get("metadata", {}); host = md.get("host") or md.get("destinationIP", "")
    chain = " > ".join(c.get("chains", [])) or "?"
    if host and host not in seen:
        seen.add(host); print(f"  {host:35} -> {chain}")
if not seen: print("  (активных соединений нет — запусти ещё раз)")
'
wait

echo
echo "=== Доступность в режиме selective (http-код) ==="
curl -s --max-time 8 -o /dev/null -w "  youtube : %{http_code}\n" https://www.youtube.com
curl -s --max-time 8 -o /dev/null -w "  ya.ru   : %{http_code}\n" https://ya.ru
curl -s --max-time 8 -o /dev/null -w "  example : %{http_code}\n" https://example.com

echo
echo "Возвращаю прежний режим: $PREV"
bash "$SDIR/vpn-mode.sh" "$PREV" >/dev/null 2>&1
echo "Готово."
