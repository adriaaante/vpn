#!/usr/bin/env bash
#
# server-ips-status.sh — какие адреса сервера сейчас живые. Запускать НА МАКЕ:
#   cd ~/vpn && bash scripts/server-ips-status.sh
#
# Нужен, когда адресов несколько (add-client-ip.sh): переключение между ними
# автоматическое и МОЛЧАЛИВОЕ, поэтому по ощущениям всё хорошо ровно до того дня,
# когда закончится последний живой адрес. Этот скрипт показывает, какой уже
# сгорел, чтобы докупить замену заранее, а не в момент простоя.
#
# Проверка — настоящее TLS-рукопожатие к домену-прикрытию через нужный адрес
# (curl --connect-to), а не пинг: у нашей блокировки TCP открывается, а данные
# выбрасываются, поэтому пинг и nc врут (грабля №5c).
# ВАЖНО: запускать при ВЫКЛЮЧЕННОМ туннеле — иначе проверка пойдёт через туннель
# и все адреса покажутся живыми. Скрипт сам предупредит.

set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL="${LOCAL:-$DIR/configs/singbox-client.local.json}"
[[ -f "$LOCAL" ]] || { echo "Нет $LOCAL — сначала настрой клиента."; exit 1; }

if pgrep -x sing-box >/dev/null 2>&1; then
  echo "[!] Туннель включён — проверка пойдёт ЧЕРЕЗ него и покажет всё живым."
  echo "    Выключи и запусти снова:  bash scripts/vpn.sh off && bash scripts/server-ips-status.sh; bash scripts/vpn.sh on"
  echo
fi

# Что проверяем, берём из самого конфига: какие адреса, порты и домены прикрытия
# клиент реально использует, те и пробуем. Итог считаем ПО АДРЕСАМ, а не по портам:
# адрес живой, если ответил хотя бы один его порт — трафик пойдёт по нему.
mapfile -t ROWS < <(python3 - "$LOCAL" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); seen={}
for o in d.get("outbounds",[]):
    if o.get("type")!="vless": continue
    srv=str(o.get("server","")); sni=((o.get("tls") or {}).get("server_name") or "")
    port=o.get("server_port",443)
    if not srv or not sni: continue
    seen.setdefault((srv,port),sni)
for (srv,port),sni in sorted(seen.items()):
    print(srv,port,sni,sep="\t")
PY
)
(( ${#ROWS[@]} )) || { echo "В конфиге нет vless-узлов."; exit 1; }

probe() { # probe <sni> <адрес> <порт> — настоящее TLS-рукопожатие через этот адрес
  # --noproxy: прокси в окружении иначе даёт ложную ошибку TLS (грабля №5b).
  curl -sS --noproxy '*' --max-time 8 --connect-to "$1:443:$2:$3" -o /dev/null "https://$1/" 2>/dev/null
}

ADDRS=$(printf '%s\n' "${ROWS[@]}" | cut -f1 | awk '!seen[$0]++')
alive=0; dead=0; dead_list=""
for a in $ADDRS; do
  ok=""; bad=""
  for row in "${ROWS[@]}"; do
    IFS=$'\t' read -r srv port sni <<< "$row"
    [[ "$srv" == "$a" ]] || continue
    if probe "$sni" "$srv" "$port"; then ok="$ok $port"; else bad="$bad $port"; fi
  done
  if [[ -n "$ok" ]]; then
    alive=$((alive+1)); echo "  $a — живой ✅  (отвечает на порту:${ok}${bad:+, молчит на:$bad})"
  else
    dead=$((dead+1)); dead_list="$dead_list $a"
    echo "  $a — не отвечает ❌  (пробовали порты:${bad})"
  fi
done

echo
if (( dead == 0 )); then
  echo "[OK] Все адреса живые ($alive). Запас есть."
elif (( alive > 0 )); then
  echo "[!] Живых адресов: $alive, мёртвых: $dead ($(echo $dead_list))."
  echo "    Туннель работает на живых, простоя нет — но запас сократился."
  echo "    Замена: докупить у EDIS доп. IPv4 (5 €/мес, ПРОСИ ДРУГОЙ ПРЕФИКС, не"
  echo "    89.46.238.x и не 83.172.151.x), затем на сервере add-server-ip.sh,"
  echo "    на маке add-client-ip.sh. Мёртвый адрес убрать: add-client-ip.sh --remove <IP>"
else
  echo "[!] Живых адресов нет. Это либо блокировка всех сразу, либо сервер лежит:"
  echo "    проверь снаружи — bash scripts/vpn-doctor.sh"
fi
