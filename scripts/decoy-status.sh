#!/usr/bin/env bash
#
# decoy-status.sh — проверяет ВСЕ домены-прикрытия и пишет результат в JSON,
# чтобы панель могла показать, какой узел доступен, а какой нет.
# Запуск на сервере (обычно его дёргает панель кнопкой «Проверить сейчас»):
#   bash scripts/decoy-status.sh
#
# Зачем отдельно от decoy-monitor.sh: тот проверяет ТОЛЬКО текущий decoy и молча
# переключает сервер. Здесь нужен полный срез — он же нужен владельцу, когда он
# выдаёт узлы для Shadowrocket (там переключение ручное).
#
# Проверки разные и это принципиально:
#   активный decoy — против ЖИВОГО сервера (127.0.0.1:443): именно он сейчас несёт
#     клиентов, и важно, что работает вся связка целиком;
#   остальные — по петле отдельным мини сервер+клиент: они на сервере не подняты,
#     проверяем лишь «одалживается ли рукопожатие», то есть годится ли для перехода.
#
# Пробы идут ПО ОЧЕРЕДИ: на 1 ГБ RAM несколько sing-box разом класть нельзя.
# flock не даёт запустить второй прогон поверх первого.

set -uo pipefail
CFG="${CFG:-/etc/sing-box/config.json}"
OUT="${OUT:-/etc/sing-box/decoy-status.json}"
PBKF="${PBKF:-/etc/sing-box/reality_public_key.txt}"
LOCK="${LOCK:-/tmp/decoy-status.lock}"
# Тот же список, что в decoy-monitor.sh и в панели — иначе покажем не то, куда
# монитор реально может переключиться.
DECOYS=(www.apple.com www.cloudflare.com dl.google.com addons.mozilla.org www.icloud.com www.samsung.com)

# Порты СВОИ: 18555/10878 занимает decoy-monitor, 10866 — server-status,
# 18443/10810 — reality-env-check. Пересечься — значит ловить ложный FAIL.
SRV_PORT=18557
CLI_PORT=10882
LIVE_PORT=10884

exec 9>"$LOCK"
flock -n 9 || { echo "[decoy-status] проверка уже идёт — выхожу"; exit 3; }

[[ -f "$CFG" ]] || { echo "[decoy-status] нет $CFG"; exit 1; }
command -v sing-box >/dev/null 2>&1 || { echo "[decoy-status] нет sing-box"; exit 1; }

CUR=$(python3 -c "import json;print(json.load(open('$CFG'))['inbounds'][0]['tls']['server_name'])")
PBK=$(tr -d '[:space:]' < "$PBKF" 2>/dev/null)
UUID=$(python3 -c "import json;print(json.load(open('$CFG'))['inbounds'][0]['users'][0]['uuid'])")
SID=$(python3 -c "import json;r=json.load(open('$CFG'))['inbounds'][0]['tls']['reality']['short_id'];print(r[0] if isinstance(r,list) else r)")
FLOW=$(python3 -c "import json;print(json.load(open('$CFG'))['inbounds'][0]['users'][0].get('flow',''))")

