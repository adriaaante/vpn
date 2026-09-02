#!/usr/bin/env bash
#
# make-ios-configs-server.sh — собирает 3 iOS-конфига (умный/strict/selective) с
# АВТОНОМНЫМ failover по доменам-прикрытиям (4 outbound в urltest) из текущего
# серверного конфига и раздаёт их по HTTP для импорта на айфон как Remote-профили.
#   cd /root/vpn && git pull origin main && bash scripts/make-ios-configs-server.sh
# На айфоне (по СОТОВОЙ связи) добавить 3 Remote-профиля по ссылкам ниже. Ctrl+C после.

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CFG="${CFG:-/etc/sing-box/config.json}"
TPL="$REPO/configs/singbox-client.template.json"
PORT=8080
# Переопределяются из vpn-users.sh, чтобы собрать конфиг ГОСТЯ тем же генератором:
#   GUEST_UUID — чей ключ класть в конфиг (по умолчанию — первый из серверного)
#   OUT_DIR    — куда сложить json (по умолчанию /tmp/ios)
#   SERVE      — 0 = только собрать файлы, не поднимать HTTP-раздачу
OUT_DIR="${OUT_DIR:-/tmp/ios}"
SERVE="${SERVE:-1}"
[[ -f "$TPL" ]] || { echo "Нет $TPL"; exit 1; }
PBKF="${PBKF:-/etc/sing-box/reality_public_key.txt}"
[[ -f "$PBKF" ]] || { echo "Нет публичного ключа ($PBKF) — запусти fix-reality-sni.sh"; exit 1; }

