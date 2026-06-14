#!/usr/bin/env bash
#
# vpn.sh — удобное включение/выключение туннеля на macOS.
#
#   vpn on        включить
#   vpn off       выключить (вернуться к прямому интернету)
#   vpn restart   перезапустить (например, после правки конфига)
#   vpn status    показать состояние и текущий внешний IP
#
# Удобный алиас (добавь в ~/.zshrc):
#   alias vpn="bash $HOME/vpn/scripts/vpn.sh"
#
# Команды управления демоном требуют sudo. Как сделать переключение
# без пароля — см. docs/macos-client-setup.md (раздел про sudoers).

set -euo pipefail

PLIST="/Library/LaunchDaemons/com.user.singbox.plist"
LABEL="com.user.singbox"

show_ip() {
  local ip
  ip="$(curl -fsS --max-time 6 https://ipinfo.io/ip 2>/dev/null || echo '?')"
  local geo
  geo="$(curl -fsS --max-time 6 https://ipinfo.io/country 2>/dev/null || echo '?')"
  echo "Внешний IP: $ip ($geo)"
}

is_loaded() { sudo launchctl print "system/$LABEL" >/dev/null 2>&1; }

cmd="${1:-status}"
case "$cmd" in
  on|start)
    if is_loaded; then
      sudo launchctl kickstart "system/$LABEL"
    else
      sudo launchctl bootstrap system "$PLIST"
    fi
    sudo launchctl enable "system/$LABEL" 2>/dev/null || true
    echo "✅ VPN включён."
    sleep 1; show_ip
    ;;
  off|stop)
    sudo launchctl bootout system "$PLIST" 2>/dev/null || true
    echo "⛔ VPN выключен — интернет идёт напрямую."
    sleep 1; show_ip
    ;;
  restart)
    sudo launchctl kickstart -k "system/$LABEL"
    echo "🔄 VPN перезапущен."
    sleep 1; show_ip
    ;;
  status)
    if is_loaded; then
      state="$(sudo launchctl print "system/$LABEL" 2>/dev/null | awk -F'= ' '/[^a-z]state =/{gsub(/ /,"",$2);print $2; exit}')"
      echo "Состояние: загружен (${state:-running})"
    else
      echo "Состояние: выключен (демон не загружен)"
    fi
    show_ip
    ;;
  *)
    echo "Использование: vpn on|off|restart|status"
    exit 1
    ;;
esac
