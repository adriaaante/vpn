#!/usr/bin/env bash
#
# connect-page.sh — собирает и раздаёт ОДНУ красивую страницу подключения с
# PIN-замком. Заходишь по ссылке с телефона → вводишь PIN → выбираешь приложение
# (sing-box «рекомендуется» или Shadowrocket) → под выбранным появляется его
# инструкция + QR/ссылки на все decoy. Секреты зашифрованы (AES-256-GCM), расшифровка
# целиком в браузере — по открытому HTTP уходит только шифртекст.
#
# На сервере:
#   cd /root/vpn && git pull origin main && bash scripts/connect-page.sh
# Затем на АЙФОНЕ (по СОТОВОЙ связи!) открой http://<IP>:8088/ , введи PIN.
# Ctrl+C после импорта — порт в фаерволе закроется, /tmp/vpn-connect удалится.
#
# PIN: спросит интерактивно, либо задай заранее:  PIN=482913 bash scripts/connect-page.sh
# Порт можно сменить:  PORT=9000 bash scripts/connect-page.sh
# Только собрать страницу без раздачи (отладка): BUILD_ONLY=1 ... — index.html
# останется в /tmp/vpn-connect (или $WORK), фаервол не трогается.

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CFG="${CFG:-/etc/sing-box/config.json}"
PBKF="${PBKF:-/etc/sing-box/reality_public_key.txt}"
TPL="$REPO/configs/singbox-client.template.json"
HTML_TPL="$REPO/scripts/assets/connect-page.template.html"
SJCL="$REPO/scripts/assets/sjcl.js"
QRLIB="$REPO/scripts/assets/qrcode.min.js"
PORT="${PORT:-8088}"

for f in "$CFG" "$PBKF" "$TPL" "$HTML_TPL" "$SJCL" "$QRLIB"; do
  [[ -f "$f" ]] || { echo "Не найден: $f"; [[ "$f" == "$PBKF" ]] && echo "  (публичный ключ — сначала запусти fix-reality-sni.sh)"; exit 1; }
done

# --- параметры сервера (домены НЕ печатаем руками — читаем из конфига, грабля №1) ---
IP="${IP:-$(curl -fsSL --max-time 6 https://api.ipify.org 2>/dev/null || echo 192.36.41.201)}"
UUID=$(python3 -c "import json;print(json.load(open('$CFG'))['inbounds'][0]['users'][0]['uuid'])")
SNI=$(python3 -c "import json;print(json.load(open('$CFG'))['inbounds'][0]['tls']['server_name'])")
SID=$(python3 -c "import json;r=json.load(open('$CFG'))['inbounds'][0]['tls']['reality']['short_id'];print(r[0] if isinstance(r,list) else r)")
FLOW=$(python3 -c "import json;print(json.load(open('$CFG'))['inbounds'][0]['users'][0].get('flow',''))")
PBK=$(tr -d '[:space:]' < "$PBKF")