IP=$(curl -fsSL --max-time 6 https://api.ipify.org 2>/dev/null || echo 83.172.151.177)
UUID="${GUEST_UUID:-$(python3 -c "import json;print(json.load(open('$CFG'))['inbounds'][0]['users'][0]['uuid'])")}"
SID=$(python3 -c "import json;r=json.load(open('$CFG'))['inbounds'][0]['tls']['reality']['short_id'];print(r[0] if isinstance(r,list) else r)")
FLOW=$(python3 -c "import json;print(json.load(open('$CFG'))['inbounds'][0]['users'][0].get('flow',''))")
PBK=$(tr -d '[:space:]' < "$PBKF")
# Имя сервера (если настроено) — тогда в конфиг попадут ещё и маршруты по домену,
# и гость переживёт смену IP без перевыпуска профиля.
SERVER_HOST="${SERVER_HOST:-$(tr -d '[:space:]' < /etc/sing-box/server-host.txt 2>/dev/null || true)}"

# Конфиги содержат UUID/short_id (учётные данные клиента) и раздаются по ОТКРЫТОМУ
# HTTP. Порт 8080 закрываем при выходе (Ctrl+C/ошибка) и чистим /tmp/ios, чтобы не
# держать учётки доступными и не оставлять дыру в фаерволе.
cleanup() { [[ "$SERVE" == 1 ]] && ufw delete allow "${PORT}/tcp" >/dev/null 2>&1; rm -rf "$OUT_DIR"; }
trap cleanup EXIT INT TERM

# Прошлая раздача могла остаться висеть (не нажали Ctrl+C) и держать порт.
# Снимаем её ДО генерации: при завершении у неё срабатывает собственный trap,
# который делает rm -rf своего каталога — если убить её позже, она унесёт
# только что собранные конфиги (ловили: "cd: /tmp/ios: No such file or directory").
if ss -tln 2>/dev/null | grep -q ":$PORT "; then
  pkill -f "http.server $PORT" 2>/dev/null && sleep 2
fi

mkdir -p "$OUT_DIR"
OUT_DIR="$OUT_DIR" SERVER_HOST="$SERVER_HOST" IP="$IP" UUID="$UUID" SID="$SID" FLOW="$FLOW" PBK="$PBK" TPL="$TPL" python3 <<'PY'
import json,os,copy
# Домены-прикрытия для авто-failover (urltest). Сервер держит один на 443; клиент
# держит все — работает тот, что совпал с серверным; если отвалится, urltest сам прыгнет.
DECOYS=["www.apple.com","www.cloudflare.com","dl.google.com","addons.mozilla.org","www.icloud.com","www.samsung.com"]
IP=os.environ['IP'];UUID=os.environ['UUID'];SID=os.environ['SID'];FLOW=os.environ['FLOW'];PBK=os.environ['PBK']
tpl=open(os.environ['TPL']).read()
for k,v in {"__SERVER_IP__":IP,"__VLESS_UUID__":UUID,
            "__REALITY_PUBLIC_KEY__":PBK,"__REALITY_SHORT_ID__":SID,"__CLASH_SECRET__":"x"}.items():
    tpl=tpl.replace(k,v)
src=json.loads(tpl)

ALT=[(2053,"www.apple.com"),(8443,"www.cloudflare.com")]  # запасные порты (DPI режет 443)

def vless(tag,sni,port=443):
    o={"type":"vless","tag":tag,"server":IP,"server_port":port,"uuid":UUID,
       "tls":{"enabled":True,"server_name":sni,"utls":{"enabled":True,"fingerprint":"chrome"},
              "reality":{"enabled":True,"public_key":PBK,"short_id":SID}}}
    if FLOW: o["flow"]=FLOW
    return o
tags=[]; vs=[]
for d in DECOYS:
    t="reality-"+d.split(".")[-2]; tags.append(t); vs.append(vless(t,d))
for port,d in ALT:
    t=f"reality-alt{port}"; tags.append(t); vs.append(vless(t,d,port))
HOST=os.environ.get("SERVER_HOST","").strip()
if HOST:
    for port,d in ((443,"www.apple.com"),(2053,"www.cloudflare.com")):
        o=vless(f"reality-dns{port}",d,port); o["server"]=HOST
        tags.append(o["tag"]); vs.append(o)
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
    # DNS берём из шаблона КАК ЕСТЬ — это новый формат (type/server +
    # route.default_domain_resolver). Раньше здесь собирался устаревший формат
    # (address: https://...), потому что ядро в приложении было старым. 2026-09-02
    # приложение обновилось до ядра 1.13, и такой профиль перестал стартовать:
    # «legacy DNS servers is deprecated … FATAL» — на телефоне sing-box молча не
    # поднимался, а Shadowrocket (другое приложение) работал. Новый формат ядро
    # ≤1.11 не понимает (unknown field "type"), совместить оба нельзя — держим
    # тот, что у актуального приложения. Проверка: sing-box check без переменных
    # ENABLE_DEPRECATED_* должен проходить чисто.
    if HOST:
        # Имя сервера резолвим МИМО туннеля, иначе кольцо: подключиться нельзя, пока
        # имя не разрешено, а разрешить нечем. detour обязан вести на НЕПУСТОЙ
        # outbound — пустой "direct" sing-box отвергает при старте.
        d["outbounds"].append({"type":"direct","tag":"direct-dns","connect_timeout":"5s"})
        d["dns"]["servers"].append({"type":"https","tag":"dns-bootstrap","server":"1.1.1.1","detour":"direct-dns"})
        d["dns"]["rules"]=[{"domain":[HOST],"server":"dns-bootstrap"}]
    return d
def is_ru_direct(x):
    if x.get("outbound")!="direct": return False
    if x.get("rule_set")=="geoip-ru": return True
    ds=x.get("domain_suffix")
    if isinstance(ds,list) and any(s in (".ru",".рф",".xn--p1ai") for s in ds): return True
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
    json.dump(cfg,open(f"{os.environ['OUT_DIR']}/{name}.json","w"),indent=2,ensure_ascii=False)
print("[*] Собраны 3 режима с авто-failover по 4 доменам (apple/cloudflare/google/mozilla)")
PY

if [[ "$SERVE" != 1 ]]; then
  # Режим "только собрать" — конфиги забирает вызывающий скрипт (vpn-users.sh).
  trap - EXIT INT TERM
  echo "[*] Конфиги собраны в $OUT_DIR"
  exit 0
fi

ufw allow "${PORT}/tcp" >/dev/null 2>&1 || true
echo
echo "============================================================"
echo " На АЙФОНЕ (по СОТОВОЙ связи!) sing-box VT -> New Profile ->"
echo " Type: REMOTE, добавь 3 профиля:"
echo
# Ссылку показываем по имени, если оно настроено: тогда и канал доставки переживёт
# смену адреса, а не только сами маршруты внутри конфига.
LINKHOST="${SERVER_HOST:-$IP}"
echo "   умный (RU напрямую):  http://$LINKHOST:$PORT/full.json"
echo "   Латвия все:           http://$LINKHOST:$PORT/strict.json"
echo "   только сервисы:       http://$LINKHOST:$PORT/selective.json"
echo "============================================================"
echo " Раздаю. НЕ закрывай, пока не импортируешь все 3. Потом Ctrl+C."
echo
cd "$OUT_DIR" && python3 -m http.server "$PORT"
