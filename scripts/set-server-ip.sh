#!/usr/bin/env bash
#
# set-server-ip.sh — переезд клиента на НОВЫЙ адрес сервера (ключи не меняются).
# Нужен, когда старый IP заблокировали и хостер выдал другой:
#   cd ~/vpn && bash scripts/set-server-ip.sh 203.0.113.7
#
# Правит адрес во ВСЕХ vless-outbound (их много: multi-decoy + запасные порты),
# проверяет конфиг и перезагружает демон. Ключи/uuid/short_id не трогает — на
# сервере они прежние, поэтому клиент оживает сразу.

set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL="$DIR/configs/singbox-client.local.json"
NEW="${1:-}"

[[ -n "$NEW" ]] || { echo "Использование: bash scripts/set-server-ip.sh <новый-IP>"; exit 2; }
# Принимаем и IPv4, и IPv6 (переезд на v6 — способ обойти блокировку v4-адреса).
if [[ "$NEW" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then :
elif [[ "$NEW" == *:* ]]; then :
else echo "Это не похоже на IP-адрес: $NEW"; exit 2; fi
[[ -f "$LOCAL" ]] || { echo "Нет $LOCAL — сначала настрой клиента."; exit 1; }

BAK="$LOCAL.bak.$(date +%s)"
cp "$LOCAL" "$BAK" && echo "[*] Бэкап: $BAK"

NEW="$NEW" HOSTFILE="$DIR/configs/server-host.txt" python3 - "$LOCAL" <<'PY'
import json,os,sys
p=sys.argv[1]; d=json.load(open(p)); new=os.environ["NEW"]; old=set(); n=0
for o in d.get("outbounds",[]):
    # reality-dns* специально ходят по ИМЕНИ сервера — их адрес не трогаем,
    # иначе доменные маршруты (страховка от блокировки IP) молча исчезают.
    if o.get("type")!="vless" or str(o.get("tag","")).startswith("reality-dns"): continue
    old.add(o.get("server")); o["server"]=new; n+=1

# Сам сервер должен идти МИМО туннеля. Иначе ssh и веб-панель к нему заворачиваются
# в туннель и рвутся при каждом перезапуске sing-box на сервере (правка
# пользователей, decoy-monitor): страница пустеет, начатое действие обрывается.
rules=d.setdefault("route",{}).setdefault("rules",[])

def is_bypass(r):
    # Своей пометки в правило не добавить: sing-box строг к неизвестным полям и
    # падает при старте. Поэтому узнаём прежний обход по форме правила.
    if set(r) - {"ip_cidr","domain","outbound"} or r.get("outbound")!="direct":
        return False
    c=r.get("ip_cidr") or []
    if len(c)==1 and str(c[0]).endswith(("/32","/128")):
        return True
    return not c and len(r.get("domain") or [])==1

rules[:] = [r for r in rules if not is_bypass(r)]
mask = "/128" if ":" in new else "/32"
host=""
try: host=open(os.environ["HOSTFILE"]).read().strip()
except OSError: pass
# Адрес и имя — ДВУМЯ правилами: внутри одного правила условия объединяются по И,
# и «этот IP И это имя» не совпало бы почти никогда.
add=[{"ip_cidr":[new+mask],"outbound":"direct"}]
if host: add.append({"domain":[host],"outbound":"direct"})
at=next((i for i,r in enumerate(rules) if r.get("ip_is_private")), 1)
rules[at+1:at+1]=add
json.dump(d,open(p,"w"),indent=2,ensure_ascii=False)
print(f"[*] Адрес заменён в {n} outbound: {', '.join(sorted(map(str,old)))} -> {new}")
print(f"[*] Сервер идёт мимо туннеля: {new}{mask}" + (f" и {host}" if host else ""))
PY
[[ $? -eq 0 ]] || { echo "[!] Правка не удалась — откат."; cp "$BAK" "$LOCAL"; exit 1; }

if command -v sing-box >/dev/null 2>&1; then
  sing-box check -c "$LOCAL" || { echo "[!] Конфиг невалиден — откат."; cp "$BAK" "$LOCAL"; exit 1; }
  echo "[*] Конфиг валиден."
fi

bash "$DIR/scripts/install-macos-daemon.sh"
echo
echo "[OK] Клиент переехал на $NEW. Проверка: curl -s https://ipinfo.io/country  (ждём LV)"
echo "Откат: cp \"$BAK\" \"$LOCAL\" && bash $DIR/scripts/install-macos-daemon.sh"
