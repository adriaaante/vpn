#!/usr/bin/env python3
"""vpn-panel.py — панель управления доступом. Запускается НА СЕРВЕРЕ:

    python3 scripts/vpn-panel.py

Слушает ТОЛЬКО 127.0.0.1 — снаружи порт не виден. Это принципиально: публичная
панель на этом же IP выдала бы, что здесь VPN, и помогла бы занести адрес в
списки блокировок (грабля №5c). С мака — `bash scripts/vpn-panel.sh`: туннель,
браузер и PIN.

Вход по PIN (см. panel_pin): SSH-пароль спрашивает туннель, а не панель;
чтобы и его не вводить, положи на сервер ssh-ключ.

Правки конфига идут только через vpn-users.sh — там бэкап, sing-box check и
откат. Панель сама конфиг sing-box не трогает, только реестр пользователей.
"""
import html
import json
import os
import re
import secrets
import shutil
import signal
import subprocess
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STORE = os.environ.get("STORE", "/etc/sing-box/users.json")
CFG = os.environ.get("CFG", "/etc/sing-box/config.json")
HOSTFILE = os.environ.get("HOSTFILE", "/etc/sing-box/server-host.txt")
DOMAIN_INFO = os.environ.get("DOMAIN_INFO", "/etc/sing-box/domain-info.json")
PINFILE = os.environ.get("PINFILE", "/etc/sing-box/panel-pin.txt")
USERS_SH = os.path.join(REPO, "scripts", "vpn-users.sh")
PORT = int(os.environ.get("PANEL_PORT", "8787"))

share_proc = {"name": None, "proc": None}
sessions = set()
fails = {"count": 0, "until": 0.0}

# Готовые наборы зон для кнопок в окне ограничений.
ZONE_PRESETS = [(".ru", "Россия"), (".fr", "Франция"), (".de", "Германия"),
                (".eu", "Евросоюз"), (".cn", "Китай"), (".ua", "Украина"),
                (".by", "Беларусь"), (".kz", "Казахстан"), (".tr", "Турция"),
                (".in", "Индия")]


def panel_pin():
    """PIN: из файла, из переменной окружения или случайный (печатается при старте)."""
    for src in (os.environ.get("PANEL_PIN"), _read(PINFILE)):
        if src and src.strip():
            return src.strip()
    pin = "".join(secrets.choice("0123456789") for _ in range(6))
    try:
        with open(PINFILE, "w") as f:
            f.write(pin + "\n")
        os.chmod(PINFILE, 0o600)
    except OSError:
        pass
    return pin


