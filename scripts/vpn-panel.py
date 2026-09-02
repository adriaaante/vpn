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
import base64
import hashlib
import hmac
import html
import json
import os
import re
import secrets
import shutil
import signal
import subprocess
import threading
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
DECOY_SH = os.path.join(REPO, "scripts", "decoy-status.sh")
DECOY_STATUS = os.environ.get("DECOY_STATUS", "/etc/sing-box/decoy-status.json")
# Кто и с какого pid раздаёт сейчас. В файле, а не только в памяти: раздача
# переживает закрытие панели, а новая панель должна знать, что она идёт,
# и уметь её закрыть.
SHARE_STATE = os.environ.get("SHARE_STATE", "/etc/sing-box/share-state.json")
BCAST_STATE = os.environ.get("BCAST_STATE", "/etc/sing-box/broadcast-state.json")
BCAST_LAST = os.environ.get("BCAST_LAST", "/etc/sing-box/broadcast-last.json")
PORT = int(os.environ.get("PANEL_PORT", "8787"))

share_proc = {"name": None, "proc": None}
sessions = set()
fails = {"count": 0, "until": 0.0}
check_proc = {"proc": None}   # идущая проверка узлов (decoy-status.sh)

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


def run(args, timeout=90, no_share=False, extra_env=None):
    env = dict(os.environ, STORE=STORE, CFG=CFG)
    if no_share:
        env["NO_SHARE"] = "1"
    env.update(extra_env or {})
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


def pretty(name):
    """Имя для показа: «owner» в таблице и памятке выглядит неопрятно. Меняется
    только вид — в конфиге и правилах остаётся ровно то имя, что заведено."""
    return name[:1].upper() + name[1:] if name else name


def share_token(name):
    """Персональный кусок ссылки. Раньше у всех был один адрес /full.json —
    и «Auto update» одного человека мог скачать конфиг другого, попав на чужую
    выдачу. Токен постоянный, поэтому ссылка у человека не меняется."""
    lst = users()
    hit = [u for u in lst if u["name"] == name]
    if not hit:
        return ""
    tok = str(hit[0].get("share_token") or "")
    if not tok:
        tok = secrets.token_hex(5)
        hit[0]["share_token"] = tok
        save_users(lst)
    return tok


def share_url(name, host):
    tok = share_token(name)
    return f"http://{host}:8080/{tok}/full.json" if tok else f"http://{host}:8080/full.json"


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


COUNTRY_RU = {"LV": "Латвия", "EE": "Эстония", "LT": "Литва", "FI": "Финляндия",
              "SE": "Швеция", "NL": "Нидерланды", "DE": "Германия", "FR": "Франция",
              "PL": "Польша", "GB": "Британия", "US": "США", "RU": "Россия"}
# Город приходит по-английски — рядом с русской страной это смотрится небрежно.
# Список короткий: только те города, куда сервер реально может переехать.
CITY_RU = {"Riga": "Рига", "Tallinn": "Таллин", "Vilnius": "Вильнюс",
           "Helsinki": "Хельсинки", "Stockholm": "Стокгольм", "Amsterdam": "Амстердам",
           "Frankfurt am Main": "Франкфурт", "Frankfurt": "Франкфурт",
           "Warsaw": "Варшава", "Paris": "Париж", "London": "Лондон", "Vienna": "Вена"}
_geo = {}


def flag(cc):
    """Флаг страны из её кода — рисуется шрифтом, картинки не нужны."""
    cc = (cc or "").strip().upper()
    if len(cc) != 2 or not cc.isalpha():
        return ""
    return chr(0x1F1E6 + ord(cc[0]) - 65) + chr(0x1F1E6 + ord(cc[1]) - 65)


def server_geo(ip):
    """Где физически стоит сервер и чей это провайдер. Спрашиваем с самого сервера
    и запоминаем: адрес и локация меняются раз в год, а окно открывают часто —
    ходить в сеть на каждый показ незачем."""
    if not ip or ip in ("—", ""):
        return {}
    if ip in _geo:
        return _geo[ip]
    try:
        d = json.loads(sh(f"curl -fsSL --max-time 5 https://ipinfo.io/{ip}/json") or "{}")
    except json.JSONDecodeError:
        d = {}
    org = str(d.get("org", ""))
    info = {"city": str(d.get("city", "")), "country": str(d.get("country", "")),
            # org приходит как «AS57494 EDIS GLOBAL SRL» — номер сети человеку не нужен
            "org": re.sub(r"^AS\d+\s+", "", org), "tz": str(d.get("timezone", ""))}
    if info["city"] or info["country"]:
        _geo[ip] = info
    return info


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


def decoy_status():
    """Последний срез доступности узлов (пишет scripts/decoy-status.sh).
    Пусто — значит проверку ещё ни разу не запускали."""
    try:
        d = json.load(open(DECOY_STATUS))
    except (OSError, json.JSONDecodeError):
        return {}
    return d if isinstance(d, dict) else {}


def check_running():
    p = check_proc.get("proc")
    return bool(p and p.poll() is None)


def start_check():
    """Запустить проверку узлов ФОНОМ: она идёт около минуты (по очереди поднимает
    мини сервер+клиент на каждый домен), а держать HTTP-ответ всё это время нельзя —
    страница выглядела бы зависшей."""
    if check_running():
        return
    check_proc["proc"] = subprocess.Popen(
        # OUT, а не DECOY_STATUS: так называется переменная в самом скрипте. По
        # умолчанию пути совпадают, поэтому расхождение не всплыло бы до первой
        # нестандартной установки.
        ["bash", DECOY_SH], env=dict(os.environ, CFG=CFG, OUT=DECOY_STATUS),
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)


def ago(ts):
    """«5 минут назад» — владельцу важна свежесть среза, а не точное время."""
    try:
        d = int(time.time()) - int(ts)
    except (TypeError, ValueError):
        return "—"
    if d < 90:
        return "только что"
    if d < 3600:
        return f"{d // 60} мин. назад"
    if d < 86400:
        return f"{d // 3600} ч. назад"
    return f"{d // 86400} дн. назад"


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
/* Заблокированная кнопка обязана ВЫГЛЯДЕТЬ заблокированной: .primary красит фон
   сам и перебивает серый вид от браузера. */
button[disabled]{opacity:.45;cursor:default}
button[disabled]:hover{border-color:var(--line);filter:none}
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
.msg.warn{background:rgba(240,164,65,.09);border-color:rgba(240,164,65,.32);
font:13.5px/1.5 -apple-system,BlinkMacSystemFont,'SF Pro Text','Segoe UI',Roboto,sans-serif;
display:flex;gap:14px;align-items:center;flex-wrap:wrap}
.msg.warn span{flex:1;min-width:240px}
code{font:12.5px ui-monospace,SFMono-Regular,Menlo,monospace;word-break:break-all}
.linkrow{display:flex;flex-wrap:wrap;gap:8px;align-items:center;padding:9px 11px;
background:var(--card2);border-radius:9px;margin-bottom:8px}
.linkrow .mode{min-width:150px;font-size:12.5px;color:var(--dim)}
.linkrow code{flex:1 1 auto;min-width:0}
/* Главная строка — ссылка, которую отправляют: крупнее и с кнопкой рядом, а не
   в самом низу окна, куда она уезжала от глаз. */
.linkrow.big{padding:12px 14px;gap:12px;background:var(--card2);
border:1px solid var(--line)}
.linkrow.big code{font-size:13.5px}
.linkrow.big .cp{font-size:13px;padding:8px 16px;font-weight:550}
details.fold{margin:14px 0 0}
details.fold summary{cursor:pointer;list-style:none;color:var(--accent);font-size:12.5px;
padding:4px 0;display:inline-flex;align-items:center;gap:7px}
details.fold summary::-webkit-details-marker{display:none}
details.fold summary:before{content:"▸";font-size:10px;transition:transform .15s}
details.fold[open] summary:before{transform:rotate(90deg)}
.linkrow .cp{flex:none;margin-left:auto;font-size:12px;padding:4px 11px;border-radius:8px;
background:var(--card);white-space:nowrap}
button.ok,button.ok:hover{background:rgba(65,209,155,.15);border-color:var(--ok);color:var(--ok)}
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
.modal{position:relative;background:var(--card);border:1px solid var(--line);border-radius:16px;
width:min(760px,100%);padding:22px 24px;max-height:86vh;overflow:auto;
box-shadow:0 24px 60px rgba(0,0,0,.55)}
.modal h3{margin:0 0 4px;font-size:17px;font-weight:640;padding-right:36px}
.modal .x{position:absolute;top:14px;right:14px;width:30px;height:30px;padding:0;
display:grid;place-items:center;font-size:13px;line-height:1;color:var(--faint);
background:transparent;border:1px solid transparent;border-radius:9px;cursor:pointer}
.modal .x:hover{background:var(--card2);border-color:var(--line);color:var(--fg)}
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
/* Копирование ссылки одной кнопкой. Панель открыта по 127.0.0.1 — это защищённый
   контекст, поэтому clipboard API доступен; execCommand оставлен запасным путём
   на случай нестандартного доступа к панели (не localhost). */
