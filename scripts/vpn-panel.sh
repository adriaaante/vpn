#!/usr/bin/env bash
#
# vpn-panel.sh — открыть веб-панель управления доступом. Запускать НА МАКЕ:
#   bash scripts/vpn-panel.sh
#
# Поднимает SSH-туннель к серверу, запускает там панель на 127.0.0.1 и открывает
# браузер. Наружу ничего не публикуется: панель слушает только петлю сервера, а
# ходим мы к ней через туннель. Ctrl+C — панель гаснет, туннель закрывается.

set -uo pipefail
SRV="${SRV:-root@89.46.238.74}"
PORT="${PANEL_PORT:-8787}"
BRANCH_GREP="${BRANCH_GREP:-claude}"

TOKEN="$(python3 -c 'import secrets;print(secrets.token_urlsafe(16))')"
URL="http://127.0.0.1:$PORT/?t=$TOKEN"

opener() { command -v open >/dev/null 2>&1 && open "$1" || { command -v xdg-open >/dev/null 2>&1 && xdg-open "$1"; } || echo "Открой вручную: $1"; }

echo "[*] Поднимаю туннель к $SRV и запускаю панель..."
echo "[*] Адрес (откроется сам): $URL"
( sleep 4; opener "$URL" >/dev/null 2>&1 ) &

# Токен передаём в окружение удалённой панели; репозиторий на сервере обновляем,
# чтобы панель и vpn-users.sh были одной версии.
REMOTE="cd /root/vpn && git fetch -q origin && git checkout \$(git branch -r | grep -m1 '$BRANCH_GREP') -- scripts && PANEL_TOKEN='$TOKEN' PANEL_PORT='$PORT' python3 scripts/vpn-panel.py"

# Длинный SSH к зарубежному адресу иногда рвут на пути или он отваливается по
# простою — тогда панель просто пропадала. Держим keepalive и переподключаемся,
# пока не нажат Ctrl+C. Токен не меняется, поэтому вкладку перезагружать не надо.
STOP=0
trap 'STOP=1' INT
while [[ $STOP -eq 0 ]]; do
  ssh -t -o ServerAliveInterval=20 -o ServerAliveCountMax=3 -o TCPKeepAlive=yes \
      -L "$PORT:127.0.0.1:$PORT" "$SRV" "$REMOTE"
  rc=$?
  [[ $STOP -eq 1 ]] && break
  echo "[!] Соединение оборвалось (код $rc). Переподключаюсь через 3 с — Ctrl+C, чтобы выйти."
  sleep 3
done

echo "[*] Панель закрыта, туннель снят."
