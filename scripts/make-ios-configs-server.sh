#!/usr/bin/env bash
#
# make-ios-configs-server.sh — собирает 3 iOS-конфига (умный/strict/selective) с
# АВТОНОМНЫМ failover по доменам-прикрытиям (4 outbound в urltest) из текущего
# серверного конфига и раздаёт их по HTTP для импорта на айфон как Remote-профили.
#   cd /root/vpn && git pull origin main && bash scripts/make-ios-configs-server.sh
# На айфоне (по СОТОВОЙ связи) добавить 3 Remote-профиля по ссылкам ниже. Ctrl+C после.

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CFG=/etc/sing-box/config.json
TPL="$REPO/configs/singbox-client.template.json"
PORT=8080
[[ -f "$TPL" ]] || { echo "Нет $TPL"; exit 1; }
[[ -f /etc/sing-box/reality_public_key.txt ]] || { echo "Нет публичного ключа — запусти fix-reality-sni.sh"; exit 1; }

IP=$(curl -fsSL --max-time 6 https://api.ipify.org 2>/dev/null || echo 192.36.41.201)
UUID=$(python3 -c "import json;print(json.load(open('$CFG'))['inbounds'][0]['users'][0]['uuid'])")
SID=$(python3 -c "import json;r=json.load(open('$CFG'))['inbounds'][0]['tls']['reality']['short_id'];print(r[0] if isinstance(r,list) else r)")
FLOW=$(python3 -c "import json;print(json.load(open('$CFG'))['inbounds'][0]['users'][0].get('flow',''))")
PBK=$(tr -d '[:space:]' < /etc/sing-box/reality_public_key.txt)

# Конфиги содержат UUID/short_id (учётные данные клиента) и раздаются по ОТКРЫТОМУ
# HTTP. Порт 8080 закрываем при выходе (Ctrl+C/ошибка) и чистим /tmp/ios, чтобы не
# держать учётки доступными и не оставлять дыру в фаерволе.
cleanup() { ufw delete allow "${PORT}/tcp" >/dev/null 2>&1 || true; rm -rf /tmp/ios; }
trap cleanup EXIT INT TERM

mkdir -p /tmp/ios
IP="$IP" UUID="$UUID" SID="$SID" FLOW="$FLOW" PBK="$PBK" TPL="$TPL" python3 <<'PY'
import json,os,copy
# Домены-прикрытия для авто-failover (urltest). Сервер держит один на 443; клиент
# держит все — работает тот, что совпал с серверным; если отвалится, urltest сам прыгнет.
DECOYS=["www.apple.com","www.cloudflare.com","dl.google.com","addons.mozilla.org"]
IP=os.environ['IP'];UUID=os.environ['UUID'];SID=os.environ['SID'];FLOW=os.environ['FLOW'];PBK=os.environ['PBK']
tpl=open(os.environ['TPL']).read()
for k,v in {"__SERVER_IP__":IP,"__VLESS_UUID__":UUID,
            "__REALITY_PUBLIC_KEY__":PBK,"__REALITY_SHORT_ID__":SID,"__CLASH_SECRET__":"x"}.items():
    tpl=tpl.replace(k,v)
src=json.loads(tpl)

def vless(tag,sni):
    o={"type":"vless","tag":tag,"server":IP,"server_port":443,"uuid":UUID,
       "tls":{"enabled":True,"server_name":sni,"utls":{"enabled":True,"fingerprint":"chrome"},
              "reality":{"enabled":True,"public_key":PBK,"short_id":SID}}}
    if FLOW: o["flow"]=FLOW
    return o
tags=[]; vs=[]
for d in DECOYS:
    t="reality-"+d.split(".")[-2]; tags.append(t); vs.append(vless(t,d))
src["outbounds"]=[
    {"type":"selector","tag":"proxy","outbounds":["auto"]+tags,"default":"auto"},
    {"type":"urltest","tag":"auto","outbounds":tags,"url":"https://www.gstatic.com/generate_204",
     "interval":"2m","tolerance":50,"idle_timeout":"30m","interrupt_exist_connections":False},
    *vs,
    {"type":"direct","tag":"direct"}]

def base():
    d=copy.deepcopy(src)
    d["inbounds"]=[{"type":"tun","tag":"tun-in","address":["172.19.0.1/30","fdfe:dcba:9876::1/126"],
        "mtu":1358,"auto_route":True,"strict_route":True,"stack":"gvisor","endpoint_independent_nat":True}]
    d.pop("experimental",None)
    d["dns"]={"servers":[{"tag":"dns-remote","address":"https://1.1.1.1/dns-query","detour":"proxy"}],
              "strategy":"ipv4_only","final":"dns-remote"}
    d.get("route",{}).pop("default_domain_resolver",None)
    return d
def is_ru_direct(x):
    if x.get("outbound")!="direct": return False
    if x.get("rule_set")=="geoip-ru": return True
    ds=x.get("domain_suffix")
    if isinstance(ds,list) and any(s in (".ru",".рф") for s in ds): return True
    return False
full=base()
strict=base(); r=strict["route"]
r["rules"]=[x for x in r["rules"] if not is_ru_direct(x)]
r["rule_set"]=[x for x in r.get("rule_set",[]) if x.get("tag")!="geoip-ru"]
sel=base(); r=sel["route"]
r["rules"].append({"domain_suffix":["google.com","googleapis.com","gstatic.com","googleusercontent.com","gvt1.com","gvt2.com","youtube-nocookie.com"],"outbound":"proxy"})
r["rules"].append({"ip_cidr":["91.108.0.0/16","149.154.160.0/20","95.161.64.0/20","185.76.151.0/24","91.105.192.0/23","2001:67c:4e8::/48","2001:b28:f23d::/48","2001:b28:f23f::/48","2001:b28:f242::/48"],"outbound":"proxy"})
r["rules"].append({"ip_cidr":["0.0.0.0/0","::/0"],"action":"reject"})
for name,cfg in (("full",full),("strict",strict),("selective",sel)):
    json.dump(cfg,open(f"/tmp/ios/{name}.json","w"),indent=2,ensure_ascii=False)
print("[*] Собраны 3 режима с авто-failover по 4 доменам (apple/cloudflare/google/mozilla)")
PY

ufw allow "${PORT}/tcp" >/dev/null 2>&1 || true
echo
echo "============================================================"
echo " На АЙФОНЕ (по СОТОВОЙ связи!) sing-box VT -> New Profile ->"
echo " Type: REMOTE, добавь 3 профиля:"
echo
echo "   умный (RU напрямую):  http://$IP:$PORT/full.json"
echo "   Латвия все:           http://$IP:$PORT/strict.json"
echo "   только сервисы:       http://$IP:$PORT/selective.json"
echo "============================================================"
echo " Раздаю. НЕ закрывай, пока не импортируешь все 3. Потом Ctrl+C."
echo
cd /tmp/ios && python3 -m http.server "$PORT"
