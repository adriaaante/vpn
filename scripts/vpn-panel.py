#!/usr/bin/env python3
"""vpn-panel.py — панель управления доступом. Запускается НА СЕРВЕРЕ:

    python3 scripts/vpn-panel.py

Слушает ТОЛЬКО 127.0.0.1 — снаружи порт не виден. Это принципиально: публичная
панель на этом же IP выдала бы, что здесь VPN, и помогла бы занести адрес в
списки блокировок (грабля №5c). С мака — `bash scripts/vpn-panel.sh`.

Вход по PIN. SSH-пароль спрашивает туннель, а не панель; чтобы и его не вводить,
положи на сервер ssh-ключ (`ssh-copy-id`).

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

# Страны для запретов: зона + понятное название.
ZONES = [(".ru", "Россия"), (".ua", "Украина"), (".by", "Беларусь"), (".kz", "Казахстан"),
         (".fr", "Франция"), (".de", "Германия"), (".it", "Италия"), (".es", "Испания"),
         (".pl", "Польша"), (".nl", "Нидерланды"), (".cz", "Чехия"), (".uk", "Британия"),
         (".eu", "Евросоюз"), (".cn", "Китай"), (".jp", "Япония"), (".kr", "Корея"),
         (".in", "Индия"), (".tr", "Турция"), (".br", "Бразилия"), (".us", "США")]


def _read(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return ""


def panel_pin():
    for src in (os.environ.get("PANEL_PIN"), _read(PINFILE)):
        if src and src.strip():
            return src.strip()
    pin = "".join(secrets.choice("0123456789") for _ in range(4))
    try:
        with open(PINFILE, "w") as f:
            f.write(pin + "\n")
        os.chmod(PINFILE, 0o600)
    except OSError:
        pass
    return pin


def sh(cmd, timeout=10):
    try:
        return subprocess.run(cmd, shell=True, capture_output=True,
                              text=True, timeout=timeout).stdout.strip()
    except Exception:
        return ""


def run(args, timeout=90, no_share=False):
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
            lst = json.load(f).get("users", [])
    except FileNotFoundError:
        run(["list"])
        try:
            with open(STORE) as f:
                lst = json.load(f).get("users", [])
        except Exception:
            return []
    except json.JSONDecodeError:
        return []
    # Владелец должен быть защищён даже в старых реестрах, заведённых до этой правки.
    if lst and not any(u.get("protected") for u in lst):
        lst[0]["protected"] = True
    return lst


def save_users(lst):
    """Сохранить реестр, НЕ потеряв остальные поля.

    Раньше здесь писалось ровно {"users": ...} — и `flow` из реестра пропадал бы
    при первой же правке ограничений. Именно такой молчаливый обрез (конфиг без
    flow, потом конфиг без пользователей) уже стоил дня простоя.
    """
    try:
        with open(STORE) as f:
            data = json.load(f)
        if not isinstance(data, dict):
            data = {}
    except (OSError, json.JSONDecodeError):
        data = {}
    data["users"] = lst
    with open(STORE, "w") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)


def find_user(name):
    for u in users():
        if u["name"] == name:
            return u
    return None


def server_status():
    ports = sh("ss -tlnp 2>/dev/null | awk '/sing-box/ {print $4}' | sed 's/.*://' | sort -un | tr '\\n' ' '")
    up = sh("uptime -p") or ""
    up = (up.replace("up ", "").replace(" days", " дн.").replace(" day", " дн.")
            .replace(" hours", " ч.").replace(" hour", " ч.")
            .replace(" minutes", " мин.").replace(" minute", " мин."))
    return {
        "singbox": sh("systemctl is-active sing-box") or "неизвестно",
        "ports": ports.strip() or "—",
        "ip": sh("curl -fsSL --max-time 5 https://api.ipify.org") or "—",
        "decoy": sh("python3 -c \"import json;print(json.load(open('%s'))['inbounds'][0]['tls']['server_name'])\"" % CFG) or "—",
        "uptime": up or "—",
    }


def domain_info():
    info = {}
    try:
        info = json.load(open(DOMAIN_INFO))
    except (OSError, json.JSONDecodeError):
        pass
    info["host"] = _read(HOSTFILE)
    if info.get("expires"):
        try:
            import datetime
            y, m, d = (int(x) for x in info["expires"].split("-"))
            info["days_left"] = (datetime.date(y, m, d) - datetime.date.today()).days
        except ValueError:
            pass
    return info


def human(n):
    n = float(n)
    for unit in ("Б", "КБ", "МБ", "ГБ", "ТБ"):
        if abs(n) < 1024 or unit == "ТБ":
            return f"{int(n)} {unit}" if unit == "Б" else f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} ТБ"


def analytics():
    """Расход трафика и текущая нагрузка сервера."""
    iface = sh("ip route get 1.1.1.1 2>/dev/null | sed -n 's/.* dev \\([^ ]*\\).*/\\1/p'") or "ens3"
    rx = tx = 0
    try:
        for line in open("/proc/net/dev"):
            if line.strip().startswith(iface + ":"):
                f = line.split(":")[1].split()
                rx, tx = int(f[0]), int(f[8])
    except OSError:
        pass
    conns = sh("ss -tn state established 2>/dev/null | grep -cE ':(443|2053|8443) '") or "0"
    days = []
    if shutil.which("vnstat"):
        try:
            data = json.loads(sh("vnstat --json d 2>/dev/null", timeout=15))
            for d in data["interfaces"][0]["traffic"]["day"][-14:]:
                dt = d["date"]
                days.append((f'{dt["day"]:02d}.{dt["month"]:02d}', d["rx"] + d["tx"]))
        except Exception:
            days = []
    return {"iface": iface, "rx": rx, "tx": tx, "total": rx + tx, "conns": conns,
            "days": days, "has_vnstat": bool(shutil.which("vnstat"))}


def qr_svg(text, level="H"):
    """QR-код ссылки. Уровень коррекции H (восстанавливает до 30% площади) —
    именно поэтому поверх кода можно рисовать логотип и он всё равно читается."""
    if not shutil.which("qrencode"):
        return ""
    try:
        p = subprocess.run(["qrencode", "-t", "SVG", "-l", level, "-m", "1", "-o", "-", text],
                           capture_output=True, timeout=10)
        if p.returncode != 0:
            return ""
        svg = p.stdout.decode("utf-8", "replace")
    except Exception:
        return ""
    # qrencode отдаёт файл с <?xml?> и DOCTYPE — внутрь HTML их вставлять нельзя.
    i = svg.find("<svg")
    if i < 0:
        return ""
    svg = svg[i:]
    m = re.match(r"<svg[^>]*>", svg)
    if m:  # снимаем жёсткие width/height, размер задаёт CSS
        tag = re.sub(r'\s(?:width|height)="[^"]*"', "", m.group(0))
        svg = tag.replace("<svg", '<svg class="qr"', 1) + svg[m.end():]
    return svg


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
.wrap{max-width:960px;margin:0 auto;padding:28px 20px 56px}
header{display:flex;align-items:center;gap:16px;padding-bottom:16px;margin-bottom:20px;
border-bottom:1px solid var(--line);flex-wrap:wrap}
svg.logo{height:24px;width:auto;flex:none}
h1{font-size:19px;font-weight:640;margin:0;padding-left:16px;border-left:1px solid var(--line)}
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
.pill{display:inline-block;padding:2px 10px;border-radius:99px;font-size:12px;
font-weight:500;white-space:nowrap}
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
textarea{min-height:110px;resize:vertical;
font:13px/1.7 ui-monospace,SFMono-Regular,Menlo,monospace}
label{display:block;font-size:11px;letter-spacing:.06em;text-transform:uppercase;
color:var(--faint);margin:16px 0 7px}
a{color:var(--accent);text-decoration:none}
a:hover{text-decoration:underline}
.msg{background:rgba(65,209,155,.08);border:1px solid rgba(65,209,155,.3);padding:12px 14px;
border-radius:11px;white-space:pre-wrap;margin-bottom:16px;
font:12.5px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace}
.msg.err{background:rgba(255,107,107,.08);border-color:rgba(255,107,107,.35)}
code{font:12.5px ui-monospace,SFMono-Regular,Menlo,monospace;word-break:break-all}
.linkrow{display:flex;flex-wrap:wrap;gap:8px;align-items:baseline;padding:9px 11px;
background:var(--card2);border-radius:9px;margin-bottom:8px}
.linkrow .mode{min-width:150px;font-size:12.5px;color:var(--dim)}
.tag{font-size:10px;letter-spacing:.05em;text-transform:uppercase;color:var(--faint);
border:1px solid var(--line);padding:1px 6px;border-radius:5px}
.zones{display:grid;grid-template-columns:repeat(auto-fill,minmax(148px,1fr));gap:8px}
.zone{display:flex;align-items:center;gap:8px;background:var(--card2);border:1px solid var(--line);
border-radius:9px;padding:8px 11px;font-size:13px;cursor:pointer}
.zone input{width:auto;padding:0;margin:0;flex:none}
.zone b{font-weight:600;font-size:12.5px}
.zone span{color:var(--dim);font-size:12px}
/* Строки «ключ-значение»: фиксированная сетка, значения переносятся и не наезжают. */
.facts{display:grid;grid-template-columns:repeat(auto-fit,minmax(210px,1fr));gap:18px 24px}
.fact b{display:block;font-size:11px;letter-spacing:.05em;text-transform:uppercase;
color:var(--faint);font-weight:500;margin-bottom:5px}
.fact span{font-size:15px;display:block;word-break:break-word;line-height:1.35}
.fact .pill{margin-top:2px}
.chart{display:flex;align-items:flex-end;gap:6px;height:120px;margin-top:12px}
.chart .col{flex:1;display:flex;flex-direction:column;justify-content:flex-end;height:100%}
.chart .col i{display:block;background:var(--accent);border-radius:5px 5px 0 0;opacity:.85}
.chart .col em{font-style:normal;font-size:9.5px;color:var(--faint);text-align:center;
margin-top:6px;display:block}
.mask{position:fixed;inset:0;background:rgba(6,8,11,.74);backdrop-filter:blur(3px);
display:none;align-items:flex-start;justify-content:center;padding:6vh 16px;z-index:50}
.mask.open{display:flex}
.modal{background:var(--card);border:1px solid var(--line);border-radius:16px;
width:min(640px,100%);padding:22px 24px;max-height:86vh;overflow:auto;
box-shadow:0 24px 60px rgba(0,0,0,.55)}
.modal h3{margin:0 0 4px;font-size:17px;font-weight:640}
.modal .sub{color:var(--dim);font-size:13px;margin:0 0 18px}
.modal .actions{display:flex;gap:8px;justify-content:flex-end;margin-top:22px}
.hint{color:var(--faint);font-size:12px;margin-top:8px;line-height:1.5}
/* Вход: цифровая клавиатура как на телефоне */
.login{max-width:320px;margin:12vh auto;text-align:center}
.login svg.logo{height:28px;margin-bottom:20px}
.login p{color:var(--dim);font-size:13.5px;margin:0 0 20px}
.dots{display:flex;gap:14px;justify-content:center;margin-bottom:26px}
.dots i{width:13px;height:13px;border-radius:50%;border:1.5px solid var(--line);display:block}
.dots i.f{background:var(--accent);border-color:var(--accent)}
.pad{display:grid;grid-template-columns:repeat(3,1fr);gap:12px}
.pad button{font-size:22px;font-weight:500;padding:16px 0;border-radius:14px;background:var(--card);
border:1px solid var(--line)}
.pad button:active{background:var(--card2)}
.pad button.sec{font-size:15px;color:var(--dim)}
/* QR вместе с логотипом: тёмная карточка, внутри белая плитка кода. */
.qrcard{display:inline-flex;flex-direction:column;align-items:center;gap:12px;
background:linear-gradient(160deg,#1e2431,#12151c);border:1px solid var(--line);
border-radius:18px;padding:17px 17px 13px}
.qrcard svg.logo{height:18px;opacity:.95}
.qrtile{background:#fff;border-radius:12px;padding:10px;line-height:0}
.qrtile svg.qr{width:var(--qr,200px);height:var(--qr,200px);display:block}
.qrcap{font-size:11px;color:var(--faint);text-align:center;letter-spacing:.03em}
.split{display:flex;gap:20px;flex-wrap:wrap;align-items:flex-start;margin-bottom:16px}
.split .col{flex:1 1 240px;min-width:220px}
.split .qrcol{flex:0 0 auto;min-width:0}
.steps{counter-reset:s;margin:0;padding:0;list-style:none}
.steps li{counter-increment:s;position:relative;padding-left:33px;margin-bottom:14px}
.steps li:before{content:counter(s);position:absolute;left:0;top:1px;width:23px;height:23px;
border-radius:50%;background:var(--card2);border:1px solid var(--line);color:var(--dim);
font-size:12px;line-height:21px;text-align:center}
.steps b{font-weight:600;font-size:14px}
.steps .sub{color:var(--dim);font-size:12.5px;margin-top:2px}
a.btn{display:inline-block;text-decoration:none}
a.btn:hover{text-decoration:none}
.btn.primary{background:var(--accent);border-color:var(--accent);color:#fff;font-weight:550}
.btn.primary:hover{filter:brightness(1.1)}
"""