function cpText(t,btn){
  var old=btn.textContent;
  function done(){btn.textContent='Скопировано ✓';btn.classList.add('ok');
    setTimeout(function(){btn.textContent=old;btn.classList.remove('ok')},1700)}
  function legacy(){var ta=document.createElement('textarea');ta.value=t;
    ta.style.position='fixed';ta.style.opacity='0';document.body.appendChild(ta);
    ta.focus();ta.select();
    try{document.execCommand('copy');done()}catch(e){btn.textContent='Не вышло — скопируйте вручную'}
    document.body.removeChild(ta)}
  if(navigator.clipboard&&navigator.clipboard.writeText){
    navigator.clipboard.writeText(t).then(done,legacy)
  }else legacy();
}
function cpRow(btn){cpText(btn.parentNode.querySelector('code').textContent.trim(),btn)}
function cpSel(sel,btn){var e=document.querySelector(sel);if(e)cpText(e.textContent.trim(),btn)}
"""


def modal(mid, title, sub, body, opened=False):
    """Крестик рисуется ЗДЕСЬ, а не в каждом окне: так он гарантированно на одном
    месте и одного вида во всех окнах. Escape и клик по фону тоже закрывают."""
    return (f'<div class="mask{" open" if opened else ""}" id="{mid}"><div class="modal">'
            f'<button type="button" class="x" aria-label="Закрыть" '
            f'onclick="closeM(\'{mid}\')">&#10005;</button>'
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
        )


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
        'сервера — берите её. Друзьям выдаётся только «умный» режим.</div>')


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
    geo = server_geo(st["ip"])
    # Автопереезд по DNS (ip-sync.timer): владельцу важно видеть, что он включён —
    # иначе при следующей смене IP снова придётся идти через VNC.
    sync_on = sh("systemctl is-active ip-sync.timer") == "active"
    sync_last = sh("journalctl -u ip-sync -n 1 --no-pager -o cat 2>/dev/null")
    country = COUNTRY_RU.get(geo.get("country", ""), geo.get("country", ""))
    city = CITY_RU.get(geo.get("city", ""), geo.get("city", ""))
    where = " · ".join(x for x in (city, country) if x) or "—"
    fl = flag(geo.get("country", ""))
    return modal(
        "server", "Сервер и домен", "Где стоит сервер, здоровье и сроки оплаты домена.",
        f'<div class="facts">'
        f'<div class="fact"><b>сервер VPN</b>'
        f'<span class="pill {"on" if alive else "bad"}">{"работает" if alive else "не работает"}</span></div>'
        f'<div class="fact"><b>где находится</b>'
        f'<span>{fl + " " if fl else ""}{html.escape(where)}</span></div>'
        f'<div class="fact"><b>провайдер</b><span>{html.escape(geo.get("org") or "—")}</span></div>'
        f'<div class="fact"><b>часовой пояс сервера</b><span>{html.escape(geo.get("tz") or "—")}</span></div>'
        f'<div class="fact"><b>автопереезд по DNS</b>'
        f'<span class="pill {"on" if sync_on else "off"}">{"включён" if sync_on else "не установлен"}</span></div>'
        f'<div class="fact"><b>запасные каналы</b><span>{nports}: {html.escape(st["ports"])}</span></div>'
        f'<div class="fact"><b>адрес сервера</b><span>{html.escape(st["ip"])}</span></div>'
        f'<div class="fact"><b>маскируется под сайт</b><span>{html.escape(st["decoy"])}</span></div>'
        f'<div class="fact"><b>имя сервера</b><span>{html.escape(dom.get("host","—"))}</span></div>'
        f'<div class="fact"><b>домен оплачен до</b><span>{html.escape(dom.get("expires","—"))}</span>'
        f'{dstate}</div>'
        f'<div class="fact"><b>регистратор</b><span>{html.escape(dom.get("registrar","—"))}</span></div>'
        f'<div class="fact"><b>работает без перезагрузки</b><span>{html.escape(st["uptime"])}</span></div>'
        f'</div>'
        f'<div class="hint">Страна сервера — это страна, которую видят зарубежные сайты '
        f'у вас и у ваших людей.<br>'
        f'Автопереезд: сменили IP у хостера → на маке <code>bash scripts/vpn-migrate.sh '
        f'&lt;новый-IP&gt;</code> — сервер подхватит адрес из DNS сам, через VNC ходить не надо.'
        f'{(" Последняя запись: " + html.escape(sync_last)) if sync_last else ""}<br>'
        f'Запасные каналы — это разные «двери» в сервер. Если одну перекроют, '
        f'устройства сами уйдут в другую, и вы этого не заметите.<br>'
        f'«Маскируется под сайт» — под каким известным сайтом сервер прячет соединение, '
        f'чтобы его не приняли за VPN.</div>'
        f'{"<div class=hint>" + " · ".join(links) + "</div>" if links else ""}'
        f'{qrencode_offer()}'
        )


def qrencode_offer():
    """Кнопка установки qrencode — только если его на сервере нет. Без него в
    памятке не строится QR sing-box (узлы Shadowrocket рисует сам телефон)."""
    if shutil.which("qrencode"):
        return ""
    return ('<div class="hint" style="margin-top:14px">На сервере нет <code>qrencode</code> — '
            'в памятке не строится QR для sing-box, остаётся только ссылка текстом.</div>'
            '<form method="post" action="/act" style="margin-top:8px">'
            '<input type="hidden" name="op" value="qrencode">'
            '<button class="primary">Включить QR-коды</button></form>')


NODE_STATE = {
    "active_ok":   ("on",  "работает сейчас"),
    "active_fail": ("bad", "активен, но не отвечает"),
    "ready":       ("mut", "готов к переходу"),
    "dead":        ("off", "не годится"),
}


def nodes_modal(opened=False):
    """Окно «Узлы»: какой домен-прикрытие доступен, а какой нет.

    Нужно прежде всего для Shadowrocket: там узлы добавляются по одному и
    переключаются РУКАМИ, поэтому владельцу надо видеть, какой сейчас рабочий.
    В sing-box этот вопрос не стоит — он перебирает узлы сам.
    """
    st = server_status()
    d = decoy_status()
    res = d.get("results") or {}
    active = d.get("active") or st["decoy"]
    # Показываем весь список, даже если срез старый или его нет: пустая таблица
    # выглядела бы поломкой.
    domains = list(DECOYS)
    for extra in (active, *res.keys()):
        if extra and extra not in domains and "[" not in extra and len(extra) < 40:
            domains.insert(0, extra)

    rows = []
    for dom in domains:
        state = res.get(dom)
        # Активный узел мог смениться уже ПОСЛЕ проверки (это делает decoy-monitor
        # сам, раз в 15 минут) — тогда «готов к переходу» уже неправда: он несёт
        # клиентов прямо сейчас. А вот «не годится» у активного НЕ переписываем:
        # это как раз то, что владельцу надо увидеть.
        if dom == st["decoy"] and state == "ready":
            state = "active_ok"
        cls, word = NODE_STATE.get(state, ("mut", "не проверялся"))
        now = ' <span class="tag">сейчас на сервере</span>' if dom == st["decoy"] else ""
        rows.append(f'<tr><td><div class="name">{html.escape(decoy_label(dom))}</div>'
                    f'<div class="note">{html.escape(dom)}</div></td>'
                    f'<td><span class="pill {cls}">{word}</span>{now}</td></tr>')

    if check_running():
        head = ('<div class="msg">Проверяю узлы — это занимает около минуты. '
                'Закройте окно и откройте снова, чтобы увидеть результат.</div>')
    elif d:
        head = (f'<div class="hint" style="margin:0 0 14px">Последняя проверка: '
                f'<b>{ago(d.get("checked_at"))}</b> (заняла {d.get("took", "?")} с).</div>')
    else:
        head = ('<div class="hint" style="margin:0 0 14px">Узлы ещё не проверялись — '
                'нажмите «Проверить сейчас».</div>')

    # Порты бывают неизвестны (нет ss или демон лежит) — тогда строка про каналы
    # превратилась бы в «сейчас: — — если один перекроют».
    ports_line = ("" if st["ports"] in ("—", "") else
                  f'<div class="hint">Каналы (порты) сейчас: {html.escape(st["ports"])} — '
                  f'если один перекроют, устройства уйдут в другой сами.</div>')
    return modal(
        "nodes", "Узлы", "Какие домены-прикрытия сейчас годятся, а какие нет.",
        head +
        f'<table><tr><th>Узел</th><th>Состояние</th></tr>{"".join(rows)}</table>'
        f'<div class="hint">Сервер держит ОДИН узел за раз — тот, что помечен «сейчас '
        f'на сервере». В <b>sing-box</b> это неважно: приложение перебирает узлы само. '
        f'В <b>Shadowrocket</b> переключение ручное, поэтому человеку нужен именно '
        f'активный узел; остальные он добавляет про запас.<br>'
        f'«Готов к переходу» — домен проверен по петле и подойдёт, если сервер решит '
        f'сменить прикрытие (это делает авто-монитор раз в 15 минут). '
        f'«Не годится» — рукопожатие с этим доменом больше не одалживается.</div>'
        f'{ports_line}'
        f'<div class="actions">'
        f'<form method="post" action="/act"><input type="hidden" name="op" value="check_decoys">'
        f'<button class="primary"{" disabled" if check_running() else ""}>Проверить сейчас</button></form>'
        f'</div>', opened=opened)


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
        '<label>Код на памятку (необязательно)</label>'
        '<input name="pin" inputmode="numeric" pattern="[0-9]*" maxlength="8" '
        'placeholder="4–8 цифр, можно оставить пустым">'
        '<div class="hint">Если задать — памятку получится открыть только с этим кодом. '
        'Код меняется потом в «Настройках».</div>'
        '<div class="actions"><button type="button" onclick="closeM(\'add\')">Отмена</button>'
        '<button class="primary">Создать и показать настройки</button></div></form>')


def qr_card(url, size=228, cap="Наведите камеру телефона на код"):
    """QR вместе с логотипом: тёмная фирменная карточка, внутри белая плитка кода.
    Логотип рядом, а не поверх кода — так он не съедает модули и код читается
    даже с потёртого скриншота. Кнопки «поставить qrencode» здесь нет намеренно:
    карточка уезжает в памятку гостю, где форма панели никуда не ведёт. Поставить
    пакет можно в окне «Сервер и домен»."""
    svg = qr_svg(url)
    tail = f'<div class="qrcap">{html.escape(cap)}</div>' if cap else ""
    inner = (f'<div class="qrtile">{svg}</div>{tail}'
             if svg else
             '<div class="qrcap" style="max-width:220px">QR не построен: на сервере нет '
             'qrencode. Отправьте ссылку текстом.</div>')
    return (f'<div class="qrcard" style="--qr:{size}px">'
            f'<div class="qrlogo">{logo_html()}</div>{inner}</div>')


# Приложения для гостя. sing-box — рекомендуемый (авто-failover по узлам +
# kill-switch), Shadowrocket — запасной: доступен в российском App Store, но узлы
# переключаются вручную.
APP_URL_SB = "https://apps.apple.com/app/id6673731168"   # sing-box VT
APP_URL_SR = "https://apps.apple.com/app/id932747118"    # Shadowrocket
PBKF = os.environ.get("PBKF", "/etc/sing-box/reality_public_key.txt")
# Домены-прикрытия (decoy), на которые может переключить сервер. Тот же список, что
# у decoy-monitor.sh — так активный decoy всегда есть среди узлов для Shadowrocket
# и его получится пометить «активен сейчас».
DECOYS = ["www.apple.com", "www.cloudflare.com", "dl.google.com",
          "addons.mozilla.org", "www.icloud.com", "www.samsung.com"]

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
/* Подшаги внутри раскрывашки: обычная нумерация, без кружков-счётчиков верхнего списка. */
.steps .substeps{list-style:decimal;padding-left:22px;margin:8px 0 12px;counter-reset:none}
.steps .substeps li{counter-increment:none;padding-left:4px;margin-bottom:9px;font-size:13.5px}
.steps .substeps li:before{content:none}
.substeps code,.fbody code{background:rgba(255,255,255,.08);padding:1px 6px;border-radius:5px;font-size:12.5px;white-space:nowrap}
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
/* Замок: тот же вид, что у входа в панель — цифры как на телефоне. */
.lock{max-width:300px;margin:8px auto 34px;text-align:center}
.lock p{color:var(--dim);font-size:13.5px;margin:0 0 18px}
.dots{display:flex;gap:13px;justify-content:center;margin-bottom:22px}
.dots i{width:12px;height:12px;border-radius:50%;border:1.5px solid var(--line);display:block}
.dots i.f{background:var(--accent);border-color:var(--accent)}
.pad{display:grid;grid-template-columns:repeat(3,1fr);gap:11px}
.pad button{font:inherit;font-size:21px;padding:15px 0;border-radius:14px;background:var(--card);
border:1px solid var(--line);color:var(--fg);cursor:pointer}
.pad button:active{background:var(--card2)}
.pad button.sec{font-size:14px;color:var(--dim)}
.err{color:var(--dim);font-size:12.5px;min-height:18px;margin-top:14px}

/* Выбор приложения — вкладки на ЧИСТОМ CSS (без JS): памятку показывают через
   innerHTML после расшифровки ПИНом, а innerHTML не выполняет <script>. Радио +
   `:checked ~` такую вставку переживают, скрипт бы не запустился. */
.apptabs .tabradio{position:absolute;width:1px;height:1px;opacity:0;pointer-events:none}
.opts{display:grid;gap:12px;margin:0 0 20px}
.opt{position:relative;display:flex;gap:14px;align-items:center;cursor:pointer;
background:var(--card2);border:1.5px solid var(--line);border-radius:16px;padding:15px 16px;
transition:border-color .15s,box-shadow .15s}
.opt .ic{flex:none;width:44px;height:44px;border-radius:12px;display:grid;place-items:center;
font-size:22px;background:var(--card)}
.opt .t{flex:1;min-width:0}
.opt .t b{display:block;font-size:15.5px}
.opt .t span{display:block;color:var(--dim);font-size:12.5px;margin-top:2px}
.opt .pick{flex:none;width:23px;height:23px;border-radius:50%;border:2px solid var(--line);
display:grid;place-items:center;color:#fff;transition:all .15s}
.opt .badge{position:absolute;top:-9px;right:14px;font-size:10.5px;font-weight:700;
letter-spacing:.02em;background:var(--ok);color:#04130d;padding:3px 9px;border-radius:999px}
.opt .badge.grey{background:var(--card2);color:var(--dim);border:1px solid var(--line);font-weight:600}
#app-sb:checked~.opts .opt-sb,#app-sr:checked~.opts .opt-sr{border-color:var(--accent);
box-shadow:0 0 0 4px rgba(91,141,255,.16)}
#app-sb:checked~.opts .opt-sb .pick,#app-sr:checked~.opts .opt-sr .pick{
background:var(--accent);border-color:var(--accent)}
#app-sb:checked~.opts .opt-sb .pick::after,#app-sr:checked~.opts .opt-sr .pick::after{
content:"✓";font-size:13px;font-weight:800}
.panel{display:none}
#app-sb:checked~.panels .panel-sb,#app-sr:checked~.panels .panel-sr{display:block}
.panel>h2:first-child{margin-top:0}
.note{font-size:13px;border-radius:12px;padding:11px 14px;margin:0 0 16px;line-height:1.5}
.note.ok{background:rgba(65,209,155,.1);color:var(--ok)}
.note.warn{background:rgba(240,164,65,.1);color:#f0a441}
/* Узлы для Shadowrocket: активный крупно, запасные — компактной сеткой. */
.node{border:1px solid var(--line);border-radius:14px;padding:14px;margin-bottom:12px;
background:var(--card2)}
.node.live{border-color:var(--ok)}
.node .nh{display:flex;align-items:center;gap:8px;margin-bottom:11px}
.node .nn{font-weight:600;font-size:14px}
.node .badge{font-size:10px;font-weight:700;color:#04130d;background:var(--ok);
padding:2px 8px;border-radius:999px}
.node .qrtile{margin:0 auto 11px}
.node .link{margin:0}
.sect-note{color:var(--dim);font-size:12.5px;margin:18px 0 10px}
/* Узел-кнопка: весь заголовок кликабелен, по нажатию телефон рисует QR. */
.nodebtn{display:flex;align-items:center;gap:8px;width:100%;text-align:left;cursor:pointer;
background:transparent;border:0;padding:0;margin:0 0 11px;color:var(--fg);font:inherit}
.nodebtn:hover{border:0}
.nodebtn .nn{flex:1}
.nodebtn .chev{font-size:11px;color:var(--accent);white-space:nowrap}
.qrslot{display:none}
.qrslot svg{display:block;width:200px;max-width:100%;height:auto;background:#fff;
padding:10px;border-radius:12px;margin:0 auto}
/* Раскрывашка «Не получается…»: нативный details — работает и после innerHTML. */
details.fold{margin:10px 0 0}
details.fold summary{cursor:pointer;list-style:none;display:inline-flex;align-items:center;
gap:7px;color:var(--accent);font-size:13.5px;padding:6px 0;-webkit-tap-highlight-color:transparent}
details.fold summary::-webkit-details-marker{display:none}
details.fold summary:before{content:"▸";font-size:11px;transition:transform .15s}
details.fold[open] summary:before{transform:rotate(90deg)}
.fbody{background:var(--card2);border:1px solid var(--line);border-radius:12px;
padding:14px 16px;margin-top:8px;font-size:13.5px;color:var(--dim);line-height:1.55}
.fbody p{margin:0 0 10px}
.fbody .link{margin:6px 0 0}
.openbtn{display:inline-block;background:var(--accent);color:#fff;font-weight:600;
font-size:14px;padding:11px 18px;border-radius:11px;text-decoration:none;margin:2px 0 12px}
.openbtn:hover{text-decoration:none;filter:brightness(1.1)}
.lrow{margin:14px 0 0}
.lrow .lhead{display:flex;align-items:center;gap:10px;margin-bottom:6px}
.lrow .lname{font-weight:600;font-size:13px;color:var(--fg)}
.lrow button{font:inherit;font-size:12px;background:var(--card);border:1px solid var(--line);
color:var(--fg);border-radius:8px;padding:4px 11px;cursor:pointer}
.lrow button:active{background:var(--bg)}
.hintline{color:var(--dim);font-size:12.5px;margin-top:12px;line-height:1.55}

/* Кнопки «сохранить в PDF» в памятке нет намеренно, но напечатать страницу
   браузер даёт всегда — пусть это хотя бы выглядит прилично и не жрёт тонер. */
@media print{
 body{background:#fff;color:#111}
 .sheet{padding:0}
 .card,.link,code{background:#f4f5f8;border-color:#dfe3ea;color:#111}
 .qrcard{background:#f4f5f8;border-color:#dfe3ea}
 .steps li:before{background:#eef0f4;border-color:#dfe3ea;color:#555}
 .lead,.qrcap,ul.plain,.foot,.steps .sub,.opt .t span{color:#555}
 svg.logo path,svg.logo rect{fill:#111}
 h1{border-color:#dfe3ea}
 header{border-color:#dfe3ea}
 .opt,.node{background:#f4f5f8;border-color:#dfe3ea}
}
"""


