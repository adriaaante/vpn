#!/usr/bin/env bash
#
# vpn-users.sh — доступ для друзей: свой ключ каждому, мгновенный отзыв и возврат.
# Запускать НА СЕРВЕРЕ под root:
#   bash scripts/vpn-users.sh list
#   bash scripts/vpn-users.sh add ivan        # завести и сразу выдать конфиг
#   bash scripts/vpn-users.sh share ivan      # выдать конфиг ещё раз
#   bash scripts/vpn-users.sh disable ivan    # отключить (ключ сохраняется)
#   bash scripts/vpn-users.sh enable ivan     # вернуть
#   bash scripts/vpn-users.sh remove ivan     # удалить насовсем
#   bash scripts/vpn-users.sh apply           # пересобрать конфиг из реестра
#   bash scripts/vpn-users.sh broadcast [часы] # раздать СВЕЖИЙ профиль всем сразу и
#                                             # закрыться, когда каждый скачал (по умолч. 24 ч)
#
# Источник правды — /etc/sing-box/users.json; из него собирается список users во
# ВСЕХ vless-инбаундах (443/2053/8443), иначе человек отвалится при переезде на
# запасной порт. Твой собственный ключ переносится в стор как есть и не меняется.
#
# Чего этот механизм НЕ умеет: запретить человеку скопировать свой конфиг другому.
# Технически невозможно. Защита в другом: ключ персональный, поэтому видно, чей
# именно утёк, и отзывается он одной командой, не задевая остальных.

set -uo pipefail
CFG="${CFG:-/etc/sing-box/config.json}"
STORE="${STORE:-/etc/sing-box/users.json}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CMD="${1:-list}"
NAME="${2:-}"

have() { command -v "$1" >/dev/null 2>&1; }
[[ -f "$CFG" ]] || { echo "Нет $CFG"; exit 1; }

# Первый запуск: переносим уже существующих пользователей из конфига, чтобы
# ничей доступ (в первую очередь твой) не пропал.
if [[ ! -f "$STORE" ]]; then
  CFG="$CFG" STORE="$STORE" python3 <<'PY'
import json,os
c=json.load(open(os.environ["CFG"]))
vless=[i for i in c.get("inbounds",[]) if i.get("type")=="vless"]
users=[]
for n,u in enumerate((vless[0].get("users") if vless else []) or []):
    users.append({"name":u.get("name") or ("owner" if n==0 else f"user{n}"),
                  "uuid":u["uuid"],"enabled":True,"note":"перенесён из config.json",
                  # Первый ключ — твой: помечаем, чтобы панель и скрипт не дали
                  # отключить или удалить его случайно и отрезать тебе доступ.
                  "protected": n == 0})
# flow обязан совпадать с клиентским. Раньше apply брал его из конфига — но
# стоит один раз собрать конфиг без пользователей, и flow исчезает навсегда.
# Поэтому храним его в сторе.
flow=""
for u in ((vless[0].get("users") if vless else []) or []):
    if u.get("flow"): flow=u["flow"]; break
json.dump({"flow":flow,"users":users},open(os.environ["STORE"],"w"),indent=2,ensure_ascii=False)
os.chmod(os.environ["STORE"],0o600)
print(f"[*] Создан {os.environ['STORE']}: перенесено пользователей — {len(users)}")
PY
fi

get_field() { # name field -> значение из стора
  NAME="$1" FIELD="$2" STORE="$STORE" python3 -c "
import json,os
d=json.load(open(os.environ['STORE']))
for u in d['users']:
    if u['name']==os.environ['NAME']: print(u.get(os.environ['FIELD'],'')); break
"
}

