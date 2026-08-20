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
import re
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


DOMAIN_INFO = os.environ.get("DOMAIN_INFO", "/etc/sing-box/domain-info.json")


def domain_info():
    """Имя сервера + факты о домене: где куплен, до какого числа оплачен."""
    host = ""
    try:
        host = open(os.environ.get("HOSTFILE", "/etc/sing-box/server-host.txt")).read().strip()
    except OSError:
        pass
    info = {}
    try:
        info = json.load(open(DOMAIN_INFO))
    except (OSError, json.JSONDecodeError):
        pass
    info["host"] = host
    exp = info.get("expires", "")
    if exp:
        try:
            y, m, dd = (int(x) for x in exp.split("-"))
            import datetime
            info["days_left"] = (datetime.date(y, m, dd) - datetime.date.today()).days
        except ValueError:
            pass
    return info


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
/* Системный шрифт намеренно: панель открывается через SSH-туннель и не должна
   ходить в интернет за шрифтами — ни лишних запросов, ни задержек. */
:root{
  --bg:#0d0f13; --card:#161920; --card2:#1b1f28; --line:#252a35;
  --fg:#e9ecf3; --dim:#96a0b5; --faint:#6a7385;
  --ok:#41d19b; --warn:#f0a441; --bad:#ff6b6b; --accent:#5b8dff;
  --radius:14px;
}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);
  font-family:-apple-system,BlinkMacSystemFont,'SF Pro Text','Segoe UI',Roboto,sans-serif;
  font-size:15px;line-height:1.55;-webkit-font-smoothing:antialiased;
  font-variant-numeric:tabular-nums}
.wrap{max-width:960px;margin:0 auto;padding:36px 22px 72px}
header{display:flex;align-items:center;gap:18px;margin-bottom:8px;
  padding-bottom:18px;border-bottom:1px solid var(--line)}
header svg.logo{flex:none;height:26px;width:auto}
header h1{padding-left:18px;border-left:1px solid var(--line)}
h1{font-size:21px;font-weight:650;letter-spacing:-.01em;margin:0}
.brand{font-size:12px;color:var(--faint);letter-spacing:.08em;text-transform:uppercase;margin-top:2px}
.sub{color:var(--dim);font-size:13px;margin:0 0 26px}
h2{font-size:12px;font-weight:600;letter-spacing:.07em;text-transform:uppercase;
  color:var(--faint);margin:0 0 14px}
.card{background:var(--card);border:1px solid var(--line);border-radius:var(--radius);
  padding:20px 22px;margin-bottom:16px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:18px}
.kv b{display:block;color:var(--faint);font-weight:500;font-size:11px;
  letter-spacing:.06em;text-transform:uppercase;margin-bottom:4px}
.kv span{font-size:14px}
table{width:100%;border-collapse:collapse}
th{text-align:left;font-size:11px;color:var(--faint);font-weight:600;letter-spacing:.06em;
  text-transform:uppercase;padding:0 8px 12px;border-bottom:1px solid var(--line)}
td{padding:14px 8px;border-bottom:1px solid var(--line);vertical-align:middle}
tr:last-child td{border-bottom:0}
.name{font-weight:600;letter-spacing:-.005em}
.note{color:var(--dim);font-size:12px}
.pill{display:inline-block;padding:3px 11px;border-radius:99px;font-size:12px;font-weight:500}
.on{background:rgba(65,209,155,.13);color:var(--ok)}
.off{background:rgba(240,164,65,.13);color:var(--warn)}
.err{background:rgba(255,107,107,.13);color:var(--bad)}
button{font:inherit;font-size:14px;border:1px solid var(--line);background:var(--card2);
  color:var(--fg);padding:8px 14px;border-radius:9px;cursor:pointer;
  transition:border-color .15s,color .15s}