JS = """
function openM(i){document.getElementById(i).classList.add('open')}
function closeM(i){document.getElementById(i).classList.remove('open')}
document.addEventListener('click',function(e){if(e.target.classList.contains('mask'))
 e.target.classList.remove('open')});
document.addEventListener('keydown',function(e){if(e.key==='Escape')
 document.querySelectorAll('.mask.open').forEach(function(m){m.classList.remove('open')})});
"""


def modal(mid, title, sub, body, opened=False):
    return (f'<div class="mask{" open" if opened else ""}" id="{mid}"><div class="modal">'
            f'<h3>{title}</h3><p class="sub">{sub}</p>{body}</div></div>')


def login_page(err=""):
    """Вход по PIN: клавиатура как на телефоне, вход по последней цифре."""
    n = len(PIN)
    warn = f'<div class="msg err">{html.escape(err)}</div>' if err else ""
    dots = "".join('<i></i>' for _ in range(n))
    keys = "".join(f'<button type="button" onclick="tap(\'{d}\')">{d}</button>'
                   for d in "123456789")
    return f"""<!doctype html><html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Вход</title><style>{CSS}</style></head><body><div class="login">
{logo_html()}
<p>Введите PIN — {n} цифры</p>{warn}
<div class="dots" id="d">{dots}</div>
<form method="post" action="/login" id="f"><input type="hidden" name="pin" id="p"></form>
<div class="pad">{keys}
<button type="button" class="sec" onclick="clr()">Стереть</button>
<button type="button" onclick="tap('0')">0</button>
<button type="button" class="sec" onclick="del()">←</button></div>
<script>
var v="",N={n},p=document.getElementById("p"),f=document.getElementById("f");
function draw(){{var ds=document.querySelectorAll("#d i");
 for(var i=0;i<ds.length;i++)ds[i].className=i<v.length?"f":""}}
function tap(d){{if(v.length>=N)return;v+=d;draw();
 if(v.length===N){{p.value=v;setTimeout(function(){{f.submit()}},120)}}}}
function del(){{v=v.slice(0,-1);draw()}}
function clr(){{v="";draw()}}
document.addEventListener("keydown",function(e){{
 if(e.key>="0"&&e.key<="9")tap(e.key);
 else if(e.key==="Backspace")del()}});
</script></div></body></html>"""


