#!/usr/bin/env bash
#
# add-server-ip.sh — прописывает на сервере ДОПОЛНИТЕЛЬНЫЙ IPv4, не трогая текущий.
# Нужен, когда у EDIS докуплен ещё один адрес («Additional IPv4»): хостер его
# выдаёт, но в систему НЕ вносит — до правки netplan он молчит.
#
#   bash scripts/add-server-ip.sh 203.0.113.9              # маска /32 (по умолчанию)
#   bash scripts/add-server-ip.sh 203.0.113.9 24           # если портал показал /24
#   bash scripts/add-server-ip.sh 203.0.113.9 32 203.0.113.1   # свой шлюз
#
# Зачем несколько адресов: sing-box слушает "::" — то есть ЛЮБОЙ адрес сервера
# обслуживается сразу, без правки его конфига. Клиент держит узлы на оба адреса
# в одном urltest и сам перескакивает, когда один перестаёт отвечать. Смысл есть
# только если адреса из РАЗНЫХ подсетей: блокируют префиксами, и соседний адрес
# в той же /24 умирает вместе с первым.
#
# Проверить, что получилось: ip -br a, затем снаружи `nc -z <новый-IP> 443`.

set -uo pipefail
NP="${NP:-/etc/netplan/50-cloud-init.yaml}"
NEW="${1:-}"; PFX="${2:-32}"; GW="${3:-}"

[[ -n "$NEW" ]] || { echo "Использование: bash scripts/add-server-ip.sh <IP> [префикс] [шлюз]"; exit 2; }
[[ "$NEW" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || { echo "Это не похоже на IPv4: $NEW"; exit 2; }
[[ "$PFX" =~ ^[0-9]{1,2}$ ]] || { echo "Префикс — число, например 32"; exit 2; }
[[ -f "$NP" ]] || { echo "Нет $NP — сеть настроена иначе, останови и позови за помощью."; exit 1; }

BAK="/root/netplan-$(date +%s).yaml.bak"
cp "$NP" "$BAK" && echo "[*] Бэкап: $BAK"

NEW="$NEW" PFX="$PFX" GW="$GW" NP="$NP" python3 <<'PY'
import os,sys
try:
    import yaml
except ImportError:
    print("[!] Нет PyYAML (apt-get install -y python3-yaml) — правь netplan руками."); sys.exit(1)
np=os.environ["NP"]; new=os.environ["NEW"]; pfx=os.environ["PFX"]; gw=os.environ["GW"].strip()
d=yaml.safe_load(open(np)) or {}
eths=(d.get("network") or {}).get("ethernets") or {}
if not eths:
    print("[!] В netplan нет секции ethernets — правь руками."); sys.exit(1)
name=sorted(eths)[0]; cfg=eths[name] or {}
addrs=cfg.setdefault("addresses",[])
cidr=f"{new}/{pfx}"
if any(str(a).split("/")[0]==new for a in addrs):
    print(f"[*] {new} уже прописан на {name} — править нечего."); sys.exit(3)
addrs.append(cidr)
# Свой шлюз нужен, только если адрес маршрутизируется отдельно. Обычный случай у
# EDIS — адрес отдают на тот же линк, и хватает существующего маршрута по умолчанию.
if gw:
    routes=cfg.setdefault("routes",[])
    routes.append({"to": cidr, "via": gw, "on-link": True})
eths[name]=cfg
yaml.safe_dump(d,open(np,"w"),default_flow_style=False,sort_keys=False)
print(f"[*] На интерфейс {name} добавлен {cidr}" + (f", шлюз {gw}" if gw else ""))
PY
rc=$?
if (( rc == 3 )); then exit 0; fi
if (( rc != 0 )); then cp "$BAK" "$NP"; echo "[!] Правка не удалась — откат."; exit 1; fi

echo "[*] Применяю netplan..."
if ! netplan apply; then
  echo "[!] netplan apply не прошёл — откат."; cp "$BAK" "$NP"; netplan apply; exit 1
fi
sleep 2
echo "[*] Адреса сейчас:"; ip -br a | sed 's/^/    /'

if ! ip -4 addr show | grep -q "inet $NEW/"; then
  echo "[!] Адрес не поднялся — откат."; cp "$BAK" "$NP"; netplan apply; exit 1
fi
if ping -c2 -W3 1.1.1.1 >/dev/null 2>&1; then
  echo "[*] Интернет на месте ✅"
else
  echo "[!] Пропал пинг — откат."; cp "$BAK" "$NP"; netplan apply; exit 1
fi
echo
echo "[OK] Сервер теперь отвечает и на $NEW (sing-box слушает \"::\", его конфиг не трогали)."
echo "Дальше НА МАКЕ:  bash scripts/add-client-ip.sh $NEW"
echo "Откат: cp $BAK $NP && netplan apply"
