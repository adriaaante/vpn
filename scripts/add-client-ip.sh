#!/usr/bin/env bash
#
# add-client-ip.sh — добавляет в конфиг мака ВТОРОЙ (третий…) адрес того же сервера,
# чтобы туннель сам перескакивал на живой, когда один адрес заблокируют.
#
#   cd ~/vpn && bash scripts/add-client-ip.sh 203.0.113.9        # добавить
#   cd ~/vpn && bash scripts/add-client-ip.sh --remove 203.0.113.9  # убрать
#
# Как это работает. Ключи, uuid и short_id у адресов ОДНИ И ТЕ ЖЕ — это один сервер,
# просто с несколькими адресами (sing-box слушает "::"). Скрипт клонирует два узла
# на новый адрес (443 и 2053, разные домены-прикрытия), кладёт их в тот же urltest
# и в селектор, и добавляет правило «этот адрес мимо туннеля» — иначе ssh и панель
# к серверу завернутся в туннель и оборвутся при перезапуске sing-box.
# Дальше urltest сам выбирает живой узел: заблокировали один адрес — трафик молча
# уходит на второй, вручную ничего делать не надо.
#
# ВАЖНО про смысл: адреса должны быть из РАЗНЫХ подсетей. Блокируют префиксами, и
# соседний адрес в той же /24 обычно умирает вместе с первым.
# Сначала пропиши адрес на сервере: bash scripts/add-server-ip.sh <IP>

set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL="${LOCAL:-$DIR/configs/singbox-client.local.json}"
INSTALL="${INSTALL:-1}"
OP=add
if [[ "${1:-}" == "--remove" ]]; then OP=remove; shift; fi
NEW="${1:-}"
[[ "$NEW" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || { echo "Использование: bash scripts/add-client-ip.sh [--remove] <IP>"; exit 2; }
[[ -f "$LOCAL" ]] || { echo "Нет $LOCAL — сначала настрой клиента."; exit 1; }

BAK="$LOCAL.bak.$(date +%s)"
cp "$LOCAL" "$BAK" && echo "[*] Бэкап: $BAK"

OP="$OP" NEW="$NEW" python3 - "$LOCAL" <<'PY'
import json,os,sys,copy
p=sys.argv[1]; new=os.environ["NEW"]; op=os.environ["OP"]
d=json.load(open(p)); outs=d.setdefault("outbounds",[])
# Тег помечен адресом: по нему же и удаляем, и не плодим дублей при повторном запуске.
mark="reality-ip-"+new.replace(".","-")
groups=[o for o in outs if o.get("type") in ("urltest","selector")]

if op=="remove":
    tags={o["tag"] for o in outs if str(o.get("tag","")).startswith(mark)}
    if not tags: print(f"[*] Узлов на {new} нет — убирать нечего."); sys.exit(3)
    outs[:] = [o for o in outs if o.get("tag") not in tags]
    for g in groups: g["outbounds"]=[t for t in g.get("outbounds",[]) if t not in tags]
    r=d.setdefault("route",{}).setdefault("rules",[])
    r[:] = [x for x in r if x.get("ip_cidr")!=[new+"/32"]]
    json.dump(d,open(p,"w"),indent=2,ensure_ascii=False)
    print(f"[*] Убрано узлов: {len(tags)} ({new})"); sys.exit(0)

if any(str(o.get("tag","")).startswith(mark) for o in outs):
    print(f"[*] {new} уже добавлен — править нечего."); sys.exit(3)
# За образец берём существующие vless-узлы: в них уже лежат ключи, uuid, short_id
# и flow этого сервера. Берём по одному на порт, чтобы не плодить лишние пробы.
src=[o for o in outs if o.get("type")=="vless" and not str(o.get("tag","")).startswith(("reality-dns","reality-ip-"))]
if not src: print("[!] В конфиге нет vless-узлов — это не наш клиент."); sys.exit(1)
by_port={}
for o in src: by_port.setdefault(o.get("server_port",443),o)
made=[]
for port,proto in sorted(by_port.items())[:2]:
    o=copy.deepcopy(proto); o["server"]=new; o["tag"]=f"{mark}-{port}"
    outs.insert(outs.index(proto)+1,o); made.append(o["tag"])
for g in groups:
    g["outbounds"]=list(dict.fromkeys(list(g.get("outbounds",[]))+made))
# Сам сервер — мимо туннеля (ssh и панель). Правило ставим сразу после «локальных сетей».
rules=d.setdefault("route",{}).setdefault("rules",[])
if not any(x.get("ip_cidr")==[new+"/32"] for x in rules):
    at=next((i for i,x in enumerate(rules) if x.get("ip_is_private")),0)
    rules.insert(at+1,{"ip_cidr":[new+"/32"],"outbound":"direct"})
json.dump(d,open(p,"w"),indent=2,ensure_ascii=False)
print(f"[*] Добавлены узлы: {', '.join(made)}")
print(f"[*] {new}/32 идёт мимо туннеля (ssh и панель к серверу)")
PY
rc=$?
if (( rc == 3 )); then rm -f "$BAK"; exit 0; fi
if (( rc != 0 )); then cp "$BAK" "$LOCAL"; echo "[!] Правка не удалась — откат."; exit 1; fi

if command -v sing-box >/dev/null 2>&1; then
  sing-box check -c "$LOCAL" || { echo "[!] Конфиг невалиден — откат."; cp "$BAK" "$LOCAL"; exit 1; }
  echo "[*] Конфиг валиден."
fi

if [[ "$INSTALL" == 1 ]]; then
  bash "$DIR/scripts/install-macos-daemon.sh" || { echo "[!] Установка не прошла. Откат: cp \"$BAK\" \"$LOCAL\" && bash $DIR/scripts/install-macos-daemon.sh"; exit 1; }
  echo
  echo "[OK] Клиент знает оба адреса и переключится сам. Проверка:"
  echo "   curl -s --max-time 10 https://ipinfo.io/json | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d[\"ip\"],d[\"country\"])'"
fi
