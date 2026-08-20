#!/usr/bin/env python3
"""vpn-panel.py — веб-панель управления доступом. Запускается НА СЕРВЕРЕ:

    python3 scripts/vpn-panel.py

Слушает ТОЛЬКО 127.0.0.1 — снаружи порт не виден вообще. Это принципиально:
публичная панель на этом же IP выдала бы, что здесь VPN, и помогла бы занести
адрес в списки (см. граблю №5c). Доступ с мака — через SSH-туннель,
одной командой `bash scripts/vpn-panel.sh` (она же откроет браузер).

Вся логика правки конфига остаётся в vpn-users.sh: панель только вызывает его,
поэтому бэкап, `sing-box check` и откат работают ровно так же, как из консоли.
"""
import html
import json
import os
import secrets
import shutil
import signal
import subprocess
import urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STORE = os.environ.get("STORE", "/etc/sing-box/users.json")
CFG = os.environ.get("CFG", "/etc/sing-box/config.json")
USERS_SH = os.path.join(REPO, "scripts", "vpn-users.sh")
PORT = int(os.environ.get("PANEL_PORT", "8787"))
TOKEN = os.environ.get("PANEL_TOKEN") or secrets.token_urlsafe(16)

share_proc = {"name": None, "proc": None}


def run(args, timeout=90, no_share=False):
    """Вызов vpn-users.sh; возвращает (код, объединённый вывод)."""
    env = dict(os.environ, STORE=STORE, CFG=CFG)
    if no_share:
        env["NO_SHARE"] = "1"
    try:
        p = subprocess.run(["bash", USERS_SH] + args, capture_output=True,
                           text=True, timeout=timeout, env=env)
        return p.returncode, (p.stdout + p.stderr).strip()
    except subprocess.TimeoutExpired:
        return 1, "Команда не ответила вовремя"


def users():
    try:
        with open(STORE) as f:
            return json.load(f).get("users", [])
    except FileNotFoundError:
        run(["list"])  # первый запуск создаёт реестр из конфига
        try:
            with open(STORE) as f:
                return json.load(f).get("users", [])
        except Exception:
            return []
    except json.JSONDecodeError:
        return []


def server_status():
    def sh(cmd):
        try:
            return subprocess.run(cmd, shell=True, capture_output=True,
                                  text=True, timeout=10).stdout.strip()
        except Exception:
            return ""
    ports = sh("ss -tlnp 2>/dev/null | awk '/sing-box/ {print $4}' | sed 's/.*://' | sort -un | tr '\\n' ' '")
    return {
        "singbox": sh("systemctl is-active sing-box") or "неизвестно",
        "ports": ports or "—",
        "ip": sh("curl -fsSL --max-time 5 https://api.ipify.org") or "—",
        "decoy": sh("python3 -c \"import json;print(json.load(open('%s'))['inbounds'][0]['tls']['server_name'])\"" % CFG) or "—",
    }


def qr_svg(text):
    """QR как SVG — если в системе есть qrencode. Без него просто не показываем."""
    if not shutil.which("qrencode"):
        return ""
    try:
        p = subprocess.run(["qrencode", "-t", "SVG", "-o", "-", text],
                           capture_output=True, timeout=10)
        return p.stdout.decode("utf-8", "replace") if p.returncode == 0 else ""
    except Exception:
        return ""


