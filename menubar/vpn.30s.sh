#!/usr/bin/env bash
#
# SwiftBar/xbar плагин: тумблер VPN в строке меню macOS.
# Показывает цветной индикатор и страну выхода; в выпадающем меню — кнопки
# включить / выключить / перезапустить.
#
# <xbar.title>VPN Latvia Toggle</xbar.title>
# <xbar.version>v1.0</xbar.version>
# <xbar.author>vpn repo</xbar.author>
# <xbar.desc>Тумблер sing-box туннеля с индикатором страны.</xbar.desc>
# <xbar.dependencies>sing-box,swiftbar</xbar.dependencies>
#
# Имя файла кодирует интервал обновления (30s). Плагин лежит в папке menubar/
# этого репозитория и сам находит scripts/vpn.sh по соседству.

export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:$PATH"

DIR="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)"
VPN="$DIR/scripts/vpn.sh"
MODE_SH="$DIR/scripts/vpn-mode.sh"
PROTO_SH="$DIR/scripts/vpn-proto.sh"
CFG="/etc/sing-box/config.json"

# Текущий режим маршрутизации (читается без sudo из конфига)
mode="full"
grep -q '"final": "direct"' "$CFG" 2>/dev/null && mode="selective"

# Текущий протокол через Clash API (без sudo)
CTRL="$(grep -o '"external_controller": *"[^"]*"' "$CFG" 2>/dev/null | sed 's/.*"\([^"]*\)"/\1/')"
SECRET="$(grep -o '"secret": *"[^"]*"' "$CFG" 2>/dev/null | sed 's/.*"\([^"]*\)"/\1/')"
CTRL="${CTRL:-127.0.0.1:9090}"
proto_now() { curl -fsS --max-time 3 -H "Authorization: Bearer $SECRET" "http://$CTRL/proxies/$1" 2>/dev/null | grep -o '"now":"[^"]*"' | head -1 | sed 's/.*:"//;s/"//'; }
mark() { [ "$1" = "$2" ] && printf ' ✓' || printf ''; }

if pgrep -x sing-box >/dev/null 2>&1; then
  cc="$(curl -fsS --max-time 4 https://ipinfo.io/country 2>/dev/null | tr -d '[:space:]')"
  ip="$(curl -fsS --max-time 4 https://ipinfo.io/ip 2>/dev/null | tr -d '[:space:]')"
  [ -z "$cc" ] && cc="??"

  if [ "$mode" = "selective" ]; then
    echo "🟢 ${cc} 🎯 | color=#34c759"
  else
    echo "🟢 ${cc} | color=#34c759"
  fi
  echo "---"
  echo "Туннель включён | color=#34c759"
  echo "IP: ${ip:-?}  ·  страна: ${cc}"
  echo "---"
  if [ "$mode" = "full" ]; then
    echo "Режим: весь трафик 🌍"
    echo "→ Переключить на «только сервисы» | bash=\"$MODE_SH\" param1=selective terminal=false refresh=true"
  else
    echo "Режим: только Claude/ChatGPT/YouTube/Telegram 🎯"
    echo "→ Переключить на «весь трафик» | bash=\"$MODE_SH\" param1=full terminal=false refresh=true"
  fi
  echo "---"
  sel="$(proto_now proxy)"
  if [ "$sel" = "auto" ]; then
    actv="$(proto_now auto)"
    echo "Протокол: авто → ${actv:-?}"
  else
    echo "Протокол: ${sel:-?}"
  fi
  echo "--Авто (выбирает сам)$(mark "$sel" auto) | bash=\"$PROTO_SH\" param1=auto terminal=false refresh=true"
  echo "--VLESS+Reality (TCP)$(mark "$sel" vless-reality) | bash=\"$PROTO_SH\" param1=reality terminal=false refresh=true"
  echo "--Hysteria2 (UDP)$(mark "$sel" hysteria2) | bash=\"$PROTO_SH\" param1=hysteria2 terminal=false refresh=true"
  echo "---"
  echo "⛔ Выключить | bash=\"$VPN\" param1=off terminal=false refresh=true"
  echo "🔄 Перезапустить | bash=\"$VPN\" param1=restart terminal=false refresh=true"
else
  echo "⚪️ off | color=#8e8e93"
  echo "---"
  echo "Туннель выключен — интернет напрямую | color=#8e8e93"
  echo "---"
  echo "✅ Включить | bash=\"$VPN\" param1=on terminal=false refresh=true"
fi

echo "---"
echo "📜 Логи | bash=\"/usr/bin/open\" param1=\"/var/log/sing-box.err.log\" terminal=false"
echo "🔁 Обновить | refresh=true"
