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
# Какую ветку развернуть на сервере. По умолчанию — ТУ ЖЕ, что сейчас на маке:
# раньше здесь стоял grep 'claude', а он берёт первую подходящую ПО АЛФАВИТУ, то
# есть запросто чужую и старую. Симптом был бы обидный: «обновился, перезапустил,
# а изменений нет» — и никакой ошибки, панель просто поднимала прежний код.
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL_BRANCH="$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)"
[[ "$LOCAL_BRANCH" == "HEAD" ]] && LOCAL_BRANCH=""
BRANCH_GREP="${BRANCH_GREP:-${LOCAL_BRANCH:-claude}}"
echo "[*] Ветка для сервера: ${BRANCH_GREP}"

URL="http://127.0.0.1:$PORT/"

opener() { command -v open >/dev/null 2>&1 && open "$1" || { command -v xdg-open >/dev/null 2>&1 && xdg-open "$1"; } || echo "Открой вручную: $1"; }

echo "[*] Поднимаю туннель к $SRV и запускаю панель..."
echo "[*] Адрес (откроется сам): $URL"
( sleep 4; opener "$URL" >/dev/null 2>&1 ) &

# Панель спрашивает PIN (печатается ниже при старте). Репозиторий на сервере
# обновляем целиком по нужным каталогам: без assets логотип не доезжает.
REMOTE="cd /root/vpn && git fetch -q origin && B=\$(git branch -r | grep -m1 '$BRANCH_GREP' | tr -d ' ') && \
[ -n \"\$B\" ] || { echo \"[!] На сервере не нашлась ветка по '$BRANCH_GREP' — обновить нечем.\"; exit 1; } && \
echo \"[*] Разворачиваю \$B\" && git checkout \$B -- scripts assets && PANEL_PORT='$PORT' python3 scripts/vpn-panel.py"

# Длинный SSH к зарубежному адресу иногда рвут на пути или он отваливается по
# простою — тогда панель просто пропадала. Держим keepalive и переподключаемся,
# пока не нажат Ctrl+C. Токен не меняется, поэтому вкладку перезагружать не надо.
STOP=0
FAILS=0
trap 'STOP=1' INT
while [[ $STOP -eq 0 ]]; do
  started=$(date +%s)
  ssh -t -o ServerAliveInterval=20 -o ServerAliveCountMax=3 -o TCPKeepAlive=yes \
      -L "$PORT:127.0.0.1:$PORT" "$SRV" "$REMOTE"
  rc=$?
  [[ $STOP -eq 1 ]] && break
  # Сессия, умершая мгновенно, — это ошибка на сервере, а не обрыв связи.
  # Раньше цикл гонял её бесконечно и заваливал экран одинаковыми трейсбеками.
  if (( $(date +%s) - started < 10 )); then FAILS=$((FAILS + 1)); else FAILS=0; fi
  if (( FAILS >= 3 )); then
    echo
    echo "[!] Панель падает сразу после запуска — три раза подряд. Дальше не пробую."
    echo "    Причина в последних строках выше: это ошибка на сервере, переподключение её не лечит."
    break
  fi
  echo "[!] Соединение оборвалось (код $rc). Переподключаюсь через 3 с — Ctrl+C, чтобы выйти."
  sleep 3
done

echo "[*] Панель закрыта, туннель снят."