def deep_link(url, name):
    """Ссылка-схема приложения sing-box: камера открывает не сайт, а сам
    импорт профиля. Формат из документации: url кодируется в параметре,
    имя профиля — во фрагменте после #."""
    return ("sing-box://import-remote-profile?url="
            + urllib.parse.quote(url, safe="") + "#" + urllib.parse.quote(name))


def decoy_label(sni):
    """Человекочитаемое имя узла из домена-прикрытия: www.apple.com -> Apple."""
    parts = [p for p in sni.split(".") if p not in ("www", "dl", "addons")]
    core = parts[0] if parts else sni
    return {"icloud": "iCloud"}.get(core, core[:1].upper() + core[1:])


def reality_params():
    """Параметры Reality для сборки vless://-ссылок (Shadowrocket): публичный ключ,
    short_id, flow. Домены руками не печатаем (грабля №1) — читаем из живого конфига.
    Возвращает None, если чего-то нет (тогда Shadowrocket-вкладка не строится)."""
    pbk = _read(PBKF)
    try:
        c = json.load(open(CFG))
        ib = next(i for i in c.get("inbounds", []) if i.get("type") == "vless")
        sid = ib["tls"]["reality"]["short_id"]
        sid = sid[0] if isinstance(sid, list) else sid
        flow = next((u["flow"] for u in ib.get("users", []) if u.get("flow")), "")
    except (OSError, json.JSONDecodeError, StopIteration, KeyError):
        return None
    if not (pbk and sid):
        return None
    return {"pbk": pbk, "sid": str(sid), "flow": flow}