# защита от испорченного markdown-ссылкой SNI (грабля №1)
if [[ "$SNI" == *"["* || ${#SNI} -gt 40 ]]; then
  echo "ВНИМАНИЕ: server_name выглядит испорченным ('$SNI', len ${#SNI}). Останавливаюсь."; exit 1
fi

# --- PIN ---
PIN="${PIN:-}"
if [[ -z "$PIN" ]]; then
  read -rsp "Придумай PIN (мин. 4 знака, его введёшь на телефоне): " PIN; echo
fi
[[ ${#PIN} -ge 4 ]] || { echo "PIN слишком короткий."; exit 1; }

WORK="${WORK:-/tmp/vpn-connect}"
if [[ -z "${BUILD_ONLY:-}" ]]; then
  cleanup(){ ufw delete allow "${PORT}/tcp" >/dev/null 2>&1 || true; rm -rf "$WORK"; }
  trap cleanup EXIT INT TERM
fi
mkdir -p "$WORK"

# --- собрать полезную нагрузку (ссылки на 4 decoy + конфиг sing-box) и зашифровать ---
IP="$IP" UUID="$UUID" SNI="$SNI" SID="$SID" FLOW="$FLOW" PBK="$PBK" \
TPL="$TPL" PIN="$PIN" REPO="$REPO" HTML_TPL="$HTML_TPL" SJCL="$SJCL" QRLIB="$QRLIB" WORK="$WORK" \
python3 <<'PY'
import os, sys, json, copy, urllib.parse
sys.path.insert(0, os.path.join(os.environ["REPO"], "scripts", "lib"))
from aesgcm import encrypt_blob

IP=os.environ["IP"]; UUID=os.environ["UUID"]; SNI=os.environ["SNI"]
SID=os.environ["SID"]; FLOW=os.environ["FLOW"] or "xtls-rprx-vision"; PBK=os.environ["PBK"]

DECOYS=[("www.apple.com","LV-apple"),("www.cloudflare.com","LV-cloudflare"),
        ("dl.google.com","LV-google"),("addons.mozilla.org","LV-mozilla")]

def link(sni,name):
    q={"encryption":"none","flow":FLOW,"security":"reality","sni":sni,
       "fp":"chrome","pbk":PBK,"sid":SID,"type":"tcp"}
    return "vless://%s@%s:443?%s#%s"%(UUID,IP,urllib.parse.urlencode(q),urllib.parse.quote(name))

links=[{"name":name,"sni":sni,"url":link(sni,name)} for sni,name in DECOYS]

# конфиг sing-box с авто-failover (режим "умный": RU напрямую, зарубеж через LV)
tpl=open(os.environ["TPL"]).read()
for k,v in {"__SERVER_IP__":IP,"__VLESS_UUID__":UUID,"__REALITY_PUBLIC_KEY__":PBK,
            "__REALITY_SHORT_ID__":SID,"__CLASH_SECRET__":"secret"}.items():
    tpl=tpl.replace(k,v)
src=json.loads(tpl)

def vless(tag,sni):
    o={"type":"vless","tag":tag,"server":IP,"server_port":443,"uuid":UUID,"flow":FLOW,
       "tls":{"enabled":True,"server_name":sni,"utls":{"enabled":True,"fingerprint":"chrome"},
              "reality":{"enabled":True,"public_key":PBK,"short_id":SID}}}
    return o
tags=[]; vs=[]
for sni,_ in DECOYS:
    t="reality-"+sni.split(".")[-2]; tags.append(t); vs.append(vless(t,sni))
src["outbounds"]=[
    {"type":"selector","tag":"proxy","outbounds":["auto"]+tags,"default":"auto"},
    {"type":"urltest","tag":"auto","outbounds":tags,"url":"https://www.gstatic.com/generate_204",
     "interval":"2m","tolerance":50,"idle_timeout":"30m","interrupt_exist_connections":False},
    *vs,
    {"type":"direct","tag":"direct"}]
# iOS-ядро sing-box VT: tun + легаси-DNS (как в make-ios-configs.sh)
src["inbounds"]=[{"type":"tun","tag":"tun-in","address":["172.19.0.1/30","fdfe:dcba:9876::1/126"],
    "mtu":1358,"auto_route":True,"strict_route":True,"stack":"gvisor","endpoint_independent_nat":True}]
src.pop("experimental",None)
src["dns"]={"servers":[{"tag":"dns-remote","address":"https://1.1.1.1/dns-query","detour":"proxy"}],
            "strategy":"ipv4_only","final":"dns-remote"}
src.get("route",{}).pop("default_domain_resolver",None)
singbox_json=json.dumps(src,indent=2,ensure_ascii=False)

payload={"server":IP,"currentSni":SNI,"links":links,"singboxConfig":singbox_json}
blob=encrypt_blob(os.environ["PIN"], json.dumps(payload,ensure_ascii=False).encode())

# --- инжект в HTML: блоб + библиотеки ---
html=open(os.environ["HTML_TPL"]).read()
html=html.replace("/*__SJCL__*/", open(os.environ["SJCL"]).read())
html=html.replace("/*__QRCODE__*/", open(os.environ["QRLIB"]).read())
html=html.replace("/*__BLOB_JSON__*/ null", json.dumps(blob))
open(os.path.join(os.environ["WORK"],"index.html"),"w").write(html)
print("[*] Страница собрана: %d узлов, конфиг sing-box вложен, всё зашифровано PIN-ом." % len(links))
PY
[[ -f "$WORK/index.html" ]] || { echo "Сборка страницы не удалась."; exit 1; }

if [[ -n "${BUILD_ONLY:-}" ]]; then
  echo "[*] BUILD_ONLY: страница в $WORK/index.html, раздача пропущена."
  exit 0
fi

ufw allow "${PORT}/tcp" >/dev/null 2>&1 || true
echo
echo "============================================================"
echo " Открой на АЙФОНЕ (по СОТОВОЙ связи!):"
echo
echo "     http://$IP:$PORT/"
echo
echo " Введи PIN, выбери приложение — покажется инструкция и QR."
echo "============================================================"
echo " Раздаю. НЕ закрывай, пока не настроишь телефон. Потом Ctrl+C."
echo
cd "$WORK" && python3 -m http.server "$PORT"
