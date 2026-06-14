#!/usr/bin/env bash
#
# upgrade-client.sh — пересобирает клиентский конфиг из ОБНОВЛЁННОГО шаблона,
# сохраняя твои значения (IP/UUID/ключи/секрет). Делает бэкап, проверяет конфиг,
# разворачивает и перезагружает демон. Безопасно: при проблеме есть .bak для отката.

set -euo pipefail
[[ "$(uname -s)" == "Darwin" ]] || { echo "Только для macOS."; exit 1; }

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL="$DIR/configs/singbox-client.local.json"
TMPL="$DIR/configs/singbox-client.template.json"
[ -f "$LOCAL" ] || { echo "Нет $LOCAL — сначала запусти install-macos-daemon.sh"; exit 1; }

BAK="$LOCAL.bak.$(date +%s)"
cp "$LOCAL" "$BAK"
echo "[*] Бэкап: $BAK"

python3 - "$LOCAL" "$TMPL" <<'PY'
import json,sys,re
local,tmpl_path=sys.argv[1],sys.argv[2]
d=json.load(open(local))
def find(tag):
    for o in d.get("outbounds",[]):
        if o.get("tag")==tag: return o
    return {}
v=find("vless-reality"); tls=v.get("tls",{}); rl=tls.get("reality",{})
sid=rl.get("short_id","")
if isinstance(sid,list): sid=(sid or [""])[0]
vals={
 "__SERVER_IP__": v.get("server",""),
 "__VLESS_UUID__": v.get("uuid",""),
 "__REALITY_SNI__": tls.get("server_name",""),
 "__REALITY_PUBLIC_KEY__": rl.get("public_key",""),
 "__REALITY_SHORT_ID__": sid,
 "__CLASH_SECRET__": d.get("experimental",{}).get("clash_api",{}).get("secret",""),
}
t=open(tmpl_path).read()
for k,val in vals.items(): t=t.replace(k,val)
left=set(re.findall(r'__[A-Z_]+__',t))
if left:
    print("Не удалось извлечь значения:", left); sys.exit(2)
open(local,"w").write(t)
print("[*] Конфиг пересобран. server="+vals["__SERVER_IP__"]+"  sni="+vals["__REALITY_SNI__"])
PY

echo "[*] Проверяю конфиг (sing-box check)..."
"$(command -v sing-box)" check -c "$LOCAL"
echo "[*] Разворачиваю и перезагружаю демон..."
bash "$DIR/scripts/install-macos-daemon.sh"

echo
echo "[OK] Готово. Если интернет НЕ вернётся за ~15 сек — откат:"
echo "  cp \"$BAK\" \"$LOCAL\" && bash $DIR/scripts/install-macos-daemon.sh"