def vless_link(uuid, host, sni, label, rp, port=443):
    """Ссылка vless:// для импорта в Shadowrocket (по QR или из буфера). Содержит
    учётные данные ЭТОГО гостя (его uuid + общий публичный ключ) — те же, что и в
    remote-профиле sing-box, поэтому ничего лишнего гостю не раскрывает."""
    q = [("encryption", "none")]
    if rp.get("flow"):
        q.append(("flow", rp["flow"]))
    q += [("security", "reality"), ("sni", sni), ("fp", "chrome"),
          ("pbk", rp["pbk"]), ("sid", rp["sid"]), ("type", "tcp")]
    return (f"vless://{uuid}@{host}:{port}?{urllib.parse.urlencode(q)}"
            f"#{urllib.parse.quote(label)}")


# Клиентская отрисовка QR для узлов Shadowrocket: qr_svg() на сервере строил бы
# по 6 QR на памятку (мегабайты + медленная расшифровка под ПИНом), поэтому QR
# рисует сам телефон по нажатию. srqr тумблит QR узла, srInit раскрывает активный.
# onclick в разметке работает даже когда блок вставлен через innerHTML (в отличие
# от <script>), поэтому функции держим глобально в <head>.
QR_LIB_FILE = os.path.join(REPO, "scripts", "assets", "qrcode.min.js")
SR_QR_JS = """
function srqr(btn){
  var slot=btn.parentNode.querySelector('.qrslot'), chev=btn.querySelector('.chev');
  if(slot.getAttribute('data-done')){
    var vis=slot.style.display!=='none'; slot.style.display=vis?'none':'block';
    if(chev)chev.textContent=vis?'Показать QR':'Скрыть QR'; return;
  }
  try{
    var q=qrcode(0,'M'); q.addData(btn.getAttribute('data-vless')); q.make();
    slot.innerHTML=q.createSvgTag({cellSize:4,margin:2,scalable:true});
    slot.setAttribute('data-done','1'); slot.style.display='block';
    if(chev)chev.textContent='Скрыть QR';
  }catch(e){ slot.textContent='Не удалось построить QR — раскройте «Не получается отсканировать?» ниже.';
    slot.style.display='block'; }
}
function cplink(b){
  var t=b.closest('.lrow').querySelector('.link').textContent.trim();
  function done(){var o=b.textContent;b.textContent='Скопировано ✓';
    setTimeout(function(){b.textContent=o},1600);}
  function legacy(){var ta=document.createElement('textarea');ta.value=t;
    ta.style.position='fixed';ta.style.opacity='0';document.body.appendChild(ta);
    ta.focus();ta.select();
    try{document.execCommand('copy');done()}catch(e){}
    document.body.removeChild(ta);}
  // по http:// (не localhost) navigator.clipboard недоступен — как и crypto.subtle
  if(navigator.clipboard&&navigator.clipboard.writeText){
    navigator.clipboard.writeText(t).then(done,legacy);
  }else legacy();
}
function srInit(){
  var opened=document.querySelectorAll('.nodebtn[data-open]');
  for(var i=0;i<opened.length;i++) srqr(opened[i]);
}
document.addEventListener('DOMContentLoaded',function(){
  // при ПИНе узлы появятся только после расшифровки — там srInit зовёт go()
  if(!document.getElementById('lock')) srInit();
});
"""


def qr_lib_ok():
    """Доехала ли вендоренная QR-библиотека. Без неё кнопку «Показать QR» рисовать
    НЕЛЬЗЯ: она бы висела мёртвой (srqr is not defined), и гость решил бы, что
    памятка сломана, вместо того чтобы скопировать ссылку."""
    return bool(_read(QR_LIB_FILE))


def guide_scripts():
    """QR-библиотека + обработчики для узлов Shadowrocket, инлайном в <head>.
    Пусто, если вендоренной библиотеки нет (тогда узлы отдаются просто ссылками)."""
    lib = _read(QR_LIB_FILE)
    if not lib:
        return ""
    return f"<script>{lib}</script><script>{SR_QR_JS}</script>"


# ПИН на памятку: внутри файла лежит не ссылка, а шифртекст — без ПИНа из него
# ничего не достать даже «посмотреть исходник».
#
# Конструкция собрана из того, что есть и в питоне, и в браузере, без внешних
# библиотек и без AES: PBKDF2-HMAC-SHA256 даёт два ключа, поток шифра —
# HMAC(ключ, nonce||счётчик), поверх — HMAC-тег (encrypt-then-MAC).
#
# Итераций 20 000, а не 200 000: памятку открывают и по http со своего сервера,
# где браузер не даёт crypto.subtle, и PBKDF2 считается чистым JS. На стойкость
# это влияет мало — её и так определяют четыре цифры.
#
# Честно про стойкость: четыре цифры — это 10 000 вариантов, и подбор на
# видеокарте займёт секунды. Это защита от пересылки дальше по цепочке
# «знакомый знакомому», а не от целенаправленного взлома. Настоящая защита
# прежняя: ключ персональный, отзывается одной кнопкой, ссылка живёт только
# во время выдачи.
GUIDE_ITERS = 20000


def seal(text, pin):
    salt, nonce = os.urandom(16), os.urandom(12)
    dk = hashlib.pbkdf2_hmac("sha256", pin.encode(), salt, GUIDE_ITERS, 64)
    ek, mk = dk[:32], dk[32:]
    data = text.encode()
    stream = b""
    i = 0
    while len(stream) < len(data):
        stream += hmac.new(ek, nonce + i.to_bytes(4, "big"), hashlib.sha256).digest()
        i += 1
    ct = bytes(a ^ b for a, b in zip(data, stream))
    tag = hmac.new(mk, nonce + ct, hashlib.sha256).digest()
    b = lambda x: base64.b64encode(x).decode()
    return {"salt": b(salt), "nonce": b(nonce), "ct": b(ct), "tag": b(tag),
            "iters": GUIDE_ITERS, "len": len(pin)}