def limits_modal(u):
    name = html.escape(u["name"])
    doms = "\n".join(u.get("block_domains", []))
    tlds = set(t if t.startswith(".") else "." + t for t in u.get("block_tld", []))
    zones = "".join(
        f'<label class="zone"><input type="checkbox" name="tld" value="{z}"'
        f'{" checked" if z in tlds else ""}><b>{z}</b><span>{cn}</span></label>'
        for z, cn in ZONES)
    return modal(
        f"lim-{name}", f"Что запрещено: {name}",
        "Запреты действуют только на этого человека, остальных не касаются.",
        f'<form method="post" action="/limits">'
        f'<input type="hidden" name="name" value="{name}">'
        f'<label>Закрыть сайты этих стран</label><div class="zones">{zones}</div>'
        f'<label>Закрыть отдельные сайты</label>'
        f'<textarea name="domains" placeholder="casino.com&#10;example.org">{html.escape(doms)}</textarea>'
        f'<div class="hint">По одному сайту в строке: напечатали адрес — нажали Enter — '
        f'печатаете следующий. Без «https://» и без «www». Закрывается и сам сайт, и всё '
        f'внутри него: например «example.org» закроет и «shop.example.org».</div>'
        f'<div class="actions"><button type="button" onclick="closeM(\'lim-{name}\')">Отмена</button>'
        f'<button class="primary">Сохранить</button></div></form>')


