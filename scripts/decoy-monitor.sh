#!/usr/bin/env bash
#
# decoy-monitor.sh — следит, «одалживается» ли текущий домен-прикрытие (decoy).
# Если перестал — сам переключает сервер на рабочий decoy и перезапускает sing-box.
# Клиенты (с multi-decoy urltest) подхватывают новый домен автоматически.
# Ставится таймером через install-decoy-monitor.sh. Логи: journalctl -u decoy-monitor.

set -uo pipefail
CFG=/etc/sing-box/config.json
DECOYS=(www.apple.com www.cloudflare.com dl.google.com addons.mozilla.org)
log(){ echo "[decoy-monitor] $*"; }
[[ -f "$CFG" ]] || { log "нет $CFG"; exit 1; }

CUR=$(python3 -c "import json;print(json.load(open('$CFG'))['inbounds'][0]['tls']['server_name'])")
PBK=$(tr -d '[:space:]' < /etc/sing-box/reality_public_key.txt 2>/dev/null)
UUID=$(python3 -c "import json;print(json.load(open('$CFG'))['inbounds'][0]['users'][0]['uuid'])")
SID=$(python3 -c "import json;r=json.load(open('$CFG'))['inbounds'][0]['tls']['reality']['short_id'];print(r[0] if isinstance(r,list) else r)")
FLOW=$(python3 -c "import json;print(json.load(open('$CFG'))['inbounds'][0]['users'][0].get('flow',''))")

# проверка ТЕКУЩЕГО decoy против ЖИВОГО сервера (127.0.0.1:443)
test_live(){
  local cc
  SNI="$CUR" PBK="$PBK" UUID="$UUID" SID="$SID" FLOW="$FLOW" python3 <<'PY'
import json,os
co={"type":"vless","server":"127.0.0.1","server_port":443,"uuid":os.environ["UUID"],
 "tls":{"enabled":True,"server_name":os.environ["SNI"],"utls":{"enabled":True,"fingerprint":"chrome"},
 "reality":{"enabled":True,"public_key":os.environ["PBK"],"short_id":os.environ["SID"]}}}
if os.environ["FLOW"]: co["flow"]=os.environ["FLOW"]
json.dump({"log":{"level":"error"},"inbounds":[{"type":"mixed","listen":"127.0.0.1","listen_port":10877}],"outbounds":[co]},open("/tmp/mon_cli.json","w"))
PY
  sing-box run -c /tmp/mon_cli.json >/dev/null 2>&1 & local P=$!
  sleep 3
  cc=$(curl -s --max-time 6 --socks5-hostname 127.0.0.1:10877 https://ipinfo.io/country 2>/dev/null)
  kill "$P" 2>/dev/null; sleep 1
  [[ -n "$cc" ]]
}

# проверка, «одалживается» ли decoy сейчас (отдельный мини сервер+клиент)
loop_ok(){
  local sni="$1" kp priv pub uuid cc S C
  kp=$(sing-box generate reality-keypair)
  priv=$(echo "$kp"|sed -n 's/^PrivateKey:[[:space:]]*//p')
  pub=$(echo "$kp"|sed -n 's/^PublicKey:[[:space:]]*//p')
  uuid=$(sing-box generate uuid)
  SNI="$sni" PRIV="$priv" PUB="$pub" UUID="$uuid" python3 <<'PY'
import json,os
sni=os.environ['SNI'];priv=os.environ['PRIV'];pub=os.environ['PUB'];uuid=os.environ['UUID']
json.dump({"log":{"level":"error"},"inbounds":[{"type":"vless","listen":"127.0.0.1","listen_port":18555,"users":[{"uuid":uuid}],"tls":{"enabled":True,"server_name":sni,"reality":{"enabled":True,"handshake":{"server":sni,"server_port":443},"private_key":priv,"short_id":["0123456789abcdef"]}}}],"outbounds":[{"type":"direct"}]},open("/tmp/mon_srv.json","w"))
json.dump({"log":{"level":"error"},"inbounds":[{"type":"mixed","listen":"127.0.0.1","listen_port":10878}],"outbounds":[{"type":"vless","server":"127.0.0.1","server_port":18555,"uuid":uuid,"tls":{"enabled":True,"server_name":sni,"utls":{"enabled":True,"fingerprint":"chrome"},"reality":{"enabled":True,"public_key":pub,"short_id":"0123456789abcdef"}}}]},open("/tmp/mon_clt.json","w"))
PY
  sing-box run -c /tmp/mon_srv.json >/dev/null 2>&1 & S=$!
  sleep 2
  sing-box run -c /tmp/mon_clt.json >/dev/null 2>&1 & C=$!
  sleep 3
  cc=$(curl -s --max-time 6 --socks5-hostname 127.0.0.1:10878 https://ipinfo.io/country 2>/dev/null)
  kill "$S" "$C" 2>/dev/null; sleep 1
  [[ -n "$cc" ]]
}

# двойная проверка (антифлап)
if test_live || test_live; then
  log "decoy '$CUR' работает — ок."
  exit 0
fi
log "decoy '$CUR' не отвечает — подбираю замену..."
for d in "${DECOYS[@]}"; do
  [[ "$d" == "$CUR" ]] && continue
  if loop_ok "$d"; then
    log "переключаю decoy: $CUR -> $d"
    SNID="$d" python3 - "$CFG" <<'PY'
import json,os,sys
p=sys.argv[1]; d=json.load(open(p)); t=d["inbounds"][0]["tls"]
t["server_name"]=os.environ["SNID"]; t["reality"]["handshake"]["server"]=os.environ["SNID"]
json.dump(d,open(p,"w"),indent=2)
PY
    sing-box check -c "$CFG" >/dev/null 2>&1 && systemctl restart sing-box
    sleep 2
    log "готово: decoy=$d, sing-box=$(systemctl is-active sing-box)"
    exit 0
  fi
done
log "рабочий decoy не найден — оставляю '$CUR'."
exit 1
