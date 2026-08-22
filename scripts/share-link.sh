#!/usr/bin/env bash
#
# share-link.sh — печатает ссылки vless:// (и QR-коды) для импорта ТВОЕГО сервера
# на другое устройство (iPhone / Android / второй Mac): Shadowrocket, Happ,
# Streisand, V2Box и любой другой Xray-совместимый клиент.
#
#   bash scripts/share-link.sh
#
# Читает локальный клиентский конфиг (configs/singbox-client.local.json, иначе
# /etc/sing-box/config.json) и собирает стандартную ссылку VLESS+Reality+Vision
# на КАЖДЫЙ decoy (LV-apple, LV-cloudflare, LV-google, LV-mozilla). Импортируй
# все: рабочая — та, чей SNI совпадает с текущим decoy сервера (обычно apple);
# если decoy-monitor на сервере переключит decoy, просто выбери соседний профиль.
# Секреты НИКУДА не отправляются — всё локально, ссылки показываем только тебе.
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

LINKS="$(python3 - "$CFG" <<'PY'
import json, sys, urllib.parse
d = json.load(open(sys.argv[1]))
outs = [x for x in d.get("outbounds", []) if x.get("type") == "vless"]
if not outs:
    sys.exit("В конфиге нет vless-outbound — это точно клиентский конфиг?")
for o in outs:
    srv  = o["server"]; port = o.get("server_port", 443); uuid = o["uuid"]
    flow = o.get("flow", "xtls-rprx-vision")
    tls  = o.get("tls", {}); sni = tls.get("server_name", "")
    fp   = tls.get("utls", {}).get("fingerprint", "chrome")
    r    = tls.get("reality", {}); pbk = r.get("public_key", "")
    sid  = r.get("short_id") or ""
    if isinstance(sid, list): sid = sid[0] if sid else ""
    # имя профиля из SNI: www.apple.com -> LV-apple, dl.google.com -> LV-google
    parts = sni.split(".")
    name = "LV-" + (parts[-2] if len(parts) >= 2 else (sni or o.get("tag", "vpn")))
    q = {"encryption": "none", "flow": flow, "security": "reality",
         "sni": sni, "fp": fp, "pbk": pbk, "sid": sid, "type": "tcp"}
    print("%s vless://%s@%s:%s?%s#%s" % (
        name, uuid, srv, port, urllib.parse.urlencode(q),
        urllib.parse.quote(name)))
PY
)"

echo
echo "Ссылки для импорта — по одной на каждый decoy. Добавь в приложение ВСЕ"
echo "(Shadowrocket: значок сканера слева вверху для QR, либо «+» → вставить ссылку):"
echo
while IFS=' ' read -r NAME LINK; do
  [[ -n "$LINK" ]] || continue
  echo "── $NAME ──"
  echo "  $LINK"
  if command -v qrencode >/dev/null 2>&1; then
    qrencode -t ANSIUTF8 "$LINK"
  fi
  echo
done <<< "$LINKS"
if ! command -v qrencode >/dev/null 2>&1; then
  echo "Чтобы показать QR-коды прямо тут: brew install qrencode  — затем запусти снова."
  echo "Либо просто скопируй ссылки выше и вставь в приложении вручную."
  echo
fi
echo "Подключаться через профиль, чей SNI совпадает с текущим decoy сервера"
echo "(по умолчанию LV-apple; текущий покажет scripts/server-status.sh)."