def analytics_modal():
    a = analytics()
    if a["days"]:
        mx = max(v for _, v in a["days"]) or 1
        cols = "".join(
            f'<div class="col"><i style="height:{max(3,int(v/mx*100))}%" '
            f'title="{human(v)}"></i><em>{d}</em></div>' for d, v in a["days"])
        chart = (f'<label>Сколько уходило по дням</label><div class="chart">{cols}</div>'
                 f'<div class="hint">Высота столбика — расход за день. '
                 f'Самый большой: {human(mx)}.</div>')
    else:
        chart = ('<label>История по дням</label>'
                 '<div class="hint">Сервер пока не ведёт дневник расхода. Включите — '
                 'и через сутки здесь появится график по дням.</div>'
                 '<form method="post" action="/act" style="margin-top:10px">'
                 '<input type="hidden" name="op" value="vnstat">'
                 '<button class="primary">Включить историю по дням</button></form>')
    return modal(
        "analytics", "Аналитика", "Сколько трафика израсходовано и что происходит сейчас.",
        f'<div class="facts">'
        f'<div class="fact"><b>получено из интернета</b><span>{human(a["rx"])}</span></div>'
        f'<div class="fact"><b>отправлено в интернет</b><span>{human(a["tx"])}</span></div>'
        f'<div class="fact"><b>всего израсходовано</b><span>{human(a["total"])}</span></div>'
        f'<div class="fact"><b>подключений прямо сейчас</b><span>{html.escape(a["conns"])}</span>'
        f'</div></div>'
        f'<div class="hint">«Подключений прямо сейчас» — сколько соединений открыто через VPN '
        f'в эту секунду. Одно устройство обычно держит несколько: браузер, почта, мессенджеры. '
        f'Число прыгает — это нормально.<br>Счётчики трафика считаются с последнего включения '
        f'сервера ({html.escape(a["iface"])}), а не за месяц.</div>'
        f'{chart}'
        f'<div class="actions"><button onclick="closeM(\'analytics\')">Закрыть</button></div>')


def links_modal():
    dom = domain_info().get("host", "")
    ip = server_status()["ip"]
    rows = []
    for f, label in (("full", "умный: РФ напрямую"), ("strict", "всё через Латвию"),
                     ("selective", "только нужные сервисы")):
        cells = ""
        if dom:
            cells += f'<code>http://{html.escape(dom)}:8080/{f}.json</code><span class="tag">по имени</span>'
        cells += f'<code>http://{html.escape(ip)}:8080/{f}.json</code><span class="tag">по адресу</span>'
        rows.append(f'<div class="linkrow"><span class="mode">{label}</span>{cells}</div>')
    return modal(
        "links", "Ссылки на настройки", "Работают, только пока идёт выдача конфига.",
        "".join(rows) +
        '<div class="hint">Ссылка «по имени» продолжит работать даже после смены адреса '
        'сервера — берите её. Друзьям выдаётся только «умный» режим.</div>'
        '<div class="actions"><button onclick="closeM(\'links\')">Закрыть</button></div>')


def server_modal():
    st, dom = server_status(), domain_info()
    alive = st["singbox"] == "active"
    left = dom.get("days_left")
    if left is None:
        dstate = '<span class="pill mut">срок неизвестен</span>'
    elif left < 30:
        dstate = f'<span class="pill bad">пора продлить: {left} дн.</span>'
    elif left < 90:
        dstate = f'<span class="pill off">осталось {left} дн.</span>'
    else:
        dstate = f'<span class="pill on">оплачен ещё {left} дн.</span>'
    links = []
    if dom.get("panel_url"):
        links.append(f'<a href="{html.escape(dom["panel_url"])}" target="_blank">открыть домен у регистратора</a>')
    if dom.get("dns_url"):
        links.append(f'<a href="{html.escape(dom["dns_url"])}" target="_blank">изменить DNS-запись</a>')
    nports = len([p for p in st["ports"].split() if p.strip()])
    return modal(
        "server", "Сервер и домен", "Здоровье сервера и сроки оплаты домена.",
        f'<div class="facts">'
        f'<div class="fact"><b>сервер VPN</b>'
        f'<span class="pill {"on" if alive else "bad"}">{"работает" if alive else "не работает"}</span></div>'
        f'<div class="fact"><b>запасные каналы</b><span>{nports}: {html.escape(st["ports"])}</span></div>'
        f'<div class="fact"><b>адрес сервера</b><span>{html.escape(st["ip"])}</span></div>'
        f'<div class="fact"><b>маскируется под сайт</b><span>{html.escape(st["decoy"])}</span></div>'
        f'<div class="fact"><b>имя сервера</b><span>{html.escape(dom.get("host","—"))}</span></div>'
        f'<div class="fact"><b>домен оплачен до</b><span>{html.escape(dom.get("expires","—"))}</span>'
        f'{dstate}</div>'
        f'<div class="fact"><b>регистратор</b><span>{html.escape(dom.get("registrar","—"))}</span></div>'
        f'<div class="fact"><b>работает без перезагрузки</b><span>{html.escape(st["uptime"])}</span></div>'
        f'</div>'
        f'<div class="hint">Запасные каналы — это разные «двери» в сервер. Если одну перекроют, '
        f'устройства сами уйдут в другую, и вы этого не заметите.<br>'
        f'«Маскируется под сайт» — под каким известным сайтом сервер прячет соединение, '
        f'чтобы его не приняли за VPN.</div>'
        f'{"<div class=hint>" + " · ".join(links) + "</div>" if links else ""}'
        f'<div class="actions"><button onclick="closeM(\'server\')">Закрыть</button></div>')


