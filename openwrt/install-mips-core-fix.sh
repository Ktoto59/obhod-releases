#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Compatibility package for OpenWrt ramips/mt7621, not a firmware installer.
set -eu
umask 077
VERSION=1.13.21-r100
PACKAGE_URL='https://api.github.com/repos/Ktoto59/obhod-releases/releases/assets/696207545'
PACKAGE_SHA256=2002eb7a6739abfce11f8fd1914a52bc28d9d61e722ec9488b5c85a5a60cdc70
PACKAGE_BYTES=10731189
work=
locked=0
was_running=0
result=error
RUN=/var/run/obhod
LOCK=/var/lock/obhod-core.lock
die() { echo "Ошибка: $*" >&2; exit 1; }

cleanup_redirect_loopback_routes() {
    # Only the erroneous RTN_LOCAL loopback prefix in MAIN. Never flush routing
    # tables, policy rules, the real LOCAL table or a WireGuard destination.
    routes=$(ip -4 route show table main) || return 1
    devices=$(printf '%s\n' "$routes" | awk '$1=="local" && ($2=="127.0.0.1" || $2=="127.0.0.1/32") {for(i=3;i<NF;i++)if($i=="dev")print $(i+1)}')
    for device in $devices; do
        case "$device" in ''|*[!a-zA-Z0-9_.:-]*) return 1 ;; esac
        [ "${#device}" -le 15 ] || return 1
        ip -4 route del table main local 127.0.0.1/32 dev "$device" scope host || return 1
        echo "Удалён ошибочный маршрут 127.0.0.1 из main: $device"
    done
}

finish() {
    code=$?
    if [ "$locked" = 1 ]; then
        printf '%s\n' "$result" > "$RUN/core-state"
        if [ "$result" = done ]; then
            echo 'Совместимое ядро установлено.' > "$RUN/core-message"
        else
            echo 'Установка исправления не завершилась. Проверьте вывод SSH и состояние службы.' > "$RUN/core-message"
            [ "$was_running" = 0 ] || /usr/libexec/obhod/control start >/dev/null 2>&1 || true
        fi
        rm -f "$LOCK/pid" "$LOCK/started" "$LOCK/token"
        rmdir /var/lock/obhod-apply.lock "$LOCK" 2>/dev/null || true
    fi
    case "$work" in /tmp/obhod-mips-fix.*) rm -rf "$work" ;; esac
    exit "$code"
}
trap finish EXIT
trap 'exit 130' INT TERM
[ "$(id -u)" = 0 ] || die 'Запустите от root.'
command -v apk >/dev/null 2>&1 && [ -f /etc/apk/world ] || die 'Этот скрипт предназначен для OpenWrt с apk.'
target=$(ubus call system board | jsonfilter -e '@.release.target')
[ "$target" = ramips/mt7621 ] || die 'Пакет предназначен только для ramips/mt7621 (mipsel_24kc).'
core=$(awk '/^P:sing-box(-tiny)?$/ {sub(/^P:/, "");print;exit}' /lib/apk/db/installed)
[ "$core" = sing-box-tiny ] || die 'Нужен установленный sing-box-tiny. Полное ядро этот пакет не заменяет.'
[ -x /usr/libexec/obhod/control ] || die 'Сначала установите Обход.'
[ -n "$PACKAGE_URL" ] || die 'Используйте опубликованную копию установщика.'
for other in sing-box podkop passwall passwall2 homeproxy; do
    if ubus call service list "{\"name\":\"$other\"}" | jsonfilter -e '@.*.instances.*.running' | grep -q true; then
        die "Сначала остановите другую службу прокси: $other."
    fi
done
mkdir -p "$RUN" /var/lock
mkdir "$LOCK" 2>/dev/null || die 'Установка ядра уже выполняется. Проверьте состояние в LuCI.'
if ! mkdir /var/lock/obhod-apply.lock 2>/dev/null; then rmdir "$LOCK"; die 'Другая операция Обхода ещё выполняется.'; fi
locked=1
echo "$$" > "$LOCK/pid"; date +%s > "$LOCK/started"
printf '%s\n' "$$-$(date +%s)" > "$LOCK/token"
echo running > "$RUN/core-state"
echo 'Устанавливается исправление ядра для 32-битного MIPS…' > "$RUN/core-message"
work=$(mktemp -d /tmp/obhod-mips-fix.XXXXXX) || die 'Нет места в /tmp.'
set -- /etc/obhod
for file in /etc/config/obhod /etc/config/sing-box /etc/config/dhcp; do [ ! -f "$file" ] || set -- "$@" "$file"; done
backup="/root/obhod-before-mips-fix-$(date +%Y%m%d-%H%M%S)-$$.tar.gz"
tar -czf "$backup" "$@" 2>/dev/null || die 'Не удалось сохранить резервную копию настроек.'
chmod 600 "$backup"
[ ! -f "$RUN/ready" ] || was_running=1
/usr/libexec/obhod/control stop || die 'Не удалось остановить Обход.'
available=$(df -Pk /tmp | awk 'NR>1 {v=$4} END {print v+0}')
[ "$available" -ge "$(( (PACKAGE_BYTES + 1023) / 1024 + 2048 ))" ] || die 'В /tmp нужно примерно 13 МБ свободного места после остановки службы.'
file="$work/sing-box-tiny-$VERSION.apk"
echo 'Скачиваем исправленное облегчённое ядро…'
uclient-fetch -q -T 120 --header='Accept: application/octet-stream' -O "$file" "$PACKAGE_URL" || die 'Не удалось скачать пакет.'
[ "$(wc -c < "$file")" -eq "$PACKAGE_BYTES" ] || die 'Неожиданный размер пакета.'
actual=$(sha256sum "$file"); actual=${actual%% *}
[ "$actual" = "$PACKAGE_SHA256" ] || die 'Контрольная сумма пакета не совпала.'
# The standard service is a separate configuration owner. Keep it disabled;
# Obhod manages the same binary using its own profile and supervisor.
if uci -q get sing-box.main >/dev/null; then
    uci set sing-box.main.enabled=0; uci commit sing-box
fi
/etc/init.d/sing-box stop >/dev/null 2>&1 || true
apk --no-network --simulate add --allow-untrusted "$file" || die 'Пакетный менеджер отклонил обновление ядра.'
apk --no-network add --allow-untrusted "$file" || die 'Не удалось обновить ядро.'
rm -f "$file"
cleanup_redirect_loopback_routes || die 'Не удалось удалить ошибочный маршрут loopback из main.'
if [ -s /etc/obhod/settings.json ]; then
    /usr/libexec/obhod/control start || die 'Ядро обновлено, но Обход не запустился. Проверьте журнал службы.'
fi
result=done
echo "Готово. Ядро: 1.13.21-obhod.1. Настройки сохранены в $backup"
echo 'WireGuard и обычные маршруты не изменялись. Обновите страницу LuCI через Ctrl+F5.'
