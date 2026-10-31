#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Release builder fills the pinned download URL and checksum in the online copy.
BUNDLE_URL='https://github.com/Ktoto59/obhod-releases/releases/download/openwrt-v0.1.2/obhod-openwrt-0.1.2.tar.gz'
BUNDLE_SHA256='7c25091e871764f5b98a1f784e725e57870386020c0725f72a8ebb16989d028a'
BUNDLE_API_URL='https://api.github.com/repos/Ktoto59/obhod-releases/releases/assets/695170689'
set -eu
umask 077
export LC_ALL=C
version=0.1.2
yes=0
preset_choice=
profile=auto
protocols=
check_only=0
work=
die() { printf 'Ошибка: %s\n' "$*" >&2; exit 1; }
cleanup() { case "$work" in /tmp/obhod-install.*) rm -rf "$work" ;; esac; }
trap cleanup EXIT
trap 'exit 130' INT TERM
while [ "$#" -gt 0 ]; do
	case "$1" in
		--yes) yes=1 ;;
		--check-only) check_only=1 ;;
		--profile) [ "$#" -ge 2 ] || die 'После --profile укажите auto, lite или full.'; profile=$2; shift ;;
		--protocols) [ "$#" -ge 2 ] || die 'После --protocols укажите proxy, wireguard, all или none.'; protocols=$2; shift ;;
		--presets) [ "$#" -ge 2 ] || die 'После --presets укажите recommended, minimal, none или ID через запятую.'; preset_choice=$2; shift ;;
		--help) echo 'install.sh [--yes] [--check-only] [--profile auto|lite|full] [--protocols proxy|wireguard|all|none] [--presets recommended|minimal|none|id,id]'; exit 0 ;;
		*) die "Неизвестный параметр: $1" ;;
	esac
	shift
done
case "$profile" in auto|lite|full) ;; *) die 'Профиль: auto, lite или full.' ;; esac
case "$protocols" in ''|proxy|wireguard|all|none) ;; *) die 'Протоколы: proxy, wireguard, all или none.' ;; esac
profile_request=$profile
[ "$(id -u)" = 0 ] || die 'Запустите установщик от root.'
[ -f /etc/openwrt_release ] || die 'Требуется OpenWrt.'
. /etc/openwrt_release
case "${DISTRIB_RELEASE:-}" in 24.10|24.10.*|25.12|25.12.*|SNAPSHOT) ;; *) die 'Поддерживаются OpenWrt 24.10 и 25.12.' ;; esac
if command -v apk >/dev/null 2>&1 && [ -f /etc/apk/world ]; then manager=apk
elif command -v opkg >/dev/null 2>&1; then manager=opkg
else die 'Не найден настроенный apk или opkg.'; fi

free_kb() { df -Pk "$1" | awk 'NR>1 {v=$4} END {if(v ~ /^[0-9]+$/)print v;else exit 1}'; }
read_resources() {
	ram_total=$(awk '$1=="MemTotal:" {print $2}' /proc/meminfo)
	ram_available=$(awk '$1=="MemAvailable:" {print $2}' /proc/meminfo)
	[ -n "$ram_available" ] || ram_available=$(awk '$1=="MemFree:" || $1=="Buffers:" || $1=="Cached:" {n+=$2} END {print n+0}' /proc/meminfo)
	flash_path=/overlay; [ -d /overlay ] || flash_path=/
	flash_free=$(free_kb "$flash_path") || die 'Не удалось определить место накопителя.'
	tmp_free=$(free_kb /tmp) || die 'Не удалось определить место /tmp.'
}
read_resources
installed_core=
if [ "$manager" = apk ]; then
	installed_core=$(awk '/^P:sing-box(-tiny)?$/ {sub(/^P:/, ""); print; exit}' /lib/apk/db/installed 2>/dev/null || true)
