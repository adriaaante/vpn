#!/usr/bin/env bash
#
# vpn-doctor.sh — ОДНА команда, собирающая полный отчёт «почему не работает VPN».
# Сам определяет, где запущен: на маке (клиент) или на сервере (Reality-инбаунд).
#
#   на маке:    cd ~/vpn && bash scripts/vpn-doctor.sh
#   на сервере: cd /root/vpn && bash scripts/vpn-doctor.sh
#
# Вывод БЕЗОПАСЕН для пересылки в чат: uuid / short_id / ключи печатаются не
# целиком, а отпечатками sha256:xxxxxxxx. Одинаковый отпечаток на обоих концах =
# параметры совпадают; разный = найден рассинхрон (главная причина «всё сдохло
# на всех устройствах сразу»). Домены выводятся с длиной и проверкой на markdown
# (грабля №1), свой публичный IP не печатается — только страна и провайдер.
#
# Переопределения для отладки: CFG=/path/to/config.json bash scripts/vpn-doctor.sh --client

set -uo pipefail

CFG="${CFG:-/etc/sing-box/config.json}"
PBKF="${PBKF:-/etc/sing-box/reality_public_key.txt}"
SRV_IP="${SRV_IP:-192.36.41.201}"
# Версия отчёта: поднимать при КАЖДОЙ правке проверок — иначе не отличить,
# свежий скрипт отработал или закешированный старый (ловили 2026-08-20).
DOCTOR_VER="2026-08-20.3"
MODE=""
case "${1:-}" in
  --client) MODE=client ;;
  --server) MODE=server ;;
  "") ;;
  *) echo "usage: vpn-doctor.sh [--client|--server]"; exit 2 ;;
esac

have() { command -v "$1" >/dev/null 2>&1; }

# GNU timeout есть на Linux, но НЕ на macOS. Без обёртки openssl/curl либо висят,
# либо (как было) команда не находится и проверка молча превращается в ложный FAIL.
if have timeout;      then TO() { timeout "$@"; };  TO_KIND=timeout
elif have gtimeout;   then TO() { gtimeout "$@"; }; TO_KIND=gtimeout
elif have perl;       then TO() { local s="$1"; shift; perl -e 'alarm shift; exec @ARGV' "$s" "$@"; }; TO_KIND=perl
else                       TO() { shift; "$@"; };   TO_KIND="НЕТ (проверки без таймаута)"
fi
hr() { printf '%s\n' "----------------------------------------------------------"; }

[[ -f "$CFG" ]] || { echo "Нет $CFG — sing-box здесь не настроен."; exit 1; }

# Кто мы: у сервера vless в inbounds, у клиента — в outbounds.
if [[ -z "$MODE" ]]; then
  MODE=$(python3 - "$CFG" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
ins=[i for i in d.get("inbounds",[]) if i.get("type")=="vless"]
print("server" if ins else "client")
PY
)
fi

echo "=========================================================="
echo " vpn-doctor v$DOCTOR_VER — режим: $MODE   ($(date -u '+%Y-%m-%d %H:%M UTC'))"
echo "=========================================================="

# ---------- общая часть: параметры Reality в виде отпечатков ----------
echo
echo "=== ПАРАМЕТРЫ REALITY (отпечатки, сравнивать клиент vs сервер) ==="
PBK_FILE_VAL="$( { tr -d '[:space:]' < "$PBKF"; } 2>/dev/null || true)"
MODE="$MODE" PBKFILE="$PBK_FILE_VAL" python3 - "$CFG" <<'PY'
import json,sys,os,hashlib

def fp(v):
    if not v: return "—"
    return "sha256:" + hashlib.sha256(v.encode()).hexdigest()[:8]

def dom(v):
    if not v: return "—"
    bad = "[" in v or "]" in v or "(" in v
    return f"{v}  (len={len(v)}{', MARKDOWN!!' if bad else ''})"

d = json.load(open(sys.argv[1]))
mode = os.environ["MODE"]

def show(label, sni, uuid, sid, key, keyname, flow):
    print(f"  {label}")
    print(f"    SNI (decoy)  : {dom(sni)}")
    print(f"    uuid         : {fp(uuid)}")
    print(f"    short_id     : {fp(sid)}   (значение: {sid or '—'})")
    print(f"    {keyname:<13}: {fp(key)}  (len={len(key) if key else 0})")
    print(f"    flow         : {flow or '—'}")

if mode == "server":
    for i in d.get("inbounds", []):
        if i.get("type") != "vless": continue
        t = i.get("tls", {}); r = t.get("reality", {})
        sid = r.get("short_id"); sid = sid[0] if isinstance(sid, list) and sid else sid
        u = (i.get("users") or [{}])[0]
        show(f"inbound  порт {i.get('listen_port')}", t.get("server_name"),
             u.get("uuid"), sid, r.get("private_key"), "private_key", u.get("flow"))
        print(f"    handshake    : {dom((r.get('handshake') or {}).get('server'))}")
    pub = os.environ.get("PBKFILE", "")
    print(f"  public_key (файл, его же держит клиент): {fp(pub)}  (len={len(pub)})")
