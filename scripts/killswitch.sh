#!/usr/bin/env bash
#
# killswitch.sh — kill-switch через pf (штатный фаервол macOS).
# Если туннель (sing-box) упал/выключен — весь исходящий трафик в интернет
# блокируется, чтобы реальный IP и DNS не утекли (fail-closed).
#
#   killswitch.sh on       включить защиту
#   killswitch.sh off      выключить защиту
#   killswitch.sh status   показать состояние
#   killswitch.sh reapply  пересобрать правила (свежий список utun) — вызывается
#                          автоматически из vpn.sh/watcher
#
# Разрешено наружу только: loopback, текущие utun*, соединения к SERVER_IP:443,
# приватные сети (LAN). Требует sudo (pfctl). Аварийно выключить всё: sudo pfctl -d
#
# ВНИМАНИЕ: в сетях с captive-portal (отель/кафе с веб-логином) под kill-switch
# страница логина не откроется — временно `killswitch off`, залогиниться, снова `on`.

set -euo pipefail

CFG="/etc/sing-box/config.json"
PF_CONF="/etc/sing-box/killswitch.pf.conf"
MARKER="/etc/sing-box/killswitch.enabled"
ANCHOR="singbox_killswitch"
RU_CIDR="/etc/sing-box/ru-cidrs.txt"
RU_URLS=(
  "https://www.ipdeny.com/ipblocks/data/aggregated/ru-aggregated.zone"
  "https://raw.githubusercontent.com/ipverse/rir-ip/master/country/ru/ipv4-aggregated.txt"
)

# Под root (запуск из демона) sudo не нужен
SUDO=""; [[ "$(id -u)" -ne 0 ]] && SUDO="sudo"

SDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
busy() { bash "$SDIR/vpn-busy.sh" "$1" 2>/dev/null || true; }
trap 'busy end' EXIT  # никогда не оставлять залипший спиннер в меню

# Список российских IP-диапазонов (чтобы RU-сайты работали напрямую при kill-switch).
# Обновляем не чаще раза в неделю. Устойчиво к ошибкам: если не скачался — не падаем,
# RU просто пойдёт как раньше. НЕ должно ломать сам kill-switch.
ensure_ru_list() {
  local age=999999
  [[ -f "$RU_CIDR" ]] && age=$(( $(date +%s) - $(stat -f %m "$RU_CIDR" 2>/dev/null || echo 0) ))
  if [[ -s "$RU_CIDR" && "$age" -le 604800 ]]; then return 0; fi
  local u data=""
  for u in "${RU_URLS[@]}"; do
    data="$(curl -fsSL --max-time 25 "$u" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/' || true)"
    [[ -n "$data" ]] && break
  done
  [[ -n "$data" ]] && printf '%s\n' "$data" | $SUDO tee "$RU_CIDR" >/dev/null 2>&1 || true
  return 0
}

server_ip() {
  # IP сервера (vless): берём ТОЛЬКО значения "server", похожие на IPv4,
  # исключая DoH (1.1.1.1) и loopback. NB: НЕ хватать "server":"dns-local" из DNS.
  grep -oE '"server": *"[0-9]{1,3}(\.[0-9]{1,3}){3}"' "$CFG" 2>/dev/null \
    | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}' \
    | grep -Ev '^(1\.1\.1\.1|8\.8\.8\.8|127\.|0\.)' \
    | head -1
}

utun_list() {
  ifconfig -l 2>/dev/null | tr ' ' '\n' | grep -E '^utun[0-9]+$'
}

build_conf() {
  local ip; ip="$(server_ip)"
  if [[ -z "$ip" ]]; then
    echo "[!] Не нашёл IP сервера в $CFG — сначала установи клиент (install-macos-daemon.sh)."; exit 1
  fi
  ensure_ru_list
  local ru_table="" ru_pass=""
  if [[ -s "$RU_CIDR" ]]; then
    ru_table="table <ru> persist file \"$RU_CIDR\""
    ru_pass="pass out quick to <ru>"
  fi

  {
    echo "# Авто-сгенерировано killswitch.sh — не редактировать вручную."
    # В pf порядок: таблицы → опции → правила.
    [[ -n "$ru_table" ]] && echo "$ru_table"
    echo "set block-policy drop"
    echo "set skip on lo0"
    echo "block drop out all"
    echo "block drop out inet6 all"
    # Туннельные интерфейсы utun0..15: пропускаем В ОБЕ СТОРОНЫ (без 'out').
    # Важно: расшифрованные ОТВЕТЫ sing-box пишет обратно в utun как 'in on utun';
    # при 'pass out ...' они блокировались → приложения не получали ответ.
    for n in $(seq 0 15); do
      echo "pass quick on utun${n} all"
    done
    # переподключение к серверу
    echo "pass out quick proto tcp to $ip port 443"
    echo "pass out quick proto udp to $ip port 443"
    # Российские IP — напрямую (RU-сайты работают при kill-switch; родной IP).
    [[ -n "$ru_pass" ]] && echo "$ru_pass"
    # Локальные сети (LAN/принтеры/роутер). DNS НАРУЖУ не пропускаем (всё через DoH в туннеле).
    echo "pass out quick to { 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 169.254.0.0/16 224.0.0.0/4 }"
    # DHCP
    echo "pass out quick proto udp from any port 68 to any port 67"
  } | $SUDO tee "$PF_CONF" >/dev/null
}

load_pf() {
  # -e -f (enable + load) надёжнее на macOS, чем -E -f; -E -f как запасной вариант
  $SUDO pfctl -e -f "$PF_CONF" >/dev/null 2>&1 || $SUDO pfctl -E -f "$PF_CONF" >/dev/null 2>&1 || true
}

case "${1:-status}" in
  on|reapply)
    [[ "$1" == "on" ]] && busy begin
    build_conf
    load_pf
    $SUDO touch "$MARKER"
    [[ "$1" == "on" ]] && { busy end; echo "🛡  Kill-switch включён (наружу — только туннель и переподключение к серверу)."; }
    ;;
  off)
    busy begin
    $SUDO pfctl -d >/dev/null 2>&1 || true
    $SUDO rm -f "$MARKER"
    busy end
    echo "Kill-switch выключен — прямой интернет без блокировки."
    ;;
  status)
    if [[ -f "$MARKER" ]]; then
      echo "Kill-switch: включён"
    else
      echo "Kill-switch: выключен"
    fi
    ;;
  *)
    echo "Использование: killswitch.sh on|off|status|reapply"; exit 1
    ;;
esac