else
	installed_core=$(opkg status 'sing-box*' 2>/dev/null | awk '/^Package:/ {p=$2} /^Status:.* installed$/ && (p=="sing-box" || p=="sing-box-tiny") {print p; exit}')
fi
if [ "$profile" = auto ]; then
	case "$installed_core" in sing-box-tiny) profile=lite ;; sing-box) profile=full ;;
		*) if [ "$ram_total" -lt 196608 ]; then profile=lite; else profile=full; fi ;;
	esac
fi
core=sing-box; default_presets=recommended
if [ "$profile" = lite ]; then core=sing-box-tiny; default_presets=minimal; fi
printf 'Обход %s · OpenWrt %s · %s\n' "$version" "$DISTRIB_RELEASE" "$manager"
printf 'Профиль: %s · %s\n' "$profile" "$core"
printf 'ОЗУ: %s МБ, доступно %s МБ; накопитель: %s МБ; /tmp: %s МБ\n' "$((ram_total/1024))" "$((ram_available/1024))" "$((flash_free/1024))" "$((tmp_free/1024))"
[ "$tmp_free" -ge 1024 ] || die 'Для подготовки комплекта требуется минимум 1 МБ в /tmp.'
[ "$flash_free" -ge 2048 ] || die 'На накопителе осталось менее 2 МБ.'

directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
if [ -n "$BUNDLE_URL" ] || [ ! -f "$directory/SHA256SUMS" ] || [ ! -f "$directory/presets.tsv" ]; then
	[ -n "$BUNDLE_URL" ] && [ -n "$BUNDLE_SHA256" ] || die 'Используйте опубликованный онлайн-установщик или install.sh из распакованного комплекта.'
	work=$(mktemp -d /tmp/obhod-install.XXXXXX) || die 'Не удалось создать рабочую папку.'
	echo 'Загружаем комплект Обхода…'
	if command -v curl >/dev/null 2>&1; then
		curl --fail --location --proto '=https' --proto-redir '=https' --max-time 90 --output "$work/bundle.tar.gz" "$BUNDLE_URL" || die 'Не удалось загрузить комплект.'
	elif [ -n "$BUNDLE_API_URL" ]; then
		wget -T 90 --header='Accept: application/octet-stream' -O "$work/bundle.tar.gz" "$BUNDLE_API_URL" || die 'Не удалось загрузить комплект; проверьте HTTPS и время роутера.'
	else wget -T 90 -O "$work/bundle.tar.gz" "$BUNDLE_URL" || die 'Не удалось загрузить комплект; проверьте HTTPS и время роутера.'; fi
	printf '%s  %s\n' "$BUNDLE_SHA256" "$work/bundle.tar.gz" | sha256sum -c - || die 'Контрольная сумма комплекта не совпала.'
	mkdir "$work/bundle"
	tar -xzf "$work/bundle.tar.gz" -C "$work/bundle" || die 'Не удалось распаковать комплект.'
	set --
	[ "$yes" = 0 ] || set -- "$@" --yes
	[ "$check_only" = 0 ] || set -- "$@" --check-only
	set -- "$@" --profile "$profile_request"
	[ -z "$protocols" ] || set -- "$@" --protocols "$protocols"
	[ -z "$preset_choice" ] || set -- "$@" --presets "$preset_choice"
	sh "$work/bundle/install.sh" "$@"
	exit $?
fi
cd "$directory"
sha256sum -c SHA256SUMS || die 'Контрольные суммы файлов не совпали.'
if [ "$manager" = apk ]; then
	[ -f "obhod-$version-r1.apk" ] && [ -f "luci-app-obhod-$version-r1.apk" ] || die 'В комплекте нет APK.'
else [ -f "obhod_$version-1_all.ipk" ] && [ -f "luci-app-obhod_$version-1_all.ipk" ] || die 'В комплекте нет IPK.'; fi
. "$directory/package-lib.sh"
planner="$directory/installer-plan.uc"

