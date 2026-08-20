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
[[ "$NEW" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || { echo "Это не похоже на IPv4: $NEW"; exit 2; }
[[ -f "$LOCAL" ]] || { echo "Нет $LOCAL — сначала настрой клиента."; exit 1; }

BAK="$LOCAL.bak.$(date +%s)"
cp "$LOCAL" "$BAK" && echo "[*] Бэкап: $BAK"

NEW="$NEW" python3 - "$LOCAL" <<'PY'
import json,os,sys
p=sys.argv[1]; d=json.load(open(p)); new=os.environ["NEW"]; old=set(); n=0
for o in d.get("outbounds",[]):
    if o.get("type")!="vless": continue
    old.add(o.get("server")); o["server"]=new; n+=1
json.dump(d,open(p,"w"),indent=2)
print(f"[*] Адрес заменён в {n} outbound: {', '.join(sorted(map(str,old)))} -> {new}")
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
