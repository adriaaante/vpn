#!/usr/bin/env bash
#
# add-domain-routes.sh — добавить маршруты по ИМЕНИ сервера рядом с IP-шными.
# Запускать НА МАКЕ:
#   bash scripts/add-domain-routes.sh lv.pine-ledger.fyi
#
# Зачем: при следующей блокировке адреса достаточно поменять A-запись в DNS —
# устройства переедут сами. IP-маршруты СОХРАНЯЮТСЯ и стоят в urltest первыми,
# поэтому отказ DNS туннель не роняет.
#
# Ключевая тонкость (иначе не работает): в конфиге `default_domain_resolver` —
# это `dns-remote`, который ходит ЧЕРЕЗ туннель. С доменом получилось бы кольцо:
# чтобы подключиться, надо разрешить имя, а имя резолвится только через туннель.
# Поэтому заводим `dns-bootstrap` — DoH мимо туннеля — и правило, что имя сервера
# резолвит только он. Мимо туннеля уходит ровно один этот запрос, и он шифрован.

set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL="$DIR/configs/singbox-client.local.json"
HOSTFILE="$DIR/configs/server-host.txt"
HOST="${1:-}"

[[ -n "$HOST" ]] || { echo "Использование: bash scripts/add-domain-routes.sh <имя.домена>"; exit 2; }
[[ "$HOST" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || { echo "Это не похоже на имя домена: $HOST"; exit 2; }
[[ -f "$LOCAL" ]] || { echo "Нет $LOCAL — сначала настрой клиента."; exit 1; }

# Имя должно резолвиться, иначе маршруты добавятся мёртвыми и urltest будет
# впустую их долбить. FORCE=1 — добавить всё равно (например, DNS ещё расходится).
if ! python3 -c "import socket,sys; socket.getaddrinfo('$HOST',443)" 2>/dev/null; then
  echo "[!] $HOST сейчас НЕ резолвится."
  [[ "${FORCE:-0}" == 1 ]] || { echo "    Подожди распространения DNS или запусти с FORCE=1."; exit 1; }
  echo "    FORCE=1 — добавляю всё равно."
else
  echo "[*] $HOST -> $(python3 -c "import socket;print(', '.join(sorted({a[4][0] for a in socket.getaddrinfo('$HOST',443)})))")"
fi

BAK="$LOCAL.bak.$(date +%s)"
cp "$LOCAL" "$BAK" && echo "[*] Бэкап: $BAK"

HOST="$HOST" python3 - "$LOCAL" <<'PY'
import json,os,sys,copy
p=sys.argv[1]; host=os.environ["HOST"]; d=json.load(open(p))

dns=d.setdefault("dns",{})
srv=dns.setdefault("servers",[])
if not any(s.get("tag")=="dns-bootstrap" for s in srv):
    srv.append({"type":"https","tag":"dns-bootstrap","server":"1.1.1.1","detour":"direct"})
rules=dns.setdefault("rules",[])
rules=[r for r in rules if r.get("server")!="dns-bootstrap"]
rules.insert(0,{"domain":[host],"server":"dns-bootstrap"})
dns["rules"]=rules

outs=d["outbounds"]
vless=[o for o in outs if o.get("type")=="vless"]
if not vless:
    print("В конфиге нет vless-outbound"); sys.exit(1)
# Пересобираем доменные маршруты с нуля — так повторный запуск с другим именем
# не оставляет мусора от прежнего.
outs[:] = [o for o in outs if not str(o.get("tag","")).startswith("reality-dns")]
by_port = {o.get("server_port"): o for o in vless}
new=[]
for port in (443, 2053):
    base = by_port.get(port) or vless[0]
    o=copy.deepcopy(base); o["tag"]=f"reality-dns{port}"; o["server"]=host; o["server_port"]=port
    new.append(o)
idx=max(i for i,o in enumerate(outs) if o.get("type")=="vless")
outs[idx+1:idx+1]=new
tags=[n["tag"] for n in new]
for o in outs:
    if o.get("type") in ("urltest","selector"):
        o["outbounds"]=[t for t in o["outbounds"] if not t.startswith("reality-dns")]+tags
json.dump(d,open(p,"w"),indent=2,ensure_ascii=False)
print("[*] Доменные маршруты:", ", ".join(tags), "->", host)
PY
[[ $? -eq 0 ]] || { echo "[!] Правка не удалась — откат."; cp "$BAK" "$LOCAL"; exit 1; }

if command -v sing-box >/dev/null 2>&1; then
  sing-box check -c "$LOCAL" || { echo "[!] Конфиг невалиден — откат."; cp "$BAK" "$LOCAL"; exit 1; }
  echo "[*] Конфиг валиден."
fi

# Запоминаем имя: upgrade-client.sh пересобирает конфиг из шаблона и иначе стёр бы
# доменные маршруты при следующем обновлении.
echo "$HOST" > "$HOSTFILE"

# SKIP_DEPLOY=1 — нас вызвал upgrade-client.sh, он развернёт демон сам (иначе
# конфиг раскатывался бы дважды подряд).
[[ "${SKIP_DEPLOY:-0}" == 1 ]] || bash "$DIR/scripts/install-macos-daemon.sh"
echo
echo "[OK] Готово. Проверка: curl -s https://ipinfo.io/country  (ждём LV)"
echo "Откат: cp \"$BAK\" \"$LOCAL\" && bash $DIR/scripts/install-macos-daemon.sh"
