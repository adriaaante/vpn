#!/usr/bin/env bash
#
# vpn-autonet.sh — авто-выбор режима маршрутизации по текущей сети.
# Дома (доверенная сеть) → «весь трафик» (full); чужие сети → «только сервисы».
#
#   vpn-autonet.sh           определить сеть и выставить режим по карте
#   vpn-autonet.sh whoami    показать идентификатор текущей сети (для карты)
#
# Карта сетей: ~/.config/vpn/netmap  (см. configs/netmap.example). Формат:
#   <SSID или MAC-шлюза>   full|selective
#   default                selective
#
# Идентификация по MAC шлюза по умолчанию (надёжнее SSID, который свежие macOS
# скрывают) + по SSID, если доступен. Режим меняется только если отличается.

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NETMAP="${VPN_NETMAP:-$HOME/.config/vpn/netmap}"
CFG="/etc/sing-box/config.json"

lc() { tr 'A-Z' 'a-z'; }

gw_ip() { route -n get default 2>/dev/null | awk '/gateway:/{print $2; exit}'; }

gw_mac() {
  local gw; gw="$(gw_ip)"
  [[ -z "$gw" ]] && return 0
  ping -c1 -t1 "$gw" >/dev/null 2>&1 || true
  arp -n "$gw" 2>/dev/null | awk '{print $4}' | grep -E '^([0-9a-fA-F]{1,2}:){5}[0-9a-fA-F]{1,2}$' | head -1 | lc
}

ssid() {
  local s
  s="$(ipconfig getsummary en0 2>/dev/null | awk -F': ' '/ SSID :/{print $2; exit}')"
  [[ -z "$s" ]] && s="$(networksetup -getairportnetwork en0 2>/dev/null | sed -n 's/^Current Wi-Fi Network: //p')"
  printf '%s' "$s"
}

current_mode() {
  if grep -q '"final": "direct"' "$CFG" 2>/dev/null; then echo "selective"; else echo "full"; fi
}

if [[ "${1:-}" == "whoami" ]]; then
  echo "SSID:        $(ssid)"
  echo "Gateway IP:  $(gw_ip)"
  echo "Gateway MAC: $(gw_mac)"
  echo
  echo "Добавь нужный идентификатор в $NETMAP, например:"
  echo "  $(gw_mac)   full"
  exit 0
fi

[[ -f "$NETMAP" ]] || { echo "Нет карты сетей $NETMAP (скопируй configs/netmap.example)."; exit 0; }

cur_ssid="$(ssid | lc)"
cur_mac="$(gw_mac)"
want=""; defmode="selective"

while read -r key val _; do
  case "$key" in ''|\#*) continue;; esac
  if [[ "$key" == "default" ]]; then defmode="$val"; continue; fi
  klc="$(printf '%s' "$key" | lc)"
  if [[ -n "$cur_ssid" && "$klc" == "$cur_ssid" ]] || [[ -n "$cur_mac" && "$klc" == "$cur_mac" ]]; then
    want="$val"; break
  fi
done < "$NETMAP"

want="${want:-$defmode}"
cur="$(current_mode)"

if [[ "$want" != "$cur" ]]; then
  echo "[autonet] сеть → режим $want (было $cur)"
  bash "$DIR/scripts/vpn-mode.sh" "$want" >/dev/null 2>&1 || true
else
  echo "[autonet] режим уже $cur — без изменений"
fi
