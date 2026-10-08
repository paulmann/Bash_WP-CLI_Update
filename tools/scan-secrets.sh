#!/usr/bin/env bash
# scan-secrets.sh — поиск похожих на секреты значений в файлах сайта.
#
# Зачем: wp-config.php и .env содержат пароли БД и соли WordPress. Перед
# бэкапом, выгрузкой в тикет или передачей дерева наружу полезно знать, что
# именно лежит рядом, а не полагаться на память.
#
# Что распознаётся (правило по ИМЕНИ, а не по формату значения):
#   1. в строке есть имя, содержащее password/passwd/pwd/secret/token/key/api/
#      auth/credential/private/access/session/licence/license/astra (регистр не важен);
#   2. за именем идёт `=`, `:` или `=>` (то есть и `NAME=VALUE`, и `"NAME": "VALUE"`,
#      и `define('DB_PASSWORD', 'VALUE')`);
#   3. значение непустое и не является подстановкой переменной, плейсхолдером,
#      путём или значением короче --min-length.
#
# Чего инструмент НЕ делает (важно):
#   он не доказывает отсутствие секретов. Значение, собранное из фрагментов,
#   закодированное в base64 или лежащее в бинарном файле, не будет найдено.
#   Отсутствие находок — свидетельство, а не доказательство. Для строгой
#   проверки нужен специализированный сканер (gitleaks, trufflehog), и он
#   дополняет этот, а не заменяется им.
#
# Коды возврата: 0 — подозрительного нет; 1 — есть находки; 2 — ошибка вызова.
set -uo pipefail

PROG="$(basename -- "$0")"
MIN_LENGTH=8
STRICT=0
FORMAT="text"
declare -a TARGETS=()
declare -a ALLOW_FILES=()

usage() {
	cat <<EOF
Usage: ${PROG} [OPTIONS] PATH...

  --min-length N    Ignore values shorter than N characters (default ${MIN_LENGTH})
  --format FORMAT   text (default) or json
  --allow-file F    File with names to treat as benign (one per line); may repeat
  --strict          Exit 1 when a value still looks like a real credential
                    (without it, findings are printed and the exit code stays 0)
  -h, --help        This help

A line is reported when its NAME looks like a secret name and the value after
'=', ':' or '=>' is not a placeholder, a variable reference, a path, or shorter
than --min-length.

Exit codes: 0 clean | 1 findings (with --strict or --format json) | 2 usage
EOF
	return 0
}

while (($#)); do
	case "$1" in
		--min-length) [[ -n "${2:-}" ]] || { printf '%s: --min-length requires a value\n' "${PROG}" >&2; exit 2; }; MIN_LENGTH="$2"; shift 2 ;;
		--min-length=*) MIN_LENGTH="${1#*=}"; shift ;;
		--format) [[ -n "${2:-}" ]] || { printf '%s: --format requires a value\n' "${PROG}" >&2; exit 2; }; FORMAT="$2"; shift 2 ;;
		--format=*) FORMAT="${1#*=}"; shift ;;
		--allow-file) [[ -n "${2:-}" ]] || { printf '%s: --allow-file requires a value\n' "${PROG}" >&2; exit 2; }; ALLOW_FILES+=("$2"); shift 2 ;;
		--allow-file=*) ALLOW_FILES+=("${1#*=}"); shift ;;
		--strict) STRICT=1; shift ;;
		-h|--help) usage; exit 0 ;;
		--) shift; while (($#)); do TARGETS+=("$1"); shift; done ;;
		-*) printf '%s: unknown option: %s\n' "${PROG}" "$1" >&2; usage >&2; exit 2 ;;
		*) TARGETS+=("$1"); shift ;;
	esac
done

[[ "${MIN_LENGTH}" =~ ^[0-9]+$ ]] || { printf '%s: --min-length must be a number\n' "${PROG}" >&2; exit 2; }
case "${FORMAT}" in text|json) ;; *) printf '%s: --format must be text or json\n' "${PROG}" >&2; exit 2 ;; esac
((${#TARGETS[@]})) || { printf '%s: no path given\n' "${PROG}" >&2; usage >&2; exit 2; }

# Имя «похоже на секрет» — по подстроке, а не по точному совпадению. Имя
# приводится к нижнему регистру: так одним набором шаблонов ловятся и
# DB_PASSWORD, и dbPassword, и SECURE_AUTH_KEY, и ASTRA_KEY. Две ветви case
# (нижний и верхний регистр) давали бы недостижимые шаблоны и вопрос линтера.
name_is_sensitive() {
	# tr(1) вместо ${name,,}: инструмент должен работать и на bash 3.2, где
	# подстановки регистра ещё нет.
	local lower=""
	lower="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
	# Слова, которых нет в базовом списке ниже: их проверяем отдельно, чтобы не
	# писать в case шаблон, перекрывающий другой шаблон (SC2221/SC2222).
	case "${lower}" in
		*apikey*|*api_key*) return 0 ;;
	esac
	case "${lower}" in
		*password*|*passwd*|*pwd*|*secret*|*token*|*key*|*auth*) return 0 ;;
		*credential*|*private*|*access*|*session*|*licence*|*license*|*astra*) return 0 ;;
	esac
	return 1
}

