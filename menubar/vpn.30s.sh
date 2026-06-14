#!/usr/bin/env bash
#
# SwiftBar плагин: пульт VPN (sing-box) в строке меню macOS.
# В ФОНЕ делает 0 внешних запросов — всё состояние берёт из ЛОКАЛЬНОГО Clash API
# (127.0.0.1) + локальной проверки pf. Страну выхода узнаём ТОЛЬКО по кнопке.
#
# <xbar.title>VPN Latvia</xbar.title>
# <xbar.version>v2</xbar.version>
# <xbar.desc>Пульт sing-box: связь, режим, протокол, kill-switch — из локального API.</xbar.desc>
#
# Имя файла кодирует интервал обновления (30s). Лежит в menubar/ этого репозитория.

export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:$PATH"

DIR="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)"
VPN="$DIR/scripts/vpn.sh"
MODE_SH="$DIR/scripts/vpn-mode.sh"
PROTO_SH="$DIR/scripts/vpn-proto.sh"
KS_SH="$DIR/scripts/killswitch.sh"
CFG="/etc/sing-box/config.json"
IPCACHE="/tmp/vpn-ipcheck"

CTRL="$(grep -o '"external_controller": *"[^"]*"' "$CFG" 2>/dev/null | sed 's/.*"\([^"]*\)"/\1/')"
SECRET="$(grep -o '"secret": *"[^"]*"' "$CFG" 2>/dev/null | sed 's/.*"\([^"]*\)"/\1/')"
CTRL="${CTRL:-127.0.0.1:9090}"
api() { curl -fsS --max-time 2 -H "Authorization: Bearer $SECRET" "http://$CTRL/$1" 2>/dev/null; }

# --- ДЕЙСТВИЕ ПО КЛИКУ: проверить выходной IP (единственный внешний запрос, по требованию) ---
if [ "${1:-}" = "checkip" ]; then
  curl -fsS --max-time 6 https://ipinfo.io/json 2>/dev/null | python3 -c 'import sys,json,time
try:
 d=json.load(sys.stdin); print(d.get("country","?")+" "+d.get("ip","?")+" "+time.strftime("%H:%M"))
except Exception: print("? ? "+time.strftime("%H:%M"))' > "$IPCACHE" 2>/dev/null
  exit 0
fi

# --- Спиннер «Применяю…» во время переключений ---
if [ -f /tmp/vpn-busy ]; then
  echo "⏳ … | color=#ff9500"
  echo "---"; echo "Применяю изменения…"; echo "🔁 Обновить | refresh=true"
  exit 0
fi

# --- Локальные проверки (0 внешних запросов) ---
# kill-switch: реальное состояние pf (нужен sudoers NOPASSWD на pfctl -s)
ks="off"; [ -f /etc/sing-box/killswitch.enabled ] && ks="on"
ks_active="no"
if sudo -n pfctl -s info 2>/dev/null | grep -q "Status: Enabled" && sudo -n pfctl -s rules 2>/dev/null | grep -q "block drop out all"; then ks_active="yes"; fi
ks_state="off"; [ "$ks" = "on" ] && ks_state="fell"; { [ "$ks" = "on" ] && [ "$ks_active" = "yes" ]; } && ks_state="ok"

# режим
mode="full"; grep -q '"final": "direct"' "$CFG" 2>/dev/null && mode="selective"

# протокол + связь из локального Clash API
nowof() { api "proxies/$1" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("now",""))
except Exception: print("")' 2>/dev/null; }
delayof() { api "proxies/$1" | python3 -c 'import sys,json
try:
 h=json.load(sys.stdin).get("history",[]); print(h[-1].get("delay","") if h else "")
except Exception: print("")' 2>/dev/null; }
fname() { case "$1" in vless-reality) echo "Reality (TCP)";; auto) echo "авто";; "") echo "…";; *) echo "$1";; esac; }
mark() { [ "$1" = "$2" ] && printf ' ✓' || printf ''; }

# страна выхода — из кэша последней ручной проверки (НЕ в фоне)
cc="—"
[ -s "$IPCACHE" ] && read -r cc ipx ipt < "$IPCACHE"

if pgrep -x sing-box >/dev/null 2>&1; then
  sel="$(nowof proxy)"; actv="$sel"; [ "$sel" = "auto" ] && actv="$(nowof auto)"
  d="$(delayof "$actv")"
  # online: последняя проверка urltest успешна (delay>0); 0 = провал; пусто = простой/неизвестно
  echo "🟢 ${cc} | color=#34c759"
  echo "---"
  if [ -n "$d" ] && [ "$d" != "0" ]; then
    echo "Туннель на связи · ${d} ms | color=#34c759"
  elif [ "$d" = "0" ]; then
    echo "⚠️ Нет связи через туннель (последняя проверка не прошла) | color=#ff3b30"
    echo "→ Перезапустить туннель | bash=\"$VPN\" param1=restart terminal=false refresh=true"
  else
    echo "Туннель поднят (связь проверяется…) | color=#8e8e93"
  fi
  echo "🌍 Проверить выходной IP сейчас | bash=\"$0\" param1=checkip terminal=false refresh=true"
  [ -s "$IPCACHE" ] && echo "   последняя проверка: ${cc} · ${ipx:-?} · в ${ipt:-?}"
  echo "---"
  if [ "$mode" = "full" ]; then
    echo "Режим: весь трафик 🌍"
    echo "→ Переключить на «только сервисы» | bash=\"$MODE_SH\" param1=selective terminal=false refresh=true"
  else
    echo "Режим: только Claude/ChatGPT/YouTube/Telegram 🎯"
    echo "→ Переключить на «весь трафик» | bash=\"$MODE_SH\" param1=full terminal=false refresh=true"
  fi
  echo "---"
  dtxt=""; { [ -n "$d" ] && [ "$d" != "0" ]; } && dtxt=" · ${d} ms"
  echo "Протокол: $(fname "$actv")${dtxt}"
  echo "--Авто$(mark "$sel" auto) | bash=\"$PROTO_SH\" param1=auto terminal=false refresh=true"
  echo "--Reality (TCP)$(mark "$sel" vless-reality) | bash=\"$PROTO_SH\" param1=reality terminal=false refresh=true"
  echo "--🚀 Проверить пинг | bash=\"$PROTO_SH\" param1=test terminal=false refresh=true"
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
  if [ "$ks_state" = "ok" ]; then
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
