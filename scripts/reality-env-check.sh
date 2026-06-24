#!/usr/bin/env bash
#
# reality-env-check.sh — почему Reality падает даже на петле на ЛЮБОЙ версии.
# Проверяет: (1) часы/NTP сервера; (2) Reality с разными доменами-прикрытиями.
# Запуск на сервере: cd /root/vpn && git pull origin main && bash scripts/reality-env-check.sh

set -uo pipefail

echo "=== ЧАСЫ СЕРВЕРА (Reality чувствителен ко времени) ==="
date -u
timedatectl 2>/dev/null | grep -iE 'Universal|System clock|NTP|synchronized' || echo "(timedatectl недоступен)"
echo

echo "=== Reality с разными доменами-прикрытиями (петля 127.0.0.1) ==="
test_decoy() {
  local sni="$1" kp priv pub uuid cc S C
  kp=$(sing-box generate reality-keypair)
  priv=$(echo "$kp" | sed -n 's/^PrivateKey:[[:space:]]*//p')
  pub=$(echo "$kp" | sed -n 's/^PublicKey:[[:space:]]*//p')
  uuid=$(sing-box generate uuid)
  SNI="$sni" PRIV="$priv" PUB="$pub" UUID="$uuid" python3 <<'PY'
import json,os
sni=os.environ['SNI']; priv=os.environ['PRIV']; pub=os.environ['PUB']; uuid=os.environ['UUID']
json.dump({"log":{"level":"error"},"inbounds":[{"type":"vless","listen":"127.0.0.1","listen_port":18443,
  "users":[{"uuid":uuid}],"tls":{"enabled":True,"server_name":sni,"reality":{"enabled":True,
  "handshake":{"server":sni,"server_port":443},"private_key":priv,"short_id":["0123456789abcdef"]}}}],
  "outbounds":[{"type":"direct"}]},open("/tmp/e_srv.json","w"))
json.dump({"log":{"level":"error"},"inbounds":[{"type":"mixed","listen":"127.0.0.1","listen_port":10810}],
  "outbounds":[{"type":"vless","server":"127.0.0.1","server_port":18443,"uuid":uuid,
  "tls":{"enabled":True,"server_name":sni,"utls":{"enabled":True,"fingerprint":"chrome"},
  "reality":{"enabled":True,"public_key":pub,"short_id":"0123456789abcdef"}}}]},open("/tmp/e_cli.json","w"))
PY
  sing-box run -c /tmp/e_srv.json >/tmp/e_srv.log 2>&1 & S=$!
  sleep 2
  sing-box run -c /tmp/e_cli.json >/tmp/e_cli.log 2>&1 & C=$!
  sleep 4
  cc=$(curl -s --max-time 6 --socks5-hostname 127.0.0.1:10810 https://ipinfo.io/country 2>/dev/null)
  kill "$S" "$C" 2>/dev/null; sleep 1
  printf '  %-24s -> %s\n' "$sni" "${cc:-FAIL}"
}
for d in www.microsoft.com www.cloudflare.com addons.mozilla.org www.apple.com dl.google.com; do
  test_decoy "$d"
done

echo
echo "=== sing-box: $(sing-box version | head -1) ==="
echo "=== последний server log теста ==="
tail -n 4 /tmp/e_srv.log 2>/dev/null
echo
echo "ИТОГ:"
echo " - если КАКОЙ-ТО домен дал страну (не FAIL) -> меняем SNI на него (лёгкий фикс)."
echo " - если ВСЕ FAIL и 'System clock synchronized: no' -> чиним время (NTP)."
echo " - если ВСЕ FAIL и часы синхронны -> окружение битое -> Reinstall OS (чистая пересборка)."