# Испорченный markdown-ссылкой SNI (грабля №1) — лучше упасть, чем писать мусор в статус.
if [[ "$CUR" == *"["* || ${#CUR} -gt 40 ]]; then
  echo "[decoy-status] server_name выглядит испорченным (len ${#CUR}) — останавливаюсь"; exit 1
fi

# активный decoy: против живого сервера
test_live(){
  local cc P
  SNI="$CUR" PBK="$PBK" UUID="$UUID" SID="$SID" FLOW="$FLOW" PORT="$LIVE_PORT" python3 <<'PY'
import json,os
co={"type":"vless","server":"127.0.0.1","server_port":443,"uuid":os.environ["UUID"],
 "tls":{"enabled":True,"server_name":os.environ["SNI"],"utls":{"enabled":True,"fingerprint":"chrome"},
 "reality":{"enabled":True,"public_key":os.environ["PBK"],"short_id":os.environ["SID"]}}}
if os.environ["FLOW"]: co["flow"]=os.environ["FLOW"]
json.dump({"log":{"level":"error"},
 "inbounds":[{"type":"mixed","listen":"127.0.0.1","listen_port":int(os.environ["PORT"])}],
 "outbounds":[co]},open("/tmp/ds_live.json","w"))
PY
  sing-box run -c /tmp/ds_live.json >/dev/null 2>&1 & P=$!
  sleep 3
  cc=$(curl -s --max-time 6 --socks5-hostname "127.0.0.1:$LIVE_PORT" https://ipinfo.io/country 2>/dev/null)
  kill "$P" 2>/dev/null; sleep 1
  [[ -n "$cc" ]]
}

# запасной decoy: «одалживается» ли рукопожатие (мини сервер+клиент на петле)
loop_ok(){
  local sni="$1" kp priv pub uuid cc S C
  kp=$(sing-box generate reality-keypair)
  priv=$(echo "$kp"|sed -n 's/^PrivateKey:[[:space:]]*//p')
  pub=$(echo "$kp"|sed -n 's/^PublicKey:[[:space:]]*//p')
  uuid=$(sing-box generate uuid)
  SNI="$sni" PRIV="$priv" PUB="$pub" UUID="$uuid" SP="$SRV_PORT" CP="$CLI_PORT" python3 <<'PY'
import json,os
sni=os.environ['SNI'];priv=os.environ['PRIV'];pub=os.environ['PUB'];uuid=os.environ['UUID']
sp=int(os.environ['SP']);cp=int(os.environ['CP'])
json.dump({"log":{"level":"error"},"inbounds":[{"type":"vless","listen":"127.0.0.1","listen_port":sp,
 "users":[{"uuid":uuid}],"tls":{"enabled":True,"server_name":sni,"reality":{"enabled":True,
 "handshake":{"server":sni,"server_port":443},"private_key":priv,
 "short_id":["0123456789abcdef"]}}}],"outbounds":[{"type":"direct"}]},open("/tmp/ds_srv.json","w"))
json.dump({"log":{"level":"error"},"inbounds":[{"type":"mixed","listen":"127.0.0.1","listen_port":cp}],
 "outbounds":[{"type":"vless","server":"127.0.0.1","server_port":sp,"uuid":uuid,
 "tls":{"enabled":True,"server_name":sni,"utls":{"enabled":True,"fingerprint":"chrome"},
 "reality":{"enabled":True,"public_key":pub,"short_id":"0123456789abcdef"}}}]},open("/tmp/ds_cli.json","w"))
PY
  sing-box run -c /tmp/ds_srv.json >/dev/null 2>&1 & S=$!
  sleep 2
  sing-box run -c /tmp/ds_cli.json >/dev/null 2>&1 & C=$!
  sleep 3
  cc=$(curl -s --max-time 6 --socks5-hostname "127.0.0.1:$CLI_PORT" https://ipinfo.io/country 2>/dev/null)
  kill "$S" "$C" 2>/dev/null; sleep 1
  [[ -n "$cc" ]]
}

TMP="$(mktemp)"
trap 'rm -f "$TMP" /tmp/ds_live.json /tmp/ds_srv.json /tmp/ds_cli.json' EXIT

LIST=("${DECOYS[@]}")
# Сервер мог уехать на домен вне списка — его тоже показываем, иначе владелец
# увидит «активного нет» и решит, что всё сломано.
printf '%s\n' "${LIST[@]}" | grep -qxF "$CUR" || LIST=("$CUR" "${LIST[@]}")

START=$(date +%s)
for d in "${LIST[@]}"; do
  if [[ "$d" == "$CUR" ]]; then
    # двойная проверка, как в мониторе: одиночный FAIL бывает от сетевого чиха
    if test_live || test_live; then st=active_ok; else st=active_fail; fi
  else
    if loop_ok "$d"; then st=ready; else st=dead; fi
  fi
  printf '%s\t%s\n' "$d" "$st" >> "$TMP"
  echo "[decoy-status] $d -> $st"
done

SRC="$TMP" OUT="$OUT" CUR="$CUR" START="$START" python3 <<'PY'
import json,os,time
res={}
for line in open(os.environ["SRC"]):
    if not line.strip(): continue
    d,st=line.rstrip("\n").split("\t")
    res[d]=st
out=os.environ["OUT"]
data={"checked_at":int(time.time()),"took":int(time.time())-int(os.environ["START"]),
      "active":os.environ["CUR"],"results":res}
# Пишем через .tmp + rename: панель читает этот файл в любой момент и не должна
# поймать половину.
tmp=out+".tmp"
json.dump(data,open(tmp,"w"),indent=2,ensure_ascii=False)
os.replace(tmp,out)
print("[decoy-status] записано в",out)
PY