GUIDE_JS = """
/* Чистый JS на случай, когда crypto.subtle недоступен: на http:// (не localhost)
   браузер его не даёт, а памятку мы отдаём именно по http со своего сервера.
   Реализация SHA-256 → HMAC → PBKDF2 по RFC; сверена с WebCrypto на векторах. */
const K256 = [0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2];

function sha256(bytes){
  const ml = bytes.length;
  const withOne = new Uint8Array((((ml + 8) >> 6) + 1) << 6);
  withOne.set(bytes); withOne[ml] = 0x80;
  const dv = new DataView(withOne.buffer);
  dv.setUint32(withOne.length - 4, (ml << 3) >>> 0);
  dv.setUint32(withOne.length - 8, Math.floor(ml / 536870912));
  let h = [0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19];
  const w = new Uint32Array(64);
  for (let off = 0; off < withOne.length; off += 64) {
    for (let i = 0; i < 16; i++) w[i] = dv.getUint32(off + i*4);
    for (let i = 16; i < 64; i++) {
      const a = w[i-15], b = w[i-2];
      const s0 = ((a>>>7)|(a<<25)) ^ ((a>>>18)|(a<<14)) ^ (a>>>3);
      const s1 = ((b>>>17)|(b<<15)) ^ ((b>>>19)|(b<<13)) ^ (b>>>10);
      w[i] = (w[i-16] + s0 + w[i-7] + s1) >>> 0;
    }
    let [a,b,c,d,e,f,g,hh] = h;
    for (let i = 0; i < 64; i++) {
      const S1 = ((e>>>6)|(e<<26)) ^ ((e>>>11)|(e<<21)) ^ ((e>>>25)|(e<<7));
      const ch = (e & f) ^ (~e & g);
      const t1 = (hh + S1 + ch + K256[i] + w[i]) >>> 0;
      const S0 = ((a>>>2)|(a<<30)) ^ ((a>>>13)|(a<<19)) ^ ((a>>>22)|(a<<10));
      const mj = (a & b) ^ (a & c) ^ (b & c);
      const t2 = (S0 + mj) >>> 0;
      hh=g; g=f; f=e; e=(d+t1)>>>0; d=c; c=b; b=a; a=(t1+t2)>>>0;
    }
    h = [(h[0]+a)>>>0,(h[1]+b)>>>0,(h[2]+c)>>>0,(h[3]+d)>>>0,
         (h[4]+e)>>>0,(h[5]+f)>>>0,(h[6]+g)>>>0,(h[7]+hh)>>>0];
  }
  const out = new Uint8Array(32), ov = new DataView(out.buffer);
  h.forEach((x,i) => ov.setUint32(i*4, x));
  return out;
}

function hmac(key, msg){
  let k = key.length > 64 ? sha256(key) : key;
  const pad = new Uint8Array(64); pad.set(k);
  const o = new Uint8Array(64), i = new Uint8Array(64);
  for (let j = 0; j < 64; j++) { o[j] = pad[j] ^ 0x5c; i[j] = pad[j] ^ 0x36 }
  const inner = new Uint8Array(64 + msg.length); inner.set(i); inner.set(msg, 64);
  const ih = sha256(inner);
  const outer = new Uint8Array(96); outer.set(o); outer.set(ih, 64);
  return sha256(outer);
}

function pbkdf2(pass, salt, iters, dkLen){
  const out = new Uint8Array(dkLen);
  let done = 0, block = 1;
  while (done < dkLen) {
    const b = new Uint8Array(salt.length + 4); b.set(salt);
    new DataView(b.buffer).setUint32(salt.length, block);
    let u = hmac(pass, b), acc = u.slice();
    for (let i = 1; i < iters; i++) {
      u = hmac(pass, u);
      for (let j = 0; j < 32; j++) acc[j] ^= u[j];
    }
    out.set(acc.subarray(0, Math.min(32, dkLen - done)), done);
    done += 32; block++;
  }
  return out;
}

const BOX = %s;
const b64 = s => Uint8Array.from(atob(s), c => c.charCodeAt(0));
const cat = (...a) => { const n = a.reduce((s,x)=>s+x.length,0), r = new Uint8Array(n);
  let o = 0; for (const x of a) { r.set(x,o); o += x.length } return r };
const fast = () => !!(window.crypto && crypto.subtle);
let pin = "";

function draw(){
  document.querySelectorAll('#dots i').forEach((d,i)=>d.classList.toggle('f', i < pin.length));
}
function tap(d){ if (pin.length < BOX.len) { pin += d; draw(); if (pin.length === BOX.len) go() } }
function del(){ pin = pin.slice(0,-1); draw() }

async function derive(p){
  const pw = new TextEncoder().encode(p), salt = b64(BOX.salt);
  if (fast()) {
    const base = await crypto.subtle.importKey("raw", pw, "PBKDF2", false, ["deriveBits"]);
    return new Uint8Array(await crypto.subtle.deriveBits(
      {name:"PBKDF2", salt, iterations:BOX.iters, hash:"SHA-256"}, base, 512));
  }
  return pbkdf2(pw, salt, BOX.iters, 64);
}
async function mac(key, msg){
  if (fast()) {
    const k = await crypto.subtle.importKey("raw", key, {name:"HMAC", hash:"SHA-256"}, false, ["sign"]);
    return new Uint8Array(await crypto.subtle.sign("HMAC", k, msg));
  }
  return hmac(key, msg);
}

async function unseal(p){
  const bits = await derive(p);
  const ek = bits.slice(0,32), mk = bits.slice(32);
  const nonce = b64(BOX.nonce), ct = b64(BOX.ct), tag = b64(BOX.tag);
  const t = await mac(mk, cat(nonce, ct));
  if (t.length !== tag.length || t.some((v,i) => v !== tag[i])) return null;
  const out = new Uint8Array(ct.length);
  for (let i = 0, off = 0; off < ct.length; i++, off += 32) {
    const c = new Uint8Array(4); new DataView(c.buffer).setUint32(0, i);
    const blk = await mac(ek, cat(nonce, c));
    for (let j = 0; j < 32 && off + j < ct.length; j++) out[off+j] = ct[off+j] ^ blk[j];
  }
  return new TextDecoder().decode(out);
}

async function go(){
  const box = document.getElementById('lock'), err = document.getElementById('err');
  err.textContent = "Проверяю…";
  await new Promise(r => setTimeout(r, 30));   // дать браузеру перерисовать надпись
  let plain = null;
  try { plain = await unseal(pin) } catch (e) { plain = null }
  if (plain === null) { err.textContent = "Неверный код. Попробуйте ещё раз."; pin = ""; draw(); return }
  document.getElementById('secret').innerHTML = plain;
  box.remove();
  if (typeof srInit === 'function') srInit();   // раскрыть QR активного узла
}
"""


