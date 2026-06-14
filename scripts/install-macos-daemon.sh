#!/usr/bin/env bash
#
# install-macos-daemon.sh
# Ставит sing-box на macOS и поднимает его КАК СИСТЕМНЫЙ ДЕМОН (launchd):
# туннель включается сам при загрузке Mac и переживает сон. Ничего нажимать
# вручную больше не нужно.
#
# Запуск:
#   bash scripts/install-macos-daemon.sh
#
# Скрипт либо возьмёт готовый configs/singbox-client.local.json,
# либо интерактивно спросит значения (их печатает серверный скрипт) и соберёт его.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
TEMPLATE="$REPO_DIR/configs/singbox-client.template.json"
LOCAL_CFG="$REPO_DIR/configs/singbox-client.local.json"
PLIST_TEMPLATE="$REPO_DIR/launchd/com.user.singbox.plist"

DEST_CFG="/etc/sing-box/config.json"
DEST_PLIST="/Library/LaunchDaemons/com.user.singbox.plist"
LABEL="com.user.singbox"

need_macos() {
  [[ "$(uname -s)" == "Darwin" ]] || { echo "Этот скрипт только для macOS."; exit 1; }
}

install_singbox() {
  if ! command -v brew >/dev/null 2>&1; then
    echo "[!] Homebrew не найден. Установи его: https://brew.sh , затем перезапусти скрипт."
    exit 1
  fi
  if ! command -v sing-box >/dev/null 2>&1; then
    echo "[*] Устанавливаю sing-box через Homebrew..."
    brew install sing-box
  fi
  SINGBOX_BIN="$(command -v sing-box)"
  echo "[*] sing-box: $SINGBOX_BIN ($(sing-box version | head -n1))"
}

build_local_cfg() {
  if [[ -f "$LOCAL_CFG" ]]; then
    echo "[*] Использую существующий $LOCAL_CFG"
    return
  fi
  echo "[*] Введи значения, которые напечатал серверный скрипт (setup-singbox-latvia.sh):"
  read -rp "  SERVER_IP          : " SERVER_IP
  read -rp "  VLESS_UUID         : " VLESS_UUID
  read -rp "  REALITY_SNI        : " REALITY_SNI
  read -rp "  REALITY_PUBLIC_KEY : " REALITY_PUBLIC_KEY
  read -rp "  REALITY_SHORT_ID   : " REALITY_SHORT_ID
  # Локальный секрет для Clash API (нужен переключателю протоколов в меню)
  CLASH_SECRET="$(openssl rand -hex 16)"
  sed \
    -e "s|__SERVER_IP__|$SERVER_IP|g" \
    -e "s|__VLESS_UUID__|$VLESS_UUID|g" \
    -e "s|__REALITY_SNI__|$REALITY_SNI|g" \
    -e "s|__REALITY_PUBLIC_KEY__|$REALITY_PUBLIC_KEY|g" \
    -e "s|__REALITY_SHORT_ID__|$REALITY_SHORT_ID|g" \
    -e "s|__CLASH_SECRET__|$CLASH_SECRET|g" \
    "$TEMPLATE" > "$LOCAL_CFG"
  echo "[*] Создан $LOCAL_CFG"
}

validate_cfg() {
  if grep -q '__[A-Z_]*__' "$LOCAL_CFG"; then
    echo "[!] В $LOCAL_CFG остались незаполненные плейсхолдеры __...__ — заполни их."
    grep -o '__[A-Z_]*__' "$LOCAL_CFG" | sort -u
    exit 1
  fi
  sing-box check -c "$LOCAL_CFG"
  echo "[*] Конфиг валиден."
}

install_daemon() {
  echo "[*] Устанавливаю конфиги и демон (нужен sudo)..."
  sudo mkdir -p /etc/sing-box

  # Два готовых режима маршрутизации (разница — поле route.final):
  #   full      = весь трафик через Латвию (final: proxy)
  #   selective = только сервисы через Латвию (final: direct)
  sudo cp "$LOCAL_CFG" /etc/sing-box/config-full.json
  sed 's/"final": "proxy"/"final": "direct"/' "$LOCAL_CFG" \
    | sudo tee /etc/sing-box/config-selective.json >/dev/null

  # По умолчанию активен полный туннель
  sudo cp /etc/sing-box/config-full.json "$DEST_CFG"
  sudo chmod 644 /etc/sing-box/config-full.json /etc/sing-box/config-selective.json "$DEST_CFG"

  # Самодостаточная копия killswitch + обёртка демона в /etc/sing-box
  # (чтобы kill-switch поднимался при загрузке независимо от расположения репозитория)
  sudo cp "$REPO_DIR/scripts/killswitch.sh" /etc/sing-box/killswitch.sh
  sudo chmod 755 /etc/sing-box/killswitch.sh
  sudo tee /etc/sing-box/daemon-run.sh >/dev/null <<RUN
#!/bin/bash
# Обёртка демона: при включённом kill-switch поднимает защиту, затем sing-box.
CFG="/etc/sing-box/config.json"
if [ -f /etc/sing-box/killswitch.enabled ]; then
  /bin/bash /etc/sing-box/killswitch.sh reapply >/dev/null 2>&1 || true
  # дотягиваем utun после старта sing-box (несколько повторов)
  ( for _ in 1 2 3 4 5 6; do sleep 5; [ -f /etc/sing-box/killswitch.enabled ] && /bin/bash /etc/sing-box/killswitch.sh reapply >/dev/null 2>&1 || true; done ) &
fi
exec "$SINGBOX_BIN" run -c "\$CFG"
RUN
  sudo chmod 755 /etc/sing-box/daemon-run.sh

  # Рендерим plist на обёртку демона
  local tmp_plist
  tmp_plist="$(mktemp)"
  sed \
    -e "s|__DAEMON_RUN__|/etc/sing-box/daemon-run.sh|g" \
    "$PLIST_TEMPLATE" > "$tmp_plist"

  sudo cp "$tmp_plist" "$DEST_PLIST"
  rm -f "$tmp_plist"
  sudo chown root:wheel "$DEST_PLIST"
  sudo chmod 644 "$DEST_PLIST"

  # (Пере)загружаем демон
  sudo launchctl bootout system "$DEST_PLIST" 2>/dev/null || true
  sudo launchctl bootstrap system "$DEST_PLIST"
  sudo launchctl enable "system/$LABEL" 2>/dev/null || true
  echo "[*] Демон загружен."
}

main() {
  need_macos
  install_singbox
  build_local_cfg
  validate_cfg
  install_daemon
  echo
  echo "[OK] Готово. Туннель будет подниматься автоматически при каждом включении Mac."
  echo
  echo "Проверка:"
  echo "  1) sudo launchctl print system/$LABEL | grep state   # должно быть running"
  echo "  2) Открой https://ipinfo.io — должен быть латвийский IP"
  echo "  3) Открой https://dnsleaktest.com — должен быть виден только наш DoH-резолвер"
  echo "  4) Логи: tail -f /var/log/sing-box.err.log"
  echo
  echo "Снять демон (если нужно): sudo launchctl bootout system $DEST_PLIST"
  echo
  echo "Режим маршрутизации (по умолчанию — весь трафик):"
  echo "  bash scripts/vpn-mode.sh selective   # только Claude/ChatGPT/YouTube/Telegram"
  echo "  bash scripts/vpn-mode.sh full        # весь трафик"
}

main "$@"
