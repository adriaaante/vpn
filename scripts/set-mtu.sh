#!/usr/bin/env bash
#
# set-mtu.sh — задаёт MTU туннеля на Mac. Лечит разрывы/EOF, когда дефолтный
# MTU sing-box (9000) слишком велик для реального пути: рукопожатие проходит,
# а на крупных пакетах соединение «замораживается». На рабочем iPhone MTU=1358.
#
#   bash scripts/set-mtu.sh [MTU]      # по умолчанию 1358
#
# Применяет ко всем развёрнутым конфигам (активный + 3 режима) и к локальному
# источнику, проверяет валидность и перезапускает демон. СЕРВЕР НЕ ТРОГАЕТ.

set -uo pipefail
MTU="${1:-1358}"
SDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SDIR")"
LOCAL="$REPO_DIR/configs/singbox-client.local.json"

patch() {  # patch <file> [sudo]
  local f="$1" pre="${2:-}"
  [ -f "$f" ] || return 0
  $pre python3 - "$f" "$MTU" <<'PY'
import json, sys
p, mtu = sys.argv[1], int(sys.argv[2])
d = json.load(open(p)); n = 0
for i in d.get("inbounds", []):
    if i.get("type") == "tun":
        i["mtu"] = mtu; n += 1
json.dump(d, open(p, "w"), indent=2, ensure_ascii=False)
print(f"  MTU={mtu} -> {p} (tun-inbound: {n})")
PY
}

echo "Бэкап активного конфига → /etc/sing-box/config.json.bak"
sudo cp /etc/sing-box/config.json /etc/sing-box/config.json.bak 2>/dev/null || true

echo "Применяю MTU=$MTU:"
for f in config.json config-full.json config-selective.json config-strict.json; do
  patch "/etc/sing-box/$f" sudo
done
patch "$LOCAL"

echo "Проверка конфига…"
if ! sudo sing-box check -c /etc/sing-box/config.json; then
  echo "[!] Конфиг невалиден. Откат: sudo cp /etc/sing-box/config.json.bak /etc/sing-box/config.json"
  exit 1
fi

echo "Перезапуск демона…"
sudo launchctl kickstart -k system/com.user.singbox
echo "✅ Готово. MTU=$MTU применён ко всем режимам, туннель перезапущен."
