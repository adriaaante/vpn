#!/usr/bin/env bash
#
# make-desktop-launcher.sh — положить на рабочий стол ярлык «FutureFlow VPN».
# Запускать НА МАКЕ:
#   bash scripts/make-desktop-launcher.sh
#
# Двойной клик по ярлыку открывает Терминал, поднимает SSH-туннель к серверу и
# сам открывает панель в браузере. Закрыть — Ctrl+C в этом окне (панель на
# сервере гаснет вместе с туннелем).
#
# Почему .command, а не .app: панели нужен видимый терминал — в нём PIN при
# старте, сообщения об обрывах связи и Ctrl+C для выхода. В .app это спрятано.

set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DESK="${DESKTOP:-$HOME/Desktop}"
NAME="${NAME:-FutureFlow VPN}"
FILE="$DESK/$NAME.command"
ICON="$DIR/assets/logo-icon.png"

[[ -d "$DESK" ]] || { echo "Нет каталога $DESK — задай свой: DESKTOP=/путь bash $0"; exit 1; }

cat > "$FILE" <<EOF
#!/bin/bash
# Ярлык панели FutureFlow. Пересоздать: bash scripts/make-desktop-launcher.sh
cd "$DIR" || { echo "Не найден каталог $DIR"; echo "Enter — закрыть"; read -r; exit 1; }
exec bash scripts/vpn-panel.sh
EOF
chmod +x "$FILE" || { echo "Не удалось сделать ярлык исполняемым"; exit 1; }
echo "[*] Ярлык: $FILE"

# Иконка: AppleScript-ObjC есть в macOS из коробки. Если система откажет —
# ярлык всё равно рабочий, просто с системным значком.
if [[ -f "$ICON" ]] && command -v osascript >/dev/null 2>&1; then
  if osascript - "$ICON" "$FILE" >/dev/null 2>&1 <<'OSA'
use framework "Foundation"
use framework "AppKit"
on run argv
  set img to current application's NSImage's alloc()'s initWithContentsOfFile:(item 1 of argv)
  current application's NSWorkspace's sharedWorkspace()'s setIcon:img forFile:(item 2 of argv) options:0
end run
OSA
  then
    echo "[*] Иконка установлена."
  else
    echo "[!] Иконку поставить не вышло — ярлык рабочий, просто со стандартным значком."
    echo "    Вручную: открой $ICON в Просмотре, Cmd+A, Cmd+C;"
    echo "    выдели ярлык, Cmd+I, кликни на значок слева сверху окна, Cmd+V."
  fi
fi

echo
echo "[OK] Двойной клик по ярлыку на рабочем столе открывает панель."
echo "     Первый запуск macOS может спросить подтверждение — нажми «Открыть»."