apply() { # собрать users во всех vless-инбаундах из стора, проверить, применить
  local bak="$CFG.bak.$(date +%s)"
  cp "$CFG" "$bak" || return 1
  CFG="$CFG" STORE="$STORE" python3 <<'PY'
import json,os
cfg=os.environ["CFG"]; c=json.load(open(cfg))
store=json.load(open(os.environ["STORE"]))
active=[u for u in store["users"] if u.get("enabled")]
vless=[i for i in c.get("inbounds",[]) if i.get("type")=="vless"]
# Конфиг без единого пользователя = «unknown UUID» всем, включая владельца.
# Один раз так и вышло — молча, потому что проверять было некому.
if not active:
    raise SystemExit("[!] В реестре нет ни одного включённого пользователя — "
                     "сборка отменена, иначе доступ потеряли бы все.")
# flow одинаков для всех и обязан совпадать с клиентским. Берём из стора;
# конфиг — только запасной источник (в нём его может уже не быть).
flow=store.get("flow") or ""
for i in vless:
    if flow: break
    for u in (i.get("users") or []):
        if u.get("flow"): flow=u["flow"]; break
for i in vless:
    i["users"]=[{k:v for k,v in (("name",u["name"]),("uuid",u["uuid"]),("flow",flow)) if v} for u in active]

# Запреты по людям: правило route с "user" + reject. Проверено на sing-box 1.13 —
# схема валидна и демон стартует. Список правил пересобираем целиком из стора,
# поэтому ручные правки route в конфиге не переживут apply (других правил тут нет).
rules=[]
for u in active:
    sufs=[str(x).strip().lower().lstrip("*") for x in u.get("block_domains",[]) if str(x).strip()]
    tlds=[str(x).strip().lower() for x in u.get("block_tld",[]) if str(x).strip()]
    tlds=[t if t.startswith(".") else "."+t for t in tlds]
    both=sorted(set(s for s in sufs+tlds if s))
    if both:
        rules.append({"user":[u["name"]],"domain_suffix":both,"action":"reject"})
if rules:
    c["route"]={"rules":rules,"final":"direct"}
else:
    c.pop("route",None)
json.dump(c,open(cfg,"w"),indent=2,ensure_ascii=False)
print("[*] Активны:", ", ".join(u["name"] for u in active) or "никого")
if rules:
    print("[*] Запреты:", "; ".join(f'{r["user"][0]}: {len(r["domain_suffix"])}' for r in rules))
PY
  if [[ $? -ne 0 ]]; then echo "[!] Сборка не удалась — откат."; cp "$bak" "$CFG"; return 1; fi
  if have sing-box && ! sing-box check -c "$CFG"; then
    echo "[!] sing-box check не прошёл — откат."; cp "$bak" "$CFG"; return 1
  fi
  # systemctl может быть недоступен (контейнер, тест) — тогда его молчание нельзя
  # трактовать как "демон умер", иначе получаем ложный откат и рассинхрон
  # стора с конфигом.
  local st
  st="$(systemctl is-active sing-box 2>/dev/null || true)"
  if [[ -z "$st" ]]; then
    echo "[*] systemd недоступен — конфиг записан, перезапусти sing-box вручную."
    return 0
  fi
  systemctl restart sing-box; sleep 2
  st="$(systemctl is-active sing-box 2>/dev/null || true)"
  if [[ "$st" != "active" ]]; then
    echo "[!] Демон не поднялся ($st) — откат конфига."; cp "$bak" "$CFG"; systemctl restart sing-box
    echo "[!] ВАЖНО: $STORE изменён, а конфиг откачен. Верни изменение в сторе или разберись с ошибкой."
    return 1
  fi
  echo "[*] sing-box: $st"
  return 0
}

BCAST_STATE="${BCAST_STATE:-/etc/sing-box/broadcast-state.json}"
BCAST_LAST="${BCAST_LAST:-/etc/sing-box/broadcast-last.json}"

ensure_token() { # name -> персональный токен ссылки (создаёт, если нет)
  local name="$1" tok
  tok="$(get_field "$name" share_token)"
  if [[ -z "$tok" || "$tok" == "None" ]]; then
    tok="$(python3 -c 'import secrets;print(secrets.token_hex(5))')"
    NAME="$name" TOK="$tok" STORE="$STORE" python3 <<'PY'
import json,os
d=json.load(open(os.environ["STORE"]))
for u in d["users"]:
    if u["name"]==os.environ["NAME"]: u["share_token"]=os.environ["TOK"]
json.dump(d,open(os.environ["STORE"],"w"),indent=2,ensure_ascii=False)
PY
  fi
  echo "$tok"
}