def guide_html(name):
    """Памятка для человека: одним файлом, без интернета — логотип, QR и что
    нажимать. Её можно скачать и переслать: внутри всё, включая код.

    Адрес сервера по IP и список запретов в памятку НЕ идут: гостю они не нужны,
    а IP лишний раз светить незачем. Если у человека задан ПИН, весь блок с
    кодом и ссылкой лежит в файле зашифрованным (см. seal) — «посмотреть
    исходник» ничего не даст.
    """
    u = find_user(name) or {}
    st, dom = server_status(), domain_info()
    host = dom.get("host") or st["ip"]
    url = share_url(name, host)
    nm = html.escape(pretty(name))
    deep = deep_link(url, name)
    pin = str(u.get("guide_pin") or "")

    # --- вкладка sing-box (рекомендуемая): remote-профиль с авто-failover ---
    # Вспомогательные ветки («нет в РФ сторе», «не сканируется») спрятаны в
    # <details>: главный путь — три шага, глазам чисто. details — нативный HTML,
    # работает и внутри блока, вставленного через innerHTML после ПИНа.
    sb_panel = f"""<h2>Приложение sing-box</h2>
    <div class="note ok">Рекомендуем: приложение само переключается на запасной узел,
    если основной заблокируют, и умеет kill-switch — не пускает трафик мимо туннеля.</div>
    <div class="split">
      <div class="col" style="flex:0 0 auto">{qr_card(deep, cap="Код открывает приложение")}</div>
      <div class="col">
        <ol class="steps">
          <li><b>Установите приложение sing-box VT</b>
            <div class="sub">App Store, бесплатное (разработчик VIRAL TECH INC.):
            <a href="{APP_URL_SB}">{APP_URL_SB}</a></div>
            <details class="fold"><summary>Нет в российском App Store?</summary>
              <div class="fbody">Смените страну аккаунта: Настройки → ваше имя →
              Медиа и покупки → Просмотреть → Страна или регион. Подойдёт любая;
              карта для бесплатного приложения не нужна — способ оплаты «Нет».
              </div></details></li>
          <li><b>Наведите камеру на код</b>
            <div class="sub">Телефон предложит открыть в sing-box — согласитесь.
            В приложении нажмите <b>Import</b>, затем <b>Create</b>. Галочку
            <i>Auto update</i> оставьте как есть.</div></li>
          <li><b>Включите переключатель на вкладке Dashboard</b>
            <div class="sub">Первый раз система попросит разрешение на VPN-профиль —
            согласитесь. Проверка на <code>ipinfo.io</code>: страна Латвия (LV).</div></li>
        </ol>
        <details class="fold"><summary>Не получается отсканировать код?</summary>
          <div class="fbody">
            <p>Если эта страница открыта на самом телефоне — сканировать и не нужно,
            просто нажмите кнопку:</p>
            <a class="openbtn" href="{html.escape(deep)}">Открыть в sing-box</a>
            <p>Или добавьте вручную: вкладка Profiles → «+» → Type: <i>Remote</i> →
            вставьте адрес в поле URL → Create.</p>
            <div class="link">{html.escape(url)}</div>
          </div></details>
      </div>
    </div>"""

    # --- вкладка Shadowrocket: отдельные vless://-узлы (переключение вручную) ---
    rp = reality_params()
    uuid = u.get("uuid", "")
    if rp and uuid:
        cur = st.get("decoy", "")
        domains = list(DECOYS)
        if cur and cur not in domains and "[" not in cur and len(cur) < 40:
            domains.insert(0, cur)
        # Активный узел — первым (у него QR раскрыт сразу). Остальные — про запас;
        # их QR рисует САМ телефон по нажатию (qrcode.min.js), а не сервер: шесть
        # серверных QR раздули бы файл до мегабайтов и под ПИНом тормозили расшифровку.
        domains.sort(key=lambda d: d != cur)

        has_qr = qr_lib_ok()

        def sr_link(sni):
            return vless_link(uuid, host, sni, f"LV-{decoy_label(sni)}", rp)

        def node(sni, live):
            esc = html.escape(sr_link(sni))
            badge = '<span class="badge">активен сейчас</span>' if live else ""
            title = f'<span class="nn">Латвия · {html.escape(decoy_label(sni))}</span>{badge}'
            if not has_qr:
                # Библиотека не доехала: без QR карточка-кнопка была бы мёртвой,
                # отдаём узел просто ссылкой.
                return (f'<div class="node{" live" if live else ""}">'
                        f'<div class="nh">{title}</div><div class="link">{esc}</div></div>')
            # data-open=1 у активного: srInit раскроет его QR сразу при показе.
            openattr = ' data-open="1"' if live else ""
            return (f'<div class="node{" live" if live else ""}">'
                    f'<button type="button" class="nh nodebtn" data-vless="{esc}"{openattr} '
                    f'onclick="srqr(this)">{title}'
                    f'<span class="chev">Показать QR</span></button>'
                    f'<div class="qrslot"></div></div>')

        active = domains[0]
        rest = domains[1:]
        nodes_html = node(active, active == cur)
        if rest:
            nodes_html += ('<div class="sect-note">Запасные узлы — если основной '
                           'перестанет открываться. Нажмите на узел, чтобы открыть '
                           'его QR:</div>'
                           + "".join(node(d, False) for d in rest))
        # Ссылки узлов с глаз убраны в раскрывашку: главный путь — QR, а копирование
        # руками нужно только когда сканировать нечем (страница на том же телефоне).
        if has_qr:
            rows = "".join(
                f'<div class="lrow"><div class="lhead">'
                f'<span class="lname">Латвия · {html.escape(decoy_label(d))}</span>'
                f'<button type="button" onclick="cplink(this)">Скопировать</button></div>'
                f'<div class="link">{html.escape(sr_link(d))}</div></div>'
                for d in domains)
            nodes_html += (
                '<details class="fold"><summary>Не получается отсканировать?</summary>'
                '<div class="fbody">'
                '<p>Скопируйте ссылку нужного узла кнопкой ниже и просто откройте '
                'Shadowrocket — он сам предложит добавить её из буфера.</p>'
                '<p>Экран «Добавить сервер» с типом <i>Subscribe</i> не подходит — '
                'наш код туда не добавляется. Нужен сканер с вкладки «Главная» '
                'или буфер обмена.</p>'
                f'{rows}</div></details>')
        else:
            nodes_html += ('<div class="hintline">Скопируйте ссылку узла (нажать и '
                           'подержать → Скопировать) и откройте Shadowrocket — он сам '
                           'предложит добавить её из буфера. Экран «Добавить сервер» с '
                           'типом Subscribe не подходит.</div>')
    else:
        nodes_html = ('<div class="note warn">Ссылки для Shadowrocket сейчас собрать не '
                      'удалось — воспользуйтесь вариантом sing-box слева.</div>')

    sr_panel = f"""<h2>Приложение Shadowrocket</h2>
    <div class="note warn">Автопереключения узлов нет. Если перестанет подключаться —
    выберите вручную другой узел (лучше тот, что помечен «активен сейчас»).</div>
    <ol class="steps">
      <li><b>Установите Shadowrocket</b>
        <div class="sub">App Store, платное (~$3), доступно в российском:
        <a href="{APP_URL_SR}">{APP_URL_SR}</a></div></li>
      <li><b>Отсканируйте QR активного узла</b>
        <div class="sub">В приложении: вкладка <b>Главная</b> → значок <b>сканера</b>
        вверху справа → наведите на QR ниже (у активного узла он уже раскрыт).</div></li>
      <li><b>Включите переключатель вверху</b>
        <div class="sub">Проверка на <code>ipinfo.io</code>: страна Латвия (LV).</div></li>
      <li><b>Российские сайты — напрямую</b> (3 минуты, один раз)
        <div class="sub">Чтобы банки, Госуслуги и остальные российские сайты видели ваш
        обычный российский адрес, а не VPN. Три правила, добавляются руками — из QR-кода
        они не берутся, зато потом не слетают при добавлении узлов.</div>
        <details class="fold"><summary>Как добавить правила — по шагам</summary>
        <div class="fbody">
        <ol class="substeps">
          <li>Внизу экрана вкладка <b>«Настройка»</b> (значок папки).</li>
          <li>В списке «Локальные файлы» нажмите <b>default.conf</b> →
            <b>«Редактировать конфигурацию»</b>.</li>
          <li>Откройте строку <b>«Правило»</b>. Там уже сотни встроенных правил
            (китайские сайты, реклама) — это норма, их не трогаем.</li>
          <li>Нажмите <b>«+»</b> вверху справа и заполните:
            <b>Тип</b> → <code>DOMAIN-SUFFIX</code>, <b>Политика</b> → <code>DIRECT</code>,
            поле <b>«Домен»</b> → <code>ru</code> (две буквы, без точки). Переключатели не трогайте.
            <b>«Сохранить»</b>.</li>
          <li>Снова <b>«+»</b>: <code>DOMAIN-SUFFIX</code>, <code>DIRECT</code>,
            домен <code>xn--p1ai</code> (без точки) — так пишется зона <b>.рф</b>, кириллицей не сработает.</li>
          <li>Снова <b>«+»</b>: <b>Тип</b> → <code>GEOIP</code>, <b>Политика</b> →
            <code>DIRECT</code>, страна <code>RU</code> (две заглавные буквы).</li>
          <li>Проверьте порядок: три новых правила должны стоять <b>выше</b> строки
            <code>FINAL</code>. Если оказались ниже — зажмите и перетащите вверх.</li>
          <li>Выключите и снова включите VPN. В <b>«Настройки» → «Маршрутизация»</b>
            должен быть выбран режим <b>«Настройка»</b> (так по умолчанию).</li>
        </ol>
        <p><b>Проверка:</b> вкладка «Настройка» → <b>«Правило тестирования»</b> → введите
        <code>sberbank.ru</code> → ответ <code>DIRECT</code>. В браузере
        <code>yandex.ru/internet</code> покажет российский адрес, а <code>ipinfo.io</code> —
        Латвию.</p>
        </div></details></li>
    </ol>
    <h2>Узлы — добавьте активный, остальные про запас</h2>
    {nodes_html}"""

    access = f"""<div class="apptabs">
  <input type="radio" name="app" id="app-sb" class="tabradio" checked>
  <input type="radio" name="app" id="app-sr" class="tabradio">
  <div class="opts">
    <label class="opt opt-sb" for="app-sb">
      <span class="badge">Рекомендовано</span>
      <span class="ic">🧭</span>
      <span class="t"><b>sing-box</b><span>Сам переключает узлы и держит kill-switch. Надёжнее.</span></span>
      <span class="pick"></span>
    </label>
    <label class="opt opt-sr" for="app-sr">
      <span class="badge grey">РФ App Store</span>
      <span class="ic">🚀</span>
      <span class="t"><b>Shadowrocket</b><span>Приложение, доступное в российском App Store.</span></span>
      <span class="pick"></span>
    </label>
  </div>
  <div class="panels">
    <div class="panel panel-sb">{sb_panel}</div>
    <div class="panel panel-sr">{sr_panel}</div>
  </div>
</div>"""

    if pin:
        box = seal(access, pin)
        keys = "".join(f'<button type="button" onclick="tap(\'{d}\')">{d}</button>'
                       for d in "123456789")
        body = (f'<div class="lock" id="lock"><p>Код из {len(pin)} цифр прислали отдельным '
                f'сообщением — введите его, чтобы открыть инструкцию.</p>'
                f'<div class="dots" id="dots">{"<i></i>" * len(pin)}</div>'
                f'<div class="pad">{keys}<span></span>'
                f'<button type="button" onclick="tap(\'0\')">0</button>'
                f'<button type="button" class="sec" onclick="del()">←</button></div>'
                f'<div class="err" id="err"></div></div>'
                f'<div id="secret"></div>'
                f'<script>{GUIDE_JS % json.dumps(box)}</script>')
    else:
        body = access

    return f"""<!doctype html><html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>FutureFlow — доступ для {nm}</title><style>{GUIDE_CSS}</style>
{guide_scripts()}</head><body>
<div class="sheet">
<header>{logo_html()}<h1>Доступ к VPN</h1></header>

<p class="lead">Личный доступ для <b>{nm}</b>. Российские сайты идут напрямую и не
тормозят, зарубежные — через сервер в Латвии. Выберите приложение — ниже появится
инструкция именно для него. Настройка — пара минут.</p>

{body}

<div class="card"><h2>Важное</h2><ul class="plain">
<li>Ссылка живёт только во время установки — потом её закрывают. Не успели,
попросите открыть ещё раз.</li>
<li>Ключ персональный: видно, чей он. Передавать другим нельзя — такой ключ
отключают.</li>
</ul></div>

<div class="foot">FutureFlow</div>
</div></body></html>"""