open_terminal() {
	if [ -t 0 ]; then exec 4<&0
	elif [ -r /dev/tty ] && (exec </dev/tty) 2>/dev/null; then exec 4</dev/tty
	else die 'Без терминала укажите --yes или --protocols и --presets.'; fi
}
if [ -z "$protocols" ]; then
	protocols=all; [ "$profile" != lite ] || protocols=proxy
	if [ "$yes" = 0 ]; then
		open_terminal
		default_answer=3; [ "$protocols" != proxy ] || default_answer=1
		printf '\nПротоколы:\n1) VLESS/Reality, Shadowsocks, Trojan, Hysteria2, TUIC, AnyTLS, SOCKS/HTTP — облегчённое ядро\n2) WireGuard — полное ядро\n3) Все поддерживаемые — полное ядро\n4) Выбрать позже в LuCI — без установки ядра\nВыбор [%s]: ' "$default_answer"
		read -r answer <&4 || die 'Ввод завершён; установка отменена.'
		case "$answer" in '') ;; 1) protocols=proxy ;; 2) protocols=wireguard ;; 3) protocols=all ;; 4) protocols=none ;; *) die 'Выберите 1, 2, 3 или 4.' ;; esac
	fi
fi
case "$protocols" in
	none) profile=none; core=; default_presets=minimal ;;
	wireguard|all) [ "$profile_request" != lite ] || die 'WireGuard требует --profile full или auto.'; profile=full; core=sing-box; default_presets=recommended ;;
	proxy) if [ "$profile_request" = full ] || [ "$installed_core" = sing-box ]; then profile=full; core=sing-box
		else profile=lite; core=sing-box-tiny; default_presets=minimal; fi ;;
esac
[ -z "$core" ] || [ -z "$installed_core" ] || [ "$installed_core" = "$core" ] || die 'Для смены установленного ядра выключите Обход и выберите протоколы в LuCI.'
printf 'Выбранные протоколы: %s · ядро: %s\n' "$protocols" "${core:-выбор позже в LuCI}"

if [ "$profile" = lite ]; then echo 'Облегчённое ядро: VLESS/Reality поддерживается; для WireGuard нужен профиль full.'; fi
if [ -z "$preset_choice" ]; then
	if [ "$yes" = 1 ]; then preset_choice=$default_presets
	else
		open_terminal
		default_answer=1; [ "$profile" != lite ] || default_answer=2
		printf '\nСписки по умолчанию:\n1) Рекомендуемые: Россия изнутри, Discord, Meta, Telegram, Google AI\n2) Минимальные: Discord, Telegram, Google AI\n3) Выбрать самостоятельно\n4) Без готовых списков\nВыбор [%s]: ' "$default_answer"
		read -r answer <&4 || die 'Ввод завершён; установка отменена.'
		case "$answer" in '') preset_choice=$default_presets ;; 1) preset_choice=recommended ;; 2) preset_choice=minimal ;; 4) preset_choice=none ;;
			3) awk -F'|' '{printf "%2d) %s\n", NR,$2}' presets.tsv
				printf 'Номера через пробел или запятую: '
				read -r answer <&4 || die 'Ввод завершён.'
				preset_choice=
				for number in $(printf '%s' "$answer" | tr ',' ' '); do
					case "$number" in ''|*[!0-9]*) die 'Ожидались номера списков.' ;; esac
					id=$(awk -F'|' -v n="$number" 'NR==n {print $1}' presets.tsv)
					[ -n "$id" ] || die "Нет списка с номером $number."
					preset_choice="${preset_choice:+$preset_choice,}$id"
				done
				[ -n "$preset_choice" ] || preset_choice=none ;;
			*) die 'Выберите 1, 2, 3 или 4.' ;;
		esac
	fi
