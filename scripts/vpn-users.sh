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
                  "uuid":u["uuid"],"enabled":True,"note":"перенесён из config.json"})
json.dump({"users":users},open(os.environ["STORE"],"w"),indent=2,ensure_ascii=False)
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
# flow берём у первого существующего пользователя: он одинаков для всех и
# обязан совпадать с клиентским, иначе Reality отвергнет подключение.
flow=""
for i in vless:
    for u in (i.get("users") or []):
        if u.get("flow"): flow=u["flow"]; break
    if flow: break
for i in vless:
    i["users"]=[{k:v for k,v in (("name",u["name"]),("uuid",u["uuid"]),("flow",flow)) if v} for u in active]
json.dump(c,open(cfg,"w"),indent=2,ensure_ascii=False)
print("[*] Активны:", ", ".join(u["name"] for u in active) or "никого")
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

share() { # собрать и раздать конфиг конкретного человека
  local name="$1" uuid out
  uuid="$(get_field "$name" uuid)"
  [[ -n "$uuid" ]] || { echo "Нет такого пользователя: $name"; exit 1; }
  [[ "$(get_field "$name" enabled)" == "True" ]] || echo "[!] $name сейчас ОТКЛЮЧЁН — конфиг соберётся, но работать не будет."
  out="/tmp/guest-$name"
  rm -rf "$out"
  GUEST_UUID="$uuid" OUT_DIR="$out" SERVE=0 bash "$REPO/scripts/make-ios-configs-server.sh" >/dev/null || {
    echo "[!] Не удалось собрать конфиг"; exit 1; }
  echo
  echo "============================================================"
  echo " Конфиг для «$name». Раздаю по HTTP — пусть импортирует как"
  echo " Remote-профиль в sing-box (iOS/Android) или скачает файл."
  echo
  echo "   умный (RU напрямую, зарубеж через VPN):"
  echo "     http://$(curl -fsSL --max-time 6 https://api.ipify.org 2>/dev/null):8080/full.json"
  echo
  echo " Ctrl+C, как только импортирует: ссылка отдаёт его ключ без пароля."
  echo "============================================================"
  ufw allow 8080/tcp >/dev/null 2>&1 || true
  trap 'ufw delete allow 8080/tcp >/dev/null 2>&1; rm -rf "$out"' EXIT INT TERM
  cd "$out" && python3 -m http.server 8080
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
    NAME="$NAME" NEW_UUID="$NEW_UUID" STORE="$STORE" python3 <<'PY'
import json,os
d=json.load(open(os.environ["STORE"]))
d["users"].append({"name":os.environ["NAME"],"uuid":os.environ["NEW_UUID"],"enabled":True,"note":""})
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
  *)
    sed -n '3,18p' "$0"
    ;;
esac
