#!/usr/bin/env bash
#
# install-all.sh — установка всего одной командой на macOS:
#   sing-box демон (автозапуск) + sudoers без пароля + строка меню +
#   watcher (failover/health) + авто-режим по сети + алиас `vpn`.
#
# Запуск:
#   bash scripts/install-all.sh
#
# Понадобятся значения с сервера (их печатает setup-singbox-latvia.sh).

set -euo pipefail

[[ "$(uname -s)" == "Darwin" ]] || { echo "Только для macOS."; exit 1; }

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
USER_NAME="$(id -un)"

echo "════════════════════════════════════════════"
echo "  Установка VPN-туннеля (всё сразу)"
echo "════════════════════════════════════════════"

# 1. Демон sing-box (интерактивно спросит значения с сервера)
echo; echo "▶ Шаг 1/6: демон sing-box"
bash "$DIR/scripts/install-macos-daemon.sh"

# 2. sudoers без пароля — чтобы кнопки в меню работали бесшумно
echo; echo "▶ Шаг 2/6: sudoers (переключения без пароля)"
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

# 3. Строка меню (SwiftBar)
echo; echo "▶ Шаг 3/6: строка меню (SwiftBar)"
bash "$DIR/scripts/install-menubar.sh"

# 4. Watcher (failover-уведомления + health-check)
echo; echo "▶ Шаг 4/6: watcher (failover + health)"
bash "$DIR/scripts/install-watcher.sh"

# 5. Авто-режим по сети
echo; echo "▶ Шаг 5/6: авто-режим по сети"
bash "$DIR/scripts/install-autonet.sh"

# 6. Алиас `vpn` + опциональный kill-switch
echo; echo "▶ Шаг 6/6: финальные штрихи"
SHELL_RC="$HOME/.zshrc"
if ! grep -q 'alias vpn=' "$SHELL_RC" 2>/dev/null; then
  echo "alias vpn=\"bash $DIR/scripts/vpn.sh\"" >> "$SHELL_RC"
  echo "  ✓ Добавлен алиас vpn в $SHELL_RC (перезапусти терминал)"
fi

printf "  Включить kill-switch (защита от утечки IP) сейчас? [y/N] "
read -r ans
if [[ "$ans" =~ ^[Yy]$ ]]; then
  bash "$DIR/scripts/killswitch.sh" on
fi

echo
echo "════════════════════════════════════════════"
echo "  Готово! Текущее состояние:"
echo "════════════════════════════════════════════"
bash "$DIR/scripts/vpn.sh" status || true
echo
echo "Команды: vpn on|off|status|mode|proto|killswitch|net  (или иконка в строке меню)"
echo "Домашнюю сеть для авто-режима добавь: vpn net whoami → впиши в ~/.config/vpn/netmap"