fi
case "$preset_choice" in recommended) preset_choice='russia_inside,discord,meta,telegram,google_ai' ;; minimal) preset_choice='discord,telegram,google_ai' ;; none) preset_choice= ;; esac
ids=
region=
for id in $(printf '%s' "$preset_choice" | tr ',' ' '); do
	case "$id" in *[!a-z0-9_]*|'') die 'Некорректный ID списка.' ;; esac
	awk -F'|' -v id="$id" '$1==id {f=1} END {exit !f}' presets.tsv || die "Неизвестный список: $id."
	case "$id" in russia_inside|russia_outside|ukraine_inside)
		[ -z "$region" ] || [ "$region" = "$id" ] || die 'Выберите только один региональный список.'
		region=$id ;;
	esac
	case ",$ids," in *",$id,"*) ;; *) ids="${ids:+$ids,}$id" ;; esac
done
if [ "$region" = russia_inside ]; then
	for id in $(printf '%s' "$ids" | tr ',' ' '); do
		awk -F'|' -v id="$id" '$1==id && $3==1 {f=1} END {exit !f}' presets.tsv || die "Список $id несовместим с «Россия: доступ изнутри»."
	done
fi
echo "Выбранные списки: ${ids:-нет}"
[ ! -s /etc/obhod/settings.json ] || echo 'Найден существующий профиль: его подключения и списки сохранятся.'
was_running=0
[ ! -f /var/run/obhod/ready ] || was_running=1

work=$(mktemp -d /tmp/obhod-install.XXXXXX) || die 'Не удалось создать рабочую папку.'
dependencies="$core firewall4 kmod-tun kmod-nft-tproxy kmod-nft-queue ca-bundle uclient-fetch jshn jsonfilter rpcd rpcd-mod-file ucode ucode-mod-fs luci-base"
echo 'Обновляем индексы подписанных репозиториев и рассчитываем зависимости…'
if [ "$manager" = apk ]; then
	apk update || die 'Не удалось обновить индексы APK.'
else
	opkg update || die 'Не удалось обновить индексы opkg.'
fi
resolve_sizes $dependencies
check_budget
[ "$check_only" = 0 ] || { echo 'Проверка пройдена. Пакеты и настройки не изменялись; обновлены индексы в /tmp.'; exit 0; }

echo 'Устанавливаем зависимости из репозиториев OpenWrt…'
if [ "$manager" = apk ]; then
	apk add $dependencies || die 'Не удалось установить зависимости.'
	apk --no-network add --allow-untrusted "./obhod-$version-r1.apk" "./luci-app-obhod-$version-r1.apk" || die 'Не удалось установить Обход.'
else
	opkg install $dependencies || die 'Не удалось установить зависимости.'
	opkg install "./obhod_$version-1_all.ipk" "./luci-app-obhod_$version-1_all.ipk" || die 'Не удалось установить Обход.'
fi
if [ ! -s /etc/obhod/settings.json ]; then
	mkdir -p /etc/obhod; chmod 700 /etc/obhod
	(
		# OpenWrt's jshn library reads optional unset variables internally.
		set +u
		. /usr/share/libubox/jshn.sh
		json_init; json_add_int version 1; json_add_array presetIds
		for id in $(printf '%s' "$ids" | tr ',' ' '); do json_add_string '' "$id"; done
		json_close_array
		defaults=$(mktemp /etc/obhod/defaults.XXXXXX) || exit 1
		json_dump > "$defaults" && mv "$defaults" /etc/obhod/defaults.json
	) || die 'Не удалось сохранить списки.'
fi
if [ "$was_running" = 1 ]; then
	/usr/libexec/obhod/control start || die 'Пакеты обновлены, но служба не запустилась. Профиль сохранён; проверьте журнал Обхода.'
fi
echo 'Готово. Войдите в LuCI заново → Службы → Обход. Добавьте подключение и нажмите «Сохранить и включить».'
echo 'Готовых туннелей в установщике нет. Действующая конфигурация сохранена.'