CSS = """
:root{--bg:#0f1115;--card:#181b22;--line:#262b36;--fg:#e8eaf0;--dim:#98a0b3;
--ok:#3ecf8e;--off:#f0883e;--bad:#ff6b6b;--accent:#5b8dff}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);
font:15px/1.5 -apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif}
.wrap{max-width:900px;margin:0 auto;padding:32px 20px 60px}
h1{font-size:22px;margin:0 0 4px}
.sub{color:var(--dim);font-size:13px;margin-bottom:24px}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;
padding:18px 20px;margin-bottom:18px}
.status{display:flex;flex-wrap:wrap;gap:22px;font-size:13px}
.status b{display:block;color:var(--dim);font-weight:500;margin-bottom:2px}
table{width:100%;border-collapse:collapse}
th{text-align:left;font-size:12px;color:var(--dim);font-weight:500;
padding:0 8px 10px;border-bottom:1px solid var(--line)}
td{padding:12px 8px;border-bottom:1px solid var(--line);vertical-align:middle}
tr:last-child td{border-bottom:0}
.name{font-weight:600}
.note{color:var(--dim);font-size:12px}
.pill{display:inline-block;padding:2px 10px;border-radius:20px;font-size:12px}
.on{background:rgba(62,207,142,.14);color:var(--ok)}
.off{background:rgba(240,136,62,.14);color:var(--off)}
button{font:inherit;border:1px solid var(--line);background:#20242e;color:var(--fg);
padding:7px 13px;border-radius:8px;cursor:pointer}
button:hover{border-color:var(--accent)}
button.danger:hover{border-color:var(--bad);color:var(--bad)}
button.primary{background:var(--accent);border-color:var(--accent);color:#fff}
.row{display:flex;gap:8px;flex-wrap:wrap}
input[type=text]{font:inherit;background:#20242e;border:1px solid var(--line);
color:var(--fg);padding:8px 12px;border-radius:8px;min-width:220px}
.msg{background:#12241c;border:1px solid #235c40;padding:12px 14px;border-radius:10px;
white-space:pre-wrap;font:13px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace;margin-bottom:18px}
.msg.err{background:#2a1618;border-color:#6d2b30}
.link{word-break:break-all;font:13px ui-monospace,SFMono-Regular,Menlo,monospace;
background:#20242e;padding:10px 12px;border-radius:8px;display:block;margin:10px 0}
svg{background:#fff;border-radius:10px;padding:8px;max-width:260px;height:auto}
.hint{color:var(--dim);font-size:12px;margin-top:8px}
"""


def page(msg="", err=False, extra=""):
    st = server_status()
    sb_cls = "on" if st["singbox"] == "active" else "off"
    rows = []
    for u in users():
        on = bool(u.get("enabled"))
        nm = html.escape(u["name"])
        note = html.escape(u.get("note", ""))
        toggle = "disable" if on else "enable"
        toggle_label = "Отключить" if on else "Включить"
        rows.append(f"""<tr>
<td><div class="name">{nm}</div>{f'<div class="note">{note}</div>' if note else ''}</td>
<td><span class="pill {'on' if on else 'off'}">{'включён' if on else 'отключён'}</span></td>
<td><div class="row">
<form method="post" action="/act"><input type="hidden" name="t" value="{TOKEN}">
<input type="hidden" name="op" value="{toggle}"><input type="hidden" name="name" value="{nm}">
<button>{toggle_label}</button></form>
<form method="get" action="/share"><input type="hidden" name="t" value="{TOKEN}">
<input type="hidden" name="name" value="{nm}"><button>Выдать конфиг</button></form>
<form method="post" action="/act" onsubmit="return confirm('Удалить {nm} насовсем?')">
<input type="hidden" name="t" value="{TOKEN}"><input type="hidden" name="op" value="remove">
<input type="hidden" name="name" value="{nm}"><button class="danger">Удалить</button></form>
</div></td></tr>""")

    msg_html = f'<div class="msg{" err" if err else ""}">{html.escape(msg)}</div>' if msg else ""
    return f"""<!doctype html><html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>VPN — доступ</title><style>{CSS}</style></head><body><div class="wrap">
<h1>Доступ к VPN</h1>
<div class="sub">Панель видна только через SSH-туннель. Снаружи порт закрыт.</div>
{msg_html}{extra}
<div class="card"><div class="status">
<div><b>sing-box</b><span class="pill {sb_cls}">{html.escape(st['singbox'])}</span></div>
<div><b>порты</b>{html.escape(st['ports'])}</div>
<div><b>адрес</b>{html.escape(st['ip'])}</div>
<div><b>текущий decoy</b>{html.escape(st['decoy'])}</div>
</div></div>
<div class="card"><table>
<tr><th>Пользователь</th><th>Статус</th><th>Действия</th></tr>
{''.join(rows) or '<tr><td colspan="3" class="note">Пока никого нет</td></tr>'}
</table></div>
<div class="card"><form method="post" action="/act" class="row">
<input type="hidden" name="t" value="{TOKEN}"><input type="hidden" name="op" value="add">
<input type="text" name="name" placeholder="имя латиницей, напр. sasha-tpk" required>
<button class="primary">Добавить человека</button></form>
<div class="hint">Латиница, цифры, дефис. У каждого свой ключ — отключается отдельно.</div>
</div></div></body></html>"""