def share_modal(name, opened=True):
    st, dom = server_status(), domain_info()
    host = dom.get("host") or st["ip"]
    url = share_url(name, host)
    guide_link = url.rsplit("/", 1)[0] + "/"   # памятка лежит рядом с конфигом
    nm = html.escape(name)
    q = urllib.parse.urlencode({"name": name})
    pin = str((find_user(name) or {}).get("guide_pin") or "")
    pin_state = (f'Сейчас код: <b>{html.escape(pin)}</b> — сообщите его человеку отдельным '
                 f'сообщением, не вместе с файлом.' if pin else
                 'Сейчас памятка без кода: кто получит файл, тот увидит инструкцию.')
    pin_form = (f'<form method="post" action="/pin" class="row" style="margin-top:16px">'
                f'<input type="hidden" name="name" value="{nm}">'
                f'<input name="pin" inputmode="numeric" pattern="[0-9]*" maxlength="8" '
                f'placeholder="4–8 цифр, пусто — снять код" value="{html.escape(pin)}" '
                f'style="max-width:230px">'
                f'<button>Сохранить код</button></form>'
                f'<div class="hint">{pin_state} Код спрашивается при открытии файла: внутри '
                f'лежит шифртекст, «посмотреть исходник» ничего не даст. Но честно: четыре '
                f'цифры — это 10 000 вариантов, от целенаправленного перебора они не спасут. '
                f'Это защита от пересылки дальше по цепочке, а не от взлома.</div>')
    alt = "" if host == st["ip"] else (
        f'<div class="hint">Если по имени не откроется — запасная ссылка по адресу: '
        f'<code>{html.escape(url.replace(host, st["ip"], 1))}</code></div>')
    return modal(
        f"cfg-{nm}", f"Настройки для «{html.escape(pretty(name))}»",
        "Отправьте человеку ссылку — она откроется у него в браузере как страница "
        "с QR и инструкцией. Работает, пока идёт выдача.",
        # QR со схемой sing-box отсюда убран намеренно: владельцу он не нужен —
        # человек получает свой QR прямо в памятке, причём для ОБОИХ приложений.
        f'<label>Ссылка для отправки</label>'
        f'<div class="linkrow big"><code id="glink-{nm}">{html.escape(guide_link)}</code>'
        f'<button type="button" class="cp primary" onclick="cpRow(this)">Скопировать</button></div>'
        f'<div class="hint">Человек откроет ссылку, введёт код и сам выберет приложение — '
        f'<b>sing-box</b> (рекомендуем: сам переключает узлы, есть kill-switch) или '
        f'<b>Shadowrocket</b> (доступен в российском App Store). Инструкция и QR для '
        f'выбранного покажутся там же.</div>'
        f'{pin_form}'
        f'<div class="hint" style="margin-top:14px">Ссылка отдаёт личный ключ без пароля — '
        f'закройте выдачу сразу после того, как человек импортировал профиль. «Закрыть '
        f'выдачу» гасит только раздачу файла: доступ, ключи и работающий туннель не '
        f'трогает — ни гостю, ни вам.</div>'
        f'<details class="fold"><summary>Другие адреса</summary>'
        f'<div class="linkrow"><code>{html.escape(url)}</code><span class="tag">профиль</span>'
        f'<button type="button" class="cp" onclick="cpRow(this)">Скопировать</button></div>'
        f'{alt}</details>'
        f'<div class="actions">'
        f'<a class="btn" href="/guide?{q}" target="_blank">Посмотреть памятку</a>'
        f'<a class="btn" href="/guide?{q}&amp;dl=1">Скачать файлом</a>'
        f'<form method="post" action="/act"><input type="hidden" name="op" value="share_stop">'
        f'<button class="danger">Закрыть выдачу</button></form></div>', opened=opened)


def bcast_banner():
    """Плашка рассылки обновления: идёт — кто уже получил и когда закроется;
    закончилась — итог с теми, до кого не дошло (их профиль остался прежним)."""
    st = bcast_state()
    if st:
        us = st.get("users", {})
        got = [n for n, u in us.items() if u.get("fetched")]
        left = max(0, int(st.get("deadline", 0)) - int(time.time()))
        till = f"{left // 3600} ч. {left % 3600 // 60} мин." if left >= 3600 else f"{max(1, left // 60)} мин."
        names = ", ".join(html.escape(pretty(n)) for n in got) or "пока никто"
        return (f'<div class="msg warn"><span>Рассылка обновления: получили '
                f'<b>{len(got)} из {len(us)}</b> ({names}). Закроется сама, когда получат все, '
                f'иначе через {till}.</span>'
                f'<form method="post" action="/act"><input type="hidden" name="op" value="bcast_stop">'
                f'<button class="danger">Остановить</button></form></div>')
    last = bcast_last()
    if not last or int(time.time()) - int(last.get("finished", 0)) > 2 * 86400:
        return ""
    us = last.get("users", {})
    miss = [pretty(n) for n, u in us.items() if not u.get("fetched")]
    why = {"all": "получили все", "timeout": "вышло время", "stopped": "остановлена вручную"}.get(
        last.get("reason"), "завершена")
    tail = (f" Не получили: <b>{html.escape(', '.join(miss))}</b> — у них прежний профиль, "
            f"можно повторить рассылку или открыть выдачу." if miss else "")
    return (f'<div class="msg"><span>Последняя рассылка {ago(last.get("finished"))}: {why}, '
            f'{len(us) - len(miss)} из {len(us)}.{tail}</span>'
            f'<form method="post" action="/act"><input type="hidden" name="op" value="bcast_dismiss">'
            f'<button>Скрыть</button></form></div>')


def page(msg="", err=False, extra_modal="", open_nodes=False):
    st, dom = server_status(), domain_info()
    rows, modals = [], []
    for u in users():
        on = bool(u.get("enabled"))
        prot = bool(u.get("protected"))
        nm = html.escape(u["name"])          # для форм: настоящее имя
        shown = html.escape(pretty(u["name"]))   # для глаз: с заглавной
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
                f'<form method="post" action="/act" onsubmit="return confirm(\'Удалить {shown}?\')">'
                f'<input type="hidden" name="op" value="remove">'
                f'<input type="hidden" name="name" value="{nm}">'
                f'<button class="danger">Удалить</button></form>')
        rows.append(f'<tr><td><div class="name">{shown}</div>{note}</td><td>{status}</td>'
                    f'<td>{lim}</td><td><div class="row">{"".join(acts)}</div></td></tr>')
        modals.append(limits_modal(u))

    msg_html = f'<div class="msg{" err" if err else ""}">{html.escape(msg)}</div>' if msg else ""
    # Раздача живёт, пока её не закроют, поэтому про неё должно быть видно всегда,
    # а не только в окне «Настройки»: открытая ссылка отдаёт личный ключ без пароля.
    sh_st = share_state()
    if sh_st:
        since = ago(sh_st.get("started"))
        share_banner = (
            f'<div class="msg warn"><span>Выдача открыта для '
            f'<b>{html.escape(pretty(str(sh_st.get("name", ""))))}</b> — ссылка на памятку '
            f'работает{"" if since == "—" else f", открыта {since}"}. Она отдаёт личный ключ '
            f'без пароля, поэтому закройте её, когда человек настроится.</span>'
            f'<form method="post" action="/act"><input type="hidden" name="op" value="share_stop">'
            f'<button class="danger">Закрыть выдачу</button></form></div>')
    else:
        share_banner = ""
    share_banner += bcast_banner()
    body = "".join(rows) or '<tr><td colspan="4" class="note">Пока никого нет</td></tr>'
    left = dom.get("days_left")
    dline = html.escape(dom.get("host", "—")) + (f' · {left} дн. до продления' if left is not None else "")
    return f"""<!doctype html><html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>FutureFlow — доступ к VPN</title><style>{CSS}</style></head><body><div class="wrap">
<header>{logo_html()}<h1>Доступ к VPN</h1><span class="sp"></span>
<button onclick="openM('analytics')">Аналитика</button>
<button onclick="openM('nodes')">Узлы</button>
<button onclick="openM('links')">Ссылки</button>
<button onclick="openM('server')">Сервер и домен</button></header>
{msg_html}{share_banner}
<div class="card"><div class="cardhead"><h2>Кто пользуется</h2><span class="sp"></span>
<button class="primary" onclick="openM('add')">Добавить человека</button>
<form method="post" action="/act" onsubmit="return confirm('Раздать всем свежий профиль? Их приложения заберут его сами в течение часа-двух; выдача закроется, когда получат все (или через сутки).')">
<input type="hidden" name="op" value="bcast_start"><button title="Профили гостей обновятся сами, без новых ссылок и QR">Разослать обновление</button></form></div>
<table><tr><th>Имя</th><th>Доступ</th><th>Ограничения</th><th></th></tr>{body}</table>
<div class="status">
<span><b>сервер</b> {"работает" if st["singbox"] == "active" else "не работает"}</span>
<span><b>каналы</b> {html.escape(st['ports'])}</span>
<span><b>адрес</b> {html.escape(st['ip'])}</span>
<span><b>домен</b> {dline}</span>
</div></div>
{add_modal()}{analytics_modal()}{nodes_modal(open_nodes)}{links_modal()}{server_modal()}{''.join(modals)}{extra_modal}
</div>
<script>{JS}</script></body></html>"""


