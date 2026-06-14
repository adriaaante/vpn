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

if pgrep -x sing-box >/dev/null 2>&1; then
  cc="$(curl -fsS --max-time 4 https://ipinfo.io/country 2>/dev/null | tr -d '[:space:]')"
  ip="$(curl -fsS --max-time 4 https://ipinfo.io/ip 2>/dev/null | tr -d '[:space:]')"
  [ -z "$cc" ] && cc="??"

  echo "🟢 ${cc} | color=#34c759"
  echo "---"
  echo "Туннель включён | color=#34c759"
  echo "IP: ${ip:-?}  ·  страна: ${cc}"
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