def share_page(name):
    st = server_status()
    url = f"http://{st['ip']}:8080/full.json"
    svg = qr_svg(url)
    stop = f"""<form method="post" action="/act"><input type="hidden" name="t" value="{TOKEN}">
<input type="hidden" name="op" value="share_stop"><button class="danger">Остановить раздачу</button></form>"""
    qr = svg if svg else '<div class="hint">QR не показан: на сервере нет qrencode (apt install qrencode).</div>'
    return f"""<div class="card"><h1 style="font-size:17px">Конфиг для «{html.escape(name)}»</h1>
<div class="sub">Пусть добавит это как <b>Remote</b>-профиль в sing-box: New Profile → Type: Remote → URL.</div>
<span class="link">{html.escape(url)}</span>{qr}
<div class="hint">Ссылка отдаёт его личный ключ без пароля — останови раздачу сразу после импорта.</div>
<div style="margin-top:12px">{stop}</div></div>"""


def start_share(name):
    """Раздача конфига — отдельным процессом: она держит http-сервер, пока не снимут."""
    stop_share()
    env = dict(os.environ, STORE=STORE, CFG=CFG)
    share_proc["proc"] = subprocess.Popen(
        ["bash", USERS_SH, "share", name], env=env,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    share_proc["name"] = name


def stop_share():
    p = share_proc.get("proc")
    if p and p.poll() is None:
        try:
            os.killpg(os.getpgid(p.pid), signal.SIGTERM)
        except Exception:
            p.terminate()
    share_proc["proc"] = None
    share_proc["name"] = None


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass  # не засоряем консоль обращениями браузера

    def _send(self, body, code=200):
        b = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def _auth(self, params):
        return params.get("t", [""])[0] == TOKEN

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(u.query)
        if not self._auth(q):
            return self._send("<h1>403</h1><p>Открывай панель ссылкой с токеном.</p>", 403)
        if u.path == "/share":
            name = q.get("name", [""])[0]
            start_share(name)
            return self._send(page(extra=share_page(name)))
        return self._send(page())

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        form = urllib.parse.parse_qs(self.rfile.read(n).decode())
        if not self._auth(form):
            return self._send("<h1>403</h1>", 403)
        op = form.get("op", [""])[0]
        name = form.get("name", [""])[0].strip()
        if op == "share_stop":
            stop_share()
            return self._send(page("Раздача остановлена."))
        if op not in ("add", "enable", "disable", "remove"):
            return self._send(page("Неизвестное действие", err=True))
        code, out = run([op, name], no_share=True)
        if op == "add" and code == 0:
            start_share(name)
            return self._send(page(out, extra=share_page(name)))
        return self._send(page(out or "Готово", err=(code != 0)))


if __name__ == "__main__":
    srv = HTTPServer(("127.0.0.1", PORT), Handler)
    print(f"Панель: http://127.0.0.1:{PORT}/?t={TOKEN}")
    print("Снаружи недоступна. С мака: bash scripts/vpn-panel.sh")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        stop_share()
        print("\nОстановлено.")
