#!/usr/bin/env bash
#
# vpn-watch.sh — одноразовая проверка активного протокола; шлёт macOS-уведомление,
# если клиент САМ (в режиме «авто») переключился на другой протокол (failover).
# Запускается периодически через LaunchAgent (см. scripts/install-watcher.sh).
#
# Ручные переключения протокола не считаются failover и не уведомляются.

set -uo pipefail

CFG="/etc/sing-box/config.json"
STATE="$HOME/.cache/vpn-active-proto"
mkdir -p "$(dirname "$STATE")"

# Туннель выключен — нечего отслеживать
pgrep -x sing-box >/dev/null 2>&1 || exit 0

# NB: kill-switch здесь НЕ переустанавливаем автоматически — по желанию пользователя
# управление kill-switch ручное (статус и кнопка «включить заново» в меню).

# Health-check: процесс жив, но трафик не идёт (завис) → авто-перезапуск демона.
# Защита от петли: нужно 5 неудач подряд (~100с) И не чаще 1 рестарта в 5 минут.
# Circuit-breaker: если 3 перезапуска подряд НЕ помогли (туннель реально сломан/
# сервер отвергает), туннель ВЫКЛЮЧАЕТСЯ. Иначе sing-box продолжает долбить сервер
# сотнями переподключений — и DDoS-защита провайдера (напр. EDIS) банит наш IP.
HEALTH="$HOME/.cache/vpn-health-fails"
LASTR="$HOME/.cache/vpn-last-restart"
RCNT="$HOME/.cache/vpn-restart-count"
if curl -fsS --max-time 6 -o /dev/null https://www.gstatic.com/generate_204 2>/dev/null; then
  echo 0 > "$HEALTH"; echo 0 > "$RCNT"   # связь есть — сбрасываем счётчики
else
  fails=$(( $(cat "$HEALTH" 2>/dev/null || echo 0) + 1 ))
  echo "$fails" > "$HEALTH"
  now=$(date +%s); last=$(cat "$LASTR" 2>/dev/null || echo 0)
  if [[ "$fails" -ge 5 ]] && (( now - last > 300 )); then
    rc=$(( $(cat "$RCNT" 2>/dev/null || echo 0) + 1 ))
    if [[ "$rc" -le 3 ]]; then
      sudo launchctl kickstart -k system/com.user.singbox >/dev/null 2>&1 || true
      echo 0 > "$HEALTH"; echo "$now" > "$LASTR"; echo "$rc" > "$RCNT"
      osascript -e "display notification \"sing-box завис — перезапущен (попытка $rc/3)\" with title \"VPN: авто-восстановление\" sound name \"Submarine\"" >/dev/null 2>&1 || true
    else
      # 3 рестарта не помогли — туннель сломан. Выключаем, чтобы не флудить сервер.
      sudo launchctl bootout system /Library/LaunchDaemons/com.user.singbox.plist >/dev/null 2>&1 || true
      echo 0 > "$HEALTH"; echo "$now" > "$LASTR"
      osascript -e 'display notification "Туннель не поднимается — ВЫКЛЮЧЕН, чтобы не флудить сервер (защита от бана IP). Проверь сервер и включи вручную: vpn on" with title "VPN: аварийное отключение" sound name "Submarine"' >/dev/null 2>&1 || true
    fi
  fi
fi

CTRL="$(grep -o '"external_controller": *"[^"]*"' "$CFG" 2>/dev/null | sed 's/.*"\([^"]*\)"/\1/')"
SECRET="$(grep -o '"secret": *"[^"]*"' "$CFG" 2>/dev/null | sed 's/.*"\([^"]*\)"/\1/')"
CTRL="${CTRL:-127.0.0.1:9090}"
now_of() { curl -fsS --max-time 3 -H "Authorization: Bearer $SECRET" "http://$CTRL/proxies/$1" 2>/dev/null | grep -o '"now":"[^"]*"' | head -1 | sed 's/.*:"//;s/"//'; }

name() {
  case "$1" in
    vless-reality) echo "VLESS+Reality (TCP)";;
    *)             echo "$1";;
  esac
}

sel="$(now_of proxy)"

# Протокол зафиксирован вручную — failover не отслеживаем, сбрасываем базу
if [[ "$sel" != "auto" ]]; then
  echo "manual:$sel" > "$STATE"
  exit 0
fi

cur="$(now_of auto)"
[[ -z "$cur" ]] && exit 0

prev="$(cat "$STATE" 2>/dev/null || true)"
echo "$cur" > "$STATE"

# Не уведомляем на первом запуске или сразу после ручного режима
case "$prev" in
  ""|manual:*) exit 0 ;;
esac

if [[ "$cur" != "$prev" ]]; then
  osascript -e "display notification \"Теперь активен: $(name "$cur")\" with title \"VPN: смена протокола\" subtitle \"было: $(name "$prev")\" sound name \"Submarine\"" >/dev/null 2>&1 || true
fi