def add_modal():
    return modal(
        "add", "Новый человек",
        "У каждого будет свой ключ — его можно отключить, не трогая остальных.",
        '<form method="post" action="/act">'
        '<input type="hidden" name="op" value="add">'
        '<label>Имя латинскими буквами</label>'
        '<input name="name" placeholder="например sasha-tpk" required '
        'pattern="[A-Za-z0-9._-]+" title="латинские буквы, цифры, дефис">'
        '<div class="hint">Русские буквы и пробелы не подойдут — имя используется в ссылках.</div>'
        '<div class="actions"><button type="button" onclick="closeM(\'add\')">Отмена</button>'
        '<button class="primary">Создать и показать настройки</button></div></form>')


def zone_words(tlds):
    names = dict(ZONES)
    return [names.get(t, t.lstrip(".").upper()) for t in tlds]


def qr_card(url, size=228, cap="Наведите камеру телефона на код", offer_install=False):
    """QR вместе с логотипом: тёмная фирменная карточка, внутри белая плитка кода.
    Логотип рядом, а не поверх кода — так он не съедает модули и код читается
    даже с потёртого скриншота."""
    svg = qr_svg(url)
    # В памятке (offer_install=False) кнопки быть не должно: файл уезжает человеку
    # и там форма панели никуда не ведёт.
    fix = ('<form method="post" action="/act" style="margin-top:8px">'
           '<input type="hidden" name="op" value="qrencode">'
           '<button>Включить QR-коды</button></form>' if offer_install else "")
    inner = (f'<div class="qrtile">{svg}</div><div class="qrcap">{html.escape(cap)}</div>'
             if svg else
             '<div class="qrcap" style="max-width:220px">QR не построен: на сервере нет '
             'qrencode. Отправьте ссылку текстом.</div>' + fix)
    return (f'<div class="qrcard" style="--qr:{size}px">'
            f'<div class="qrlogo">{logo_html()}</div>{inner}</div>')


APP_URL = "https://apps.apple.com/app/id6673731168"

GUIDE_CSS = """
:root{--bg:#0c0e12;--card:#161a22;--card2:#1c212c;--line:#262c39;--fg:#eef1f7;
--dim:#9aa4b8;--faint:#6d768a;--accent:#5b8dff;--ok:#41d19b}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font-size:15px;line-height:1.55;
font-family:-apple-system,BlinkMacSystemFont,'SF Pro Text','Segoe UI',Roboto,sans-serif;
-webkit-font-smoothing:antialiased}
.sheet{max-width:820px;margin:0 auto;padding:34px 22px 60px}
header{display:flex;align-items:center;gap:16px;flex-wrap:wrap;
padding-bottom:18px;border-bottom:1px solid var(--line);margin-bottom:26px}
svg.logo{height:24px;width:auto;flex:none}
h1{font-size:20px;font-weight:640;margin:0;padding-left:16px;border-left:1px solid var(--line)}
header .sp{flex:1}
.lead{color:var(--dim);font-size:14.5px;margin:0 0 26px;max-width:640px}
.split{display:flex;gap:26px;flex-wrap:wrap;align-items:flex-start;margin-bottom:26px}
.split .col{flex:1 1 300px;min-width:280px}
.qrcard{display:inline-flex;flex-direction:column;align-items:center;gap:13px;
background:linear-gradient(160deg,#1e2431,#12151c);border:1px solid var(--line);
border-radius:20px;padding:20px 20px 16px}
.qrcard svg.logo{height:19px;opacity:.95}
.qrtile{background:#fff;border-radius:14px;padding:11px;line-height:0}
.qrtile svg.qr{width:var(--qr,228px);height:var(--qr,228px);display:block}
.qrcap{font-size:11.5px;color:var(--faint);text-align:center;letter-spacing:.03em}
h2{font-size:12px;font-weight:600;letter-spacing:.07em;text-transform:uppercase;
color:var(--faint);margin:0 0 14px}
.steps{counter-reset:s;margin:0;padding:0;list-style:none}
.steps li{counter-increment:s;position:relative;padding-left:36px;margin-bottom:16px}
.steps li:before{content:counter(s);position:absolute;left:0;top:1px;width:24px;height:24px;
border-radius:50%;background:var(--card2);border:1px solid var(--line);color:var(--dim);
font-size:12px;line-height:22px;text-align:center}
.steps b{font-weight:600}
.steps .sub{color:var(--dim);font-size:13.5px;margin-top:3px}
.card{background:var(--card);border:1px solid var(--line);border-radius:15px;
padding:18px 20px;margin-bottom:16px}
code{font:12.5px ui-monospace,SFMono-Regular,Menlo,monospace;word-break:break-all;
background:var(--card2);border-radius:6px;padding:2px 6px}
.link{display:block;background:var(--card2);border:1px solid var(--line);border-radius:11px;
padding:11px 13px;margin:10px 0 4px;font:13px ui-monospace,SFMono-Regular,Menlo,monospace;
word-break:break-all;color:var(--fg)}
a{color:var(--accent);text-decoration:none}
a:hover{text-decoration:underline}
ul.plain{margin:8px 0 0;padding-left:20px;color:var(--dim);font-size:13.5px}
ul.plain li{margin-bottom:5px}
.foot{color:var(--faint);font-size:12px;margin-top:28px;padding-top:16px;
border-top:1px solid var(--line)}

.np{font:inherit;font-size:13px;border:1px solid var(--line);background:var(--card2);
color:var(--fg);padding:7px 13px;border-radius:9px;cursor:pointer}
/* На печати/в PDF — светлая тема, иначе уходит тонна тонера и плохо читается. */
@media print{
 body{background:#fff;color:#111}
 .sheet{padding:0}
 .card,.link,code{background:#f4f5f8;border-color:#dfe3ea;color:#111}
 .qrcard{background:#f4f5f8;border-color:#dfe3ea}
 .steps li:before{background:#eef0f4;border-color:#dfe3ea;color:#555}
 .lead,.dim,.qrcap,ul.plain,.foot,.steps .sub{color:#555}
 svg.logo path,svg.logo rect{fill:#111}
 .np{display:none}
 h1{border-color:#dfe3ea}
 header{border-color:#dfe3ea}
}
"""