stop_broadcast() { # снять идущую рассылку (она держит тот же порт 8080)
  local pid
  pid="$(python3 -c "import json;print(json.load(open('$BCAST_STATE')).get('pid',''))" 2>/dev/null)"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 0
  if tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q "vpn-users.sh broadcast"; then
    kill -TERM -- "-$(ps -o pgid= -p "$pid" | tr -d ' ')" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
    sleep 1
  fi
  rm -f "$BCAST_STATE"
}

free_port_8080() {
  # Снимаем зависшую прошлую раздачу ДО сборки: её trap делает rm -rf своего
  # каталога и иначе унёс бы уже готовые файлы (см. make-ios-configs-server.sh).
  stop_broadcast
  if ss -tln 2>/dev/null | grep -q ":8080 "; then pkill -f "http.server 8080" 2>/dev/null && sleep 2; fi
}

share() { # собрать и раздать конфиг конкретного человека
  local name="$1" uuid out
  uuid="$(get_field "$name" uuid)"
  [[ -n "$uuid" ]] || { echo "Нет такого пользователя: $name"; exit 1; }
  [[ "$(get_field "$name" enabled)" == "True" ]] || echo "[!] $name сейчас ОТКЛЮЧЁН — конфиг соберётся, но работать не будет."
  free_port_8080
  # Ссылка у каждого своя. Раньше все получали http://host:8080/full.json —
  # и ежечасное «Auto update» у одного человека могло скачать конфиг другого,
  # если в этот момент шла его выдача. Токен постоянный (лежит в реестре),
  # поэтому ссылка человека не меняется от выдачи к выдаче.
  local tok root
  tok="$(ensure_token "$name")"
  root="/tmp/guest-$name"
  out="$root/$tok"
  rm -rf "$root"
  GUEST_UUID="$uuid" OUT_DIR="$out" SERVE=0 bash "$REPO/scripts/make-ios-configs-server.sh" >/dev/null || {
    echo "[!] Не удалось собрать конфиг"; exit 1; }
  # Гостю отдаём ТОЛЬКО умный режим: остальные два — способ случайно пустить весь
  # трафик (в том числе видео) через наш канал и запутаться в профилях.
  rm -f "$out/strict.json" "$out/selective.json"
  # Пустой index.html: без него python -m http.server отдаёт по «/» листинг
  # каталога, то есть показывает токен любому, кто заглянет на порт.
  : > "$root/index.html"
  # Заглушка в каталоге человека. Настоящую памятку панель кладёт сюда фоном
  # через несколько секунд, но открыть ссылку могут и раньше — и тогда вместо
  # памятки показывался ЛИСТИНГ КАТАЛОГА (ловили именно это). Страница
  # обновляется сама, поэтому памятка появится без участия человека.
  cat > "$out/index.html" <<'PLACEHOLDER'
<!doctype html><html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="refresh" content="3">
<title>FutureFlow — доступ к VPN</title><style>
body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;
background:#0c0e12;color:#eef1f7;font:15px/1.55 -apple-system,BlinkMacSystemFont,
'SF Pro Text','Segoe UI',Roboto,sans-serif;-webkit-font-smoothing:antialiased}
.box{text-align:center;padding:28px}
h1{font-size:19px;font-weight:640;margin:0 0 8px}
p{color:#9aa4b8;font-size:13.5px;margin:0}
.sp{width:26px;height:26px;margin:0 auto 18px;border-radius:50%;
border:2px solid #262c39;border-top-color:#5b8dff;animation:r .8s linear infinite}
@keyframes r{to{transform:rotate(360deg)}}
</style></head><body><div class="box"><div class="sp"></div>
<h1>Готовим памятку…</h1><p>Страница обновится сама через пару секунд.</p>
</div></body></html>
PLACEHOLDER
  echo
  echo "============================================================"
  echo " Конфиг для «$name». Раздаю по HTTP — пусть импортирует как"
  echo " Remote-профиль в sing-box (iOS/Android) или скачает файл."
  echo
  # По имени, если оно настроено: ссылка тогда не привяжется к текущему адресу.
  local linkhost
  linkhost="$(tr -d '[:space:]' < /etc/sing-box/server-host.txt 2>/dev/null || true)"
  [[ -n "$linkhost" ]] || linkhost="$(curl -fsSL --max-time 6 https://api.ipify.org 2>/dev/null)"
  echo "   умный (RU напрямую, зарубеж через VPN):"
  echo "     http://$linkhost:8080/$tok/full.json"
  echo
  echo " Ctrl+C, как только импортирует: ссылка отдаёт его ключ без пароля."
  echo "============================================================"
  ufw allow 8080/tcp >/dev/null 2>&1 || true
  trap 'ufw delete allow 8080/tcp >/dev/null 2>&1; rm -rf "$root"' EXIT INT TERM
  cd "$root" && python3 -m http.server 8080
}

broadcast() { # раздать СВЕЖИЕ профили всем включённым и закрыться, когда все скачали
  # Зачем: у гостей в sing-box стоит «Auto update» раз в час по личной ссылке, но
  # ссылка живёт только во время выдачи. Чтобы обновление правил (как .рф в
  # punycode) дошло само, раздаём ВСЕ каталоги разом и следим по запросам, кто
  # уже забрал full.json. Закрываемся, когда забрали все, или по таймауту.
  # root НЕ local: trap EXIT срабатывает уже после выхода из функции, и при set -u
  # локальная переменная там не видна («root: unbound variable», уборка не шла).
  local hours="${1:-24}" map
  root="/tmp/guest-all"
  [[ "$hours" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "Часы — число: broadcast 24"; exit 2; }
  free_port_8080
  # Имя<TAB>uuid<TAB>токен по каждому включённому; токены без записи создаём тут же.
  map="$(STORE="$STORE" python3 <<'PY'
import json,os,secrets
p=os.environ["STORE"]; d=json.load(open(p)); dirty=False
for u in d["users"]:
    if not u.get("enabled"): continue
    if not u.get("share_token"): u["share_token"]=secrets.token_hex(5); dirty=True
    print(u["name"], u["uuid"], u["share_token"], sep="\t")
if dirty: json.dump(d,open(p,"w"),indent=2,ensure_ascii=False)
PY
)"
  [[ -n "$map" ]] || { echo "Включённых пользователей нет — раздавать нечего."; exit 1; }
  rm -rf "$root"; mkdir -p "$root"; : > "$root/index.html"
  local n=0 name uuid tok
  while IFS=$'\t' read -r name uuid tok; do
    [[ -n "$name" ]] || continue
    GUEST_UUID="$uuid" OUT_DIR="$root/$tok" SERVE=0 bash "$REPO/scripts/make-ios-configs-server.sh" >/dev/null \
      || { echo "[!] Не собрался конфиг для $name"; rm -rf "$root"; exit 1; }
    rm -f "$root/$tok/strict.json" "$root/$tok/selective.json"
    # По личной ссылке в это время памятки нет — только профиль для приложения.
    cat > "$root/$tok/index.html" <<'HTML'
<!doctype html><html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>FutureFlow</title>
<style>body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;
background:#0c0e12;color:#eef1f7;font:15px/1.55 -apple-system,BlinkMacSystemFont,'SF Pro Text',
'Segoe UI',Roboto,sans-serif}.box{text-align:center;padding:28px;max-width:420px}
h1{font-size:19px;font-weight:640;margin:0 0 8px}p{color:#9aa4b8;font-size:13.5px;margin:0}</style>
</head><body><div class="box"><h1>Профиль обновляется сам</h1>
<p>Приложение sing-box заберёт свежие настройки автоматически. Если нужна памятка
с QR-кодом — попросите владельца открыть выдачу.</p></div></body></html>
HTML
    n=$((n+1))
  done <<< "$map"
  echo "[*] Собрано профилей: $n. Раздаю на 8080 до $hours ч или пока все не скачают."
  ufw allow 8080/tcp >/dev/null 2>&1 || true
  trap 'ufw delete allow 8080/tcp >/dev/null 2>&1; rm -rf "$root"; rm -f "$BCAST_STATE"' EXIT INT TERM
  ROOT="$root" STATE="$BCAST_STATE" LAST="$BCAST_LAST" HOURS="$hours" MAP="$map" OWN_PID="$$" python3 - <<'PY'
import http.server, json, os, signal, threading, time, functools
root=os.environ["ROOT"]; state=os.environ["STATE"]; last=os.environ["LAST"]
hours=float(os.environ["HOURS"]); now=int(time.time())
users={}
for line in os.environ["MAP"].splitlines():
    name,_,tok=line.split("\t"); users[name]={"token":tok,"fetched":None}
tok2name={u["token"]:n for n,u in users.items()}
st={"pid":int(os.environ["OWN_PID"]),"started":now,"deadline":int(now+hours*3600),"users":users}
lock=threading.Lock()
def save(path,obj):
    tmp=path+".tmp"
    with open(tmp,"w") as f: json.dump(obj,f,ensure_ascii=False,indent=1)
    os.replace(tmp,path)
save(state,st)
def finish(reason):
    with lock:
        st["finished"]=int(time.time()); st["reason"]=reason; save(last,st)
class H(http.server.SimpleHTTPRequestHandler):
    def log_message(self,*a): pass
    def do_GET(self):
        super().do_GET()
        parts=self.path.split("?")[0].strip("/").split("/")
        if len(parts)==2 and parts[1]=="full.json" and parts[0] in tok2name:
            with lock:
                u=st["users"][tok2name[parts[0]]]
                if not u["fetched"]: u["fetched"]=int(time.time()); save(state,st)
http.server.ThreadingHTTPServer.allow_reuse_address=True
srv=http.server.ThreadingHTTPServer(("0.0.0.0",8080),functools.partial(H,directory=root))
def on_term(*a):
    finish("stopped"); os._exit(0)
signal.signal(signal.SIGTERM,on_term); signal.signal(signal.SIGINT,on_term)
def watch():
    while True:
        time.sleep(float(os.environ.get("BCAST_TICK","15")))
        with lock: done=all(u["fetched"] for u in st["users"].values())
        if done or time.time()>st["deadline"]:
            finish("all" if done else "timeout"); srv.shutdown(); return
threading.Thread(target=watch,daemon=True).start()
srv.serve_forever()
PY
  echo "[*] Рассылка завершена."
}

case "$CMD" in
  list)
    STORE="$STORE" python3 <<'PY'
