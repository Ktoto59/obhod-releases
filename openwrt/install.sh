#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Release builder fills the pinned download URL and checksum in the online copy.
BUNDLE_URL='https://github.com/Ktoto59/obhod-releases/releases/download/openwrt-v0.1.1/obhod-openwrt-0.1.1.tar.gz'
BUNDLE_SHA256='0c5b4a4038e3f19c0bc401a404affaf1d2978b8c51c82467b3bb23aa1f603d78'
BUNDLE_API_URL='https://api.github.com/repos/Ktoto59/obhod-releases/releases/assets/695113633'
set -eu
umask 077
export LC_ALL=C
version=0.1.1
yes=0
preset_choice=
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
		--presets) [ "$#" -ge 2 ] || die 'После --presets укажите recommended, minimal, none или ID через запятую.'; preset_choice=$2; shift ;;
		--help) echo 'install.sh [--yes] [--check-only] [--presets recommended|minimal|none|id,id]'; exit 0 ;;
		*) die "Неизвестный параметр: $1" ;;
	esac
	shift
done
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
printf 'Обход %s · OpenWrt %s · %s\n' "$version" "$DISTRIB_RELEASE" "$manager"
printf 'ОЗУ: %s МБ, доступно %s МБ; накопитель: %s МБ; /tmp: %s МБ\n' "$((ram_total/1024))" "$((ram_available/1024))" "$((flash_free/1024))" "$((tmp_free/1024))"
[ "$ram_total" -ge 114688 ] || die 'Нужно минимум 128 МБ ОЗУ (112 МБ после резерва ядра).'
[ "$ram_available" -ge 49152 ] || die 'Нужно не менее 48 МБ доступной ОЗУ.'
[ "$tmp_free" -ge 16384 ] || die 'Для подготовки требуется минимум 16 МБ в /tmp.'
[ "$flash_free" -ge 4096 ] || die 'На накопителе осталось менее 4 МБ.'

directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
if [ ! -f "$directory/SHA256SUMS" ] || [ ! -f "$directory/presets.tsv" ]; then
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
	[ -z "$preset_choice" ] || set -- "$@" --presets "$preset_choice"
	sh "$work/bundle/install.sh" "$@"
	exit $?
fi
cd "$directory"
sha256sum -c SHA256SUMS || die 'Контрольные суммы файлов не совпали.'
if [ "$manager" = apk ]; then
	[ -f "obhod-$version-r1.apk" ] && [ -f "luci-app-obhod-$version-r1.apk" ] || die 'В комплекте нет APK.'
else [ -f "obhod_$version-1_all.ipk" ] && [ -f "luci-app-obhod_$version-1_all.ipk" ] || die 'В комплекте нет IPK.'; fi

if [ -z "$preset_choice" ]; then
	if [ "$yes" = 1 ]; then preset_choice=recommended
	else
		if [ -t 0 ]; then exec 4<&0
		elif [ -r /dev/tty ] && (exec </dev/tty) 2>/dev/null; then exec 4</dev/tty
		else die 'Без терминала укажите --yes или --presets.'; fi
		printf '\nСписки по умолчанию:\n1) Рекомендуемые: Россия изнутри, Discord, Meta, Telegram, Google AI\n2) Минимальные: Discord, Telegram, Google AI\n3) Выбрать самостоятельно\n4) Без готовых списков\nВыбор [1]: '
		read -r answer <&4 || die 'Ввод завершён; установка отменена.'
		case "$answer" in ''|1) preset_choice=recommended ;; 2) preset_choice=minimal ;; 4) preset_choice=none ;;
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
dependencies='sing-box firewall4 kmod-tun kmod-nft-tproxy kmod-nft-queue curl ca-bundle jshn jsonfilter rpcd rpcd-mod-file ucode ucode-mod-fs luci-base'
echo 'Обновляем индексы подписанных репозиториев и рассчитываем зависимости…'
if [ "$manager" = apk ]; then
	command -v ucode >/dev/null 2>&1 || die 'В этой сборке нет штатного ucode; точная оценка места недоступна.'
	apk update || die 'Не удалось обновить индексы APK.'
	apk query --world --recursive --format json --fields name,version,installed-size,file-size $dependencies > "$work/plan.json" || die 'Не удалось разрешить зависимости APK.'
	apk query --installed --format json --fields name,version '*' > "$work/installed.json" || die 'Не удалось получить установленные пакеты.'
	ucode installer-plan.uc "$work/plan.json" "$work/installed.json" > "$work/sizes" || die 'Не удалось оценить размер APK.'
	read -r installed_bytes download_bytes < "$work/sizes"
else
	opkg update || die 'Не удалось обновить индексы opkg.'
	opkg --noaction install $dependencies > "$work/plan.txt" 2>&1 || { cat "$work/plan.txt"; die 'Не удалось разрешить зависимости opkg.'; }
	awk '$1=="Installing" || $1=="Upgrading" {print $2}' "$work/plan.txt" | sort -u > "$work/names"
	installed_bytes=0; download_bytes=0
	while read -r name; do
		[ -n "$name" ] || continue
		opkg info "$name" > "$work/info" || die "Нет метаданных $name."
		values=$(awk '$1=="Installed-Size:" && $2 ~ /^[0-9]+$/ {if($2>i)i=$2;s=1} $1=="Size:" && $2 ~ /^[0-9]+$/ {if($2>d)d=$2;t=1} END {if(!s || !t)exit 1;printf "%.0f %.0f\n",i,d}' "$work/info") || die "Неизвестен размер $name."
		set -- $values
		installed_bytes=$((installed_bytes + $1)); download_bytes=$((download_bytes + $2))
	done < "$work/names"
fi
case "$installed_bytes:$download_bytes" in *[!0-9:]*|:*) die 'Некорректные размеры пакетов.' ;; esac
required_flash=$(((installed_bytes + 1023) / 1024 + 8192))
required_tmp=$(((download_bytes + 1023) / 1024 + 8192))
read_resources
printf 'Новые зависимости: до %s МБ после распаковки, загрузка до %s МБ. Запас накопителя: 8 МБ.\n' "$(((installed_bytes+1048575)/1048576))" "$(((download_bytes+1048575)/1048576))"
[ "$flash_free" -ge "$required_flash" ] || die "Недостаточно места: нужно $required_flash КБ, доступно $flash_free КБ."
[ "$tmp_free" -ge "$required_tmp" ] || die "Недостаточно /tmp: нужно $required_tmp КБ, доступно $tmp_free КБ."
[ "$ram_available" -ge "$((required_tmp + 32768))" ] || die 'Недостаточно ОЗУ для загрузки с запасом 32 МБ.'
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
