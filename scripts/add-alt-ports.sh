#!/usr/bin/env bash
#
# add-alt-ports.sh — поднимает Reality ДОПОЛНИТЕЛЬНО на запасных портах.
# Запускать НА СЕРВЕРЕ под root:
#   cd /root/vpn && git pull origin main && bash scripts/add-alt-ports.sh
#
# Зачем: DPI умеет резать рукопожатие по паре «IP + порт 443», при этом путь до
# ОСТАЛЬНЫХ портов остаётся чистым (проверяется `scripts/path-probe.sh`: ответ
# refused = пакеты доходят). Клиент держит все порты в одном urltest и сам
# выбирает живой — как с доменами-прикрытиями.
#
# Идемпотентно: существующие входы не трогает, ключи/uuid/short_id НЕ меняет
# (иначе отвалятся все клиенты — грабля №2), при ошибке откатывает конфиг.

set -uo pipefail
CFG=/etc/sing-box/config.json
PORTS="${ALT_PORTS:-2053 8443}"

[[ -f "$CFG" ]] || { echo "Нет $CFG — sing-box здесь не настроен."; exit 1; }
BAK="$CFG.bak.$(date +%s)"
cp "$CFG" "$BAK" || exit 1
echo "[*] Бэкап: $BAK"

PORTS="$PORTS" python3 - "$CFG" <<'PY'
import json,os,sys,copy
p=sys.argv[1]; d=json.load(open(p))
vless=[i for i in d.get("inbounds",[]) if i.get("type")=="vless"]
if not vless:
    print("В конфиге нет vless-инбаунда — нечего клонировать."); sys.exit(2)
base=vless[0]
have={i.get("listen_port") for i in vless}
added=[]
for port in [int(x) for x in os.environ["PORTS"].split()]:
    if port in have: continue
    n=copy.deepcopy(base)
    n["listen_port"]=port
    n["tag"]=f"vless-reality-in-{port}"
    d["inbounds"].append(n); added.append(port)
json.dump(d,open(p,"w"),indent=2)
print("[*] Добавлены порты:", ", ".join(map(str,added)) if added else "нет (уже были)")
print("[*] Теперь слушаем:", ", ".join(str(i["listen_port"]) for i in d["inbounds"] if i.get("type")=="vless"))
PY
rc=$?
[[ $rc -eq 0 ]] || { echo "[!] Правка не удалась — откат."; cp "$BAK" "$CFG"; exit $rc; }

echo "[*] Проверяю конфиг..."
if ! sing-box check -c "$CFG"; then
  echo "[!] sing-box check не прошёл — откатываю."; cp "$BAK" "$CFG"; exit 1
fi

# Фаервол: на EDIS ufw обычно нет и порты открыты по умолчанию (LEARNINGS №6).
if command -v ufw >/dev/null 2>&1; then
  for p in $PORTS; do ufw allow "$p/tcp" >/dev/null 2>&1 || true; done
  echo "[*] ufw: порты открыты."
fi

systemctl restart sing-box
sleep 2
echo "[*] sing-box: $(systemctl is-active sing-box)"
if [[ "$(systemctl is-active sing-box)" != "active" ]]; then
  echo "[!] Демон не поднялся — откатываю конфиг."; cp "$BAK" "$CFG"; systemctl restart sing-box; exit 1
fi

echo "[*] Слушаются порты:"
ss -tlnp 2>/dev/null | awk '/sing-box/ {print "    "$4}' | sort -u

echo
echo "[OK] Готово. Дальше на КЛИЕНТЕ:"
echo "  мак:    cd ~/vpn && git pull && bash scripts/upgrade-client.sh"
echo "  айфон:  bash scripts/make-ios-configs-server.sh   (здесь же, на сервере)"
echo "Откат при необходимости: cp $BAK $CFG && systemctl restart sing-box"
