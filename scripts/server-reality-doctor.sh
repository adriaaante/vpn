#!/usr/bin/env bash
#
# server-reality-doctor.sh — диагностирует и чинит Reality на сервере через
# ЛОКАЛЬНЫЕ (loopback) тесты, не завися от клиента, Mac и блокировок IP.
# Запускать на сервере под root (можно из VNC-консоли):
#   cd /root/vpn && git pull origin main && bash scripts/server-reality-doctor.sh
#
# Логика:
#   1) проверяет, работает ли Reality на петле (127.0.0.1) С flow и БЕЗ flow;
#   2) если оба падают — переустанавливает sing-box (свежий бинарь) и повторяет;
#   3) применяет рабочую схему к боевому /etc/sing-box/config.json (свежий ключ,
#      flow по результату), перезапускает сервис и проверяет петлёй;
#   4) печатает значения для клиента (айфон/мак).

set -uo pipefail
CFG=/etc/sing-box/config.json
CRED=/etc/sing-box/credentials.txt

[[ -f "$CFG" ]] || { echo "Нет $CFG — сервер не настроен. Запусти setup-singbox-latvia.sh"; exit 1; }

SNI=$(python3 -c "import json;print(json.load(open('$CFG'))['inbounds'][0]['tls']['server_name'])")
UUID=$(python3 -c "import json;print(json.load(open('$CFG'))['inbounds'][0]['users'][0]['uuid'])")
SHORTID=$(python3 -c "import json;r=json.load(open('$CFG'))['inbounds'][0]['tls']['reality']['short_id'];print(r[0] if isinstance(r,list) else r)")
echo "[*] SNI=$SNI  UUID=$UUID  SHORT_ID=$SHORTID  sing-box=$(sing-box version | head -1)"

