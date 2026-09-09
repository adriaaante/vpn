#!/usr/bin/env bash
#
# check-ru-direct.sh — какие российские сервисы РЕАЛЬНО идут напрямую, а какие
# уходят в туннель. Запускать НА МАКЕ:
#   bash scripts/check-ru-direct.sh                 # встроенный список
#   bash scripts/check-ru-direct.sh parking.mos.ru tbank.ru   # свои хосты
#
# Проверяет ДВА независимых пути, которыми трафик уходит напрямую:
#   1) по ДОМЕНУ — правило route с domain_suffix. Работает сразу при старте и
#      только если виден SNI.
#   2) по АДРЕСУ — набор geoip-ru. Работает всегда, но это УДАЛЁННЫЙ набор: он
#      скачивается через туннель, и пока не скачался, не действует (грабля №11).
# Опасен только хост, не покрытый НИ ОДНИМ из путей — он гарантированно идёт
# через Латвию, и российский сервис видит зарубежный адрес.
#
# NB: `sing-box rule-set match` печатает вердикт в STDERR, а не в stdout — с
# `2>/dev/null` проверка молча показывает «не покрыто» для всего подряд.

set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CFG="${LOCAL:-$DIR/configs/singbox-client.local.json}"
[[ -f "$CFG" ]] || CFG="$DIR/configs/singbox-client.template.json"
SRS="${SRS:-${TMPDIR:-/tmp}/geoip-ru.srs}"
SRS_URL="https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-ru.srs"

HOSTS=("$@")
if [ "${#HOSTS[@]}" -eq 0 ]; then
  # Парковки и город, T-Банк, платёжные, госуслуги — то, что чаще всего просят.
  HOSTS=(parking.mos.ru lk.parking.mos.ru api.parking.mos.ru pgu.mos.ru avtokod.mos.ru
         transport.mos.ru troika.mos.ru emias.info emias.mos.ru
         tbank.ru id.tbank.ru secure.tbank.ru api.tinkoff.ru acdn.tinkoff.ru
         qr.nspk.ru sbp.nspk.ru privetmir.ru yookassa.ru cloudpayments.ru
         online.sberbank.ru sberbank.com alfabank.ru online.vtb.ru
         gosuslugi.ru esia.gosuslugi.ru nalog.gov.ru)
fi

# Список доменных суффиксов берём ИЗ КОНФИГА, а не пишем руками: иначе проверка
# будет расходиться с тем, что реально стоит у клиента.
SUFFIXES="$(python3 - "$CFG" <<'PY'
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: sys.exit(0)
for r in d.get("route",{}).get("rules",[]):
    if r.get("outbound")=="direct":
        for s in (r.get("domain_suffix") or []): print(s)
PY
)"
[ -n "$SUFFIXES" ] || { echo "В $CFG не нашлось правил «напрямую по домену»."; exit 1; }
echo "[*] Конфиг: $CFG"
echo "[*] Доменных суффиксов в правиле: $(printf '%s\n' "$SUFFIXES" | grep -c .)"

HAVE_SB=0; command -v sing-box >/dev/null 2>&1 && HAVE_SB=1
if [ "$HAVE_SB" = 1 ]; then
  if [ ! -s "$SRS" ] || [ -n "$(find "$SRS" -mtime +1 2>/dev/null)" ]; then
    curl -fsSL --max-time 30 -o "$SRS" "$SRS_URL" 2>/dev/null \
      || echo "[!] Не скачался список рос. адресов — проверю только по доменам."
  fi
  [ -s "$SRS" ] || HAVE_SB=0
else
  echo "[!] sing-box не найден — проверю только по доменам."
fi

resolve() {
  curl -fsS --max-time 6 -H 'accept: application/dns-json' \
    "https://cloudflare-dns.com/dns-query?name=$1&type=A" 2>/dev/null \
  | python3 -c 'import json,sys
try: print(next(a["data"] for a in json.load(sys.stdin).get("Answer",[]) if a.get("type")==1))
except Exception: print("")' 2>/dev/null
}

bad=""
printf "\n%-24s %-16s %-10s %s\n" "ХОСТ" "АДРЕС" "ПО ДОМЕНУ" "ПО АДРЕСУ"
for h in "${HOSTS[@]}"; do
  by_dom="нет"
  while IFS= read -r suf; do
    [ -n "$suf" ] || continue
    s="${suf#.}"
    case "$h" in "$s"|*".$s") by_dom="да"; break;; esac
  done <<< "$SUFFIXES"

  ip="$(resolve "$h")"
  by_ip="?"
  if [ -z "$ip" ]; then
    by_ip="нет A-записи"
  elif [ "$HAVE_SB" = 1 ]; then
    # </dev/null обязателен: иначе sing-box съедает stdin и цикл обрывается.
    if sing-box rule-set match --format binary "$SRS" "$ip" </dev/null 2>&1 | grep -q '^match'; then
      by_ip="да"
    else
      by_ip="нет"
    fi
  fi
  printf "%-24s %-16s %-10s %s\n" "$h" "${ip:-—}" "$by_dom" "$by_ip"
  [ "$by_dom" = "нет" ] && [ "$by_ip" = "нет" ] && bad="$bad $h"
done

echo
if [ -n "$bad" ]; then
  echo "[!] Идут ЧЕРЕЗ ТУННЕЛЬ (рос. сервис увидит зарубежный адрес):"
  for h in $bad; do echo "    $h"; done
  echo "    Лечится добавлением домена в правило: см. WANT в scripts/fix-ru-rules.sh"
else
  echo "[OK] Все проверенные хосты идут напрямую хотя бы одним путём."
  echo "     Помеченные «по домену: нет» уязвимы только в первые секунды после"
  echo "     запуска, пока не скачался список адресов — на маке он в кеше, на"
  echo "     айфоне кеш включён с 09.09.2026 (грабля №11)."
fi