def _read(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return ""


def sh(cmd, timeout=10):
    try:
        return subprocess.run(cmd, shell=True, capture_output=True,
                              text=True, timeout=timeout).stdout.strip()
    except Exception:
        return ""


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


def save_users(lst):
    with open(STORE, "w") as f:
        json.dump({"users": lst}, f, indent=2, ensure_ascii=False)


def find_user(name):
    for u in users():
        if u["name"] == name:
            return u
    return None


def server_status():
    ports = sh("ss -tlnp 2>/dev/null | awk '/sing-box/ {print $4}' | sed 's/.*://' | sort -un | tr '\\n' ' '")
    return {
        "singbox": sh("systemctl is-active sing-box") or "неизвестно",
        "ports": ports or "—",
        "ip": sh("curl -fsSL --max-time 5 https://api.ipify.org") or "—",
        "decoy": sh("python3 -c \"import json;print(json.load(open('%s'))['inbounds'][0]['tls']['server_name'])\"" % CFG) or "—",
        "uptime": sh("uptime -p") or "—",
    }


def domain_info():
    info = {}
    try:
        info = json.load(open(DOMAIN_INFO))
    except (OSError, json.JSONDecodeError):
        pass
    info["host"] = _read(HOSTFILE)
    exp = info.get("expires", "")
    if exp:
        try:
            import datetime
            y, m, d = (int(x) for x in exp.split("-"))
            info["days_left"] = (datetime.date(y, m, d) - datetime.date.today()).days
        except ValueError:
            pass
    return info


def human(n):
    for unit in ("Б", "КБ", "МБ", "ГБ", "ТБ"):
        if abs(n) < 1024 or unit == "ТБ":
            return f"{n:.1f} {unit}" if unit != "Б" else f"{int(n)} Б"
        n /= 1024
    return f"{n:.1f} ТБ"


def analytics():
    """Трафик сервера и живые соединения.

    Побайтовой статистики ПО ЛЮДЯМ здесь нет и быть не может: официальная сборка
    sing-box собрана без V2Ray-API (`rebuild with -tags with_v2ray_api`), а Clash
    API считает только суммарно. Поэтому честно показываем общий трафик и
    активность, не выдавая догадки за данные.
    """
    iface = sh("ip route get 1.1.1.1 2>/dev/null | sed -n 's/.* dev \\([^ ]*\\).*/\\1/p'") or "ens3"
    rx = tx = 0
    try:
        for line in open("/proc/net/dev"):
            if line.strip().startswith(iface + ":"):
                f = line.split(":")[1].split()
                rx, tx = int(f[0]), int(f[8])
    except OSError:
        pass
    conns = sh("ss -tn state established 2>/dev/null | grep -cE ':(443|2053|8443) '")
    days = []
    vn = sh("vnstat --json d 2>/dev/null", timeout=15)
    if vn:
        try:
            data = json.loads(vn)["interfaces"][0]["traffic"]["day"][-14:]
            for d in data:
                dt = d["date"]
                days.append((f'{dt["day"]:02d}.{dt["month"]:02d}', d["rx"] + d["tx"]))
        except Exception:
            days = []
    return {"iface": iface, "rx": rx, "tx": tx, "total": rx + tx,
            "conns": conns or "0", "days": days, "has_vnstat": bool(shutil.which("vnstat"))}


def qr_svg(text):
    if not shutil.which("qrencode"):
        return ""
    try:
        p = subprocess.run(["qrencode", "-t", "SVG", "-o", "-", text],
                           capture_output=True, timeout=10)
        return p.stdout.decode("utf-8", "replace") if p.returncode == 0 else ""
    except Exception:
        return ""


LOGO_FALLBACK = ('<svg class="logo" viewBox="0 0 40 40" fill="none"><rect width="40" height="40" '
                 'rx="11" fill="#5b8dff"/><path d="M12 27V13h13v3.6h-9.1v2.9h8v3.5h-8V27H12z" '
                 'fill="#fff"/></svg>')


def logo_html():
    """Логотип из assets/logo.svg. Размеры в файле в миллиметрах — снимаем их,
    иначе шапка распухает; высоту задаёт CSS."""
    svg = _read(os.path.join(REPO, "assets", "logo.svg"))
    if not svg:
        return LOGO_FALLBACK
    svg = re.sub(r'\s(width|height)="[^"]*"', "", svg, count=2)
    return svg.replace("<svg", '<svg class="logo"', 1)


CSS = """
/* Шрифт системный намеренно: панель живёт за SSH-туннелем и не должна ходить в
   интернет за шрифтами. */
:root{--bg:#0c0e12;--card:#15181f;--card2:#1a1e27;--line:#242935;--fg:#e9ecf3;
--dim:#98a2b6;--faint:#6b7488;--ok:#41d19b;--warn:#f0a441;--bad:#ff6b6b;--accent:#5b8dff}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font-size:15px;line-height:1.5;
font-family:-apple-system,BlinkMacSystemFont,'SF Pro Text','Segoe UI',Roboto,sans-serif;
-webkit-font-smoothing:antialiased;font-variant-numeric:tabular-nums}
.wrap{max-width:940px;margin:0 auto;padding:28px 20px 56px}
header{display:flex;align-items:center;gap:16px;padding-bottom:16px;margin-bottom:20px;
border-bottom:1px solid var(--line);flex-wrap:wrap}
svg.logo{height:24px;width:auto;flex:none}
h1{font-size:19px;font-weight:640;letter-spacing:-.01em;margin:0;
padding-left:16px;border-left:1px solid var(--line)}
header .sp{flex:1}
h2{font-size:12px;font-weight:600;letter-spacing:.07em;text-transform:uppercase;
color:var(--faint);margin:0}
.card{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:18px 20px}
.cardhead{display:flex;align-items:center;gap:12px;margin-bottom:14px}
.cardhead .sp{flex:1}
table{width:100%;border-collapse:collapse}
th{text-align:left;font-size:11px;color:var(--faint);font-weight:600;letter-spacing:.06em;
text-transform:uppercase;padding:0 6px 10px;border-bottom:1px solid var(--line)}
td{padding:12px 6px;border-bottom:1px solid var(--line);vertical-align:middle}
tr:last-child td{border-bottom:0}
.name{font-weight:600}
.note{color:var(--dim);font-size:12px}
.pill{display:inline-block;padding:2px 10px;border-radius:99px;font-size:12px;font-weight:500;
white-space:nowrap}
.on{background:rgba(65,209,155,.13);color:var(--ok)}
.off{background:rgba(240,164,65,.13);color:var(--warn)}
.bad{background:rgba(255,107,107,.13);color:var(--bad)}
.mut{background:var(--card2);color:var(--dim)}
button,.btn{font:inherit;font-size:13.5px;border:1px solid var(--line);background:var(--card2);
color:var(--fg);padding:7px 12px;border-radius:9px;cursor:pointer;white-space:nowrap;
transition:border-color .15s,color .15s}
button:hover,.btn:hover{border-color:var(--accent)}
button.danger:hover{border-color:var(--bad);color:var(--bad)}
button.primary{background:var(--accent);border-color:var(--accent);color:#fff;font-weight:550}
button.primary:hover{filter:brightness(1.1)}
.row{display:flex;gap:7px;flex-wrap:wrap;align-items:center}
.status{display:flex;gap:20px;flex-wrap:wrap;font-size:12.5px;color:var(--dim);
margin-top:18px;padding-top:14px;border-top:1px solid var(--line)}
.status b{color:var(--faint);font-weight:500}
input,textarea{font:inherit;background:var(--card2);border:1px solid var(--line);color:var(--fg);
padding:9px 12px;border-radius:9px;width:100%}
input:focus,textarea:focus{outline:none;border-color:var(--accent)}
textarea{min-height:92px;resize:vertical;font:13px ui-monospace,SFMono-Regular,Menlo,monospace}
label{display:block;font-size:11px;letter-spacing:.06em;text-transform:uppercase;
color:var(--faint);margin:14px 0 6px}
a{color:var(--accent);text-decoration:none}
a:hover{text-decoration:underline}
.msg{background:rgba(65,209,155,.08);border:1px solid rgba(65,209,155,.3);padding:12px 14px;
border-radius:11px;white-space:pre-wrap;margin-bottom:16px;
font:12.5px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace}
.msg.err{background:rgba(255,107,107,.08);border-color:rgba(255,107,107,.35)}
code{font:12.5px ui-monospace,SFMono-Regular,Menlo,monospace;word-break:break-all}
.linkrow{display:flex;flex-wrap:wrap;gap:8px;align-items:baseline;padding:9px 11px;
background:var(--card2);border-radius:9px;margin-bottom:8px}
.linkrow .mode{min-width:140px;font-size:12.5px;color:var(--dim)}
.tag{font-size:10px;letter-spacing:.05em;text-transform:uppercase;color:var(--faint);
border:1px solid var(--line);padding:1px 6px;border-radius:5px}
.zones{display:flex;flex-wrap:wrap;gap:7px}
.zone{display:inline-flex;align-items:center;gap:6px;background:var(--card2);
border:1px solid var(--line);border-radius:8px;padding:6px 10px;font-size:13px;cursor:pointer}
.zone input{width:auto;padding:0;margin:0}
.bar{height:7px;background:var(--card2);border-radius:99px;overflow:hidden;margin-top:6px}
.bar i{display:block;height:100%;background:var(--accent)}
.chart{display:flex;align-items:flex-end;gap:5px;height:110px;margin-top:10px}
.chart div{flex:1;background:var(--accent);border-radius:4px 4px 0 0;min-height:2px;opacity:.8}
.chart span{display:block;font-size:9px;color:var(--faint);text-align:center;margin-top:5px}
.kpi{display:grid;grid-template-columns:repeat(auto-fit,minmax(130px,1fr));gap:16px}
.kpi b{display:block;font-size:11px;letter-spacing:.06em;text-transform:uppercase;
color:var(--faint);font-weight:500;margin-bottom:3px}
.kpi span{font-size:19px;font-weight:600}
/* Модальные окна: без библиотек — скрытый чекбокс не нужен, хватает класса. */
.mask{position:fixed;inset:0;background:rgba(6,8,11,.72);backdrop-filter:blur(3px);
display:none;align-items:flex-start;justify-content:center;padding:6vh 16px;z-index:50}
.mask.open{display:flex}
.modal{background:var(--card);border:1px solid var(--line);border-radius:16px;
width:min(620px,100%);padding:22px 24px;max-height:86vh;overflow:auto;
box-shadow:0 24px 60px rgba(0,0,0,.5)}
.modal h3{margin:0 0 4px;font-size:17px;font-weight:640}
.modal .sub{color:var(--dim);font-size:13px;margin:0 0 18px}
.modal .actions{display:flex;gap:8px;justify-content:flex-end;margin-top:22px}
.hint{color:var(--faint);font-size:12px;margin-top:8px}
.login{max-width:340px;margin:16vh auto;text-align:center}
.login svg.logo{height:30px;margin-bottom:22px}
.login input{text-align:center;font-size:22px;letter-spacing:.34em;padding:12px}
"""

JS = """
function openM(id){document.getElementById(id).classList.add('open')}
function closeM(id){document.getElementById(id).classList.remove('open')}
document.addEventListener('click',function(e){if(e.target.classList.contains('mask'))
  e.target.classList.remove('open')});
document.addEventListener('keydown',function(e){if(e.key==='Escape')
  document.querySelectorAll('.mask.open').forEach(function(m){m.classList.remove('open')})});
"""


def modal(mid, title, sub, body, wide=False):
    return (f'<div class="mask" id="{mid}"><div class="modal">'
            f'<h3>{title}</h3><p class="sub">{sub}</p>{body}</div></div>')


def login_page(err=""):
    warn = f'<div class="msg err">{html.escape(err)}</div>' if err else ""
    return (f'<!doctype html><html lang="ru"><head><meta charset="utf-8">'
            f'<meta name="viewport" content="width=device-width,initial-scale=1">'
            f'<title>Вход</title><style>{CSS}</style></head><body><div class="login">'
            f'{logo_html()}{warn}'
            f'<form method="post" action="/login">'
            f'<input name="pin" type="password" inputmode="numeric" autocomplete="off" '
            f'autofocus placeholder="PIN" required>'
            f'<div style="margin-top:14px"><button class="primary" style="width:100%">Войти</button></div>'
            f'</form><div class="hint">PIN печатается в терминале при запуске панели.</div>'
            f'</div></body></html>')


def limits_modal(u):
    name = html.escape(u["name"])
    doms = "\n".join(u.get("block_domains", []))
    tlds = set(t if t.startswith(".") else "." + t for t in u.get("block_tld", []))
    zones = "".join(
        f'<label class="zone"><input type="checkbox" name="tld" value="{z}"'
        f'{" checked" if z in tlds else ""}> {z} <span class="note">{cn}</span></label>'
        for z, cn in ZONE_PRESETS)
    return modal(
        f"lim-{name}", f"Ограничения — {name}", "Запреты действуют только для этого человека.",
        f'<form method="post" action="/limits">'
        f'<input type="hidden" name="name" value="{name}">'
        f'<label>Запрещённые зоны</label><div class="zones">{zones}</div>'
        f'<label>Запрещённые домены</label>'
        f'<textarea name="domains" placeholder="по одному в строке&#10;casino.com&#10;example.org">'
        f'{html.escape(doms)}</textarea>'
        f'<div class="hint">Домен блокируется вместе с поддоменами. Работает по имени, '
        f'поэтому прямой заход по IP правило не поймает.</div>'
        f'<div class="actions"><button type="button" onclick="closeM(\'lim-{name}\')">Отмена</button>'
        f'<button class="primary">Сохранить</button></div></form>')


def analytics_modal():
    a = analytics()
    if a["days"]:
        mx = max(v for _, v in a["days"]) or 1
        bars = "".join(
            f'<div style="height:{max(2,int(v/mx*100))}%" title="{human(v)}"></div>'
            for _, v in a["days"])
        labels = "".join(f'<span>{d}</span>' for d, _ in a["days"])
        chart = (f'<label>Трафик по дням (последние {len(a["days"])})</label>'
                 f'<div class="chart">{bars}</div>'
                 f'<div style="display:flex;gap:5px">{labels}</div>')
    else:
        chart = ('<div class="hint">Истории по дням пока нет. Поставь счётчик один раз: '
                 '<code>apt install -y vnstat</code> — дальше график появится сам.</div>')
    return modal(
        "analytics", "Аналитика", "Трафик сервера и текущая нагрузка.",
        f'<div class="kpi">'
        f'<div><b>принято</b><span>{human(a["rx"])}</span></div>'
        f'<div><b>отдано</b><span>{human(a["tx"])}</span></div>'
        f'<div><b>всего</b><span>{human(a["total"])}</span></div>'
        f'<div><b>соединений сейчас</b><span>{html.escape(str(a["conns"]))}</span></div>'
        f'</div><div class="hint">Счётчики интерфейса {html.escape(a["iface"])} '
        f'с момента загрузки сервера.</div>'
        f'{chart}'
        f'<div class="hint" style="margin-top:16px">Разбивки по людям здесь нет намеренно: '
        f'официальная сборка sing-box идёт без V2Ray-статистики, а Clash API считает только '
        f'суммарно. Показывать выдуманные цифры хуже, чем не показывать никаких.</div>'
        f'<div class="actions"><button onclick="closeM(\'analytics\')">Закрыть</button></div>')


def links_modal():
    dom = domain_info().get("host", "")
    ip = server_status()["ip"]
    rows = []
    for f, label in (("full", "умный (RU напрямую)"), ("strict", "всё через Латвию"),
                     ("selective", "только сервисы")):
        cells = ""
        if dom:
            cells += f'<code>http://{html.escape(dom)}:8080/{f}.json</code><span class="tag">домен</span>'
        cells += f'<code>http://{html.escape(ip)}:8080/{f}.json</code><span class="tag">ip</span>'
        rows.append(f'<div class="linkrow"><span class="mode">{label}</span>{cells}</div>')
    return modal(
        "links", "Ссылки на конфиги", "Живут, только пока идёт раздача.",
        "".join(rows) +
        '<div class="hint">Ссылка по домену переживает смену адреса сервера — предпочитай её. '
        'Гостям отдаётся только «умный».</div>'
        '<div class="actions"><button onclick="closeM(\'links\')">Закрыть</button></div>')


def server_modal():
    st, dom = server_status(), domain_info()
    left = dom.get("days_left")
    if left is None:
        dstate = '<span class="pill mut">срок не указан</span>'
    elif left < 30:
        dstate = f'<span class="pill bad">продлить: {left} дн.</span>'
    elif left < 90:
        dstate = f'<span class="pill off">осталось {left} дн.</span>'
    else:
        dstate = f'<span class="pill on">оплачен ещё {left} дн.</span>'
    links = []
    if dom.get("panel_url"):
        links.append(f'<a href="{html.escape(dom["panel_url"])}" target="_blank">домен в панели</a>')
    if dom.get("dns_url"):
        links.append(f'<a href="{html.escape(dom["dns_url"])}" target="_blank">DNS-записи</a>')
    return modal(
        "server", "Сервер и домен", "Состояние и сроки.",
        f'<div class="kpi">'
        f'<div><b>sing-box</b><span class="pill {"on" if st["singbox"]=="active" else "bad"}">'
        f'{html.escape(st["singbox"])}</span></div>'
        f'<div><b>порты</b><span style="font-size:15px">{html.escape(st["ports"])}</span></div>'
        f'<div><b>адрес</b><span style="font-size:15px">{html.escape(st["ip"])}</span></div>'
        f'<div><b>decoy</b><span style="font-size:15px">{html.escape(st["decoy"])}</span></div>'
        f'<div><b>домен</b><span style="font-size:15px">{html.escape(dom.get("host","—"))}</span></div>'
        f'<div><b>оплачен до</b><span style="font-size:15px">{html.escape(dom.get("expires","—"))}</span></div>'
        f'<div><b>состояние домена</b><span>{dstate}</span></div>'
        f'<div><b>аптайм</b><span style="font-size:15px">{html.escape(st["uptime"])}</span></div>'
        f'</div>{"<div class=hint>" + " · ".join(links) + "</div>" if links else ""}'
        f'<div class="actions"><button onclick="closeM(\'server\')">Закрыть</button></div>')


def add_modal():
    return modal(
        "add", "Новый человек", "Ключ создаётся персональный — отключается отдельно от остальных.",
        '<form method="post" action="/act">'
        '<input type="hidden" name="op" value="add">'
        '<label>Имя латиницей</label>'
        '<input name="name" placeholder="например sasha-tpk" required '
        'pattern="[A-Za-z0-9._-]+" title="латиница, цифры, точка, дефис, подчёркивание">'
        '<div class="hint">Кириллица и пробелы не годятся: имя уходит в пути и колонки.</div>'
        '<div class="actions"><button type="button" onclick="closeM(\'add\')">Отмена</button>'
        '<button class="primary">Создать и выдать конфиг</button></div></form>')


def page(msg="", err=False, extra=""):
    st, dom = server_status(), domain_info()
    rows, modals = [], []
    for u in users():
        on = bool(u.get("enabled"))
        nm = html.escape(u["name"])
        note = f'<div class="note">{html.escape(u.get("note",""))}</div>' if u.get("note") else ""
        nlim = len(u.get("block_domains", [])) + len(u.get("block_tld", []))
        lim = (f'<span class="pill mut">{nlim} запретов</span>' if nlim
               else '<span class="note">нет</span>')
        rows.append(
            f'<tr><td><div class="name">{nm}</div>{note}</td>'
            f'<td><span class="pill {"on" if on else "off"}">'
            f'{"включён" if on else "отключён"}</span></td>'
            f'<td>{lim}</td><td><div class="row">'
            f'<form method="post" action="/act"><input type="hidden" name="op" '
            f'value="{"disable" if on else "enable"}">'
            f'<input type="hidden" name="name" value="{nm}">'
            f'<button>{"Отключить" if on else "Включить"}</button></form>'
            f'<button onclick="openM(\'lim-{nm}\')">Ограничения</button>'
            f'<form method="get" action="/share"><input type="hidden" name="name" value="{nm}">'
            f'<button>Конфиг</button></form>'
            f'<form method="post" action="/act" onsubmit="return confirm(\'Удалить {nm}?\')">'
            f'<input type="hidden" name="op" value="remove"><input type="hidden" name="name" value="{nm}">'
            f'<button class="danger">Удалить</button></form>'
            f'</div></td></tr>')
        modals.append(limits_modal(u))

    msg_html = f'<div class="msg{" err" if err else ""}">{html.escape(msg)}</div>' if msg else ""
    body = "".join(rows) or '<tr><td colspan="4" class="note">Пока никого нет</td></tr>'
    left = dom.get("days_left")
    dom_line = (f'{html.escape(dom.get("host","—"))} · до {html.escape(dom.get("expires","—"))}'
                + (f' ({left} дн.)' if left is not None else ""))
    return f"""<!doctype html><html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>FutureFlow — доступ к VPN</title><style>{CSS}</style></head><body><div class="wrap">
<header>{logo_html()}<h1>Доступ к VPN</h1><span class="sp"></span>
<button onclick="openM('analytics')">Аналитика</button>
<button onclick="openM('links')">Конфиги</button>
<button onclick="openM('server')">Сервер и домен</button></header>
{msg_html}{extra}
<div class="card"><div class="cardhead"><h2>Люди</h2><span class="sp"></span>
<button class="primary" onclick="openM('add')">Добавить</button></div>
<table><tr><th>Пользователь</th><th>Статус</th><th>Ограничения</th><th>Действия</th></tr>
{body}</table>
<div class="status">
<span><b>sing-box</b> {html.escape(st['singbox'])}</span>
<span><b>порты</b> {html.escape(st['ports'])}</span>
<span><b>адрес</b> {html.escape(st['ip'])}</span>
<span><b>decoy</b> {html.escape(st['decoy'])}</span>
<span><b>домен</b> {dom_line}</span>
</div></div>
{add_modal()}{analytics_modal()}{links_modal()}{server_modal()}{''.join(modals)}
<script>{JS}</script></body></html>"""


def share_page(name):
    st, dom = server_status(), domain_info()
    host = dom.get("host") or st["ip"]
    url = f"http://{host}:8080/full.json"
    svg = qr_svg(url)
    qr = (svg.replace("<svg", '<svg style="background:#fff;border-radius:12px;padding:10px;'
                             'max-width:230px;height:auto" ', 1) if svg else
          '<div class="hint">QR нет: поставь qrencode (apt install -y qrencode).</div>')
    alt = "" if host == st["ip"] else (
        f'<div class="hint">Запасная ссылка: <code>http://{html.escape(st["ip"])}:8080/full.json</code></div>')
    return (f'<div class="card" style="margin-bottom:16px">'
            f'<div class="cardhead"><h2>Конфиг для «{html.escape(name)}»</h2></div>'
            f'<div class="linkrow"><code>{html.escape(url)}</code><span class="tag">домен</span></div>'
            f'{alt}<div style="margin:14px 0">{qr}</div>'
            f'<p class="note">Пусть добавит как <b>Remote</b>-профиль: sing-box → New Profile → '
            f'Type: Remote → URL.</p>'
            f'<div class="hint">Ссылка отдаёт его личный ключ без пароля — останавливай сразу '
            f'после импорта.</div>'
            f'<form method="post" action="/act" style="margin-top:12px">'
            f'<input type="hidden" name="op" value="share_stop">'
            f'<button class="danger">Остановить раздачу</button></form></div>')


def start_share(name):
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
    share_proc.update({"proc": None, "name": None})


PIN = panel_pin()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, body, code=200, cookie=None):
        b = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(b)))
        if cookie:
            self.send_header("Set-Cookie",
                             f"sid={cookie}; Path=/; HttpOnly; SameSite=Strict")
        self.end_headers()
        self.wfile.write(b)

    def _authed(self):
        raw = self.headers.get("Cookie", "")
        for part in raw.split(";"):
            if part.strip().startswith("sid="):
                return part.strip()[4:] in sessions
        return False

    def _form(self):
        n = int(self.headers.get("Content-Length", 0))
        return urllib.parse.parse_qs(self.rfile.read(n).decode())

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        if not self._authed():
            return self._send(login_page())
        if u.path == "/share":
            name = urllib.parse.parse_qs(u.query).get("name", [""])[0]
            if not find_user(name):
                return self._send(page("Нет такого пользователя", err=True))
            start_share(name)
            return self._send(page(extra=share_page(name)))
        return self._send(page())

    def do_POST(self):
        if self.path == "/login":
            now = time.time()
            if fails["until"] > now:
                return self._send(login_page(
                    f"Слишком много попыток. Подожди {int(fails['until']-now)} с."))
            pin = self._form().get("pin", [""])[0].strip()
            if secrets.compare_digest(pin, PIN):
                sid = secrets.token_urlsafe(24)
                sessions.add(sid)
                fails.update({"count": 0, "until": 0.0})
                return self._send(page(), cookie=sid)
            fails["count"] += 1
            if fails["count"] >= 5:
                fails.update({"count": 0, "until": now + 300})
                return self._send(login_page("Слишком много попыток. Подожди 5 минут."))
            return self._send(login_page("Неверный PIN."))

        if not self._authed():
            return self._send(login_page())
        form = self._form()

        if self.path == "/limits":
            name = form.get("name", [""])[0]
            lst = users()
            hit = [x for x in lst if x["name"] == name]
            if not hit:
                return self._send(page("Нет такого пользователя", err=True))
            doms = [d.strip().lower() for d in form.get("domains", [""])[0].splitlines() if d.strip()]
            hit[0]["block_domains"] = doms
            hit[0]["block_tld"] = [t for t in form.get("tld", [])]
            save_users(lst)
            code, out = run(["apply"])
            return self._send(page(out or "Ограничения сохранены", err=(code != 0)))

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
    print(f"Панель: http://127.0.0.1:{PORT}/")
    print(f"PIN: {PIN}   (хранится в {PINFILE})")
    print("Снаружи недоступна. С мака: bash scripts/vpn-panel.sh")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        stop_share()
        print("\nОстановлено.")
