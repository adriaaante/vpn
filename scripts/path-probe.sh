#!/usr/bin/env bash
#
# path-probe.sh — ищет ЖИВОЙ маршрут до сервера, когда TLS на IPv4:443 режут
# (грабля №5). Запускать НА КЛИЕНТЕ с выключенным туннелем:
#   cd ~/vpn && bash scripts/path-probe.sh
#
# Отвечает на три вопроса:
#   1) проходит ли TLS по IPv6 (фильтры обычно висят на IPv4-адресе);
#   2) чист ли путь до ДРУГИХ портов сервера — по ним никто не слушает, поэтому
#      ответ "refused" доказывает, что пакеты дошли и вернулись (путь чист, помогает
#      перенос порта), а "timeout" = режут и там;
#   3) на каком шаге рвётся текущий IPv4:443 (глотают ClientHello или рвут RST).
# Секретов не печатает — вывод можно слать в чат целиком.

set -uo pipefail

SRV_IP="${SRV_IP:-89.46.238.74}"
SRV_V6_NET="${SRV_V6_NET:-2a03:f80:371:9ef5}"   # блок из панели EDIS
SNI="${SNI:-www.apple.com}"
ALT_PORTS="${ALT_PORTS:-2053 8443 993 2083 8880}"
PROBE_VER="2026-08-20.2"

have() { command -v "$1" >/dev/null 2>&1; }
# GNU timeout есть на Linux, но не на macOS (грабля №5b).
if have timeout;    then TO() { timeout "$@"; };  TO_KIND=timeout
elif have gtimeout; then TO() { gtimeout "$@"; }; TO_KIND=gtimeout
elif have perl;     then TO() { local s="$1"; shift; perl -e 'alarm shift; exec @ARGV' "$s" "$@"; }; TO_KIND=perl
else                     TO() { shift; "$@"; };   TO_KIND="нет"
fi

echo "=========================================================="
echo " path-probe v$PROBE_VER   ($(date -u '+%F %H:%M UTC'))   таймаут: $TO_KIND"
echo "=========================================================="

# TLS-рукопожатие через curl: не зависит от капризов LibreSSL и понимает [IPv6].
tls_try() { # $1 = адрес (IPv4 | [IPv6]) , $2 = порт
  TO 20 curl -s -o /dev/null --noproxy '*' --max-time 15 \
     --connect-to "$SNI:443:$1:$2" "https://$SNI/" 2>/dev/null
}

echo
echo "=== 1. ТЕКУЩИЙ МАРШРУТ: IPv4:443 ==="
if tls_try "$SRV_IP" 443; then
  echo "  TLS проходит ✅  — блокировки нет, ищи причину в параметрах (vpn-doctor)."
else
  echo "  TLS НЕ проходит ❌"
  echo "  --- где именно рвётся (последние строки curl) ---"
  TO 25 curl -sv --noproxy '*' --max-time 15 \
     --connect-to "$SNI:443:$SRV_IP:443" "https://$SNI/" -o /dev/null 2>&1 \
     | grep -vE '^\{|^\}|^\* Trying|Host www' | tail -6 | sed 's/^/    /'
fi

echo
echo "=== 2. IPv6 ДО СЕРВЕРА ==="
MY6=$(TO 12 curl -s -6 --noproxy '*' --max-time 8 https://ifconfig.co 2>/dev/null)
if [[ -z "$MY6" ]]; then
  echo "  у ТВОЕЙ сети IPv6 нет (или не отвечает) — вариант с IPv6 отпадает."
else
  echo "  IPv6 у твоей сети есть."
  FOUND6=""
  for h in "${SRV_V6:-}" "$SRV_V6_NET::1" "$SRV_V6_NET::2"; do
    [[ -z "$h" ]] && continue
    printf '  %-28s ' "$h"
    if TO 8 bash -c "exec 3<>/dev/tcp/$h/443" >/dev/null 2>&1; then
      echo -n "TCP открыт; TLS -> "
      if tls_try "[$h]" 443; then echo "ПРОХОДИТ ✅"; FOUND6="$h"; break; else echo "режут ❌"; fi
    else
      echo "TCP не отвечает"
    fi
  done
  [[ -n "$FOUND6" ]] && echo "  => рабочий обход: $FOUND6 (переключаем клиента на IPv6)"
fi

echo
echo "=== 3. ЧИСТ ЛИ ПУТЬ ДО ДРУГИХ ПОРТОВ ==="
echo "  (на них никто не слушает: 'refused' = пакеты дошли и вернулись, путь чист"
echo "   и перенос порта поможет; 'timeout' = режут и там)"
# refused vs timeout различаем по тексту ошибки bash (nc на macOS и Linux
# принимает разные флаги, поэтому /dev/tcp надёжнее).
port_state() {
  local err rc
  err=$(TO 8 bash -c "exec 3<>/dev/tcp/$SRV_IP/$1" 2>&1); rc=$?
  # Порт с живым Reality: одного TCP мало — DPI режет уже рукопожатие, поэтому
  # сразу пробуем TLS. Это и есть ответ «поедет ли туннель по этому порту».
  if (( rc == 0 )); then
    if tls_try "$SRV_IP" "$1"; then echo "слушает, TLS ПРОХОДИТ ✅ — годится для туннеля"
    else echo "слушает, но TLS режут ❌"; fi
    return
  fi
  case "$err" in
    *efused*) echo "refused  — путь чист ✅" ;;
    *)        echo "timeout/фильтр ❌" ;;
  esac
}
for p in $ALT_PORTS; do
  printf '  порт %-6s %s\n' "$p" "$(port_state "$p")"
done

echo
echo "=== 4. КОНТРОЛЬ (чужой сайт, чтобы проверки выше были достоверны) ==="
if TO 20 curl -s -o /dev/null --noproxy '*' --max-time 12 https://www.google.com/ 2>/dev/null; then
  echo "  TLS к www.google.com проходит ✅ — инструмент и сеть в порядке."
else
  echo "  ⚠️ TLS к www.google.com тоже не проходит — проверки выше НЕдостоверны."
fi
echo "----------------------------------------------------------"
