#!/usr/bin/env bash
#
# vpn-mode.sh — переключение режима маршрутизации (3 режима).
#
#   vpn-mode strict      ВЕСЬ трафик через Латвию (даже RU) — максимально скрыто
#   vpn-mode full        умный: зарубеж через Латвию, RU напрямую (быстро)
#   vpn-mode selective   только Claude/ChatGPT/YouTube/Telegram через Латвию
#   vpn-mode status      показать текущий режим
#
# Установщик кладёт 3 готовых конфига (config-strict/full/selective.json);
# этот скрипт подставляет нужный, пишет маркер /etc/sing-box/mode и перезапускает демон.
# Требует sudo (для бесшумной работы из меню — sudoers, см. setup-sudoers.sh).

set -euo pipefail

SBDIR="/etc/sing-box"
ACTIVE="$SBDIR/config.json"
MARK="$SBDIR/mode"
LABEL="com.user.singbox"

current() { cat "$MARK" 2>/dev/null || echo unknown; }

reload() { sudo launchctl kickstart -k "system/$LABEL" 2>/dev/null || true; }
SDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
busy() { bash "$SDIR/vpn-busy.sh" "$1" 2>/dev/null || true; }

apply() {  # apply <mode> <config-file> <message>
  [[ -f "$SBDIR/$2" ]] || { echo "Нет $SBDIR/$2 — запусти install-macos-daemon.sh"; exit 1; }
  busy begin
  sudo cp "$SBDIR/$2" "$ACTIVE"
  echo "$1" | sudo tee "$MARK" >/dev/null
  reload
  busy end
  echo "$3"
}

cmd="${1:-status}"
case "$cmd" in
  strict|all)
    apply strict config-strict.json "🛡 Режим: ВЕСЬ трафик через Латвию (включая RU) — максимально скрыто."
    ;;
  full)
    apply full config-full.json "🌍 Режим: умный — зарубеж через Латвию, RU напрямую."
    ;;
  selective|services)
    apply selective config-selective.json "🎯 Режим: только Claude/ChatGPT/YouTube/Telegram через Латвию."
    ;;
  status)
    case "$(current)" in
      strict)    echo "Текущий режим: всё через Латвию (strict)";;
      full)      echo "Текущий режим: умный — зарубеж Латвия, RU напрямую (full)";;
      selective) echo "Текущий режим: только сервисы (selective)";;
      *)         echo "Текущий режим: неизвестен";;
    esac
    ;;
  *)
    echo "Использование: vpn-mode strict|full|selective|status"; exit 1
    ;;
esac
