#!/usr/bin/env bash
#
# repair-access.sh — вернуть пользователей в конфиг сервера, если их там не стало.
# Запускать НА СЕРВЕРЕ под root:
#   bash scripts/repair-access.sh
#
# Зачем: в vless-инбаундах может оказаться пустой список `users` — тогда Reality
# рукопожатие проходит, а дальше сервер отвечает `unknown UUID` ВСЕМ, включая
# владельца, и это выглядит как «VPN просто перестал работать». Так и вышло
# 2026-08-21: `vpn-users.sh apply` собрал конфиг из пустого реестра.
#
# Что делает: ищет живых пользователей — сначала в реестре, потом в самых свежих
# бэкапах конфига (`config.json.bak.*`, их пишет сам vpn-users.sh) — возвращает
# их в реестр и пересобирает конфиг штатным `vpn-users.sh apply` (бэкап, check,
# рестарт, откат при неудаче). Ничего не удаляет и ключей не меняет.

set -uo pipefail
CFG="${CFG:-/etc/sing-box/config.json}"
STORE="${STORE:-/etc/sing-box/users.json}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

[[ -f "$CFG" ]] || { echo "Нет $CFG"; exit 1; }

echo "[*] Сейчас в конфиге:"
CFG="$CFG" STORE="$STORE" python3 <<'PY'
import json,os
c=json.load(open(os.environ["CFG"]))
for i in c.get("inbounds",[]):
    if i.get("type")!="vless": continue
    us=i.get("users") or []
    names=", ".join(u.get("name") or "?" for u in us) or "НИКОГО"
    print(f"    порт {i.get('listen_port')}: {len(us)} — {names}")
st=os.environ["STORE"]
if os.path.exists(st):
    d=json.load(open(st))
    print(f"    реестр {st}: {len(d.get('users',[]))} записей, flow={d.get('flow') or '—'}")
else:
    print(f"    реестра {st} нет")
PY

# Восстанавливаем реестр из бэкапов, если в нём (или в конфиге) пусто.
# Код 3 = «чинить нечего», это не ошибка, поэтому без `|| exit` — разбор ниже.
CFG="$CFG" STORE="$STORE" python3 <<'PY'
import glob,json,os

cfg, store_path = os.environ["CFG"], os.environ["STORE"]

def vless(c):
    return [i for i in c.get("inbounds",[]) if i.get("type")=="vless"]

def harvest(c):
    """Пользователи и flow из конфига — что есть в самом первом непустом инбаунде."""
    for i in vless(c):
        us=[u for u in (i.get("users") or []) if u.get("uuid")]
        if us:
            flow=next((u.get("flow") for u in us if u.get("flow")), "")
            return us, flow
    return [], ""

store={"flow":"","users":[]}
if os.path.exists(store_path):
    try:
        store=json.load(open(store_path))
    except ValueError:
        print("[!] Реестр не читается как JSON — соберу заново из бэкапов.")
        store={"flow":"","users":[]}
store.setdefault("users",[]); store.setdefault("flow","")

have_cfg, cfg_flow = harvest(json.load(open(cfg)))
if store["users"] and any(u.get("enabled") for u in store["users"]) and have_cfg:
    print("[OK] Пользователи есть и в реестре, и в конфиге — чинить нечего.")
    raise SystemExit(3)

# Источники по убыванию свежести: текущий конфиг, затем его бэкапы.
sources=[cfg]+sorted(glob.glob(cfg+".bak.*"), reverse=True)
found, flow = have_cfg, cfg_flow
for src in sources:
    if found: break
    try:
        found, flow = harvest(json.load(open(src)))
    except Exception:
        continue
    if found:
        print(f"[*] Нашёл пользователей в {src}: "
              + ", ".join(u.get("name") or "?" for u in found))

if not found:
    print("[!] Ни в конфиге, ни в бэкапах нет ни одного uuid. Восстановить нечего —")
    print("    ключ берётся из /etc/sing-box/credentials.txt или из клиентского конфига.")
    raise SystemExit(1)

known={u.get("uuid") for u in store["users"]}
for n,u in enumerate(found):
    if u["uuid"] in known: continue
    store["users"].append({"name":u.get("name") or ("owner" if n==0 else f"user{n}"),
                           "uuid":u["uuid"],"enabled":True,
                           "note":"восстановлен repair-access.sh",
                           "protected": n==0 and not known})
for u in store["users"]:
    u["enabled"]=True if u.get("uuid") in {x["uuid"] for x in found} else u.get("enabled",True)
store["flow"]=store.get("flow") or flow
json.dump(store,open(store_path,"w"),indent=2,ensure_ascii=False)
os.chmod(store_path,0o600)
print(f"[*] Реестр обновлён: {len(store['users'])} записей, flow={store['flow'] or '—'}")
PY
rc=$?
[[ $rc -eq 3 ]] && exit 0
[[ $rc -eq 0 ]] || exit $rc

echo "[*] Пересобираю конфиг штатным vpn-users.sh (бэкап + check + откат при сбое)..."
CFG="$CFG" STORE="$STORE" bash "$REPO/scripts/vpn-users.sh" apply || exit 1

echo
echo "[*] Стало:"
CFG="$CFG" python3 <<'PY'
import json,os
c=json.load(open(os.environ["CFG"]))
for i in c.get("inbounds",[]):
    if i.get("type")!="vless": continue
    us=i.get("users") or []
    print(f"    порт {i.get('listen_port')}: {len(us)} — "
          + (", ".join(f"{u.get('name')} flow={u.get('flow') or '—'}" for u in us) or "НИКОГО"))
PY
echo "[OK] Готово. Проверь с клиента: bash scripts/vpn.sh on && curl -s https://ipinfo.io/country"
