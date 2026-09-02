#!/usr/bin/env bash
#
# fix-ru-rules.sh — доносит до УЖЕ настроенного мака правки правил «российское — напрямую»
# из шаблона. Нужен потому, что configs/singbox-client.local.json собирается из шаблона
# один раз, и правки шаблона в него сами не попадают (install-macos-daemon.sh
# переиспользует существующий файл).
#   cd ~/vpn && bash scripts/fix-ru-rules.sh
#
# Что правит (идемпотентно, можно гонять сколько угодно):
#   1. К правилу RU→direct добавляет ".xn--p1ai" — это ".рф" в punycode. В TLS (SNI)
#      домен всегда идёт в punycode, поэтому кириллическое ".рф" в правиле НЕ
#      срабатывало и сайты .рф уходили через Латвию (проверено на sing-box 1.13.13).
#   2. dns.reverse_mapping=true — sing-box запоминает, какому имени он отдал IP, и
#      доменные правила работают даже там, где SNI снифером не читается.
# Затем: бэкап → sing-box check → откат при провале → install-macos-daemon.sh.

set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL="${LOCAL:-$DIR/configs/singbox-client.local.json}"
INSTALL="${INSTALL:-1}"
[[ -f "$LOCAL" ]] || { echo "Нет $LOCAL — сначала настрой клиента."; exit 1; }

BAK="$LOCAL.bak.$(date +%s)"
cp "$LOCAL" "$BAK" && echo "[*] Бэкап: $BAK"

python3 - "$LOCAL" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); changed=[]
rules=d.setdefault("route",{}).setdefault("rules",[])
ru=[r for r in rules if r.get("outbound")=="direct" and ".ru" in (r.get("domain_suffix") or [])]
if not ru:
    print("[!] Не нашёл правило RU→direct (domain_suffix с .ru) — это не умный режим?"); sys.exit(1)
for r in ru:
    if ".xn--p1ai" not in r["domain_suffix"]:
        i=r["domain_suffix"].index(".рф")+1 if ".рф" in r["domain_suffix"] else len(r["domain_suffix"])
        r["domain_suffix"].insert(i,".xn--p1ai"); changed.append(".xn--p1ai в правило RU→direct")
dns=d.setdefault("dns",{})
if dns.get("reverse_mapping") is not True:
    dns["reverse_mapping"]=True; changed.append("dns.reverse_mapping=true")
if not changed:
    print("[*] Уже применено, править нечего."); sys.exit(0)
json.dump(d,open(p,"w"),indent=2,ensure_ascii=False)
print("[*] Применено: "+"; ".join(changed))
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
  echo "[OK] Правила обновлены. Проверка (VPN включён, умный режим):"
  echo "   curl -s https://ipinfo.io/country                 # зарубеж видит LV"
  echo "   curl -s https://yandex.ru/internet/api/v0/ip     # yandex.ru видит РОССИЙСКИЙ адрес, не 83.172.x.x"
fi
