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

# Под root (запуск из демона) sudo не нужен
SUDO=""; [[ "$(id -u)" -ne 0 ]] && SUDO="sudo"

SDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
busy() { bash "$SDIR/vpn-busy.sh" "$1" 2>/dev/null || true; }

server_ip() {
  # IP сервера из первого outbound с "server" (vless/hysteria2)
  grep -o '"server": *"[^"]*"' "$CFG" 2>/dev/null \
    | sed 's/.*"\([^"]*\)"/\1/' \
    | grep -Ev '^(1\.1\.1\.1|8\.8\.8\.8|127\.|::1)$' \
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

  {
    echo "# Авто-сгенерировано killswitch.sh — не редактировать вручную."
    echo "set block-policy drop"
    echo "set skip on lo0"
    echo "block drop out all"
    # вход трафика в туннель
    for u in $(utun_list); do
      echo "pass out quick on $u all"
    done
    # переподключение к серверу
    echo "pass out quick proto tcp to $ip port 443"
    echo "pass out quick proto udp to $ip port 443"
    # локальные сети (LAN/принтеры/роутер/DHCP/DNS роутера)
    echo "pass out quick to { 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 169.254.0.0/16 224.0.0.0/4 }"
    # DHCP
    echo "pass out quick proto udp from any port 68 to any port 67"
  } | $SUDO tee "$PF_CONF" >/dev/null
}

load_pf() {
  $SUDO pfctl -E -f "$PF_CONF" >/dev/null 2>&1 || $SUDO pfctl -e -f "$PF_CONF" >/dev/null 2>&1 || true
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