import json,os,hashlib
d=json.load(open(os.environ["STORE"]))
print(f"{'ПОЛЬЗОВАТЕЛЬ':<22}{'СТАТУС':<12}{'КЛЮЧ (отпечаток)':<20}ЗАМЕТКА")
for u in d["users"]:
    fp="sha256:"+hashlib.sha256(u["uuid"].encode()).hexdigest()[:8]
    print(f"{u['name']:<22}{('включён' if u.get('enabled') else 'ОТКЛЮЧЁН'):<12}{fp:<20}{u.get('note','')}")
PY
    ;;
  add)
    [[ -n "$NAME" ]] || { echo "Использование: vpn-users.sh add <имя>"; exit 2; }
    # Только латиница/цифры/._- : имя уходит в путь раздачи и в колонки вывода,
    # кириллица и пробелы ломают и то, и другое (проверено на "Саша ТПК Сферикс").
    [[ "$NAME" =~ ^[A-Za-z0-9._-]+$ ]] || {
      echo "Имя только латиницей, без пробелов: буквы, цифры, точка, дефис, подчёркивание."
      echo "Например:  sasha-tpk-sferiks"; exit 2; }
    [[ -n "$(get_field "$NAME" uuid)" ]] && { echo "Пользователь $NAME уже есть."; exit 1; }
    NEW_UUID="$(sing-box generate uuid 2>/dev/null || python3 -c 'import uuid;print(uuid.uuid4())')"
    NAME="$NAME" NEW_UUID="$NEW_UUID" STORE="$STORE" GUIDE_PIN="${GUIDE_PIN:-}" python3 <<'PY'