# Значение, которое не является секретом: пустое, подстановка, плейсхолдер, путь, число.
value_is_benign() {
	# Регистр приводится к нижнему, поэтому в шаблонах ниже нет пар вида
	# *example*|*EXAMPLE*: второй шаблон такой пары недостижим (SC2221/SC2222).
	local v=""
	v="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
	# '${'* недостижим после '$'* — дублирование оставлено для читателя, который
	# ищет именно подстановку переменной.
	# shellcheck disable=SC2221,SC2222
	case "${v}" in
		'') return 0 ;;
		'$'*|'${'*|'%'*|'{{'*|'<'*|'('*|'getenv'*|'env('*) return 0 ;;
		*placeholder*|*changeme*|*change_me*|*your_*|*example*|*xxxx*|*redacted*|*dummy*|*test*) return 0 ;;
		/*|./*|../*|~/*) return 0 ;;
		*' '*) return 0 ;;
		*.php|*.env|*.yml|*.yaml|*.json|*.conf|*.ini|*.sql|*.log|*.txt) return 0 ;;
	esac
	[[ "${v}" =~ ^[0-9]+$ ]] && return 0
	((${#v} < MIN_LENGTH)) && return 0
	return 1
}

allowlisted() {
	local name="$1" file="" line=""
	((${#ALLOW_FILES[@]})) || return 1
	for file in "${ALLOW_FILES[@]}"; do
		[[ -r "${file}" ]] || continue
		while IFS= read -r line || [[ -n "${line}" ]]; do
			line="${line%%#*}"
			line="$(printf '%s' "${line}" | tr -d '[:space:]')"
			[[ -n "${line}" ]] || continue
			[[ "${name}" == "${line}" ]] && return 0
		done <"${file}"
	done
	return 1
}

FINDINGS=0
FILES_SCANNED=0
in_json_first=1
[[ "${FORMAT}" == "json" ]] && printf '{"findings":['

report() {
	local file="$1" no="$2" name="$3" value="$4"
	((FINDINGS++)) || true
	# Значение маскируется: цель — показать, что секрет есть, а не переписать его в лог.
	local masked="${value:0:2}…(${#value} симв.)"
	if [[ "${FORMAT}" == "json" ]]; then
		local esc_name="${name//\\/\\\\}"; esc_name="${esc_name//\"/\\\"}"
		local esc_file="${file//\\/\\\\}"; esc_file="${esc_file//\"/\\\"}"
		((in_json_first)) || printf ','
		in_json_first=0
		printf '{"file":"%s","line":%s,"name":"%s","value_length":%s}' \
			"${esc_file}" "${no}" "${esc_name}" "${#value}"
	else
		printf '%s:%s: %s = %s\n' "${file}" "${no}" "${name}" "${masked}"
	fi
	return 0
}

scan_file() {
	local file="$1" line="" no=0 name="" value="" rest=""
	[[ -f "${file}" ]] || return 0
	((FILES_SCANNED++)) || true
	while IFS= read -r line || [[ -n "${line}" ]]; do
		((no++)) || true
		# define('DB_PASSWORD', 'value') и define("DB_PASSWORD", "value")
		if [[ "${line}" =~ define[[:space:]]*\([[:space:]]*[\"\']([A-Za-z_][A-Za-z0-9_]*)[\"\'][[:space:]]*,[[:space:]]*[\"\']([^\"\']*)[\"\'] ]]; then
			name="${BASH_REMATCH[1]}"; value="${BASH_REMATCH[2]}"
			if name_is_sensitive "${name}" && ! value_is_benign "${value}" && ! allowlisted "${name}"; then
				report "${file}" "${no}" "${name}" "${value}"
			fi
			continue
		fi
		# NAME=VALUE, NAME: VALUE, "NAME": "VALUE", NAME => VALUE
		if [[ "${line}" =~ ^[[:space:]]*[\"\']?([A-Za-z_][A-Za-z0-9_.-]*)[\"\']?[[:space:]]*(=>|=|:)[[:space:]]*(.+)$ ]]; then
			name="${BASH_REMATCH[1]}"; rest="${BASH_REMATCH[3]}"
			# кавычки и завершающая запятая/точка с запятой снимаются
			rest="${rest%%[,;]*}"
			rest="${rest%\"}"; rest="${rest#\"}"
			rest="${rest%\'}"; rest="${rest#\'}"
			rest="${rest%\"}"; rest="${rest#\"}"
			rest="${rest%\'}"; rest="${rest#\'}"
			value="${rest}"
			[[ "${name}" == "define" ]] && continue
			if name_is_sensitive "${name}" && ! value_is_benign "${value}" && ! allowlisted "${name}"; then
				report "${file}" "${no}" "${name}" "${value}"
			fi
		fi
	done <"${file}"
	return 0
}

for target in "${TARGETS[@]}"; do
	if [[ -d "${target}" ]]; then
		# Только текстовые файлы конфигурации: сканировать дампы и бинарники бессмысленно.
		while IFS= read -r found; do
			scan_file "${found}"
		done < <(find "${target}" -type f \( -name 'wp-config*.php' -o -name '.env*' -o -name '*.ini' -o -name '*.conf' -o -name '*.yml' -o -name '*.yaml' -o -name '*.json' -o -name '*.sh' \) 2>/dev/null | LC_ALL=C sort)
	elif [[ -f "${target}" ]]; then
		scan_file "${target}"
	else
		printf '%s: no such file or directory: %s\n' "${PROG}" "${target}" >&2
		exit 2
	fi
done

if [[ "${FORMAT}" == "json" ]]; then
	printf '],"files_scanned":%s,"findings_count":%s}\n' "${FILES_SCANNED}" "${FINDINGS}"
else
	printf '%s\n' "-- ${PROG}: files scanned: ${FILES_SCANNED}, findings: ${FINDINGS}"
fi

if ((FINDINGS > 0)) && ((STRICT)); then
	exit 1
fi
exit 0