def deep_link(url, name):
    """Ссылка-схема приложения sing-box: камера открывает не сайт, а сам
    импорт профиля. Формат из документации: url кодируется в параметре,
    имя профиля — во фрагменте после #."""
    return ("sing-box://import-remote-profile?url="
            + urllib.parse.quote(url, safe="") + "#" + urllib.parse.quote(name))


def guide_html(name):
    """Памятка для человека: одним файлом, без интернета — логотип, QR и что
    нажимать. Её можно скачать и переслать: внутри всё, включая код.
    Адрес сервера по IP и список запретов в памятку НЕ идут: гостю они не нужны,
    а IP лишний раз светить незачем."""
    st, dom = server_status(), domain_info()
    host = dom.get("host") or st["ip"]
    url = f"http://{host}:8080/full.json"
    nm = html.escape(name)
    deep = deep_link(url, name)

    return f"""<!doctype html><html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>FutureFlow — доступ для {nm}</title><style>{GUIDE_CSS}</style></head><body>
<div class="sheet">
<header>{logo_html()}<h1>Доступ к VPN</h1><span class="sp"></span>
<button class="np" onclick="window.print()">Сохранить в PDF</button></header>

<p class="lead">Личный доступ для <b>{nm}</b>. Российские сайты идут напрямую и не
тормозят, зарубежные — через сервер в Латвии. Настройка занимает пару минут:
установить приложение и один раз добавить профиль.</p>

<div class="split">
  <div class="col" style="flex:0 0 auto">{qr_card(deep, cap="Код открывает приложение, а не сайт")}</div>
  <div class="col">
    <h2>Что делать</h2>
    <ol class="steps">
      <li><b>Сначала установите приложение sing-box VT</b>
        <div class="sub">iPhone, iPad и Mac — App Store, разработчик VIRAL TECH INC.:
        <a href="{APP_URL}">{APP_URL}</a>. Приложение бесплатное. Пока его нет,
        код сканировать бессмысленно.</div></li>
      <li><b>Наведите камеру на код</b>
        <div class="sub">Телефон предложит открыть в sing-box — согласитесь.
        В приложении нажмите <b>Import</b>, затем <b>Create</b>. Галочку
        <i>Auto update</i> и интервал <i>60</i> оставьте как есть.</div></li>
      <li><b>Не предложил открыть приложение — добавьте вручную</b>
        <div class="sub">Вкладка Profiles → «+» → Type: <i>Remote</i> →
        вставьте адрес в поле URL → Create.</div>
        <div class="link">{html.escape(url)}</div></li>
      <li><b>Включите переключатель на вкладке Dashboard</b>
        <div class="sub">Первый раз система попросит разрешение на VPN-профиль —
        согласитесь. Дальше всё включается одной кнопкой.</div></li>
      <li><b>Проверьте</b>
        <div class="sub">Откройте <code>ipinfo.io</code> — страна должна быть
        Латвия (LV). Российские сайты при этом работают как обычно.</div></li>
    </ol>
  </div>
</div>

<div class="card"><h2>Важное</h2><ul class="plain">
<li>Ссылка работает, только пока владелец держит выдачу открытой. Не успели —
попросите открыть ещё раз.</li>
<li>Ключ персональный: по нему видно, чей он. Передавать другим нельзя — такой
ключ отключают, остальные при этом продолжают работать.</li>
<li>Пропал интернет при включённом VPN — выключите и включите переключатель;
не помогло, напишите владельцу.</li>
</ul></div>

<div class="foot">FutureFlow · памятка собрана панелью управления доступом.
Внутри файла нет паролей — только ссылка на профиль.</div>
</div></body></html>"""


