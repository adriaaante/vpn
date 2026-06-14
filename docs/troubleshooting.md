# Troubleshooting и устойчивость к волнам блокировок

## Быстрая диагностика

```bash
# демон жив?
sudo launchctl print system/com.user.singbox | grep -i state
# логи клиента
tail -n 100 /var/log/sing-box.err.log
# на сервере
systemctl status sing-box
journalctl -u sing-box -n 100 --no-pager
```

Признак, что туннель не поднялся: <https://ipinfo.io> показывает российский IP
или интернет вообще не работает.

## Интернет пропал полностью
1. Проверь статус демона (выше). Если упал — `sudo launchctl kickstart -k system/com.user.singbox`.
2. Проверь доступность сервера: `nc -vz -w3 <SERVER_IP> 443` (TCP).
3. Если сервер недоступен по 443 — возможно, IP/порт под блокировкой. См. ниже
   «Волна блокировок».
4. Крайний случай — выгрузи демон, чтобы вернуть прямой интернет:
   `sudo launchctl bootout system /Library/LaunchDaemons/com.user.singbox.plist`.

## Волна блокировок (раньше работало — перестало)
Россия периодически «давит» конкретные схемы. Порядок действий по нарастанию:

1. **Ничего не делай 1–3 минуты** — клиент сам переключится между Reality и
   Hysteria2 (`urltest`).
2. **Смени SNI** у Reality (на сервере), если душат именно его маскировку:
   ```bash
   REALITY_SNI=www.icloud.com bash scripts/setup-singbox-latvia.sh
   ```
   затем обнови значение `REALITY_SNI` в `configs/singbox-client.local.json` и
   `bash scripts/install-macos-daemon.sh`.
3. **Смени порт** Hysteria2/Reality (если душат по порту 443 — реже, но бывает):
   поправь `listen_port` в серверном конфиге и `server_port` в клиентском.
4. **Добавь третий протокол — AmneziaWG** (обфусцированный WireGuard) как
   независимый резерв. В sing-box AmneziaWG-обфускация не поддерживается напрямую,
   поэтому его проще держать **отдельным каналом** через приложение
   [AmneziaVPN](https://amnezia.org) на том же VPS и переключаться на него вручную,
   когда обе TLS/QUIC-схемы придавили.
5. **Транспорт XHTTP/gRPC для Reality** — при особо агрессивных волнах против
   VLESS-over-TCP помогает завернуть Reality в XHTTP. Это правка inbound/outbound
   `transport` с обеих сторон (см. документацию sing-box `V2Ray Transport`).

## Максимальная надёжность: второй сервер
Заведи **второй VPS** (другой провайдер/IP, можно соседняя ЕС-страна) и повтори
`setup-singbox-latvia.sh`. Затем в `configs/singbox-client.local.json`:

- добавь ещё два outbound (`vless-reality-2`, `hysteria2-2`) со значениями
  второго сервера;
- впиши их в список `outbounds` у `auto` (`urltest`) и `proxy`.

Теперь падение или блокировка целого сервера тоже переживается автоматически.

## DNS-leak или RU-сайт идёт через туннель / наоборот
- Leak: проверь, что в TUN стоит `"strict_route": true`, а в секции `dns`
  `final` указывает на `dns-remote` (DoH через `proxy`). Перезапусти демон.
- Российский сайт пошёл через Латвию: добавь его домен в оба списка
  `domain_suffix` (в секциях `dns.rules` и `route.rules`) клиентского конфига.
  Для полного списка российских доменов можно подключить готовый rule-set
  Antizapret (см. `savely-krasovsky/antizapret-sing-box`).

## Нет интернета из-за kill-switch
Kill-switch специально блокирует трафик, когда туннель не работает. Если интернет
пропал и его надо срочно вернуть:
```bash
sudo pfctl -d                 # полностью выключить pf (снять блокировку)
bash scripts/killswitch.sh off
```
В сетях с веб-логином (captive-portal) под kill-switch не открыть страницу входа —
выключи kill-switch, залогинься, включи обратно. Если после переподключения
туннеля приложения «не видят» сеть — список `utun` мог устареть, выполни
`bash scripts/killswitch.sh reapply`.

## TUN не поднимается на macOS
- Убедись, что демон работает от root (он в `/Library/LaunchDaemons`).
- На свежих macOS не используй `set_system_proxy` вместе с TUN (в нашем конфиге
  его нет специально).
- Проверь права: первый запуск sing-box может потребовать разрешения сетевого
  расширения в «Системные настройки → Конфиденциальность и безопасность».

## Полезное
- Проверка конфига перед применением: `sing-box check -c configs/singbox-client.local.json`.
- Форматирование конфига: `sing-box format -w -c configs/singbox-client.local.json`.
- Версия: `sing-box version` (нужна **≥ 1.12** из-за нового формата DNS/FakeIP).