button:hover{border-color:var(--accent)}
button.danger:hover{border-color:var(--bad);color:var(--bad)}
button.primary{background:var(--accent);border-color:var(--accent);color:#fff;font-weight:550}
button.primary:hover{filter:brightness(1.08)}
.row{display:flex;gap:8px;flex-wrap:wrap;align-items:center}
input[type=text]{font:inherit;background:var(--card2);border:1px solid var(--line);
  color:var(--fg);padding:9px 13px;border-radius:9px;min-width:240px}
input[type=text]:focus{outline:none;border-color:var(--accent)}
a{color:var(--accent);text-decoration:none}
a:hover{text-decoration:underline}
.msg{background:rgba(65,209,155,.08);border:1px solid rgba(65,209,155,.3);
  padding:13px 15px;border-radius:11px;white-space:pre-wrap;
  font:13px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace;margin-bottom:16px}
.msg.bad{background:rgba(255,107,107,.08);border-color:rgba(255,107,107,.35)}
.links{display:grid;grid-template-columns:1fr;gap:10px}
.linkrow{display:flex;flex-wrap:wrap;align-items:baseline;gap:10px;padding:10px 12px;
  background:var(--card2);border-radius:10px}
.linkrow .mode{min-width:150px;font-size:13px;color:var(--dim)}
.linkrow code{font:12.5px ui-monospace,SFMono-Regular,Menlo,monospace;
  color:var(--fg);word-break:break-all}
.tag{font-size:10px;letter-spacing:.06em;text-transform:uppercase;color:var(--faint);
  border:1px solid var(--line);padding:1px 6px;border-radius:5px}
svg.qr{background:#fff;border-radius:12px;padding:10px;max-width:250px;height:auto}
.hint{color:var(--faint);font-size:12px;margin-top:10px}
"""


LOGO_FALLBACK = """<svg width="40" height="40" viewBox="0 0 40 40" fill="none" aria-hidden="true">
  <rect width="40" height="40" rx="11" fill="url(#ffg)"/>
  <path d="M12 27V13h13v3.6h-9.1v2.9h8v3.5h-8V27H12z" fill="#fff"/>
  <path d="M24.5 27c2.9-1.1 4.6-3.4 5-6.9" stroke="#fff" stroke-width="2.1"
        stroke-linecap="round" opacity=".65"/>
  <defs><linearGradient id="ffg" x1="0" y1="0" x2="40" y2="40">
    <stop stop-color="#5b8dff"/><stop offset="1" stop-color="#41d19b"/>
  </linearGradient></defs>
</svg>"""


def logo_html():
    """Фирменный знак из assets/logo.svg. Размер задаём классом: в файле он в
    миллиметрах, и без этого шапка распухла бы на пол-экрана."""
    try:
        svg = open(os.path.join(REPO, "assets", "logo.svg")).read()
    except OSError:
        return LOGO_FALLBACK
    svg = re.sub(r'\s(width|height)="[^"]*"', "", svg, count=2)
    return svg.replace("<svg", '<svg class="logo"', 1)

MODES = (("full", "умный (RU напрямую)"),
         ("strict", "всё через Латвию"),
         ("selective", "только сервисы"))


def config_links(dom, ip):
    """Все ссылки на конфиги — и по имени, и по адресу, чтобы видеть картину целиком."""
    rows = []
    for fname, label in MODES:
        cells = []
        if dom:
            cells.append('<code>http://%s:8080/%s.json</code><span class="tag">домен</span>'
                         % (html.escape(dom), fname))
        cells.append('<code>http://%s:8080/%s.json</code><span class="tag">ip</span>'
                     % (html.escape(ip), fname))
        rows.append('<div class="linkrow"><span class="mode">%s</span>%s</div>'
                    % (label, "".join(cells)))
    return ('<div class="card"><h2>Ссылки на конфиги</h2><div class="links">%s</div>'
            '<div class="hint">Живут, только пока идёт раздача (кнопка «Выдать конфиг»). '
            'Ссылка по домену переживает смену адреса сервера — предпочитай её. '
            'Гостям отдаём только «умный».</div></div>' % "".join(rows))


def domain_card(info):
    if not info.get("host"):
        return ('<div class="card"><h2>Домен</h2><div class="note">Имя сервера не настроено. '
                'Задать: <code>echo имя &gt; /etc/sing-box/server-host.txt</code></div></div>')
    left = info.get("days_left")
    if left is None:
        state = '<span class="pill off">срок не указан</span>'
    elif left < 30:
        state = '<span class="pill err">пора продлевать: %d дн.</span>' % left
    elif left < 90:
        state = '<span class="pill off">осталось %d дн.</span>' % left
    else:
        state = '<span class="pill on">оплачен ещё %d дн.</span>' % left
    links = []
    if info.get("panel_url"):
        links.append('<a href="%s" target="_blank">домен в панели регистратора</a>'
                     % html.escape(info["panel_url"]))
    if info.get("dns_url"):
        links.append('<a href="%s" target="_blank">DNS-записи</a>' % html.escape(info["dns_url"]))
    tail = '<div class="hint">%s</div>' % " · ".join(links) if links else ""
    return ('<div class="card"><h2>Домен</h2><div class="grid">'
            '<div class="kv"><b>имя</b><span>%s</span></div>'
            '<div class="kv"><b>регистратор</b><span>%s</span></div>'
            '<div class="kv"><b>оплачен до</b><span>%s</span></div>'
            '<div class="kv"><b>состояние</b><span>%s</span></div>'
            '</div>%s</div>'
            % (html.escape(info["host"]), html.escape(info.get("registrar", "—")),
               html.escape(info.get("expires", "—")), state, tail))


def page(msg="", err=False, extra=""):
    st = server_status()
    dom = domain_info()
    sb_cls = "on" if st["singbox"] == "active" else "err"
    rows = []
    for u in users():
        on = bool(u.get("enabled"))
        nm = html.escape(u["name"])
        note = html.escape(u.get("note", ""))
        toggle = "disable" if on else "enable"
        note_html = '<div class="note">%s</div>' % note if note else ""
        rows.append(
            '<tr><td><div class="name">%s</div>%s</td>'
            '<td><span class="pill %s">%s</span></td>'
            '<td><div class="row">'
            '<form method="post" action="/act"><input type="hidden" name="t" value="%s">'
            '<input type="hidden" name="op" value="%s"><input type="hidden" name="name" value="%s">'
            '<button>%s</button></form>'
            '<form method="get" action="/share"><input type="hidden" name="t" value="%s">'
            '<input type="hidden" name="name" value="%s"><button>Выдать конфиг</button></form>'
            '<form method="post" action="/act" onsubmit="return confirm(\'Удалить %s?\')">'
            '<input type="hidden" name="t" value="%s"><input type="hidden" name="op" value="remove">'
            '<input type="hidden" name="name" value="%s"><button class="danger">Удалить</button></form>'
            '</div></td></tr>'
            % (nm, note_html, "on" if on else "off", "включён" if on else "отключён",
               TOKEN, toggle, nm, "Отключить" if on else "Включить",
               TOKEN, nm, nm, TOKEN, nm))

    msg_html = ('<div class="msg%s">%s</div>' % (" bad" if err else "", html.escape(msg))) if msg else ""
    body = "".join(rows) or '<tr><td colspan="3" class="note">Пока никого нет</td></tr>'
    return ("""<!doctype html><html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>FutureFlow — доступ к VPN</title><style>%s</style></head><body><div class="wrap">
<header>%s<h1>Доступ к VPN</h1></header>
<p class="sub">Панель открыта только через SSH-туннель — снаружи порт закрыт.</p>
%s%s
<div class="card"><h2>Сервер</h2><div class="grid">
<div class="kv"><b>sing-box</b><span class="pill %s">%s</span></div>
<div class="kv"><b>порты</b><span>%s</span></div>
<div class="kv"><b>адрес</b><span>%s</span></div>
<div class="kv"><b>текущий decoy</b><span>%s</span></div>
</div></div>
%s
<div class="card"><h2>Люди</h2><table>
<tr><th>Пользователь</th><th>Статус</th><th>Действия</th></tr>%s</table></div>
%s
<div class="card"><h2>Добавить человека</h2>
<form method="post" action="/act" class="row">
<input type="hidden" name="t" value="%s"><input type="hidden" name="op" value="add">
<input type="text" name="name" placeholder="имя латиницей, напр. sasha-tpk" required>
<button class="primary">Добавить</button></form>
<div class="hint">Латиница, цифры, дефис. Ключ персональный — отключается отдельно от остальных.</div>
</div></div></body></html>"""
            % (CSS, logo_html(), msg_html, extra, sb_cls, html.escape(st["singbox"]),
               html.escape(st["ports"]), html.escape(st["ip"]), html.escape(st["decoy"]),
               domain_card(dom), body, config_links(dom.get("host", ""), st["ip"]), TOKEN))


def share_page(name):
    st = server_status()
    dom = domain_info()
    host = dom.get("host") or st["ip"]
    url = "http://%s:8080/full.json" % host
    svg = qr_svg(url)
    qr = svg.replace("<svg", '<svg class="qr"', 1) if svg else (
        '<div class="hint">QR нет: на сервере не установлен qrencode (apt install qrencode).</div>')
    alt = "" if host == st["ip"] else (
        '<div class="hint">Запасная ссылка по адресу: <code>http://%s:8080/full.json</code></div>'
        % html.escape(st["ip"]))
    return ('<div class="card"><h2>Конфиг для «%s»</h2>'
            '<p class="note">Пусть добавит как <b>Remote</b>-профиль: '
            'sing-box → New Profile → Type: Remote → URL.</p>'
            '<div class="linkrow"><code>%s</code><span class="tag">домен</span></div>%s'
            '<div style="margin:14px 0">%s</div>'
            '<div class="hint">Ссылка отдаёт его личный ключ без пароля — '
            'останови раздачу сразу после импорта.</div>'
            '<form method="post" action="/act" style="margin-top:12px">'
            '<input type="hidden" name="t" value="%s">'
            '<input type="hidden" name="op" value="share_stop">'
            '<button class="danger">Остановить раздачу</button></form></div>'
            % (html.escape(name), html.escape(url), alt, qr, TOKEN))


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
