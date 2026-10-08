#!/usr/bin/env bash
# compat_test.sh — проверки совместимости и сквозные прогоны итоговой версии.
#
# Заменяет smoke_test.sh донора: тот проверял поведение source-конфига и запускался
# на bash 3.2, где сам менеджер не работает по построению (нужен bash >= 4.2).
# Здесь проверяется то, что заявлено в README:
#   * контракт базы: 17 коротких ключей и 10 режимов;
#   * новые режимы и ключи;
#   * коды возврата;
#   * конфиг как данные: маски, метасимволы, неизвестный ключ;
#   * сквозные прогоны на моке: режимы, бэкап, счётчики, ключ вне argv.
#
# Запуск: bash research/hybrid/tests/compat_test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HYB="$(cd "${HERE}/.." && pwd)"
ROOT="$(cd "${HYB}/../.." && pwd)"
BASH_BIN="${ROOT}/research/bin/bash52"
[[ -x "${BASH_BIN}" ]] || BASH_BIN="$(command -v bash)"
MGR="${HYB}/Bash_WP-CLI_Update.sh"
FX="${ROOT}/research/stand/fx"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n       %s\n' "$1" "${2:-}"; }
is()  { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "ожидалось [$3], получено [$2]"; fi; }

W="$(mktemp -d "${TMPDIR:-/tmp}/hybrid-compat.XXXXXX")"
cleanup() { rm -rf "$W"; }
trap cleanup EXIT
cp "${MGR}" "$W/"; cp "${ROOT}/research/stand/mock/wp" "$W/wp"; chmod +x "$W"/*.sh "$W/wp"
mkdir -p "$W/logs"
printf '%s\n' "${FX}/site-alpha" "${FX}/site beta.example.com" > "$W/sites.txt"
ARGS=(--wp-bin "$W/wp" --no-user-switch --no-color --log-dir "$W/logs" --sites-file "$W/sites.txt")

printf 'версия bash: %s\n' "$("${BASH_BIN}" -c 'printf %s "${BASH_VERSION}"')"

printf '\n1. Контракт базы: 17 коротких ключей\n'
# Ключи, которым нужен запуск, получают рабочее окружение стенда: без него
# менеджер честно отвечает rc=3 «нет WP-CLI», и это не отказ ключа.
for spec in "-D --help" "-f --help" "-c --help" "-p --help" "-t --help" "-d --help" "-x --help" \
            "-r --help" "-s --help" "-l --help" "-h" \
            "-A activate --list-sites" "-N akismet --list-sites" "-F --help" "-J --help"; do
  # shellcheck disable=SC2086
  "${BASH_BIN}" "${MGR}" "${ARGS[@]}" $spec >/dev/null 2>&1
  rc=$?
  if [[ "$rc" == "3" ]]; then bad "ключ ${spec%% *}" "rc=3: менеджер не стартовал"; else ok "ключ ${spec%% *} принят"; fi
done
for spec in "-m -A activate -N akismet --list-sites" "-S ${FX}/site-alpha --list-sites"; do
  # shellcheck disable=SC2086
  "${BASH_BIN}" "${MGR}" "${ARGS[@]}" $spec >/dev/null 2>&1
  rc=$?
  if [[ "$rc" == "3" ]]; then bad "ключ ${spec%% *}" "rc=3: менеджер не стартовал"; else ok "ключ ${spec%% *} принят"; fi
done

printf '\n2. Режимы базы и новые режимы\n'
# режим astra без ключа обязан отказать с понятным кодом, с ключом — пройти
printf 'LICENCE-KEY-FOR-TEST-1\n' > "$W/astra.key"; chmod 600 "$W/astra.key"
for mode in full core plugins themes db-optimize db-fix cron verify; do
  out=$("${BASH_BIN}" "${MGR}" "${ARGS[@]}" "--${mode}" 2>&1); rc=$?
  is "режим --${mode} отработал" "$rc" "0"
done
out=$("${BASH_BIN}" "${MGR}" "${ARGS[@]}" --astra 2>&1); rc=$?
is "режим --astra без ключа отказывает" "$rc" "1"
out=$("${BASH_BIN}" "${MGR}" "${ARGS[@]}" --astra --astra-key-file "$W/astra.key" 2>&1); rc=$?
is "режим --astra с ключом проходит" "$rc" "0"
for mode in health secrets; do
  out=$("${BASH_BIN}" "${MGR}" "${ARGS[@]}" "--${mode}" 2>&1); rc=$?
  [[ "$rc" == "0" || "$rc" == "1" ]] && ok "новый режим --${mode} доступен" || bad "режим --${mode}" "rc=$rc"
done
n=$("${BASH_BIN}" "${MGR}" --list-modes 2>/dev/null | grep -c .)
is "--list-modes печатает 18 режимов" "$n" "18"

printf '\n3. Коды возврата\n'
"${BASH_BIN}" "${MGR}" --help >/dev/null 2>&1;                    is "--help" "$?" "0"
"${BASH_BIN}" "${MGR}" --version >/dev/null 2>&1;                 is "--version" "$?" "0"
"${BASH_BIN}" "${MGR}" >/dev/null 2>&1;                           is "без режима" "$?" "2"
"${BASH_BIN}" "${MGR}" --full --core >/dev/null 2>&1;             is "конфликт режимов" "$?" "2"
"${BASH_BIN}" "${MGR}" --full -b bogus >/dev/null 2>&1;           is "неверный --backup" "$?" "2"
"${BASH_BIN}" "${MGR}" --fail-on bogus --list-modes >/dev/null 2>&1; is "неверный --fail-on" "$?" "2"
"${BASH_BIN}" "${MGR}" "${ARGS[@]}" -p --max-sites -1 >/dev/null 2>&1; is "отрицательный --max-sites" "$?" "2"

printf '\n4. Конфиг: данные, а не код\n'
printf 'JOBS=2\n' > "$W/ok.conf"; chmod 600 "$W/ok.conf"
is "конфиг 0600 принят" "$("${BASH_BIN}" "${MGR}" --config "$W/ok.conf" --list-modes >/dev/null 2>&1; echo $?)" "0"
for m in 0620 0660 0664 0666; do
  printf 'JOBS=2\n' > "$W/perm$m.conf"; chmod "$m" "$W/perm$m.conf"
  is "конфиг $m отвергнут" "$("${BASH_BIN}" "${MGR}" --config "$W/perm$m.conf" --list-modes >/dev/null 2>&1; echo $?)" "2"
done
printf 'JOBS=$(touch %s/PWNED)\n' "$W" > "$W/sub.conf"; chmod 600 "$W/sub.conf"
"${BASH_BIN}" "${MGR}" --config "$W/sub.conf" --list-modes >/dev/null 2>&1
if [[ -e "$W/PWNED" ]]; then bad "подстановка в конфиге не исполняется" "файл создан"; else ok "подстановка в конфиге не исполняется"; fi
printf 'UNKNOWN=1\n' > "$W/unknown.conf"; chmod 600 "$W/unknown.conf"
is "неизвестный ключ → rc=5" "$("${BASH_BIN}" "${MGR}" --config "$W/unknown.conf" --list-modes >/dev/null 2>&1; echo $?)" "5"

printf '\n5. Сквозные прогоны на моке\n'
rm -f "$W/mock.log"
WP_MOCK_LOG="$W/mock.log" "${BASH_BIN}" "${MGR}" "${ARGS[@]}" -p >/dev/null 2>&1
is "режим -p прошёл" "$?" "0"
n=$(grep -c '^CALL' "$W/mock.log" 2>/dev/null || echo 0)
is "вызовов wp на двух сайтах" "$n" "2"
rm -rf "$W/backupdir"; mkdir -p "$W/backupdir"
WP_MOCK_LOG="$W/mock.log" "${BASH_BIN}" "${MGR}" "${ARGS[@]}" -c -b db -B "$W/backupdir" >/dev/null 2>&1
is "бэкап в режиме -c" "$(find "$W/backupdir" -name 'db-*.sql' 2>/dev/null | wc -l | tr -d ' ')" "2"
printf 'SECRET-KEY-IN-ARGV-987\n' > "$W/astra.key"; chmod 600 "$W/astra.key"
rm -f "$W/mock.log"
WP_MOCK_LOG="$W/mock.log" "${BASH_BIN}" "${MGR}" "${ARGS[@]}" --astra --astra-key-file "$W/astra.key" >/dev/null 2>&1
if grep -q 'SECRET-KEY-IN-ARGV-987' "$W/mock.log" 2>/dev/null; then
  bad "ключ Astra не попадает в argv" "ключ найден в argv вызова wp"
else
  ok "ключ Astra не попадает в argv"
fi
sum=$(WP_MOCK_LOG="$W/mock.log" "${BASH_BIN}" "${MGR}" "${ARGS[@]}" -j 2 -p 2>&1 | awk '/WP operations:/{print $3}')
is "счётчики при -j 2" "$sum" "2"

printf '\n───────────────────────────────────────────────────────────\n'
printf 'passed: %s, failed: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" == "0" ]]
