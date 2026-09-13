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
# Принимаем и АДРЕС, и ИМЯ. Имя лучше: у второго сервера будет свой поддомен
# (скажем se.pine-ledger.fyi), и при блокировке его адреса достаточно поменять
# A-запись — узел переедет сам, как это уже работает для основного сервера.
if [[ "$NEW" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then KIND=ip
elif [[ "$NEW" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]]; then KIND=host
else echo "Использование: bash scripts/add-client-ip.sh [--remove] <IP-или-имя>"; exit 2; fi
[[ -f "$LOCAL" ]] || { echo "Нет $LOCAL — сначала настрой клиента."; exit 1; }

BAK="$LOCAL.bak.$(date +%s)"
cp "$LOCAL" "$BAK" && echo "[*] Бэкап: $BAK"

OP="$OP" NEW="$NEW" KIND="$KIND" python3 - "$LOCAL" <<'PY'
import json,os,sys,copy
p=sys.argv[1]; new=os.environ["NEW"]; op=os.environ["OP"]; kind=os.environ["KIND"]
# Обход «сам сервер мимо туннеля» для адреса задаётся по ip_cidr, для имени — по
# domain. Внутри ОДНОГО правила условия объединяются по И, поэтому смешивать нельзя.
bypass = {"ip_cidr":[new+"/32"],"outbound":"direct"} if kind=="ip" else {"domain":[new],"outbound":"direct"}
def is_bypass(x): return x.get("ip_cidr")==bypass.get("ip_cidr") and x.get("domain")==bypass.get("domain")
d=json.load(open(p)); outs=d.setdefault("outbounds",[])
# Тег помечен адресом: по нему же и удаляем, и не плодим дублей при повторном запуске.
mark="reality-ip-"+new.replace(".","-")   # тег годится и для адреса, и для имени
groups=[o for o in outs if o.get("type") in ("urltest","selector")]

if op=="remove":
    tags={o["tag"] for o in outs if str(o.get("tag","")).startswith(mark)}
    if not tags: print(f"[*] Узлов на {new} нет — убирать нечего."); sys.exit(3)
    outs[:] = [o for o in outs if o.get("tag") not in tags]
    for g in groups: g["outbounds"]=[t for t in g.get("outbounds",[]) if t not in tags]
    r=d.setdefault("route",{}).setdefault("rules",[])
    r[:] = [x for x in r if not is_bypass(x)]
    for dr in d.get("dns",{}).get("rules",[]):
        if dr.get("server")=="dns-bootstrap" and new in (dr.get("domain") or []):
            dr["domain"]=[x for x in dr["domain"] if x!=new]
    d.setdefault("dns",{})["rules"]=[r for r in d.get("dns",{}).get("rules",[])
                                     if r.get("server")!="dns-bootstrap" or r.get("domain")]
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
# Имя сервера надо резолвить МИМО туннеля, иначе кольцо: чтобы подключиться, нужно
# разрешить имя, а разрешить нечем — именно тогда, когда туннель и не работает.
# Заводим (или переиспользуем) dns-bootstrap поверх непустого direct-dns: пустой
# direct sing-box отвергает при старте (грабля №6).
if kind=="host":
    dns=d.setdefault("dns",{}); srv=dns.setdefault("servers",[])
    if not any(x.get("tag")=="direct-dns" for x in outs):
        outs.append({"type":"direct","tag":"direct-dns","connect_timeout":"5s"})
    if not any(x.get("tag")=="dns-bootstrap" for x in srv):
        srv.append({"type":"https","tag":"dns-bootstrap","server":"1.1.1.1","detour":"direct-dns"})
    drules=dns.setdefault("rules",[])
    hit=next((r for r in drules if r.get("server")=="dns-bootstrap"), None)
    if hit is None:
        drules.insert(0,{"domain":[new],"server":"dns-bootstrap"})
    elif new not in (hit.get("domain") or []):
        hit["domain"]=list(hit.get("domain") or [])+[new]
    print(f"[*] {new} резолвится мимо туннеля (иначе не подключиться, когда туннель лёг)")

# Сам сервер — мимо туннеля (ssh и панель). Правило ставим сразу после «локальных сетей».
rules=d.setdefault("route",{}).setdefault("rules",[])
if not any(is_bypass(x) for x in rules):
    at=next((i for i,x in enumerate(rules) if x.get("ip_is_private")),0)
    rules.insert(at+1,bypass)
json.dump(d,open(p,"w"),indent=2,ensure_ascii=False)
print(f"[*] Добавлены узлы: {', '.join(made)}")
print(f"[*] {new}{'/32' if kind=='ip' else ''} идёт мимо туннеля (ssh и панель к серверу)")
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
