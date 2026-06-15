#!/usr/bin/env bash
#
# make-ios-configs.sh — собирает 3 конфига для приложения sing-box VT на iPhone
# из локального Mac-конфига. НА MAC НИЧЕГО НЕ МЕНЯЕТ (только читает) — результат
# кладёт отдельными файлами configs/ios-{strict,full,selective}.local.json
# (они gitignored, т.к. содержат твои секреты).
#
#   bash scripts/make-ios-configs.sh
#
# Затем перекинь 3 файла на iPhone (AirDrop/Файлы/iCloud) и импортируй в sing-box VT
# как локальные профили. Переключение профиля = переключение режима.
#
# Режимы:
#   ios-strict     — ВЕСЬ трафик через Латвию (включая RU); RU IP не видит никто
#   ios-full       — зарубеж через Латвию, российские сайты напрямую
#   ios-selective  — только сервисы (Claude/ChatGPT/YouTube/Telegram) через Латвию,
#                    RU-сайты напрямую, ВСЁ остальное зарубежное блокируется
#                    (leak-proof: российский IP не утечёт ни на один иностранный сайт)

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:-$REPO_DIR/configs/singbox-client.local.json}"
[[ -f "$SRC" ]] || { echo "Не найден $SRC — сначала установи клиент на Mac (install-macos-daemon.sh)."; exit 1; }
OUT="$REPO_DIR/configs"

python3 - "$SRC" "$OUT" <<'PY'
import json, sys, copy, os
src = json.load(open(sys.argv[1])); out = sys.argv[2]

def base():
    d = copy.deepcopy(src)
    # tun под iOS: стек gvisor, mtu 1358, endpoint_independent_nat
    d["inbounds"] = [{
        "type": "tun", "tag": "tun-in",
        "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
        "mtu": 1358, "auto_route": True, "strict_route": True,
        "stack": "gvisor", "endpoint_independent_nat": True
    }]
    # macOS-специфику убираем: кэш и clash_api приложение задаёт само
    d.pop("experimental", None)
    # Ядро sing-box в приложении iOS (sing-box VT) старше 1.12 и не понимает
    # новый формат DNS (поле "type") и route.default_domain_resolver.
    # Переводим DNS в легаси-формат (через "address") и убираем 1.12+ поля.
    d["dns"] = {
        "servers": [
            {"tag": "dns-remote", "address": "https://1.1.1.1/dns-query", "detour": "proxy"}
        ],
        "strategy": "ipv4_only",
        "final": "dns-remote"
    }
    d.get("route", {}).pop("default_domain_resolver", None)
    return d

def is_ru_direct(x):
    if x.get("outbound") != "direct": return False
    if x.get("rule_set") == "geoip-ru": return True
    ds = x.get("domain_suffix")
    if isinstance(ds, list) and any(s in (".ru", ".рф") for s in ds): return True
    return False

# FULL — как на Mac: зарубеж→Латвия, RU→напрямую
full = base()

# STRICT — убираем правила «RU напрямую», всё (включая RU) идёт через Латвию
strict = base(); r = strict["route"]
r["rules"] = [x for x in r["rules"] if not is_ru_direct(x)]
r["rule_set"] = [x for x in r.get("rule_set", []) if x.get("tag") != "geoip-ru"]

# SELECTIVE (leak-proof) — сервисы→Латвия, RU→напрямую, всё прочее → reject.
# catch-all reject стоит ПОСЛЕ правил сервисов/RU, поэтому they win; до final
# дело не доходит → ни один незащищённый зарубежный коннект не уйдёт с RU IP.
sel = base(); r = sel["route"]
r["rules"].append({"ip_cidr": ["0.0.0.0/0", "::/0"], "action": "reject"})

for name, cfg in (("strict", strict), ("full", full), ("selective", sel)):
    p = os.path.join(out, f"ios-{name}.local.json")
    with open(p, "w") as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)
    print("создан", p)
PY

echo
echo "Готово. 3 файла лежат в configs/:"
echo "  ios-strict.local.json     — всё через Латвию"
echo "  ios-full.local.json       — зарубеж через Латвию, RU напрямую"
echo "  ios-selective.local.json  — только сервисы (leak-proof)"
echo
echo "Проверка валидности (если установлен sing-box на Mac):"
echo "  for m in strict full selective; do sing-box check -c configs/ios-\$m.local.json && echo \"\$m OK\"; done"