# loop_test <yes|no flow> <client_port> <server_port> -> печатает OK(cc)/FAIL, код 0/1
loop_test() {
  local uf="$1" cport="$2" sport="$3" kp priv pub tuuid cc
  kp=$(sing-box generate reality-keypair)
  priv=$(echo "$kp" | sed -n 's/^PrivateKey:[[:space:]]*//p')
  pub=$(echo "$kp" | sed -n 's/^PublicKey:[[:space:]]*//p')
  tuuid=$(sing-box generate uuid)
  SNI="$SNI" UF="$uf" PRIV="$priv" PUB="$pub" TUUID="$tuuid" CPORT="$cport" SPORT="$sport" python3 <<'PY'
import json,os
sni=os.environ['SNI']; uf=os.environ['UF']=='yes'
priv=os.environ['PRIV']; pub=os.environ['PUB']; uuid=os.environ['TUUID']
cport=int(os.environ['CPORT']); sport=int(os.environ['SPORT'])
suser={"uuid":uuid}
cout={"type":"vless","server":"127.0.0.1","server_port":sport,"uuid":uuid,
      "tls":{"enabled":True,"server_name":sni,"utls":{"enabled":True,"fingerprint":"chrome"},
             "reality":{"enabled":True,"public_key":pub,"short_id":"0123456789abcdef"}}}
if uf:
    suser["flow"]="xtls-rprx-vision"; cout["flow"]="xtls-rprx-vision"
srv={"log":{"level":"error"},"inbounds":[{"type":"vless","listen":"127.0.0.1","listen_port":sport,
     "users":[suser],"tls":{"enabled":True,"server_name":sni,"reality":{"enabled":True,
     "handshake":{"server":sni,"server_port":443},"private_key":priv,"short_id":["0123456789abcdef"]}}}],
     "outbounds":[{"type":"direct"}]}
cli={"log":{"level":"error"},"inbounds":[{"type":"mixed","listen":"127.0.0.1","listen_port":cport}],
     "outbounds":[cout]}
json.dump(srv,open("/tmp/d_srv.json","w")); json.dump(cli,open("/tmp/d_cli.json","w"))
PY
  sing-box run -c /tmp/d_srv.json >/tmp/d_srv.log 2>&1 & local S=$!
  sleep 2
  sing-box run -c /tmp/d_cli.json >/tmp/d_cli.log 2>&1 & local C=$!
  sleep 4
  cc=$(curl -s --max-time 6 --socks5-hostname "127.0.0.1:$cport" https://ipinfo.io/country 2>/dev/null)
  kill "$S" "$C" 2>/dev/null; sleep 1
  if [[ -n "$cc" ]]; then echo "OK ($cc)"; return 0; else echo "FAIL"; return 1; fi
}

run_suite() {
  echo -n "    Reality С vision flow : "; loop_test yes 10901 18901 && WF=ok || WF=fail
  echo -n "    Reality БЕЗ flow      : "; loop_test no  10902 18902 && NF=ok || NF=fail
}

echo "[*] Проба №1 (текущий бинарь):"
WF=fail; NF=fail; run_suite

if [[ "$WF" = fail && "$NF" = fail ]]; then
  echo "[!] Оба варианта упали — переустанавливаю sing-box (свежий релиз)..."
  arch=amd64; case "$(uname -m)" in aarch64|arm64) arch=arm64;; esac
  tmp=$(mktemp -d)
  curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest -o "$tmp/rel.json"
  tag=$(grep -m1 '"tag_name"' "$tmp/rel.json" | cut -d'"' -f4); ver=${tag#v}
  if curl -fsSL "https://github.com/SagerNet/sing-box/releases/download/${tag}/sing-box-${ver}-linux-${arch}.tar.gz" -o "$tmp/sb.tgz"; then
    tar -xzf "$tmp/sb.tgz" -C "$tmp"
    install -m755 "$tmp/sing-box-${ver}-linux-${arch}/sing-box" /usr/local/bin/sing-box
    echo "[*] Переустановлено: $(sing-box version | head -1)"
    echo "[*] Проба №2 (после переустановки):"
    run_suite
  else
    echo "[!] Не удалось скачать sing-box — проверь интернет сервера."
  fi
  rm -rf "$tmp"
fi

# Выбор рабочей схемы
FLOW=""
if [[ "${WF:-fail}" = ok ]]; then FLOW="xtls-rprx-vision"; RECIPE="С flow (vision)"
elif [[ "${NF:-fail}" = ok ]]; then FLOW=""; RECIPE="БЕЗ flow"
else
  echo
  echo "[X] Reality не поднимается даже локально ни с flow, ни без. Логи последнего теста:"
  echo "--- server log ---"; tail -n 6 /tmp/d_srv.log 2>/dev/null
  echo "--- client log ---"; tail -n 6 /tmp/d_cli.log 2>/dev/null
  echo "Скинь это в чат — разберём. Боевой конфиг НЕ трогал."
  exit 2
fi
echo "[*] Рабочая схема: $RECIPE"

# Применяем к боевому конфигу: свежий ключ + flow по результату
KP=$(sing-box generate reality-keypair)
NPRIV=$(echo "$KP" | sed -n 's/^PrivateKey:[[:space:]]*//p')
NPUB=$(echo "$KP" | sed -n 's/^PublicKey:[[:space:]]*//p')
cp "$CFG" "$CFG.bak.$(date +%s 2>/dev/null || echo bak)" 2>/dev/null || true
NPRIV="$NPRIV" FLOW="$FLOW" python3 - "$CFG" <<'PY'
import json,os,sys
p=sys.argv[1]; d=json.load(open(p))
i=d["inbounds"][0]; i["tls"]["reality"]["private_key"]=os.environ["NPRIV"]
u=i["users"][0]
if os.environ["FLOW"]: u["flow"]=os.environ["FLOW"]
else: u.pop("flow",None)
json.dump(d,open(p,"w"),indent=2)
PY
sing-box check -c "$CFG" >/dev/null 2>&1 && echo "[*] Боевой конфиг валиден" || { echo "[X] Боевой конфиг сломан — откатываю"; cp "$CFG".bak.* "$CFG" 2>/dev/null; exit 3; }
systemctl restart sing-box; sleep 2
echo "[*] sing-box service: $(systemctl is-active sing-box)"

# Проверка боевого Reality по петле (порт 443, реальный ключ/flow)
echo "$NPUB" > /etc/sing-box/reality_public_key.txt
SNI="$SNI" PUB="$NPUB" UUID="$UUID" SHORTID="$SHORTID" FLOW="$FLOW" python3 <<'PY'
import json,os
cout={"type":"vless","server":"127.0.0.1","server_port":443,"uuid":os.environ["UUID"],
      "tls":{"enabled":True,"server_name":os.environ["SNI"],"utls":{"enabled":True,"fingerprint":"chrome"},
             "reality":{"enabled":True,"public_key":os.environ["PUB"],"short_id":os.environ["SHORTID"]}}}
if os.environ["FLOW"]: cout["flow"]=os.environ["FLOW"]
json.dump({"log":{"level":"error"},"inbounds":[{"type":"mixed","listen":"127.0.0.1","listen_port":10999}],"outbounds":[cout]},open("/tmp/d_prod.json","w"))
PY
sing-box run -c /tmp/d_prod.json >/tmp/d_prod.log 2>&1 & PP=$!
sleep 4
PCC=$(curl -s --max-time 6 --socks5-hostname 127.0.0.1:10999 https://ipinfo.io/country 2>/dev/null)
kill "$PP" 2>/dev/null
echo "[*] Боевой Reality по петле: ${PCC:-FAIL}"

IP=$(curl -fsSL --max-time 6 https://api.ipify.org 2>/dev/null || echo "192.36.41.201")
echo
echo "============================================================"
echo " ЗНАЧЕНИЯ ДЛЯ КЛИЕНТА (айфон/мак) — перепиши их:"
echo "   SERVER_IP          = $IP"
echo "   SERVER_PORT        = 443"
echo "   VLESS_UUID         = $UUID"
echo "   REALITY_SNI        = $SNI"
echo "   REALITY_PUBLIC_KEY = $NPUB"
echo "   REALITY_SHORT_ID   = $SHORTID"
echo "   FLOW               = ${FLOW:-<нет, оставить пустым>}"
echo "============================================================"
[[ -n "$PCC" ]] && echo "[OK] Сервер починен и проверен (петля -> $PCC)." \
                || echo "[!] Боевая петля не прошла — скинь вывод в чат."
