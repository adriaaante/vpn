#!/usr/bin/env bash
#
# vpn-mode.sh — переключение режима маршрутизации.
#
#   vpn-mode full        весь трафик через Латвию (кроме РФ)
#   vpn-mode selective   через Латвию только сервисы (Claude/ChatGPT/YouTube/Telegram),
#                        остальное — напрямую
#   vpn-mode toggle      переключить туда-обратно
#   vpn-mode status      показать текущий режим
#
# Разница между режимами — одно поле route.final в конфиге. Установщик
# (install-macos-daemon.sh) кладёт два готовых конфига; этот скрипт просто
# подставляет нужный и перезапускает демон.
#
# Требует sudo (cp системного конфига + перезапуск демона). Для бесшумной работы
# из меню настрой sudoers — см. docs/macos-client-setup.md.

set -euo pipefail

SBDIR="/etc/sing-box"
ACTIVE="$SBDIR/config.json"
LABEL="com.user.singbox"

current() {
  if grep -q '"final": "direct"' "$ACTIVE" 2>/dev/null; then
    echo "selective"
  elif grep -q '"final": "proxy"' "$ACTIVE" 2>/dev/null; then
    echo "full"
  else
    echo "unknown"
  fi
}

reload() { sudo launchctl kickstart -k "system/$LABEL" 2>/dev/null || true; }

cmd="${1:-status}"
case "$cmd" in
  full)
    [[ -f "$SBDIR/config-full.json" ]] || { echo "Нет $SBDIR/config-full.json — запусти install-macos-daemon.sh"; exit 1; }
    sudo cp "$SBDIR/config-full.json" "$ACTIVE"; reload
    echo "🌍 Режим: весь трафик через Латвию (кроме РФ)."
    ;;
  selective|services)
    [[ -f "$SBDIR/config-selective.json" ]] || { echo "Нет $SBDIR/config-selective.json — запусти install-macos-daemon.sh"; exit 1; }
    sudo cp "$SBDIR/config-selective.json" "$ACTIVE"; reload
    echo "🎯 Режим: только Claude/ChatGPT/YouTube/Telegram через Латвию, остальное напрямую."
    ;;
  toggle)
    if [[ "$(current)" == "full" ]]; then exec "$0" selective; else exec "$0" full; fi
    ;;
  status)
    case "$(current)" in
      full)      echo "Текущий режим: весь трафик (full)";;
      selective) echo "Текущий режим: только сервисы (selective)";;
      *)         echo "Текущий режим: неизвестен (конфиг не найден?)";;
    esac
    ;;
  *)
    echo "Использование: vpn-mode full|selective|toggle|status"; exit 1
    ;;
esac
