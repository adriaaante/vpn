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
KS_SH="$DIR/scripts/killswitch.sh"
CFG="/etc/sing-box/config.json"

# Состояние kill-switch: маркер (хотим ли мы защиту) + РЕАЛЬНАЯ проверка pf
# (включён ли pf и загружено ли наше правило). Требует sudoers NOPASSWD на pfctl -s.
ks="off"; [ -f /etc/sing-box/killswitch.enabled ] && ks="on"
ks_active="no"
if sudo -n pfctl -s info 2>/dev/null | grep -q "Status: Enabled" && sudo -n pfctl -s rules 2>/dev/null | grep -q "block drop out all"; then
  ks_active="yes"
fi
# ok = хотим и реально активен; fell = хотим, но pf сбросился (macOS); off = не хотим
ks_state="off"
[ "$ks" = "on" ] && ks_state="fell"
{ [ "$ks" = "on" ] && [ "$ks_active" = "yes" ]; } && ks_state="ok"

# Текущий режим маршрутизации (читается без sudo из конфига)
mode="full"
grep -q '"final": "direct"' "$CFG" 2>/dev/null && mode="selective"

# Текущий протокол через Clash API (без sudo)
CTRL="$(grep -o '"external_controller": *"[^"]*"' "$CFG" 2>/dev/null | sed 's/.*"\([^"]*\)"/\1/')"
SECRET="$(grep -o '"secret": *"[^"]*"' "$CFG" 2>/dev/null | sed 's/.*"\([^"]*\)"/\1/')"
CTRL="${CTRL:-127.0.0.1:9090}"
proto_now() { curl -fsS --max-time 3 -H "Authorization: Bearer $SECRET" "http://$CTRL/proxies/$1" 2>/dev/null | python3 -c 'import sys,json;
try: print(json.load(sys.stdin).get("now",""))
except Exception: print("")' 2>/dev/null; }
proto_delay() { curl -fsS --max-time 3 -H "Authorization: Bearer $SECRET" "http://$CTRL/proxies/$1" 2>/dev/null | python3 -c 'import sys,json;
try:
 h=json.load(sys.stdin).get("history",[]); print(h[-1]["delay"] if h else "")
except Exception: print("")' 2>/dev/null; }
mark() { [ "$1" = "$2" ] && printf ' ✓' || printf ''; }

# Спиннер «Применяю…» пока идёт переключение/перезапуск
if [ -f /tmp/vpn-busy ]; then
  echo "⏳ … | color=#ff9500"
  echo "---"
  echo "Применяю изменения…"
  echo "🔁 Обновить | refresh=true"
  exit 0
fi

if pgrep -x sing-box >/dev/null 2>&1; then
  cc="$(curl -fsS --max-time 4 https://ipinfo.io/country 2>/dev/null | tr -d '[:space:]')"
  ip="$(curl -fsS --max-time 4 https://ipinfo.io/ip 2>/dev/null | tr -d '[:space:]')"
  [ -z "$cc" ] && cc="??"

  smark=""; [ "$mode" = "selective" ] && smark=" 🎯"
  echo "🟢 ${cc}${smark} | color=#34c759"
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
  fname() { case "$1" in vless-reality) echo "Reality (TCP)";; hysteria2) echo "Hysteria2 (UDP)";; auto) echo "авто";; "") echo "…";; *) echo "$1";; esac; }
  sel="$(proto_now proxy)"
  if [ "$sel" = "auto" ]; then actv="$(proto_now auto)"; else actv="$sel"; fi
  d="$(proto_delay "$actv")"
  dtxt=""; { [ -n "$d" ] && [ "$d" != "0" ]; } && dtxt=" · ${d} ms"
  if [ "$sel" = "auto" ]; then
    echo "Протокол: авто → $(fname "$actv")${dtxt}"
  else
    echo "Протокол: $(fname "$actv")${dtxt}"
  fi
  echo "--Авто (выбирает сам)$(mark "$sel" auto) | bash=\"$PROTO_SH\" param1=auto terminal=false refresh=true"
  echo "--VLESS+Reality (TCP)$(mark "$sel" vless-reality) | bash=\"$PROTO_SH\" param1=reality terminal=false refresh=true"
  echo "--Hysteria2 (UDP)$(mark "$sel" hysteria2) | bash=\"$PROTO_SH\" param1=hysteria2 terminal=false refresh=true"
  echo "--🚀 Проверить пинг сейчас | bash=\"$PROTO_SH\" param1=test terminal=false refresh=true"
  echo "---"
  if [ "$ks_state" = "ok" ]; then
    echo "🛡 Kill-switch: включён и активен | color=#34c759"
    echo "→ Выключить kill-switch | bash=\"$KS_SH\" param1=off terminal=false refresh=true"
  elif [ "$ks_state" = "fell" ]; then
    echo "⚠️ Kill-switch ОТВАЛИЛСЯ — защита не активна! | color=#ff3b30"
    echo "→ ВКЛЮЧИТЬ ЗАНОВО | bash=\"$KS_SH\" param1=on terminal=false refresh=true"
  else
    echo "🛡 Kill-switch: выключен"
    echo "→ Включить kill-switch (защита от утечки IP) | bash=\"$KS_SH\" param1=on terminal=false refresh=true"
  fi
  echo "---"
  echo "⛔ Выключить | bash=\"$VPN\" param1=off terminal=false refresh=true"
  echo "🔄 Перезапустить | bash=\"$VPN\" param1=restart terminal=false refresh=true"
else
  echo "⚪️ off | color=#8e8e93"
  echo "---"
  echo "Туннель выключен — интернет напрямую | color=#8e8e93"
  if [ "$ks" = "on" ]; then
    echo "🛡 Kill-switch активен — интернет заблокирован до подключения | color=#ff9500"
    echo "→ Выключить kill-switch | bash=\"$KS_SH\" param1=off terminal=false refresh=true"
  fi
  echo "---"
  echo "✅ Включить | bash=\"$VPN\" param1=on terminal=false refresh=true"
fi

echo "---"
echo "🩺 Диагностика | bash=\"$VPN\" param1=status terminal=true"
echo "📜 Логи | bash=\"/usr/bin/open\" param1=\"/var/log/sing-box.err.log\" terminal=false"
echo "🔁 Обновить | refresh=true"
