#!/usr/bin/env bash
#
# server-status.sh — быстрая проверка здоровья сервера VPN (запускать на сервере).
#   cd /root/vpn && git pull origin main && bash scripts/server-status.sh
# Показывает: sing-box, текущий decoy (тест по петле), авто-монитор, порт 443.

set -uo pipefail
CFG=/etc/sing-box/config.json
[[ -f "$CFG" ]] || { echo "Нет $CFG"; exit 1; }

echo "=== sing-box ==="
echo "  service: $(systemctl is-active sing-box 2>/dev/null)"
echo "  version: $(sing-box version 2>/dev/null | head -1)"

CUR=$(python3 -c "import json;print(json.load(open('$CFG'))['inbounds'][0]['tls']['server_name'])")
PBK=$(tr -d '[:space:]' < /etc/sing-box/reality_public_key.txt 2>/dev/null)
UUID=$(python3 -c "import json;print(json.load(open('$CFG'))['inbounds'][0]['users'][0]['uuid'])")
SID=$(python3 -c "import json;r=json.load(open('$CFG'))['inbounds'][0]['tls']['reality']['short_id'];print(r[0] if isinstance(r,list) else r)")
FLOW=$(python3 -c "import json;print(json.load(open('$CFG'))['inbounds'][0]['users'][0].get('flow',''))")

echo "=== Reality (текущий decoy: $CUR) ==="
SNI="$CUR" PBK="$PBK" UUID="$UUID" SID="$SID" FLOW="$FLOW" python3 <<'PY'
import json,os
co={"type":"vless","server":"127.0.0.1","server_port":443,"uuid":os.environ["UUID"],
 "tls":{"enabled":True,"server_name":os.environ["SNI"],"utls":{"enabled":True,"fingerprint":"chrome"},
 "reality":{"enabled":True,"public_key":os.environ["PBK"],"short_id":os.environ["SID"]}}}
if os.environ["FLOW"]: co["flow"]=os.environ["FLOW"]
json.dump({"log":{"level":"error"},"inbounds":[{"type":"mixed","listen":"127.0.0.1","listen_port":10866}],"outbounds":[co]},open("/tmp/st_cli.json","w"))
PY
sing-box run -c /tmp/st_cli.json >/dev/null 2>&1 & P=$!
sleep 3
CC=$(curl -s --max-time 6 --socks5-hostname 127.0.0.1:10866 https://ipinfo.io/country 2>/dev/null)
kill "$P" 2>/dev/null
[[ -n "$CC" ]] && echo "  петля -> $CC  ✓ Reality работает" || echo "  петля -> FAIL  ⚠️ (монитор переключит decoy в течение 15 мин)"

echo "=== авто-монитор смены домена ==="
echo "  timer: $(systemctl is-active decoy-monitor.timer 2>/dev/null || echo 'НЕ установлен (bash scripts/install-decoy-monitor.sh)')"
systemctl list-timers decoy-monitor.timer --no-pager 2>/dev/null | grep -i decoy || true
echo "  последний прогон:"; journalctl -u decoy-monitor -n 2 --no-pager 2>/dev/null | sed 's/^/    /' || true

echo "=== порт 443 ==="
ss -tlnp 2>/dev/null | grep -q ':443 ' && echo "  443/tcp слушается ✓" || echo "  443/tcp НЕ слушается ⚠️"

echo "=== вход по SSH ==="
sshd -T 2>/dev/null | grep -q '^passwordauthentication no' \
  && echo "  пароль отключён ✓ (вход по ключу)" \
  || echo "  ⚠️ вход по паролю включён — запусти bash scripts/harden-server.sh"
