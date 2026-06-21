#!/usr/bin/env bash
#
# setup-singbox-latvia.sh
# Провижининг VPS в Латвии: ставит sing-box и поднимает точку входа:
#   - VLESS + Vision + Reality (TCP/443)  -> скрытный канал
# Генерирует все секреты, открывает порт, печатает значения для клиента.
#
# Запуск (на чистом Debian/Ubuntu VPS, под root):
#   bash scripts/setup-singbox-latvia.sh
#
# Идемпотентный: повторный запуск пересоберёт конфиг и перезапустит сервис.
# Все секреты сохраняются в /etc/sing-box/credentials.txt (не коммитить!).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
TEMPLATE="$REPO_DIR/configs/singbox-server.template.json"
SB_DIR="/etc/sing-box"
CONFIG="$SB_DIR/config.json"
CRED="$SB_DIR/credentials.txt"

# --- SNI для Reality: крупный, реально доступный сайт (можно сменить) ---
REALITY_SNI="${REALITY_SNI:-www.microsoft.com}"

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "Запусти под root (sudo)." >&2; exit 1
  fi
}

install_singbox() {
  if command -v sing-box >/dev/null 2>&1; then
    echo "[*] sing-box уже установлен: $(sing-box version | head -n1)"
    return
  fi
  echo "[*] Устанавливаю sing-box из официальных релизов GitHub..."
  local arch tag ver tmp
  case "$(uname -m)" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) echo "Неизвестная архитектура $(uname -m)"; exit 1 ;;
  esac
  tmp="$(mktemp -d)"
  # NB: качаем в файл, затем грепаем файл. НЕ `curl | grep -m1` — под
  # `set -o pipefail` grep рано закрывает пайп → curl: (23) → падение скрипта.
  curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest -o "$tmp/rel.json"
  tag="$(grep -m1 '"tag_name"' "$tmp/rel.json" | cut -d'"' -f4)"
  ver="${tag#v}"
  curl -fsSL "https://github.com/SagerNet/sing-box/releases/download/${tag}/sing-box-${ver}-linux-${arch}.tar.gz" \
    -o "$tmp/sb.tar.gz"
  tar -xzf "$tmp/sb.tar.gz" -C "$tmp"
  install -m 0755 "$tmp/sing-box-${ver}-linux-${arch}/sing-box" /usr/local/bin/sing-box
  rm -rf "$tmp"
  echo "[*] Установлено: $(sing-box version | head -n1)"
}

gen_secrets() {
  mkdir -p "$SB_DIR"
  echo "[*] Генерирую ключи и секреты..."
  local kp
  kp="$(sing-box generate reality-keypair)"
  REALITY_PRIVATE_KEY="$(echo "$kp" | awk '/PrivateKey/{print $2}')"
  REALITY_PUBLIC_KEY="$(echo "$kp" | awk '/PublicKey/{print $2}')"
  VLESS_UUID="$(sing-box generate uuid)"
  REALITY_SHORT_ID="$(sing-box generate rand --hex 8)"
}

render_config() {
  echo "[*] Собираю $CONFIG из шаблона..."
  sed \
    -e "s|__VLESS_UUID__|$VLESS_UUID|g" \
    -e "s|__REALITY_SNI__|$REALITY_SNI|g" \
    -e "s|__REALITY_PRIVATE_KEY__|$REALITY_PRIVATE_KEY|g" \
    -e "s|__REALITY_SHORT_ID__|$REALITY_SHORT_ID|g" \
    "$TEMPLATE" > "$CONFIG"
  sing-box check -c "$CONFIG"
  echo "[*] Конфиг валиден."
}

setup_service() {
  echo "[*] Создаю systemd-сервис..."
  cat > /etc/systemd/system/sing-box.service <<'UNIT'
[Unit]
Description=sing-box service
After=network.target nss-lookup.target

[Service]
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=5s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable sing-box >/dev/null 2>&1 || true
  systemctl restart sing-box
}

open_firewall() {
  if command -v ufw >/dev/null 2>&1; then
    echo "[*] Открываю 443/tcp в ufw..."
    ufw allow 443/tcp >/dev/null 2>&1 || true
  else
    echo "[!] ufw не найден — открой 443/tcp в фаерволе провайдера вручную."
  fi
}

print_client_values() {
  local ip
  ip="$(curl -fsSL https://api.ipify.org || echo "ВАШ_IP")"
  {
    echo "=== Значения для клиентского конфига (configs/singbox-client.template.json) ==="
    echo "SERVER_IP            = $ip"
    echo "VLESS_UUID           = $VLESS_UUID"
    echo "REALITY_SNI          = $REALITY_SNI"
    echo "REALITY_PUBLIC_KEY   = $REALITY_PUBLIC_KEY"
    echo "REALITY_SHORT_ID     = $REALITY_SHORT_ID"
    echo
    echo "VLESS share-link (для импорта в Hiddify/v2rayN, если нужно вручную):"
    echo "vless://$VLESS_UUID@$ip:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$REALITY_SNI&fp=chrome&pbk=$REALITY_PUBLIC_KEY&sid=$REALITY_SHORT_ID&type=tcp#latvia-reality"
  } | tee "$CRED"
  chmod 600 "$CRED"
  echo
  echo "[*] Эти значения также сохранены в $CRED (никому не показывать, не коммитить)."
}

main() {
  require_root
  install_singbox
  gen_secrets
  render_config
  setup_service
  open_firewall
  sleep 1
  systemctl --no-pager --full status sing-box | head -n 5 || true
  echo
  print_client_values
  echo
  echo "[OK] Сервер готов. Дальше настрой Mac: docs/macos-client-setup.md"
}

main "$@"
