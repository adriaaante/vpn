#!/usr/bin/env bash
#
# change-server-ip.sh — прописывает НОВЫЙ IPv4 на сервере после смены адреса
# у хостера (EDIS: дополнение "IP Change" — старый IP умирает сразу, новый надо
# внести в ОС руками через VNC).
#
# ВАЖНО: скачать скрипт на сервер НАДО ЗАРАНЕЕ, до смены IP — после неё сети нет.
#   cd /root/vpn && git fetch origin && git checkout $(git branch -r|grep -m1 claude) -- scripts
#
# Запуск в консоли VNC:
#   bash scripts/change-server-ip.sh 203.0.113.7            # шлюз = x.y.z.1
#   bash scripts/change-server-ip.sh 203.0.113.7 203.0.113.254   # шлюз явно
#
# Ключи Reality не трогаются: клиенту достаточно `scripts/set-server-ip.sh <новый-IP>`.

set -uo pipefail
NP=/etc/netplan/50-cloud-init.yaml
NEW="${1:-}"
GW="${2:-}"

[[ -n "$NEW" ]] || { echo "Использование: bash scripts/change-server-ip.sh <новый-IP> [шлюз]"; exit 2; }
[[ "$NEW" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || { echo "Это не похоже на IPv4: $NEW"; exit 2; }
[[ -f "$NP" ]] || { echo "Нет $NP — сеть настроена иначе, останови и позови за помощью."; exit 1; }
# По умолчанию шлюз — первый адрес подсети нового IP (у EDIS это так).
[[ -n "$GW" ]] || GW="${NEW%.*}.1"

OLD=$(grep -oE '"[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]+"' "$NP" | head -1 | tr -d '"')
OLDIP="${OLD%%/*}"
OLDGW=$(grep -A1 'to: "default"' "$NP" | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}' | head -1)
echo "[*] Было: адрес $OLDIP, шлюз $OLDGW"
echo "[*] Станет: адрес $NEW, шлюз $GW"

BAK="/root/netplan-$(date +%s).yaml.bak"
cp "$NP" "$BAK" && echo "[*] Бэкап: $BAK"

sed -i "s|$OLDIP|$NEW|g; s|\"$OLDGW\"|\"$GW\"|g" "$NP"
grep -E 'addresses:|via:|"' "$NP" | sed 's/^/    /'

echo "[*] Применяю (если через 120 с не подтвердить — netplan откатится сам)..."
netplan apply
sleep 3
echo "[*] Адреса сейчас:"; ip -br a | sed 's/^/    /'

if ping -c2 -W3 1.1.1.1 >/dev/null 2>&1; then
  echo "[*] Интернет есть ✅"
else
  echo "[!] Пинг не идёт. Проверь шлюз: если он не $GW, запусти скрипт ещё раз с явным шлюзом."
  echo "    Откат: cp $BAK $NP && netplan apply"
  exit 1
fi

# cloud-init при перезагрузке пересобирает netplan из данных хостера и может
# вернуть старый адрес — тогда сервер пропадёт из сети до следующего VNC.
CC=/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
if [[ ! -f "$CC" ]]; then
  mkdir -p /etc/cloud/cloud.cfg.d
  echo 'network: {config: disabled}' > "$CC"
  echo "[*] cloud-init больше не перепишет сеть при перезагрузке."
fi

systemctl restart sing-box
sleep 2
echo "[*] sing-box: $(systemctl is-active sing-box)"
echo "[*] Слушает:"; ss -tlnp 2>/dev/null | awk '/sing-box/ {print "    "$4}' | sort -u

echo
echo "[OK] Сервер на новом адресе. Дальше на маке (ключи прежние, менять их не надо):"
echo "  cd ~/vpn && bash scripts/set-server-ip.sh $NEW"
echo "Для айфона: bash scripts/make-ios-configs-server.sh"
