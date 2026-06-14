#!/usr/bin/env bash
#
# vpn-busy.sh begin|end — показывает/убирает индикатор «Применяю…» в строке меню.
# Помечает /tmp/vpn-busy и просит SwiftBar обновить плагин, чтобы спиннер появился
# сразу, пока идёт переключение/перезапуск.

MARK="/tmp/vpn-busy"
refresh() { open "swiftbar://refreshallplugins" >/dev/null 2>&1 || true; }

case "${1:-}" in
  begin) : > "$MARK"; refresh ;;
  end)   rm -f "$MARK"; refresh ;;
  *) : ;;
esac
