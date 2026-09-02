#!/usr/bin/env bash
#
# install-ip-sync.sh — ставит ip-sync.sh как systemd-таймер (раз в минуту).
# Сервер сам переезжает на новый IPv4, как только A-запись имени сервера
# показывает другой адрес, а старый мёртв. Запускать НА СЕРВЕРЕ:
#   bash scripts/install-ip-sync.sh
# Нужен /etc/sing-box/server-host.txt с именем сервера (он уже есть).

set -euo pipefail
SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ip-sync.sh"
[[ -f "$SCRIPT" ]] || { echo "Нет $SCRIPT"; exit 1; }
[[ -s /etc/sing-box/server-host.txt ]] || { echo "Нет /etc/sing-box/server-host.txt — без имени сервера сверять нечего."; exit 1; }

cat > /etc/systemd/system/ip-sync.service <<UNIT
[Unit]
Description=Follow DNS A-record and reconfigure IPv4 after hoster IP change
After=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash $SCRIPT
UNIT

cat > /etc/systemd/system/ip-sync.timer <<'UNIT'
[Unit]
Description=Run ip-sync every minute

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
Persistent=true

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now ip-sync.timer
echo "[OK] Автопереезд включён (сверка DNS раз в минуту)."
echo "     Статус:  systemctl list-timers | grep ip-sync"
echo "     Логи:    journalctl -u ip-sync -n 20 --no-pager"
echo "     Проверка сейчас (должна промолчать, если DNS = текущий адрес):"
echo "       systemctl start ip-sync.service && journalctl -u ip-sync -n 3 --no-pager"