else:
    for o in d.get("outbounds", []):
        if o.get("type") != "vless": continue
        t = o.get("tls", {}); r = t.get("reality", {})
        sid = r.get("short_id"); sid = sid[0] if isinstance(sid, list) and sid else sid
        show(f"outbound '{o.get('tag')}' -> {o.get('server')}:{o.get('server_port')}",
             t.get("server_name"), o.get("uuid"), sid, r.get("public_key"),
             "public_key", o.get("flow"))
    ut = [o for o in d.get("outbounds", []) if o.get("type") == "urltest"]
    for o in ut:
        print(f"  urltest '{o.get('tag')}': {', '.join(o.get('outbounds', []))}")
PY

# ---------- клиент (mac) ----------
if [[ "$MODE" == "client" ]]; then
  echo
  echo "=== ДЕМОН НА МАКЕ ==="
  echo "  sing-box: $(sing-box version 2>/dev/null | head -1 || echo 'НЕ УСТАНОВЛЕН')"
  echo "  процесс : $(pgrep -x sing-box >/dev/null && echo 'работает' || echo 'НЕ РАБОТАЕТ')"
  echo "  режим   : $(cat /etc/sing-box/mode 2>/dev/null || echo '—')"
  echo "  killswitch: $([[ -f /etc/sing-box/killswitch.enabled ]] && echo ВКЛЮЧЁН || echo выключен)"
  if have launchctl; then
    sudo -n launchctl print system/com.user.singbox 2>/dev/null \
      | grep -E '^\s*(state|last exit code) ' | sed 's/^/  launchd: /' || echo "  launchd: не загружен"
  fi

  echo
  echo "=== ЛОГ КЛИЕНТА (последние ошибки) ==="
  tail -n 15 /var/log/sing-box.err.log 2>/dev/null | sed 's/^/  /' || echo "  (лога нет)"

  echo
  echo "=== СЕТЬ ДО СЕРВЕРА (запускать с ВЫКЛЮЧЕННЫМ туннелем) ==="
  tcp_ok() {
    nc -z -G 5 "$SRV_IP" "$1" >/dev/null 2>&1 \
      || TO 6 bash -c "exec 3<>/dev/tcp/$SRV_IP/$1" >/dev/null 2>&1
  }
  P443=НЕТ; tcp_ok 443 && P443=да
  P22=НЕТ;  tcp_ok 22  && P22=да
  echo "  TCP 443 (наш Reality) открыт : $P443"
  echo "  TCP 22  (SSH, не-TLS, тот же IP): $P22   <-- если 22 открыт, а 443 нет — режут порт, а не IP"
  echo "  наш выход в интернет: $(curl -s --max-time 8 https://ipinfo.io/country 2>/dev/null | tr -d '\n') / $(curl -s --max-time 8 https://ipinfo.io/org 2>/dev/null)"

  echo
  echo "=== TLS-ХЕНДШЕЙК ==="
  echo "  openssl: $(openssl version 2>/dev/null || echo 'НЕТ')"
  echo "  таймаут-обёртка: $TO_KIND"
  # CN прикрытия через openssl; если openssl молчит (LibreSSL на macOS капризен) —
  # запасная проба через curl: она тоже делает НАСТОЯЩИЙ TLS-хендшейк с нужным SNI.
  cn_of() {
    local cn
    cn=$(echo | TO 12 openssl s_client -connect "$1:443" -servername "$2" 2>/dev/null \
         | sed -n 's/^subject=.*CN *= *//p' | head -1)
    if [[ -n "$cn" ]]; then echo "$cn"; return 0; fi
    if TO 15 curl -s -o /dev/null --noproxy '*' --max-time 12 \
         --connect-to "$2:443:$1:443" "https://$2/" 2>/dev/null; then
      echo "хендшейк прошёл (curl)"; return 0
    fi
    return 1
  }
  err_of() { echo | TO 12 openssl s_client -connect "$1:443" -servername "$2" 2>&1 >/dev/null \
             | grep -iE 'error|alert|unknown|refus|timed|connect:|not found' | head -1 | cut -c1-64; }

  # КОНТРОЛЬ: чужой заведомо живой сайт. Провалился он — виноват инструмент или
  # блокируется весь TLS, и проверки по decoy ниже недостоверны (грабля №5).
  CTRL_CN=$(cn_of www.google.com www.google.com)
  printf '  контроль www.google.com (чужой сайт): %s\n' "${CTRL_CN:-FAIL}"
  echo "  --- к нашему серверу, по каждому decoy ---"
  OKC=0
  for d in www.apple.com www.cloudflare.com dl.google.com addons.mozilla.org www.icloud.com www.samsung.com; do
    cn=$(cn_of "$SRV_IP" "$d")
    if [[ -n "$cn" ]]; then
      OKC=$((OKC+1)); printf '  %-22s CN=%s\n' "$d" "$cn"
    else
      printf '  %-22s FAIL  %s\n' "$d" "$(err_of "$SRV_IP" "$d")"
    fi
  done

  echo
  echo "=== ВЕРДИКТ ==="
  if [[ -z "$CTRL_CN" ]]; then
    echo "  ⚠️ Контроль к чужому сайту ТОЖЕ провалился — дело в openssl или режется весь TLS."
    echo "     Строки по decoy сейчас ничего не доказывают. Перепроверь с другой сети."
  elif (( OKC > 0 )); then
    echo "  Путь до сервера чист: рукопожатие одалживается ($OKC из 6 decoy)."
    echo "  Если туннель всё равно мёртв — рассинхрон параметров: сверь отпечатки uuid/"
    echo "  short_id/ключа с выводом 'bash scripts/vpn-doctor.sh --server' на сервере."
  elif [[ "$P443" == "да" ]]; then
    echo "  TCP до сервера проходит, но TLS не проходит НИ ПО ОДНОМУ decoy при живом контроле"
    echo "  ⇒ рукопожатие режут на пути (DPI/ТСПУ). Сервер, ключи и decoy тут ни при чём —"
    echo "  менять надо порт/IP сервера или транспорт, а не домен-прикрытие."
  else
    echo "  До сервера не доходит даже TCP ⇒ блокировка IP сервера или бан твоего IP у хостера"
    echo "  (грабля №3). Сверься с check-host.net по TCP 443."
  fi
