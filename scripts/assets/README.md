# scripts/assets — вендоренные библиотеки для страницы подключения

Инлайнятся в `connect.html`, который собирает `scripts/connect-page.sh`. Страница
раздаётся по ОБЫЧНОМУ HTTP с сервера, где недоступен `window.crypto.subtle`
(небезопасный origin), поэтому крипта — чистый JS, без WebCrypto.

- **sjcl.js** — Stanford JavaScript Crypto Library, собран с модулем `gcm`
  (`./configure --with=...,gcm && make`). Расшифровывает в браузере блоб,
  который сервер зашифровал `scripts/lib/aesgcm.py` (AES-256-GCM + PBKDF2-SHA256).
  Лицензия: BSD-2 / GPL-2 (dual). Источник: https://github.com/bitwiseshiftleft/sjcl
- **qrcode.min.js** — qrcode-generator (Kazuhiko Arase), рисует QR из
  расшифрованных vless-ссылок прямо в браузере (ссылки не появляются на сервере
  в открытом виде). Лицензия: MIT. Источник:
  https://github.com/kazuhikoarase/qrcode-generator

Совместимость Python-шифрование ↔ SJCL-расшифровка проверяется
`scripts/lib/aesgcm.py` (self-test по NIST-векторам) и вручную через node.
