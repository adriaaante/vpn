#!/usr/bin/env bash
#
# server-share-qr.sh — печатает vless:// ссылку + QR на основе ТЕКУЩЕГО серверного
# конфига (для импорта в sing-box VT на айфоне без ввода ключей руками).
# Запуск на сервере: cd /root/vpn && git pull origin main && bash scripts/server-share-qr.sh

set -uo pipefail
CFG=/etc/sing-box/config.json
PBKF=/etc/sing-box/reality_public_key.txt
[[ -f "$CFG" ]] || { echo "Нет $CFG"; exit 1; }
[[ -f "$PBKF" ]] || { echo "Нет $PBKF (публичный ключ). Сначала запусти fix-reality-sni.sh"; exit 1; }

IP=$(curl -fsSL --max-time 6 https://api.ipify.org 2>/dev/null || echo 192.36.41.201)
UUID=$(python3 -c "import json;print(json.load(open('$CFG'))['inbounds'][0]['users'][0]['uuid'])")
SNI=$(python3 -c "import json;print(json.load(open('$CFG'))['inbounds'][0]['tls']['server_name'])")
SID=$(python3 -c "import json;r=json.load(open('$CFG'))['inbounds'][0]['tls']['reality']['short_id'];print(r[0] if isinstance(r,list) else r)")
FLOW=$(python3 -c "import json;print(json.load(open('$CFG'))['inbounds'][0]['users'][0].get('flow',''))")
PBK=$(tr -d '[:space:]' < "$PBKF")
PORT=443
FLOWQ=""; [[ -n "$FLOW" ]] && FLOWQ="flow=${FLOW}&"

LINK="vless://${UUID}@${IP}:${PORT}?encryption=none&${FLOWQ}security=reality&sni=${SNI}&fp=chrome&pbk=${PBK}&sid=${SID}&type=tcp#latvia-${SNI}"

echo "============================================================"
echo " ССЫЛКА ДЛЯ ИМПОРТА (vless://):"
echo
echo "$LINK"
echo
echo "============================================================"
echo " QR — отсканируй камерой айфона или в sing-box VT 'Import QR':"
echo
if ! command -v qrencode >/dev/null 2>&1; then
  apt-get update -qq >/dev/null 2>&1 || true
  apt-get install -y qrencode >/dev/null 2>&1 || true
fi
if command -v qrencode >/dev/null 2>&1; then
  qrencode -t ANSIUTF8 "$LINK"
else
  echo "(qrencode не поставился — введи ссылку выше вручную в приложении)"
fi
echo
echo "Импортируй в sing-box VT -> подключись. Если с Wi-Fi не цепляется (бан IP) —"
echo "попробуй на сотовой связи или перезагрузи роутер для нового IP."
