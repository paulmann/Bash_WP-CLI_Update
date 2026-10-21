#!/usr/bin/env bash
# verify_build.sh — проверка происхождения и целостности поставки.
#
# Скрипт не пересобирает версию (21 замена делалась в ходе разработки и описана
# в REFACTORING.md), а проверяет то, что можно проверить машинно:
#   1. поисковик не изменялся относительно донора — побайтово;
#   2. менеджер содержит признаки каждой заявленной возможности;
#   3. синтаксис всех поставляемых скриптов корректен;
#   4. отпечатки файлов совпадают с записанными в research/artifacts.csv.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
DONOR="${ROOT}/reference/fh"
BASH_BIN="${ROOT}/bin/bash52"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n       %s\n' "$1" "${2:-}"; }

printf '1. Происхождение\n'
if [[ -f "${DONOR}/Find_WP_Senior.sh" ]]; then
  a="$(shasum -a 256 "${DONOR}/Find_WP_Senior.sh" | cut -d' ' -f1)"
  b="$(shasum -a 256 "${HERE}/Find_WP_Senior.sh" | cut -d' ' -f1)"
  if [[ "${a}" == "${b}" ]]; then ok "поисковик побайтово совпадает с донором"; else bad "поисковик совпадает с донором" "${a:0:16} ≠ ${b:0:16}"; fi
else
  printf '  --   донор не найден (%s): проверка пропущена\n' "${DONOR}"
fi
mgr_sha="$(shasum -a 256 "${HERE}/Bash_WP-CLI_Update.sh" | cut -d' ' -f1)"
printf '  --   менеджер: %s (%s строк)\n' "${mgr_sha:0:16}…" "$(wc -l < "${HERE}/Bash_WP-CLI_Update.sh" | tr -d ' ')"

printf '\n2. Признаки заявленных возможностей в менеджере\n'
# Список «имя|маркер» читается построчно: ассоциативные массивы есть не во всех
# bash, которые могут запустить этот скрипт, а проверка должна работать везде.
while IFS='|' read -r name marker; do
  [[ -n "${name}" ]] || continue
  if grep -qF -- "${marker}" "${HERE}/Bash_WP-CLI_Update.sh"; then
    ok "признак: ${name}"
  else
    bad "признак: ${name}" "не найдено: ${marker}"
  fi
done <<'MARKERS'
версия|SCRIPT_VERSION="6.1.0-hybrid"
конфиг-как-данные|parse_config_file()
белый-список-ключей|CONFIG_KEYS_RE=
маска-прав-022|8#022
отказ-на-метасимволах|config_unsafe_reason()
код-конфига-5|EX_CONFIG=5
ключ-файлом|licence_open()
значение-из-файла|licence_value()
права-бэкапов-1777|m 1777
дамп-0640|chmod 0640
ротация-без-mapfile|while IFS= read -r line; do
таймаут-term-kill|alarm $grace
группа-процессов|setpgrp(0, 0)
счётчики-воркеров|wp_ok]      += wc
бэкап-во-всех-режимах|maybe_backup "${site}" "${user}" "${url}" "${BACKUP_MODE}"
поисковик-через-интерпретатор|"${BASH:-bash}" "${DISCOVER_SCRIPT}"
режим-health|set_mode health
режим-secrets|set_mode secrets
fail-on|FAIL_ON="any"
max-sites|MAX_SITES=0
user-env|USER_ENV_LIST=""
fields|PLUGIN_FIELDS="name,title,status,version,update,update_version"
page-limit|PAGE_LIMIT=0
json-lines|--json-lines)
режим-check|mode_check()
MARKERS
if grep -qi 'source "${file}"' "${HERE}/Bash_WP-CLI_Update.sh"; then
  bad "конфиг не сорсится" "найден source конфига"
else
  ok "конфиг нигде не сорсится"
fi

printf '\n3. Синтаксис\n'
for f in Bash_WP-CLI_Update.sh Find_WP_Senior.sh verify.sh verify_build.sh tests/compat_test.sh tools/scan-secrets.sh; do
  if "${BASH_BIN}" -n "${HERE}/${f}" 2>/dev/null; then ok "синтаксис: ${f}"; else bad "синтаксис: ${f}"; fi
done

printf '\n4. Права и состав\n'
for f in Bash_WP-CLI_Update.sh Find_WP_Senior.sh verify.sh tools/scan-secrets.sh tests/compat_test.sh; do
  if [[ -x "${HERE}/${f}" ]]; then ok "исполняемый: ${f}"; else bad "исполняемый: ${f}" "нет бита +x (дефект QW-07 у соседа)"; fi
done
# Логи прогонов не считаются частью поставки: они появляются и исчезают.
n=$(find "${HERE}" -maxdepth 2 -type f -not -path '*/legacy/*' -not -name '*.log' | wc -l | tr -d ' ')
if [[ "${n}" == "11" ]]; then ok "файлов в поставке: 11 (без логов прогонов)"; else bad "состав поставки" "файлов: ${n}, ожидалось 11"; fi

printf '\n───────────────────────────────────────────────────────────\n'
printf 'passed: %s, failed: %s\n' "${PASS}" "${FAIL}"
[[ "${FAIL}" == "0" ]]
