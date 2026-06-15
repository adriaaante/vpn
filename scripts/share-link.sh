#!/usr/bin/env bash
#
# share-link.sh — печатает ссылку vless:// (и QR-код) для импорта ТВОЕГО сервера
# на другое устройство (iPhone / Android / второй Mac).
#
#   bash scripts/share-link.sh
#
# Читает локальный клиентский конфиг (configs/singbox-client.local.json, иначе
# /etc/sing-box/config.json) и собирает стандартную ссылку VLESS+Reality+Vision.
# Секреты НИКУДА не отправляются — всё локально, ссылку показываем только тебе.
#
# По умолчанию используется тот же UUID, что и на этом Mac: один UUID нормально
# работает на нескольких устройствах одновременно (для личного использования —
# проще всего и без изменений на сервере). Если нужен отдельный UUID на телефон
# (чтобы отзывать устройства по отдельности) — см. docs/troubleshooting.md.
#
# QR-код требует qrencode:  brew install qrencode

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CFG="${1:-$REPO_DIR/configs/singbox-client.local.json}"
[[ -f "$CFG" ]] || CFG="/etc/sing-box/config.json"
[[ -f "$CFG" ]] || { echo "Не найден клиентский конфиг ($CFG)."; exit 1; }

LINK="$(python3 - "$CFG" <<'PY'
import json, sys, urllib.parse
d = json.load(open(sys.argv[1]))
o = next((x for x in d.get("outbounds", []) if x.get("type") == "vless"), None)
if not o:
    sys.exit("В конфиге нет vless-outbound — это точно клиентский конфиг?")
srv  = o["server"]; port = o.get("server_port", 443); uuid = o["uuid"]
flow = o.get("flow", "xtls-rprx-vision")
tls  = o.get("tls", {}); sni = tls.get("server_name", "")
fp   = tls.get("utls", {}).get("fingerprint", "chrome")
r    = tls.get("reality", {}); pbk = r.get("public_key", "")
sid  = r.get("short_id") or ""
if isinstance(sid, list): sid = sid[0] if sid else ""
q = {"encryption": "none", "flow": flow, "security": "reality",
     "sni": sni, "fp": fp, "pbk": pbk, "sid": sid, "type": "tcp"}
print("vless://%s@%s:%s?%s#%s" % (
    uuid, srv, port, urllib.parse.urlencode(q),
    urllib.parse.quote("VPN-Latvia")))
PY
)"

echo
echo "Ссылка для импорта (вставь в приложение на iPhone или отсканируй QR):"
echo
echo "  $LINK"
echo
if command -v qrencode >/dev/null 2>&1; then
  echo "QR-код — открой приложение (Streisand/v2RayTun/Happ/sing-box) → «+» →"
  echo "импорт из QR / сканировать, и наведи камеру на этот код:"
  echo
  qrencode -t ANSIUTF8 "$LINK"
else
  echo "Чтобы показать QR-код прямо тут: brew install qrencode  — затем запусти снова."
  echo "Либо просто скопируй ссылку выше и вставь в приложении вручную."
fi
echo