fi

# ---------- сервер ----------
if [[ "$MODE" == "server" ]]; then
  echo
  echo "=== ДЕМОН НА СЕРВЕРЕ ==="
  echo "  sing-box: $(sing-box version 2>/dev/null | head -1 || echo 'НЕ УСТАНОВЛЕН')"
  echo "  service : $(systemctl is-active sing-box 2>/dev/null)  (enabled: $(systemctl is-enabled sing-box 2>/dev/null))"
  echo "  аптайм  : $(uptime -p 2>/dev/null)"
  echo "  часы    : $(date -u '+%F %T UTC')  NTP: $(timedatectl show -p NTPSynchronized --value 2>/dev/null)"
  echo "  порт 443: $(ss -tlnp 2>/dev/null | grep -c ':443 ') слушателей"
  echo "  живых TCP-сессий на 443: $(ss -tn state established '( sport = :443 )' 2>/dev/null | tail -n +2 | wc -l)"
  echo "  конфиг валиден: $(sing-box check -c "$CFG" >/dev/null 2>&1 && echo да || echo 'НЕТ')"

  echo
  echo "=== ТЕСТ REALITY ПО ПЕТЛЕ (родным ключом сервера, без сети) ==="
  echo "  Это отделяет «сервер сломан» от «сеть/клиент виноваты»."
  loop_out=$(bash "$(dirname "${BASH_SOURCE[0]}")/server-status.sh" 2>/dev/null \
             | sed -n '/Reality/,/монитор/p' | sed '/монитор/d')
  [[ -n "$loop_out" ]] && echo "$loop_out" | sed 's/^/  /' \
    || echo "  (server-status.sh не отработал — sing-box не установлен?)"

  echo
  echo "=== ОТВЕРГНУТЫЕ КЛИЕНТЫ ЗА СУТКИ ==="
  n=$(journalctl -u sing-box --since '24 hours ago' --no-pager 2>/dev/null | grep -ci 'invalid connection')
  echo "  'REALITY: processed invalid connection': $n шт."
  echo "  IP-адреса, которых отвергли (последний октет скрыт):"
  journalctl -u sing-box --since '24 hours ago' --no-pager 2>/dev/null \
    | grep -i 'invalid connection' \
    | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' \
    | sed 's/\.[0-9]*$/.x/' | sort | uniq -c | sort -rn | head -5 | sed 's/^/    /' \
    || echo "    (нет)"
  echo "  последние строки лога:"
  journalctl -u sing-box -n 8 --no-pager 2>/dev/null | sed 's/^/    /'

  echo
  echo "=== АВТО-МОНИТОР DECOY ==="
  echo "  timer: $(systemctl is-active decoy-monitor.timer 2>/dev/null || echo 'НЕ установлен')"
  journalctl -u decoy-monitor -n 5 --no-pager 2>/dev/null | sed 's/^/    /'

  echo
  echo "=== КОГДА В ПОСЛЕДНИЙ РАЗ МЕНЯЛСЯ КОНФИГ/КЛЮЧИ ==="
  echo "  (если дата совпадает с днём поломки — виноват перезапуск setup/fix-reality-sni)"
  for f in "$CFG" "$PBKF" /etc/sing-box/credentials.txt; do
    [[ -e "$f" ]] && printf '    %-40s %s\n' "$f" "$(date -r "$f" '+%F %T' 2>/dev/null || stat -c %y "$f" 2>/dev/null)"
  done
fi

hr
echo "Готово. Этот вывод можно целиком отправить в чат — секретов в нём нет."
