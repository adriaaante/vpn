#!/usr/bin/env bash
#
# vpn.sh — единый командный центр туннеля на macOS.
#
#   vpn on | off | restart       включить / выключить / перезапустить
#   vpn status                   полная диагностика (по умолчанию)
#   vpn mode  [strict|full|selective|status]   режим маршрутизации
#   vpn proto [auto|reality|hysteria2|status|test]   выбор протокола
#   vpn killswitch [on|off|status]             защита от утечки IP
#   vpn help                     справка
#
# Удобный алиас (добавь в ~/.zshrc):
#   alias vpn="bash $HOME/vpn/scripts/vpn.sh"

set -uo pipefail

PLIST="/Library/LaunchDaemons/com.user.singbox.plist"
LABEL="com.user.singbox"
CFG="/etc/sing-box/config.json"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

is_loaded() { sudo launchctl print "system/$LABEL" >/dev/null 2>&1; }
busy() { bash "$DIR/vpn-busy.sh" "$1" 2>/dev/null || true; }
reapply_killswitch() {
  [[ -f /etc/sing-box/killswitch.enabled ]] || return 0
  # Сразу + несколько раз в фоне: sing-box после рестарта создаёт новый utun не
  # мгновенно; так pf быстро подхватывает свежий интерфейс и не блокирует туннель.
  bash "$DIR/killswitch.sh" reapply >/dev/null 2>&1 || true
  ( for _ in 1 2 3 4 5 6; do sleep 2; [[ -f /etc/sing-box/killswitch.enabled ]] && bash "$DIR/killswitch.sh" reapply >/dev/null 2>&1 || true; done ) >/dev/null 2>&1 &
}

server_ip() {
  grep -oE '"server": *"[0-9]{1,3}(\.[0-9]{1,3}){3}"' "$CFG" 2>/dev/null \
    | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}' \
    | grep -Ev '^(1\.1\.1\.1|8\.8\.8\.8|127\.|0\.)' | head -1
}
clash_ctrl() { local c; c="$(grep -o '"external_controller": *"[^"]*"' "$CFG" 2>/dev/null | sed 's/.*"\([^"]*\)"/\1/')"; echo "${c:-127.0.0.1:9090}"; }
clash_secret() { grep -o '"secret": *"[^"]*"' "$CFG" 2>/dev/null | sed 's/.*"\([^"]*\)"/\1/'; }
proto_now() { curl -fsS --max-time 3 -H "Authorization: Bearer $(clash_secret)" "http://$(clash_ctrl)/proxies/$1" 2>/dev/null | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("now",""))
except Exception: print("")' 2>/dev/null; }

show_ip() {
  local ip geo
  ip="$(curl -fsS --max-time 6 https://ipinfo.io/ip 2>/dev/null || echo '?')"
  geo="$(curl -fsS --max-time 6 https://ipinfo.io/country 2>/dev/null || echo '?')"
  echo "Внешний IP: $ip ($geo)"
}

full_status() {
  echo "  VPN — диагностика"
  echo "  ─────────────────"

  # Туннель
  if pgrep -x sing-box >/dev/null 2>&1; then
    echo "  Туннель:      🟢 включён"
  else
    if is_loaded; then echo "  Туннель:      🟠 демон загружен, процесс не найден"
    else echo "  Туннель:      ⚪️ выключен"; fi
  fi

  # IP/страна
  local ip geo
  ip="$(curl -fsS --max-time 6 https://ipinfo.io/ip 2>/dev/null || echo '?')"
  geo="$(curl -fsS --max-time 6 https://ipinfo.io/country 2>/dev/null || echo '?')"
  if [ "$geo" = "LV" ]; then echo "  Внешний IP:   $ip ($geo) ✓ Латвия"
  elif [ "$geo" = "RU" ]; then echo "  Внешний IP:   $ip ($geo) ⚠️ Россия — туннель не активен!"
  else echo "  Внешний IP:   $ip ($geo)"; fi

  # Протокол + пинг
  local sel actv d
  sel="$(proto_now proxy)"
  if [ "$sel" = "auto" ]; then actv="$(proto_now auto)"; else actv="$sel"; fi
  d="$(curl -fsS --max-time 3 -H "Authorization: Bearer $(clash_secret)" "http://$(clash_ctrl)/proxies/${actv}" 2>/dev/null | grep -o '"delay":[0-9]*' | tail -1 | sed 's/.*://')"
  [ -n "${sel:-}" ] && echo "  Протокол:     ${sel}${actv:+ → $actv}${d:+ · ${d} ms}"

  # Режим (из маркера)
  case "$(cat /etc/sing-box/mode 2>/dev/null || echo full)" in
    strict)    echo "  Режим:        🛡 всё через Латвию (скрыто)";;
    selective) echo "  Режим:        🎯 только сервисы";;
    *)         echo "  Режим:        🌍 умный (RU напрямую)";;
  esac

  # Kill-switch
  if [ -f /etc/sing-box/killswitch.enabled ]; then echo "  Kill-switch:  🛡 включён"; else echo "  Kill-switch:  выключен"; fi

  # Watcher (failover/health)
  if launchctl print "gui/$(id -u)/com.user.singbox-watch" >/dev/null 2>&1; then echo "  Watcher:      ✓ работает (failover + health)"; else echo "  Watcher:      выключен"; fi

  # Доступность сервера
  local sip; sip="$(server_ip)"
  if [ -n "$sip" ]; then
    if nc -z -G 3 "$sip" 443 >/dev/null 2>&1; then echo "  Сервер:       $sip:443 ✓ доступен"; else echo "  Сервер:       $sip:443 ⚠️ недоступен"; fi
  fi
}

cmd="${1:-status}"; shift 2>/dev/null || true
case "$cmd" in
  on|start)
    busy begin
    if is_loaded; then sudo launchctl kickstart "system/$LABEL"; else sudo launchctl bootstrap system "$PLIST"; fi
    sudo launchctl enable "system/$LABEL" 2>/dev/null || true
    sleep 1; reapply_killswitch; busy end
    echo "✅ VPN включён."; show_ip
    ;;
  off|stop)
    busy begin
    sudo launchctl bootout system "$PLIST" 2>/dev/null || true
    busy end
    echo "⛔ VPN выключен — интернет идёт напрямую."
    sleep 1; show_ip
    ;;
  restart)
    busy begin
    sudo launchctl kickstart -k "system/$LABEL"
    sleep 1; reapply_killswitch; busy end
    echo "🔄 VPN перезапущен."; show_ip
    ;;
  status|diag|diagnose)
    full_status
    ;;
  mode)       bash "$DIR/vpn-mode.sh" "$@" ;;
  proto)      bash "$DIR/vpn-proto.sh" "$@" ;;
  killswitch|ks) bash "$DIR/killswitch.sh" "$@" ;;
  help|-h|--help)
    sed -n '3,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    ;;
  *)
    echo "Неизвестная команда: $cmd"; echo "vpn help — список команд"; exit 1
    ;;
esac
