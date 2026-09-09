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

# Аварийно выключенный туннель НАДО пробовать поднимать снова. Иначе схема
# «поменял A-запись — всё починилось само» не работает: пока адрес был мёртв,
# circuit-breaker ниже успевал выключить туннель, и он оставался выключенным
# навсегда, до ручного `vpn on`. Теперь пробуем раз в полчаса: адрес сервера мог
# смениться, а узлы по имени (reality-dns*) подхватят новый сами.
# Выключение РУКАМИ (`vpn off`) снимает маркер, поэтому осознанное «выключено»
# мы не трогаем и обратно не включаем.
AUTOOFF="$HOME/.cache/vpn-auto-off"
RETRY_SEC="${VPN_RETRY_SEC:-1800}"
PLIST="${PLIST:-/Library/LaunchDaemons/com.user.singbox.plist}"

if ! pgrep -x sing-box >/dev/null 2>&1; then
  if [[ -f "$AUTOOFF" ]]; then
    off_at="$(cat "$AUTOOFF" 2>/dev/null || echo 0)"; now="$(date +%s)"
    if [[ "$off_at" =~ ^[0-9]+$ ]] && (( now - off_at >= RETRY_SEC )); then
      # Метку двигаем ДО попытки: не вышло — следующая не раньше, чем через RETRY_SEC.
      echo "$now" > "$AUTOOFF"
      sudo launchctl bootstrap system "$PLIST" >/dev/null 2>&1 || true
      osascript -e 'display notification "Пробую поднять туннель заново — адрес сервера мог смениться." with title "VPN: авто-восстановление"' >/dev/null 2>&1 || true
    fi
  fi
  exit 0
fi
# Туннель работает — аварийный маркер больше не нужен.
rm -f "$AUTOOFF"

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
      sudo launchctl bootout system "$PLIST" >/dev/null 2>&1 || true
      echo 0 > "$HEALTH"; echo "$now" > "$LASTR"
      date +%s > "$AUTOOFF"   # метка «выключили МЫ» — значит можно пробовать снова
      osascript -e 'display notification "Туннель не поднимается — ВЫКЛЮЧЕН, чтобы не флудить сервер. Сам попробую снова через 30 минут; если сменишь A-запись, подхватит новый адрес." with title "VPN: аварийное отключение" sound name "Submarine"' >/dev/null 2>&1 || true
    fi
  fi
fi

CTRL="$(grep -o '"external_controller": *"[^"]*"' "$CFG" 2>/dev/null | sed 's/.*"\([^"]*\)"/\1/')"
SECRET="$(grep -o '"secret": *"[^"]*"' "$CFG" 2>/dev/null | sed 's/.*"\([^"]*\)"/\1/')"
CTRL="${CTRL:-127.0.0.1:9090}"
now_of() { curl -fsS --max-time 3 -H "Authorization: Bearer $SECRET" "http://$CTRL/proxies/$1" 2>/dev/null | grep -o '"now":"[^"]*"' | head -1 | sed 's/.*:"//;s/"//'; }

name() {
  case "$1" in
    vless-reality)      echo "Reality · apple.com";;
    reality-cloudflare) echo "Reality · cloudflare.com";;
    reality-google)     echo "Reality · google.com";;
    reality-mozilla)    echo "Reality · mozilla.org";;
    reality-icloud)     echo "Reality · icloud.com";;
    reality-samsung)    echo "Reality · samsung.com";;
    reality-alt2053)    echo "Reality · порт 2053";;
    reality-alt8443)    echo "Reality · порт 8443";;
    *)                  echo "$1";;
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
