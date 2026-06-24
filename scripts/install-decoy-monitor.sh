#!/usr/bin/env bash
#
# install-decoy-monitor.sh — ставит decoy-monitor.sh как systemd-таймер (раз в 15 мин).
# Сервер сам переключает домен-прикрытие, если текущий перестал «одалживаться».
#   bash scripts/install-decoy-monitor.sh

set -euo pipefail
SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/decoy-monitor.sh"
[[ -f "$SCRIPT" ]] || { echo "Нет $SCRIPT"; exit 1; }

cat > /etc/systemd/system/decoy-monitor.service <<UNIT
[Unit]
Description=Reality decoy health monitor (auto-switch SNI)
After=sing-box.service

[Service]
Type=oneshot
ExecStart=/bin/bash $SCRIPT
UNIT

cat > /etc/systemd/system/decoy-monitor.timer <<'UNIT'
[Unit]
Description=Run reality decoy monitor periodically

[Timer]
OnBootSec=5min
OnUnitActiveSec=15min
Persistent=true

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now decoy-monitor.timer
echo "[OK] Монитор установлен (проверка каждые 15 мин)."
echo "     Статус:  systemctl list-timers | grep decoy"
echo "     Логи:    journalctl -u decoy-monitor -n 20 --no-pager"
echo "     Разовый прогон сейчас:  systemctl start decoy-monitor.service && journalctl -u decoy-monitor -n 5 --no-pager"
