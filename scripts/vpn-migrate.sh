#!/usr/bin/env bash
#
# vpn-migrate.sh — переезд на новый IP сервера ОДНОЙ командой. Запускать НА МАКЕ,
# когда хостер уже выдал новый адрес (письмо «Assigned IPv4»):
#   cd ~/vpn && bash scripts/vpn-migrate.sh 203.0.113.7
#   cd ~/vpn && bash scripts/vpn-migrate.sh 203.0.113.7 203.0.113.254   # если шлюз не .1
#
# Что происходит:
#   1. A-запись имени сервера -> новый адрес (через API Porkbun, если ключи лежат в
#      configs/porkbun-api.local.txt; иначе попросит поменять руками и подождёт).
#   2. Сервер по IPv6 видит новую A-запись (ip-sync.sh, таймер раз в минуту) и
#      сам прописывает адрес — заходить на него через VNC больше не нужно.
#   3. Мак переселяется на новый адрес (set-server-ip.sh), туннель включается.
#   Гости ничего не делают: их узлы прописаны по имени.
#
# Ключи Porkbun (API Key и Secret, раздел API Access в аккаунте; у домена должен быть
# включён API Access) — двумя строками в configs/porkbun-api.local.txt. В репозиторий
# файл не попадает (gitignore).

set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEYS="$DIR/configs/porkbun-api.local.txt"
HOSTFILE="$DIR/configs/server-host.txt"
NEW="${1:-}"; GW="${2:-}"
[[ "$NEW" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || { echo "Использование: bash scripts/vpn-migrate.sh <новый-IP> [шлюз]"; exit 2; }
HOST="$(tr -d '[:space:]' < "$HOSTFILE" 2>/dev/null || true)"
[[ -n "$HOST" ]] || { echo "Нет $HOSTFILE с именем сервера."; exit 1; }
SUB="${HOST%%.*}"; DOMAIN="${HOST#*.}"   # lv.pine-ledger.fyi -> lv + pine-ledger.fyi

resolve(){ # текущая A-запись через DoH (мимо кеша мака)
  curl -fsS --max-time 8 -H 'accept: application/dns-json' \
    "https://cloudflare-dns.com/dns-query?name=$HOST&type=A" 2>/dev/null \
  | python3 -c 'import json,sys
for a in json.load(sys.stdin).get("Answer",[]):
    if a.get("type")==1: print(a["data"]); break' 2>/dev/null
}

echo "=== 1. DNS: $HOST -> $NEW ==="
if [[ "$(resolve)" == "$NEW" ]]; then
  echo "  уже указывает на $NEW"
elif [[ -s "$KEYS" ]]; then
  API=$(sed -n 1p "$KEYS" | tr -d '[:space:]'); SEC=$(sed -n 2p "$KEYS" | tr -d '[:space:]')
  pb(){ # pb <path> <json-доп.поля>
    curl -fsS --max-time 20 -H 'Content-Type: application/json' \
      -d "{\"apikey\":\"$API\",\"secretapikey\":\"$SEC\"${2:+,$2}}" \
      "https://api.porkbun.com/api/json/v3/$1" 2>&1
  }
  echo "  Porkbun: $(pb ping | head -c 120)"
  r=$(pb "dns/editByNameType/$DOMAIN/A/$SUB" "\"content\":\"$NEW\",\"ttl\":\"600\"")
  if [[ "$r" == *SUCCESS* ]]; then echo "  A-запись обновлена ✅"
  else echo "  Porkbun ответил: $r"; echo "  Не вышло — поменяйте A-запись «$SUB» на $NEW руками в Porkbun, я подожду."; fi
  if [[ -n "$GW" ]]; then
    r=$(pb "dns/editByNameType/$DOMAIN/TXT/_gw.$SUB" "\"content\":\"$GW\",\"ttl\":\"600\"")
    [[ "$r" == *SUCCESS* ]] || r=$(pb "dns/create/$DOMAIN" "\"name\":\"_gw.$SUB\",\"type\":\"TXT\",\"content\":\"$GW\",\"ttl\":\"600\"")
    [[ "$r" == *SUCCESS* ]] && echo "  шлюз $GW записан в TXT _gw.$SUB ✅" || echo "  TXT со шлюзом не записался: $r"
  fi
else
  echo "  Ключей Porkbun нет ($KEYS) — поменяйте A-запись «$SUB» домена $DOMAIN на $NEW"
  echo "  руками в Porkbun. Я подожду, пока DNS покажет новый адрес."
fi

echo "=== 2. Жду, пока DNS разойдётся (TTL 600, до 10 мин) ==="
for i in $(seq 1 60); do
  [[ "$(resolve)" == "$NEW" ]] && { echo "  DNS показывает $NEW ✅"; break; }
  (( i % 6 == 0 )) && echo "  …ещё нет ($((i*10)) с)"
  sleep 10
done

echo "=== 3. Мак: переселяю узлы на $NEW (нужен sudo) ==="
bash "$DIR/scripts/set-server-ip.sh" "$NEW" || { echo "  set-server-ip.sh не прошёл — см. выше"; exit 1; }

echo "=== 4. Жду, пока сервер сам прописал адрес (ip-sync на сервере, ~1–3 мин) ==="
ok=0
for i in $(seq 1 36); do
  if curl -sS --noproxy '*' --max-time 6 --connect-to "www.apple.com:443:$NEW:443" \
       -o /dev/null https://www.apple.com/ 2>/dev/null; then ok=1; echo "  сервер отвечает на $NEW ✅"; break; fi
  (( i % 6 == 0 )) && echo "  …сервер ещё не поднялся ($((i*10)) с)"
  sleep 10
done
if (( ! ok )); then
  echo "  Сервер не ответил за 6 минут. Проверьте на нём: journalctl -u ip-sync -n 10"
  echo "  (через VNC, если SSH не пускает). Возможно, шлюз не .1 — повторите с явным шлюзом."
  exit 1
fi

echo "=== 5. Включаю туннель ==="
bash "$DIR/scripts/vpn.sh" on
sleep 4
echo "  страна выхода: $(curl -s --max-time 8 https://ipinfo.io/country)  (ждём LV)"
echo
echo "[OK] Переезд завершён. Гости переедут сами по имени $HOST."
