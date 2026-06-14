# LEARNINGS — грабли и уроки реального развёртывания

Записано по итогам первой боевой установки (сервер EDIS Латвия + MacBook Apple
Silicon). Чтобы будущие сессии знали контекст и не наступали на те же грабли.

## 1. `curl | grep -m1` под `set -o pipefail` валит скрипт
Симптом: `curl: (23) Failure writing output to destination, passed N returned 0`.
Причина: `grep -m1` закрывает пайп после первого совпадения → curl получает broken
pipe → под `pipefail` весь пайплайн возвращает ошибку → `set -e` рвёт скрипт.
Фикс: качать в файл, потом грепать файл (`curl -o f.json ...; grep ... f.json`).
Исправлено в `scripts/setup-singbox-latvia.sh` (`install_singbox`).

## 2. Длинные многострочные вставки в Терминал ломаются
Bracketed paste (`^[[200~`), перенос строк и heredoc рвут вставку больших блоков.
Фикс: использовать `git clone` + запуск скрипта, либо однострочные команды.

## 3. Почта/markdown превращает голые домены в ссылки
`www.microsoft.com` → `[www.microsoft.com](https://www.microsoft.com)` при копировании
через письмо/markdown-рендер → ломает команды и значения.
Фикс: передавать через Telegram «Избранное» (plain text) или печатать руками;
значения вроде SNI задавать явно и проверять.

## 4. VMware Horizon: буфер обмена односторонний
local→remote разрешён, remote→local запрещён политикой компании (DLP).
Обход: переслать текст себе через сервис, открывающийся и локально (почта/Telegram).

## 5. Контекст пользователя: читает инструкции В Horizon, выполняет ЛОКАЛЬНО
Claude локально заблокирован → инструкции читаются в удалённом столе, а команды
выполняются в локальном терминале Mac. Отсюда трудности переноса команд (см. #3, #4).

## 6. EDIS: на сервере нет `ufw`
Скрипт это переживает (ветка else). Порты 443 tcp/udp открыты у провайдера по
умолчанию — отдельно открывать не пришлось.

## 7. sing-box 1.13: обязателен `route.default_domain_resolver`
`sing-box check` падает FATAL: "missing route.default_domain_resolver ... 1.12.0".
Фикс: добавить в `route` клиентского конфига `"default_domain_resolver": "dns-local"`.
NB: именно `dns-local` (а не через прокси) — чтобы не было кольца: urltest резолвит
тестовый URL, а прокси в этот момент ещё тестируется.
Исправлено в `configs/singbox-client.template.json`.

## 8. REALITY_SNI вставился со скобками markdown (следствие #3)
В конфиг попало `[www.microsoft.com](https://...)`. Клиентский SNI ОБЯЗАН совпадать
с серверным (`www.microsoft.com`). Фикс на месте — perl-замена в local-конфиге.

## 9. rule_set `geoip-telegram` → 404 → краш-луп sing-box
Симптом: `FATAL start service: initialize rule-set[1]: geoip-telegram: unexpected
status: 404 Not Found`. У SagerNet/sing-geoip нет `geoip-telegram.srs` → 404 →
sing-box не стартует → TUN не создаётся → трафик идёт напрямую (страна = RU).
Фикс: убрать rule_set `geoip-telegram` и его route-правило. Telegram остаётся по
`domain_suffix` (telegram.org, t.me, ...). В full-режиме app-трафик Telegram идёт
через `final: proxy`.
Исправлено в `configs/singbox-client.template.json`.

## Общий вывод по надёжности шаблонов
Удалённые rule_set'ы — потенциальная точка отказа (404/блокировка/недоступность на
старте). Если добавляем новый rule_set — проверять, что URL реально существует, и
помнить, что любой их сбой = FATAL у sing-box (краш-луп). По возможности —
минимизировать зависимость от внешних rule_set на старте.
