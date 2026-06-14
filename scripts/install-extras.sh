#!/usr/bin/env bash
#
# install-extras.sh — удобства поверх уже работающего туннеля (НЕ трогает демон/конфиг):
#   - sudoers без пароля (чтобы кнопки в меню работали бесшумно)
#   - строка меню (SwiftBar-плагин)
#   - watcher (уведомления о failover + health-check + актуализация kill-switch)
#   - алиас `vpn`
#
# Запуск (после того как туннель уже поднят install-macos-daemon.sh):
#   bash scripts/install-extras.sh

set -euo pipefail

[[ "$(uname -s)" == "Darwin" ]] || { echo "Только для macOS."; exit 1; }

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
USER_NAME="$(id -un)"

echo "════════════════════════════════════════════"
echo "  Установка удобств (тулбар, watcher)"
echo "════════════════════════════════════════════"

# 1. sudoers без пароля — для бесшумных переключений из меню
echo; echo "▶ sudoers (переключения без пароля)"
SUDOERS_TMP="$(mktemp)"
cat > "$SUDOERS_TMP" <<EOF
$USER_NAME ALL=(root) NOPASSWD: /bin/launchctl bootstrap system /Library/LaunchDaemons/com.user.singbox.plist, \\
  /bin/launchctl bootout system /Library/LaunchDaemons/com.user.singbox.plist, \\
  /bin/launchctl kickstart *com.user.singbox, /bin/launchctl kickstart -k system/com.user.singbox, \\
  /bin/launchctl enable system/com.user.singbox, /bin/launchctl print system/com.user.singbox, \\
  /bin/cp /etc/sing-box/config-full.json /etc/sing-box/config.json, \\
  /bin/cp /etc/sing-box/config-selective.json /etc/sing-box/config.json, \\
  /usr/bin/tee /etc/sing-box/killswitch.pf.conf, \\
  /sbin/pfctl -E -f /etc/sing-box/killswitch.pf.conf, \\
  /sbin/pfctl -e -f /etc/sing-box/killswitch.pf.conf, \\
  /sbin/pfctl -d, \\
  /usr/bin/touch /etc/sing-box/killswitch.enabled, \\
  /bin/rm -f /etc/sing-box/killswitch.enabled
EOF
if sudo visudo -cf "$SUDOERS_TMP" >/dev/null 2>&1; then
  sudo cp "$SUDOERS_TMP" /etc/sudoers.d/singbox
  sudo chmod 440 /etc/sudoers.d/singbox
  echo "  ✓ /etc/sudoers.d/singbox установлен"
else
  echo "  ⚠️ Проверка sudoers не прошла — пропускаю (кнопки будут просить пароль)."
fi
rm -f "$SUDOERS_TMP"

# 2. Строка меню (SwiftBar)
echo; echo "▶ строка меню (SwiftBar)"
bash "$DIR/scripts/install-menubar.sh"

# 3. Watcher (failover-уведомления + health-check)
echo; echo "▶ watcher (failover + health)"
bash "$DIR/scripts/install-watcher.sh"


# 4b. Kill-switch включён по умолчанию (защита от утечки IP; fail-closed)
echo; echo "▶ kill-switch (защита от утечки IP)"
bash "$DIR/scripts/killswitch.sh" on || true
echo "  ℹ️ Включён по умолчанию: если туннель упадёт — интернет блокируется,"
echo "     чтобы реальный IP не утёк. Выключить можно из меню или: vpn killswitch off"

# 5. Алиас `vpn`
echo; echo "▶ алиас vpn"
SHELL_RC="$HOME/.zshrc"
if ! grep -q 'alias vpn=' "$SHELL_RC" 2>/dev/null; then
  echo "alias vpn=\"bash $DIR/scripts/vpn.sh\"" >> "$SHELL_RC"
  echo "  ✓ добавлен алиас vpn в $SHELL_RC (перезапусти терминал)"
else
  echo "  ✓ алиас vpn уже есть"
fi

echo
echo "════════════════════════════════════════════"
echo "  Готово! В строке меню появилась иконка 🟢."
echo "════════════════════════════════════════════"
echo "Управление: vpn on|off|status|mode|proto|killswitch  (или иконка в меню)"
