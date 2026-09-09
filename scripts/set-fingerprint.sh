#!/usr/bin/env bash
#
# set-fingerprint.sh — меняет отпечаток TLS-клиента (uTLS) в конфиге мака.
#   cd ~/vpn && bash scripts/set-fingerprint.sh firefox   # уйти из-под правила ТСПУ
#   cd ~/vpn && bash scripts/set-fingerprint.sh chrome    # вернуть как было
#
# ЗАЧЕМ. Разбор схемы ограничений ТСПУ (habr.com/ru/articles/1044396/, июнь 2026)
# описывает «заморозку» соединений, которая включается, только когда совпали ТРИ
# условия сразу:
#   1. адрес сервера в «подозрительной» подсети/AS (любой зарубежный хостинг);
#   2. отпечаток TLS-клиента — chrome, safari или ios;
#   3. больше 3 параллельных попыток TLS к серверу в рамках ОДНОГО SNI за 60 с
#      (интервал между ними меньше ~350–400 мс).
# При срабатывании замирают ВСЕ соединения к этому адресу на 120 с — по любому
# порту, включая ssh. Это ровно наша «грабля №5c»: TCP открыт, данные не идут,
# ssh-22 мёртв, а пустые порты честно отвечают RST.
# Условие 2 снимается одним словом: firefox, edge, 360, qq и android проходят.
# Сервер отпечаток клиента не проверяет — правка чисто клиентская и обратимая.
#
# ЧЕСТНО ПРО ШАНСЫ. Это дешёвая проверка, а не обещание. Против неё говорит то,
# что все ОПИСАННЫЕ поведенческие механизмы ТСПУ (заморозка по объёму 16 КБ,
# policing по числу TLS-соединений) ssh НЕ трогают — это их опознавательный
# признак, — а у нас 02.09 и 20.08 ssh-22 умирал вместе со всем остальным. Значит
# вероятнее списочный бан префикса хостера, и тогда отпечаток не поможет.
# Но проверка занимает минуту, ничего не стоит и обратима, поэтому делается ПЕРВОЙ,
# до трат на новый адрес: если туннель ожил на том же «заблокированном» адресе —
# дело было в отпечатке, и переезжать вообще не нужно.

set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL="${LOCAL:-$DIR/configs/singbox-client.local.json}"
INSTALL="${INSTALL:-1}"
FP="${1:-firefox}"
# Список — тот, что понимает uTLS в sing-box; random/randomized не берём: они
# могут выпасть в chrome, то есть ровно в проблемный вариант.
case "$FP" in
  chrome|firefox|edge|safari|ios|android|360|qq) ;;
  *) echo "Отпечаток: chrome|firefox|edge|safari|ios|android|360|qq (сейчас: $FP)"; exit 2 ;;
esac
[[ -f "$LOCAL" ]] || { echo "Нет $LOCAL — сначала настрой клиента."; exit 1; }

BAK="$LOCAL.bak.$(date +%s)"
cp "$LOCAL" "$BAK" && echo "[*] Бэкап: $BAK"

FP="$FP" python3 - "$LOCAL" <<'PY'
import json,os,sys
p=sys.argv[1]; fp=os.environ["FP"]; d=json.load(open(p)); was=set(); n=0
for o in d.get("outbounds",[]):
    u=(o.get("tls") or {}).get("utls")
    if not isinstance(u,dict): continue
    was.add(str(u.get("fingerprint","—"))); u["fingerprint"]=fp; n+=1
if not n:
    print("[!] В конфиге нет ни одного utls-отпечатка — править нечего."); sys.exit(1)
json.dump(d,open(p,"w"),indent=2,ensure_ascii=False)
print(f"[*] Отпечаток в {n} узлах: {', '.join(sorted(was))} -> {fp}")
PY
rc=$?
if (( rc != 0 )); then cp "$BAK" "$LOCAL"; echo "[!] Правка не удалась — откат."; exit 1; fi

if command -v sing-box >/dev/null 2>&1; then
  sing-box check -c "$LOCAL" || { echo "[!] Конфиг невалиден — откат."; cp "$BAK" "$LOCAL"; exit 1; }
  echo "[*] Конфиг валиден."
fi

if [[ "$INSTALL" == 1 ]]; then
  bash "$DIR/scripts/install-macos-daemon.sh" || { echo "[!] Установка не прошла. Откат: cp \"$BAK\" \"$LOCAL\" && bash $DIR/scripts/install-macos-daemon.sh"; exit 1; }
  echo
  echo "[OK] Отпечаток теперь $FP. Проверка (подожди 15–20 с после установки):"
  echo "   curl -s --max-time 10 https://ipinfo.io/json | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d[\"ip\"],d[\"country\"])'"
  echo "   ждём латвийский адрес и LV. Вернуть как было: bash scripts/set-fingerprint.sh chrome"
fi
