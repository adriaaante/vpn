#!/usr/bin/env bash
#
# fix-reality-sni.sh — чинит Reality сменой домена-прикрытия (SNI).
# Причина сбоя: www.microsoft.com перестал годиться как Reality-decoy с этого
# сервера (handshake не одалживается -> "processed invalid connection").
# Скрипт подбирает рабочий decoy (петлевой тест), применяет к боевому конфигу
# со свежим ключом, перезапускает и печатает значения для клиента.
#
# Запуск на сервере: cd /root/vpn && git pull origin main && bash scripts/fix-reality-sni.sh

set -uo pipefail
CFG=/etc/sing-box/config.json
[[ -f "$CFG" ]] || { echo "Нет $CFG"; exit 1; }
UUID=$(python3 -c "import json;print(json.load(open('$CFG'))['inbounds'][0]['users'][0]['uuid'])")
SHORTID=$(python3 -c "import json;r=json.load(open('$CFG'))['inbounds'][0]['tls']['reality']['short_id'];print(r[0] if isinstance(r,list) else r)")

# loop_test <sni> <yes|no flow> -> 0 если Reality поднялся
loop_test() {
  local sni="$1" uf="$2" kp priv pub uuid cc S C
  kp=$(sing-box generate reality-keypair)
  priv=$(echo "$kp" | sed -n 's/^PrivateKey:[[:space:]]*//p')
  pub=$(echo "$kp" | sed -n 's/^PublicKey:[[:space:]]*//p')
  uuid=$(sing-box generate uuid)
  SNI="$sni" UF="$uf" PRIV="$priv" PUB="$pub" UUID="$uuid" python3 <<'PY'
import json,os
sni=os.environ['SNI']; uf=os.environ['UF']=='yes'
priv=os.environ['PRIV']; pub=os.environ['PUB']; uuid=os.environ['UUID']
su={"uuid":uuid}; co={"type":"vless","server":"127.0.0.1","server_port":18444,"uuid":uuid,
  "tls":{"enabled":True,"server_name":sni,"utls":{"enabled":True,"fingerprint":"chrome"},
  "reality":{"enabled":True,"public_key":pub,"short_id":"0123456789abcdef"}}}
if uf: su["flow"]="xtls-rprx-vision"; co["flow"]="xtls-rprx-vision"
json.dump({"log":{"level":"error"},"inbounds":[{"type":"vless","listen":"127.0.0.1","listen_port":18444,
  "users":[su],"tls":{"enabled":True,"server_name":sni,"reality":{"enabled":True,
  "handshake":{"server":sni,"server_port":443},"private_key":priv,"short_id":["0123456789abcdef"]}}}],
  "outbounds":[{"type":"direct"}]},open("/tmp/f_srv.json","w"))
json.dump({"log":{"level":"error"},"inbounds":[{"type":"mixed","listen":"127.0.0.1","listen_port":10811}],
  "outbounds":[co]},open("/tmp/f_cli.json","w"))
PY
  sing-box run -c /tmp/f_srv.json >/tmp/f_srv.log 2>&1 & S=$!
  sleep 2
  sing-box run -c /tmp/f_cli.json >/tmp/f_cli.log 2>&1 & C=$!
  sleep 4
  cc=$(curl -s --max-time 6 --socks5-hostname 127.0.0.1:10811 https://ipinfo.io/country 2>/dev/null)
  kill "$S" "$C" 2>/dev/null; sleep 1
  [[ -n "$cc" ]]
}

SNI=""; FLOW=""
for cand in www.apple.com www.cloudflare.com dl.google.com addons.mozilla.org; do
  echo -n "[*] $cand : flow... "
  if loop_test "$cand" yes; then echo "OK"; SNI="$cand"; FLOW="xtls-rprx-vision"; break; fi
  echo -n "без flow... "
  if loop_test "$cand" no; then echo "OK (без flow)"; SNI="$cand"; FLOW=""; break; fi
  echo "FAIL"
done
[[ -z "$SNI" ]] && { echo "[X] Ни один decoy не сработал — скинь вывод."; exit 2; }
echo "[*] Выбран SNI=$SNI  flow=${FLOW:-нет}"

# применяем к боевому конфигу: новый decoy + свежий ключ + flow по результату
KP=$(sing-box generate reality-keypair)
NPRIV=$(echo "$KP" | sed -n 's/^PrivateKey:[[:space:]]*//p')
NPUB=$(echo "$KP" | sed -n 's/^PublicKey:[[:space:]]*//p')
cp "$CFG" "$CFG.bak.$(date +%s 2>/dev/null || echo bak)" 2>/dev/null || true
SNI="$SNI" NPRIV="$NPRIV" FLOW="$FLOW" python3 - "$CFG" <<'PY'
import json,os,sys
p=sys.argv[1]; d=json.load(open(p)); i=d["inbounds"][0]; t=i["tls"]
t["server_name"]=os.environ["SNI"]
t["reality"]["handshake"]["server"]=os.environ["SNI"]
t["reality"]["private_key"]=os.environ["NPRIV"]
u=i["users"][0]
if os.environ["FLOW"]: u["flow"]=os.environ["FLOW"]
else: u.pop("flow",None)
json.dump(d,open(p,"w"),indent=2)
PY
sing-box check -c "$CFG" >/dev/null 2>&1 && echo "[*] боевой конфиг валиден" || { echo "[X] конфиг сломан — откат"; cp "$(ls -1t "$CFG".bak.* 2>/dev/null | head -1)" "$CFG" 2>/dev/null; exit 3; }
echo "$NPUB" > /etc/sing-box/reality_public_key.txt
systemctl restart sing-box; sleep 2
echo "[*] sing-box service: $(systemctl is-active sing-box)"

# проверка боевого Reality по петле (порт 443)
SNI="$SNI" PUB="$NPUB" UUID="$UUID" SHORTID="$SHORTID" FLOW="$FLOW" python3 <<'PY'
import json,os
co={"type":"vless","server":"127.0.0.1","server_port":443,"uuid":os.environ["UUID"],
 "tls":{"enabled":True,"server_name":os.environ["SNI"],"utls":{"enabled":True,"fingerprint":"chrome"},
 "reality":{"enabled":True,"public_key":os.environ["PUB"],"short_id":os.environ["SHORTID"]}}}
if os.environ["FLOW"]: co["flow"]=os.environ["FLOW"]
json.dump({"log":{"level":"error"},"inbounds":[{"type":"mixed","listen":"127.0.0.1","listen_port":10999}],"outbounds":[co]},open("/tmp/f_prod.json","w"))
PY
sing-box run -c /tmp/f_prod.json >/tmp/f_prod.log 2>&1 & PP=$!
sleep 4
PCC=$(curl -s --max-time 6 --socks5-hostname 127.0.0.1:10999 https://ipinfo.io/country 2>/dev/null)
kill "$PP" 2>/dev/null
echo "[*] Боевой Reality по петле: ${PCC:-FAIL}"

IP=$(curl -fsSL --max-time 6 https://api.ipify.org 2>/dev/null || echo "192.36.41.201")
echo
echo "============================================================"
echo " ЗНАЧЕНИЯ ДЛЯ КЛИЕНТА (айфон/мак):"
echo "   SERVER_IP          = $IP"
echo "   SERVER_PORT        = 443"
echo "   VLESS_UUID         = $UUID"
echo "   REALITY_SNI        = $SNI"
echo "   REALITY_PUBLIC_KEY = $NPUB"
echo "   REALITY_SHORT_ID   = $SHORTID"
echo "   FLOW               = ${FLOW:-нет}"
echo "============================================================"
[[ -n "$PCC" ]] && echo "[OK] Сервер ПОЧИНЕН и проверен (петля -> $PCC). Дальше — клиент." \
                || echo "[!] Боевая петля не прошла — скинь вывод."
