# DEPLOYMENT — карта «где что лежит»

Памятка по реальному развёртыванию: что где находится на сервере и на Mac, какими
командами проверять. Значения-секреты тут НЕ хранятся (только плейсхолдеры).

## Сервер (VPS, Латвия/ЕС, Debian 13)
- бинарь sing-box: `/usr/local/bin/sing-box`
- конфиг: `/etc/sing-box/config.json` (VLESS+Reality TCP/443 + Hysteria2 UDP/443)
- сертификат Hysteria2: `/etc/sing-box/cert.pem`, `/etc/sing-box/key.pem`
- **секреты/значения для клиента**: `/etc/sing-box/credentials.txt` (НЕ коммитить)
- автозапуск: `/etc/systemd/system/sing-box.service`
- репозиторий: `/root/vpn`
- проверка: `systemctl status sing-box`, логи `journalctl -u sing-box -n 50`

Установка сервера (на чистом VPS под root):
```bash
apt-get update && apt-get install -y git
git clone -b <branch> https://github.com/<owner>/vpn && cd vpn
bash scripts/setup-singbox-latvia.sh
```
Скрипт печатает 6 значений для клиента (SERVER_IP, VLESS_UUID, REALITY_SNI,
REALITY_PUBLIC_KEY, REALITY_SHORT_ID, HYSTERIA2_PASSWORD).

## Mac (Apple Silicon)
- репозиторий: `~/vpn`
- sing-box: `/opt/homebrew/bin/sing-box` (через Homebrew)
- конфиг с секретами: `~/vpn/configs/singbox-client.local.json` (gitignored)
- развёрнутые конфиги: `/etc/sing-box/config.json` (+ `config-full.json`, `config-selective.json`)
- обёртка демона (поднимает kill-switch): `/etc/sing-box/daemon-run.sh`
- демон автозапуска: `/Library/LaunchDaemons/com.user.singbox.plist`
- логи: `/var/log/sing-box.err.log`, `/var/log/sing-box.out.log`
- управление: алиас `vpn ...` (см. `scripts/vpn.sh`) + плагин в строке меню

Установка клиента (Mac):
```bash
# Homebrew (если нет): https://brew.sh
git clone -b <branch> https://github.com/<owner>/vpn ~/vpn
cd ~/vpn
bash scripts/install-macos-daemon.sh   # ставит туннель, спросит 6 значений
bash scripts/install-extras.sh         # тулбар + watcher + alias
```

## Быстрая диагностика
```bash
curl -s https://ipinfo.io/country      # ожидаем LV (или страну сервера)
vpn status                             # полная диагностика
tail -n 40 /var/log/sing-box.err.log   # логи клиента (Mac)
```

## Где что в репозитории
- `scripts/` — установка и управление (`setup-singbox-latvia.sh`,
  `install-macos-daemon.sh`, `install-extras.sh`, `vpn.sh`, `vpn-mode.sh`,
  `vpn-proto.sh`, `killswitch.sh`, `vpn-watch.sh`, ...).
- `configs/` — шаблоны конфигов sing-box (сервер/клиент).
- `launchd/` — plist'ы демона/агентов.
- `menubar/` — плагин SwiftBar.
- `docs/` — инструкции и `LEARNINGS.md` (грабли и уроки).
