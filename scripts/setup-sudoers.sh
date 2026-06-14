#!/usr/bin/env bash
#
# setup-sudoers.sh — настраивает/обновляет правила sudo без пароля для управления
# туннелем и kill-switch из меню (включая чтение состояния pf для индикации).
# Безопасно запускать повторно.

set -euo pipefail
[[ "$(uname -s)" == "Darwin" ]] || { echo "Только для macOS."; exit 1; }

U="$(id -un)"
TMP="$(mktemp)"
cat > "$TMP" <<EOF
$U ALL=(root) NOPASSWD: /bin/launchctl bootstrap system /Library/LaunchDaemons/com.user.singbox.plist, \\
  /bin/launchctl bootout system /Library/LaunchDaemons/com.user.singbox.plist, \\
  /bin/launchctl kickstart *com.user.singbox, /bin/launchctl kickstart -k system/com.user.singbox, \\
  /bin/launchctl enable system/com.user.singbox, /bin/launchctl print system/com.user.singbox, \\
  /bin/cp /etc/sing-box/config-full.json /etc/sing-box/config.json, \\
  /bin/cp /etc/sing-box/config-selective.json /etc/sing-box/config.json, \\
  /usr/bin/tee /etc/sing-box/killswitch.pf.conf, \\
  /sbin/pfctl -E -f /etc/sing-box/killswitch.pf.conf, \\
  /sbin/pfctl -e -f /etc/sing-box/killswitch.pf.conf, \\
  /sbin/pfctl -d, \\
  /sbin/pfctl -s info, /sbin/pfctl -s rules, \\
  /usr/bin/touch /etc/sing-box/killswitch.enabled, \\
  /bin/rm -f /etc/sing-box/killswitch.enabled
EOF

if sudo visudo -cf "$TMP" >/dev/null 2>&1; then
  sudo cp "$TMP" /etc/sudoers.d/singbox
  sudo chmod 440 /etc/sudoers.d/singbox
  echo "[OK] /etc/sudoers.d/singbox обновлён (управление и проверка kill-switch без пароля)."
else
  echo "[!] Проверка sudoers не прошла — файл не изменён."
fi
rm -f "$TMP"