def share_dir(name):
    """Каталог, из которого vpn-users.sh раздаёт конфиг этого человека."""
    return f"/tmp/guest-{name}/{share_token(name)}"


def publish_guide(name, wait=60.0):
    """Положить памятку рядом с конфигом — чтобы человеку можно было послать
    ССЫЛКУ, а не файл. Вложение в мессенджере открывается встроенным
    просмотром, где скрипты не выполняются: цифры кода не нажимаются, и
    приходится сохранять файл и открывать его браузером вручную.
    По ссылке всё работает сразу.

    Ждём до `wait` секунд, а не 5, как раньше: сборка конфигов идёт дольше —
    там и снятие прежней раздачи со `sleep 2`, и `curl` к ipify с таймаутом 6 с.
    Не дождались — index.html не появлялся, и гость по ссылке видел ЛИСТИНГ
    КАТАЛОГА вместо памятки (ровно этот симптом и словили)."""
    d = share_dir(name)
    deadline = time.time() + wait
    while time.time() < deadline:
        # Ждём не каталог, а готовый конфиг: раздача сначала СНОСИТ прежний
        # каталог и только потом собирает файлы — попасть в это окно значит
        # положить памятку в то, что через миг удалят.
        if os.path.exists(os.path.join(d, "full.json")):
            try:
                with open(os.path.join(d, "index.html"), "w") as f:
                    f.write(guide_html(name))
                return True
            except OSError:
                return False
        time.sleep(0.3)
    return False


def publish_guide_async(name, wait=60.0):
    """Памятку кладём ФОНОМ: держать HTTP-ответ панели все секунды сборки нельзя —
    страница выглядела бы зависшей, а раньше именно из-за спешки мы не дожидались
    конфига и оставляли каталог без index.html."""
    threading.Thread(target=publish_guide, args=(name, wait), daemon=True).start()


def _is_users_cmd(pid, cmd):
    """Это точно наш процесс vpn-users.sh <cmd>, а не чужой с переиспользованным
    pid. Проверка по аргументам, как в take_over_port: pid'ы переиспользуются, и
    убить по записи из файла что попало — плохая идея."""
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as f:
            argv = [x.decode("utf-8", "replace") for x in f.read().split(b"\0") if x]
    except OSError:
        return False
    return any(a.endswith("vpn-users.sh") for a in argv) and cmd in argv


def _is_share(pid):
    return _is_users_cmd(pid, "share")


def _kill_group(pid, alive):
    """SIGTERM, потом SIGKILL всей группе процесса; alive(pid) говорит, жив ли ещё."""
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(os.getpgid(pid), sig)
        except OSError:
            return
        for _ in range(10):
            time.sleep(0.2)
            if not alive(pid):
                return


def bcast_state():
    """Идёт ли рассылка обновления: {pid, started, deadline, users{name:{token,fetched}}}
    или {}. Файл пишет сам скрипт рассылки; протухший (процесс умер) убираем."""
    try:
        d = json.load(open(BCAST_STATE))
    except (OSError, json.JSONDecodeError):
        return {}
    pid = d.get("pid")
    if isinstance(pid, int) and _is_users_cmd(pid, "broadcast"):
        return d
    try:
        os.remove(BCAST_STATE)
    except OSError:
        pass
    return {}


def bcast_last():
    """Итог последней рассылки (пишется при завершении) или {}."""
    try:
        return json.load(open(BCAST_LAST))
    except (OSError, json.JSONDecodeError):
        return {}


def start_broadcast(hours=24):
    """Раздать свежие профили всем включённым; скрипт сам закроется, когда каждый
    скачает full.json (или через hours). Обычную выдачу снимаем: порт один."""
    stop_share()
    stop_broadcast()
    try:
        os.remove(BCAST_LAST)
    except OSError:
        pass
    env = dict(os.environ, STORE=STORE, CFG=CFG, BCAST_STATE=BCAST_STATE, BCAST_LAST=BCAST_LAST)
    subprocess.Popen(["bash", USERS_SH, "broadcast", str(hours)], env=env,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)


def stop_broadcast():
    st = bcast_state()
    if st.get("pid"):
        _kill_group(st["pid"], lambda p: _is_users_cmd(p, "broadcast"))
    try:
        os.remove(BCAST_STATE)
    except OSError:
        pass


def share_state():
    """Идёт ли раздача сейчас: {name, pid, started} или {}. Читаем с диска —
    раздачу мог запустить прежний экземпляр панели."""
    try:
        d = json.load(open(SHARE_STATE))
    except (OSError, json.JSONDecodeError):
        return {}
    pid = d.get("pid")
    if isinstance(pid, int) and _is_share(pid):
        return d
    # процесс умер сам (ошибка, перезагрузка) — состояние протухло
    try:
        os.remove(SHARE_STATE)
    except OSError:
        pass
    return {}


def start_share(name):
    stop_share()
    stop_broadcast()
    # Закрепляем токен ДО запуска скрипта. Иначе гонка: скрипт, не найдя токена,
    # сгенерирует свой и создаст каталог с ним, а панель параллельно сгенерирует
    # другой и положит памятку мимо — по ссылке остался бы листинг каталога.
    share_token(name)
    env = dict(os.environ, STORE=STORE, CFG=CFG)
    # start_new_session: раздача уходит в СВОЮ сессию, поэтому переживает и выход
    # из панели, и обрыв ssh (HUP по сессии до неё не долетает). Закрывается
    # только кнопкой «Закрыть выдачу».
    proc = subprocess.Popen(
        ["bash", USERS_SH, "share", name], env=env,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    share_proc.update({"proc": proc, "name": name})
    try:
        with open(SHARE_STATE, "w") as f:
            json.dump({"name": name, "pid": proc.pid, "started": int(time.time())}, f)
    except OSError:
        pass


def stop_share():
    st = share_state()
    pid = st.get("pid")
    if pid:
        _kill_group(pid, _is_share)
    try:
        os.remove(SHARE_STATE)
    except OSError:
        pass
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
            publish_guide_async(name)
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

        if self.path == "/pin":
            name = form.get("name", [""])[0]
            pin = re.sub(r"\D", "", form.get("pin", [""])[0])
            if pin and not 4 <= len(pin) <= 8:
                return self._send(page("Код — от 4 до 8 цифр", err=True,
                                       extra_modal=share_modal(name, opened=False)))
            lst = users()
            hit = [x for x in lst if x["name"] == name]
            if not hit:
                return self._send(page("Нет такого человека", err=True))
            if pin:
                hit[0]["guide_pin"] = pin
            else:
                hit[0].pop("guide_pin", None)
            save_users(lst)
            # Памятка уже лежит в раздаче — пересобираем, иначе там остался бы
            # старый код (или его отсутствие).
            if share_state().get("name") == name:
                publish_guide_async(name, wait=15)
            return self._send(page(f"Код на памятку {'сохранён' if pin else 'снят'}: {name}",
                                   extra_modal=share_modal(name)))

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
        if op == "bcast_start":
            if not any(u.get("enabled") for u in users()):
                return self._send(page("Включённых людей нет — рассылать некому.", err=True))
            start_broadcast()
            return self._send(page("Рассылка запущена: профили заберутся сами."))
        if op == "bcast_stop":
            stop_broadcast()
            return self._send(page("Рассылка остановлена."))
        if op == "bcast_dismiss":
            try:
                os.remove(BCAST_LAST)
            except OSError:
                pass
            return self._send(page())
        if op == "check_decoys":
            start_check()
            return self._send(page(open_nodes=True))
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
        pin = re.sub(r"\D", "", form.get("pin", [""])[0]) if op == "add" else ""
        code, out = run([op, name], no_share=True,
                        extra_env={"GUIDE_PIN": pin} if pin else None)
        if op == "add" and code == 0:
            start_share(name)
            publish_guide_async(name)
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
    # Раздачу тут НЕ трогаем: ссылка на памятку должна жить, пока владелец сам не
    # нажмёт «Закрыть выдачу». Раньше выход из панели (Ctrl+C, обрыв ssh) уносил
    # её с собой, и у человека ссылка внезапно переставала открываться.
    st = share_state()
    if st:
        print(f"\nРаздача для «{st.get('name')}» продолжает работать. "
              f"Закрыть — кнопкой «Закрыть выдачу» в панели.")
    print("Остановлено.")
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