def share_modal(name, opened=True):
    st, dom = server_status(), domain_info()
    host = dom.get("host") or st["ip"]
    url = f"http://{host}:8080/full.json"
    nm = html.escape(name)
    q = urllib.parse.urlencode({"name": name})
    alt = "" if host == st["ip"] else (
        f'<div class="hint">Если по имени не откроется — запасная ссылка по адресу: '
        f'<code>http://{html.escape(st["ip"])}:8080/full.json</code></div>')
    return modal(
        f"cfg-{nm}", f"Настройки для «{nm}»",
        "Покажите код с экрана или отправьте памятку — в ней тот же код и те же шаги.",
        f'<div class="split"><div class="col qrcol">{qr_card(deep_link(url, name), 196, cap="Код открывает приложение", offer_install=True)}</div>'
        f'<div class="col"><ol class="steps">'
        f'<li><b>Приложение sing-box VT</b>'
        f'<div class="sub">App Store, бесплатное. Для iPhone, iPad и Mac.</div></li>'
        f'<li><b>Камера на код → Import → Create</b>'
        f'<div class="sub">Или вручную: New Profile → Type: Remote → ссылка в поле URL.</div></li>'
        f'<li><b>Включить переключатель</b>'
        f'<div class="sub">Система спросит разрешение на VPN — согласиться.</div></li>'
        f'</ol></div></div>'
        f'<div class="linkrow"><code>{html.escape(url)}</code><span class="tag">по имени</span></div>'
        f'{alt}'
        f'<div class="hint">Ссылка отдаёт личный ключ без пароля — закройте выдачу сразу '
        f'после того, как человек импортировал профиль.</div>'
        f'<div class="actions">'
        f'<a class="btn" href="/guide?{q}" target="_blank">Посмотреть памятку</a>'
        f'<a class="btn primary" href="/guide?{q}&amp;dl=1">Скачать и отправить</a>'
        f'<form method="post" action="/act"><input type="hidden" name="op" value="share_stop">'
        f'<button class="danger">Закрыть выдачу</button></form></div>', opened=opened)


def page(msg="", err=False, extra_modal=""):
    st, dom = server_status(), domain_info()
    rows, modals = [], []
    for u in users():
        on = bool(u.get("enabled"))
        prot = bool(u.get("protected"))
        nm = html.escape(u["name"])
        note = f'<div class="note">{html.escape(u.get("note",""))}</div>' if u.get("note") else ""
        nlim = len(u.get("block_domains", [])) + len(u.get("block_tld", []))
        lim = (f'<span class="pill mut">закрыто: {nlim}</span>' if nlim
               else '<span class="note">без ограничений</span>')
        status = ('<span class="pill on">это вы</span>' if prot else
                  f'<span class="pill {"on" if on else "off"}">'
                  f'{"подключён" if on else "отключён"}</span>')
        acts = []
        if not prot:
            acts.append(
                f'<form method="post" action="/act"><input type="hidden" name="op" '
                f'value="{"disable" if on else "enable"}">'
                f'<input type="hidden" name="name" value="{nm}">'
                f'<button>{"Отключить" if on else "Включить"}</button></form>')
        acts.append(f'<button onclick="openM(\'lim-{nm}\')">Ограничения</button>')
        acts.append(f'<form method="get" action="/share">'
                    f'<input type="hidden" name="name" value="{nm}">'
                    f'<button>Настройки</button></form>')
        if not prot:
            acts.append(
                f'<form method="post" action="/act" onsubmit="return confirm(\'Удалить {nm}?\')">'
                f'<input type="hidden" name="op" value="remove">'
                f'<input type="hidden" name="name" value="{nm}">'
                f'<button class="danger">Удалить</button></form>')
        rows.append(f'<tr><td><div class="name">{nm}</div>{note}</td><td>{status}</td>'
                    f'<td>{lim}</td><td><div class="row">{"".join(acts)}</div></td></tr>')
        modals.append(limits_modal(u))

    msg_html = f'<div class="msg{" err" if err else ""}">{html.escape(msg)}</div>' if msg else ""
    body = "".join(rows) or '<tr><td colspan="4" class="note">Пока никого нет</td></tr>'
    left = dom.get("days_left")
    dline = html.escape(dom.get("host", "—")) + (f' · {left} дн. до продления' if left is not None else "")
    return f"""<!doctype html><html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>FutureFlow — доступ к VPN</title><style>{CSS}</style></head><body><div class="wrap">
<header>{logo_html()}<h1>Доступ к VPN</h1><span class="sp"></span>
<button onclick="openM('analytics')">Аналитика</button>
<button onclick="openM('links')">Ссылки</button>
<button onclick="openM('server')">Сервер и домен</button></header>
{msg_html}
<div class="card"><div class="cardhead"><h2>Кто пользуется</h2><span class="sp"></span>
<button class="primary" onclick="openM('add')">Добавить человека</button></div>
<table><tr><th>Имя</th><th>Доступ</th><th>Ограничения</th><th></th></tr>{body}</table>
<div class="status">
<span><b>сервер</b> {"работает" if st["singbox"] == "active" else "не работает"}</span>
<span><b>каналы</b> {html.escape(st['ports'])}</span>
<span><b>адрес</b> {html.escape(st['ip'])}</span>
<span><b>домен</b> {dline}</span>
</div></div>
{add_modal()}{analytics_modal()}{links_modal()}{server_modal()}{''.join(modals)}{extra_modal}
<script>{JS}</script></body></html>"""


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

    def _send(self, body, code=200, cookie=None, disp=None):
        b = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(b)))
        if cookie:
            self.send_header("Set-Cookie", f"sid={cookie}; Path=/; HttpOnly; SameSite=Strict")
        if disp:
            self.send_header("Content-Disposition", disp)
        self.end_headers()
        self.wfile.write(b)

    def _authed(self):
        for part in self.headers.get("Cookie", "").split(";"):
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
        if u.path == "/guide":
            q = urllib.parse.parse_qs(u.query)
            name = q.get("name", [""])[0]
            if not find_user(name):
                return self._send(page("Нет такого человека", err=True))
            body = guide_html(name)
            if q.get("dl"):
                safe = re.sub(r"[^A-Za-z0-9._-]", "-", name) or "guest"
                return self._send(body, disp=f'attachment; filename="futureflow-{safe}.html"')
            return self._send(body)
        if u.path == "/share":
            name = urllib.parse.parse_qs(u.query).get("name", [""])[0]
            if not find_user(name):
                return self._send(page("Нет такого человека", err=True))
            start_share(name)
            return self._send(page(extra_modal=share_modal(name)))
        return self._send(page())

    def do_POST(self):
        if self.path == "/login":
            now = time.time()
            if fails["until"] > now:
                return self._send(login_page(
                    f"Слишком много попыток. Подождите {int(fails['until']-now)} с."))
            pin = self._form().get("pin", [""])[0].strip()
            if secrets.compare_digest(pin, PIN):
                sid = secrets.token_urlsafe(24)
                sessions.add(sid)
                fails.update({"count": 0, "until": 0.0})
                return self._send(page(), cookie=sid)
            fails["count"] += 1
            if fails["count"] >= 5:
                fails.update({"count": 0, "until": now + 300})
                return self._send(login_page("Слишком много попыток. Подождите 5 минут."))
            return self._send(login_page("Неверный PIN."))

        if not self._authed():
            return self._send(login_page())
        form = self._form()

        if self.path == "/limits":
            name = form.get("name", [""])[0]
            lst = users()
            hit = [x for x in lst if x["name"] == name]
            if not hit:
                return self._send(page("Нет такого человека", err=True))
            hit[0]["block_domains"] = [d.strip().lower()
                                       for d in form.get("domains", [""])[0].splitlines() if d.strip()]
            hit[0]["block_tld"] = list(form.get("tld", []))
            save_users(lst)
            code, out = run(["apply"])
            return self._send(page("Ограничения сохранены" if code == 0 else out, err=(code != 0)))

        op = form.get("op", [""])[0]
        name = form.get("name", [""])[0].strip()
        if op == "share_stop":
            stop_share()
            return self._send(page("Выдача закрыта."))
        if op == "qrencode":
            out = sh("apt-get install -y qrencode >/dev/null 2>&1 && echo ok", timeout=180)
            return self._send(page(
                "QR-коды включены — откройте «Настройки» у человека ещё раз."
                if out.endswith("ok") else "Не удалось поставить qrencode — попробуйте позже.",
                err=not out.endswith("ok")))
        if op == "vnstat":
            out = sh("apt-get install -y vnstat >/dev/null 2>&1 && systemctl enable --now vnstat "
                     "&& echo ok", timeout=180)
            return self._send(page(
                "История включена. График появится, когда наберутся данные за сутки."
                if out.endswith("ok") else "Не удалось включить историю — попробуйте позже.",
                err=not out.endswith("ok")))
        if op not in ("add", "enable", "disable", "remove"):
            return self._send(page("Неизвестное действие", err=True))
        code, out = run([op, name], no_share=True)
        if op == "add" and code == 0:
            start_share(name)
            return self._send(page(f"Готово: {name} добавлен", extra_modal=share_modal(name)))
        return self._send(page(out or "Готово", err=(code != 0)))


