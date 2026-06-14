# Сервер: VPS в Латвии + sing-box (VLESS+Reality и Hysteria2)

## 1. Выбор VPS

Критерии:
- **Локация — Латвия** (Riga). Подойдут провайдеры с латвийскими дата-центрами
  (например, недорогие европейские хостеры с площадкой в Riga). Если конкретно
  Латвии нет — соседняя ЕС-страна (Литва, Эстония, Финляндия, Германия) тоже
  годится для Claude/ChatGPT, но геолокация будет «соседней».
- **ОС**: Debian 12 или Ubuntu 22.04/24.04 (64-bit), root-доступ по SSH.
- **Ресурсы**: 1 vCPU / 1 GB RAM достаточно для личного использования.
- **Сеть**: чистый IPv4 (желательно «не засвеченный»), нелимитированный или
  щедрый трафик.
- **IP-репутация**: свежий/выделенный IP лучше переживает блокировки.

> Совет по надёжности: можно взять **два** VPS у разных провайдеров — позже
> добавишь второй сервер в клиентский `urltest`, и падение одного переживётся
> автоматически (см. `docs/troubleshooting.md`).

## 2. Запуск

На VPS под `root`:

```bash
apt update && apt install -y git curl openssl
git clone <этот-репозиторий> vpn && cd vpn
bash scripts/setup-singbox-latvia.sh
```

Скрипт:
1. ставит `sing-box` из официальных релизов;
2. генерирует ключи Reality, UUID, short-id, пароль Hysteria2 и самоподписанный
   сертификат;
3. собирает `/etc/sing-box/config.json` из `configs/singbox-server.template.json`;
4. поднимает systemd-сервис `sing-box` (автозапуск при перезагрузке сервера);
5. открывает `443/tcp` и `443/udp` (если есть `ufw`);
6. **печатает значения для клиента** и сохраняет их в `/etc/sing-box/credentials.txt`.

### Сменить SNI (по желанию)
Reality маскируется под визит к реальному сайту. По умолчанию `www.microsoft.com`.
Можно задать другой крупный, точно доступный в РФ сайт:
```bash
REALITY_SNI=www.icloud.com bash scripts/setup-singbox-latvia.sh
```
Требования к SNI: сайт должен поддерживать TLS 1.3 + HTTP/2, быть «не подозрительным»
и реально доступным из России (иначе под белыми списками маскировка не сработает).

## 3. Проверка сервера

```bash
systemctl status sing-box          # active (running)
ss -tlnp | grep 443                 # слушается 443/tcp
ss -ulnp | grep 443                 # слушается 443/udp
sing-box check -c /etc/sing-box/config.json   # конфиг валиден
```

Порты в фаерволе провайдера (панель управления VPS) тоже должны быть открыты:
**443 TCP и 443 UDP**.

## 4. Что дальше

Скопируй напечатанные значения (`SERVER_IP`, `VLESS_UUID`, `REALITY_SNI`,
`REALITY_PUBLIC_KEY`, `REALITY_SHORT_ID`, `HYSTERIA2_PASSWORD`) и переходи к
настройке Mac: [`macos-client-setup.md`](macos-client-setup.md).

> ⚠️ `credentials.txt` и сертификаты — секреты. Не коммить их и никому не передавай.