import json,os
d=json.load(open(os.environ["STORE"]))
u={"name":os.environ["NAME"],"uuid":os.environ["NEW_UUID"],"enabled":True,"note":""}
# ПИН на памятку пишем ЗДЕСЬ, а не потом из панели: следом идёт apply с
# перезапуском sing-box, а он рвёт ssh-туннель панели — дописать не успеть.
pin="".join(c for c in os.environ.get("GUIDE_PIN","") if c.isdigit())
if 4 <= len(pin) <= 8:
    u["guide_pin"]=pin
d["users"].append(u)
json.dump(d,open(os.environ["STORE"],"w"),indent=2,ensure_ascii=False)
print(f"[*] Добавлен {os.environ['NAME']}")
PY
    apply || exit 1
    # NO_SHARE=1 — вызов из панели: она поднимет раздачу сама, отдельным процессом,
    # иначе add блокировался бы на http-сервере и панель ждала бы его вечно.
    [[ "${NO_SHARE:-0}" == 1 ]] || share "$NAME"
    ;;
  enable|disable)
    [[ -n "$NAME" ]] || { echo "Использование: vpn-users.sh $CMD <имя>"; exit 2; }
    if [[ "$CMD" == disable && "$(get_field "$NAME" protected)" == "True" ]]; then
      echo "«$NAME» — владелец, его отключение отрежет доступ тебе самому. Отказано."; exit 1
    fi
    NAME="$NAME" ON="$([[ "$CMD" == enable ]] && echo 1 || echo 0)" STORE="$STORE" python3 <<'PY'