def _is_panel(pid):
    """Это точно ДРУГОЙ экземпляр панели, а не что-то, где её имя просто
    упомянуто в аргументах.

    Ровно на этом ловились дважды: строка `... python3 scripts/vpn-panel.py`
    попадает в аргументы породившей оболочки (у нас — `bash -c` от sshd), и
    наивный поиск по `ps` убивал собственного родителя вместе с SSH-сессией.
    Поэтому смотрим не «есть ли подстрока», а первые два аргумента процесса:
    у настоящей панели это интерпретатор и путь к самому скрипту, у оболочки —
    `bash` и `-c`.
    """
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as f:
            argv = [x.decode("utf-8", "replace") for x in f.read().split(b"\0") if x]
    except OSError:
        return False
    return (len(argv) >= 2 and "python" in os.path.basename(argv[0])
            and argv[1].endswith("vpn-panel.py"))


def take_over_port():
    """Забрать порт у прежнего экземпляра панели.

    Обрыв SSH не всегда доходит до серверного процесса (sshd не шлёт HUP, если
    связь просто пропала) — старая панель остаётся жить и держит порт, а новая
    падает с `Address already in use`, и лаунчер уходит в бесконечный
    переподключай-упади. Поэтому гасим прежний экземпляр сами. Ищем по /proc,
    а не по pid-файлу: панель от прежней версии его не писала.
    """
    if not os.path.isdir("/proc"):
        return
    skip = {os.getpid(), os.getppid()}
    for entry in os.listdir("/proc"):
        if not entry.isdigit() or int(entry) in skip or not _is_panel(int(entry)):
            continue
        pid = int(entry)
        print(f"[*] Прежняя панель (pid {pid}) держит порт — останавливаю.")
        for sig in (signal.SIGTERM, signal.SIGKILL):
            try:
                os.kill(pid, sig)
            except OSError:
                break
            for _ in range(12):
                time.sleep(0.25)
                try:
                    os.kill(pid, 0)
                except OSError:
                    break
            else:
                continue
            break


def bye(*_):
    stop_share()
    print("\nОстановлено.")
    raise SystemExit(0)


if __name__ == "__main__":
    take_over_port()
    # Туннель рвётся — панель должна уйти сама, а не остаться сиротой с портом.
    for _sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(_sig, bye)
    srv = HTTPServer(("127.0.0.1", PORT), Handler)
    print(f"Панель: http://127.0.0.1:{PORT}/")
    print(f"PIN: {PIN}   (хранится в {PINFILE})")
    print("Снаружи недоступна. С мака: bash scripts/vpn-panel.sh")
    try:
        srv.serve_forever()
    except SystemExit:
        pass
