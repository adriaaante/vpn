# scripts/assets — вендоренные библиотеки

- **qrcode.min.js** — qrcode-generator (Kazuhiko Arase), рисует QR прямо в
  браузере. Используется памяткой гостя (`vpn-panel.py` → `guide_html`): QR
  запасных узлов Shadowrocket строятся по нажатию на устройстве гостя, а не
  сервером — иначе 6 серверных SVG раздували файл до мегабайтов и замедляли
  расшифровку под ПИНом. Лицензия: MIT. Источник:
  https://github.com/kazuhikoarase/qrcode-generator