import json,os,sys
d=json.load(open(os.environ["STORE"])); n=os.environ["NAME"]; on=os.environ["ON"]=="1"
hit=[u for u in d["users"] if u["name"]==n]
if not hit: print("Нет такого пользователя:",n); sys.exit(1)
hit[0]["enabled"]=on
json.dump(d,open(os.environ["STORE"],"w"),indent=2,ensure_ascii=False)
print(f"[*] {n}: {'включён' if on else 'ОТКЛЮЧЁН'}")
PY
    [[ $? -eq 0 ]] && apply
    ;;
  remove)
    [[ -n "$NAME" ]] || { echo "Использование: vpn-users.sh remove <имя>"; exit 2; }
    if [[ "$(get_field "$NAME" protected)" == "True" ]]; then
      echo "«$NAME» — владелец, удаление отрежет доступ тебе самому. Отказано."; exit 1
    fi
    NAME="$NAME" STORE="$STORE" python3 <<'PY'
import json,os,sys
d=json.load(open(os.environ["STORE"])); n=os.environ["NAME"]
if n not in [u["name"] for u in d["users"]]: print("Нет такого пользователя:",n); sys.exit(1)
d["users"]=[u for u in d["users"] if u["name"]!=n]
json.dump(d,open(os.environ["STORE"],"w"),indent=2,ensure_ascii=False)
print(f"[*] {n} удалён насовсем")
PY
    [[ $? -eq 0 ]] && apply
    ;;
  share)
    [[ -n "$NAME" ]] || { echo "Использование: vpn-users.sh share <имя>"; exit 2; }
    share "$NAME"
    ;;
  apply)
    # Пересобрать конфиг из стора: пользователи + их запреты. Зовётся панелью
    # после правки ограничений.
    apply
    ;;
  broadcast)
    broadcast "${NAME:-24}"
    ;;
  *)
    sed -n '3,18p' "$0"
    ;;
esac
