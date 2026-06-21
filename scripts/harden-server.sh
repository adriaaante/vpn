#!/usr/bin/env bash
#
# harden-server.sh — одноразовый, идемпотентный хардненинг VPS (Debian/Ubuntu).
# НЕ трогает sing-box/туннель и НЕ влияет на маскировку (РКН этого не видит).
# Ставится один раз и дальше обслуживает себя сам:
#   1) SSH: вход только по ключу (пароль/челлендж отключаются) — ТОЛЬКО если у root
#      уже есть рабочий authorized_keys (иначе скрипт откажется, чтобы не залочить).
#   2) fail2ban: демон сам банит переборщиков SSH.
#   3) unattended-upgrades: ОС сама ставит security-патчи Debian/Ubuntu.
#
# СОЗНАТЕЛЬНО НЕ автоматизирует обновление sing-box: у него бывают ломающие
# изменения между версиями — авто-апдейт без присмотра может уронить туннель.
#
# Запуск на VPS под root:
#   bash scripts/harden-server.sh
# Откат SSH-части (если что): rm /etc/ssh/sshd_config.d/99-vpn-hardening.conf && systemctl reload ssh

set -euo pipefail

require_root() { [[ "$(id -u)" -eq 0 ]] || { echo "Запусти под root."; exit 1; }; }

harden_ssh() {
  echo "[*] SSH: проверяю наличие ключей у root перед отключением пароля..."
  local keys="${HOME:-/root}/.ssh/authorized_keys"
  if [[ ! -s "$keys" ]]; then
    echo "[!] У root НЕТ ~/.ssh/authorized_keys (или он пуст)."
    echo "    Чтобы не залочить тебя, пароль НЕ отключаю."
    echo "    Сначала добавь свой публичный ключ:  ssh-copy-id root@<SERVER_IP>"
    echo "    затем запусти скрипт снова. fail2ban и авто-патчи поставлю и сейчас."
    return 0
  fi

  local drop="/etc/ssh/sshd_config.d/99-vpn-hardening.conf"
  install -d -m 755 /etc/ssh/sshd_config.d
  cat > "$drop" <<'CONF'
# Управляется harden-server.sh. Вход только по ключу.
PasswordAuthentication no
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
CONF

  # Проверяем конфиг ДО перезагрузки — кривой sshd_config не применяем.
  if sshd -t 2>/dev/null; then
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
    echo "[*] SSH: пароль отключён, вход по ключу. Текущая сессия не разрывается (reload)."
    echo "    ВАЖНО: не закрывай эту сессию, пока в НОВОМ окне не убедишься, что ключ пускает."
  else
    echo "[!] sshd -t не прошёл — откатываю дроп-ин, ничего не меняю."
    rm -f "$drop"
  fi
}

install_fail2ban() {
  echo "[*] Ставлю fail2ban (сам банит переборщиков SSH)..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y fail2ban >/dev/null
  # Локальный jail для sshd (дефолтных настроек достаточно для личного VPS).
  cat > /etc/fail2ban/jail.d/vpn-sshd.local <<'JAIL'
[sshd]
enabled  = true
maxretry = 5
bantime  = 1h
findtime = 10m
JAIL
  systemctl enable fail2ban >/dev/null 2>&1 || true
  systemctl restart fail2ban
}

enable_auto_security_updates() {
  echo "[*] Включаю авто-установку security-патчей ОС..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y unattended-upgrades >/dev/null
  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'AUTO'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
AUTO
  systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
}

verify() {
  echo
  echo "=== Проверка ==="
  echo "- SSH password auth:"; sshd -T 2>/dev/null | grep -E '^passwordauthentication' || echo "  (sshd -T недоступен)"
  echo "- fail2ban:"; systemctl is-active fail2ban 2>/dev/null | sed 's/^/  /'
  fail2ban-client status sshd 2>/dev/null | sed 's/^/  /' || true
  echo "- unattended-upgrades:"; systemctl is-active unattended-upgrades 2>/dev/null | sed 's/^/  /'
  echo "- sing-box (НЕ трогали):"; systemctl is-active sing-box 2>/dev/null | sed 's/^/  /'
}

main() {
  require_root
  echo "[*] apt-get update..."; apt-get update -qq || true
  install_fail2ban
  enable_auto_security_updates
  harden_ssh
  verify
  echo
  echo "[OK] Готово. Дальше всё обслуживает себя само. Туннель/маскировку не трогали."
  echo "    ПЕРЕД закрытием сессии: открой новое окно и проверь  ssh root@<SERVER_IP>  (по ключу)."
}

main "$@"
