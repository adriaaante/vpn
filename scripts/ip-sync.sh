#!/usr/bin/env bash
#
# ip-sync.sh — сервер сам переезжает на новый IPv4, когда владелец сменил адрес у
# хостера. Таймер раз в минуту (install-ip-sync.sh). Запускать НА СЕРВЕРЕ.
#
# Почему через DNS, а не через API EDIS: после смены адреса у сервера мёртв IPv4,
# живёт только IPv6, а session.edisglobal.com по IPv6 не отвечает. Зато DNS-over-HTTPS
# у Cloudflare/Google по IPv6 есть. Поэтому канал такой: владелец (или
# vpn-migrate.sh на маке) ставит новый адрес в A-запись имени сервера, а сервер по
# IPv6 читает её и прописывает адрес себе. Никаких секретов на сервере не нужно.
#
# Защита от случайной правки DNS: если текущий IPv4 ЖИВОЙ, а A-запись показывает
# другое — НЕ переезжаем, только пишем в журнал. Переезд — только когда старый
# адрес реально мёртв.
#
# Шлюз: TXT-запись _gw.<имя> (если владелец её задал), иначе <новый-IP>.1 — у EDIS так.
# Маршрутизация у хостера доезжает не сразу после письма: change-server-ip.sh
# упадёт на пинге, а следующий тик через минуту повторит — он идемпотентен.

set -uo pipefail
NP="${NP:-/etc/netplan/50-cloud-init.yaml}"
HOSTFILE="${HOSTFILE:-/etc/sing-box/server-host.txt}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK=/tmp/ip-sync.lock
log(){ echo "[ip-sync] $*"; }

exec 9>"$LOCK"
flock -n 9 || exit 0

HOST="$(tr -d '[:space:]' < "$HOSTFILE" 2>/dev/null || true)"
[[ -n "$HOST" ]] || { log "нет имени сервера в $HOSTFILE — нечего сверять"; exit 0; }
[[ -f "$NP" ]] || { log "нет $NP"; exit 0; }

CUR=$(grep -oE '"[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]+"' "$NP" | head -1 | tr -d '"'); CUR="${CUR%%/*}"

# DNS по IPv6 через DoH: единственное, что доступно серверу без IPv4.
doh(){ # doh <name> <type> -> первое значение
  local name="$1" type="$2" r
  for url in "https://cloudflare-dns.com/dns-query" "https://dns.google/resolve"; do
    r=$(curl -6 -fsS --max-time 8 -H 'accept: application/dns-json' \
          "$url?name=$name&type=$type" 2>/dev/null)
    [[ -n "$r" ]] || continue
    # JSON — через переменную окружения: stdin занят текстом самого скрипта.
    R="$r" python3 - "$type" <<'PY' && return 0
import json,os,sys
d=json.loads(os.environ["R"]); t=sys.argv[1]
want={"A":1,"TXT":16}[t]
for a in d.get("Answer",[]):
    if a.get("type")==want:
        print(a["data"].strip('"')); sys.exit(0)
sys.exit(1)
PY
  done
  return 1
}

WANT=$(doh "$HOST" A) || { log "не удалось прочитать A-запись $HOST по IPv6 — жду"; exit 0; }
[[ "$WANT" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || { log "странный ответ DNS: $WANT"; exit 0; }
[[ "$WANT" == "$CUR" ]] && exit 0   # всё на месте, молчим

# Адрес в DNS другой. Жив ли текущий IPv4?
if curl -4 -fsS --max-time 6 -o /dev/null https://api.ipify.org 2>/dev/null; then
  log "DNS указывает на $WANT, но текущий $CUR живой — не переезжаю (правка DNS случайна?)"
  exit 0
fi

GW=$(doh "_gw.$HOST" TXT 2>/dev/null || true)
[[ "$GW" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || GW="${WANT%.*}.1"
log "IPv4 $CUR мёртв, DNS ведёт на $WANT (шлюз $GW) — переезжаю"
bash "$REPO/scripts/change-server-ip.sh" "$WANT" "$GW"
