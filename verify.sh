#!/usr/bin/env bash
# Автономная проверка гибрида на общем стенде. Каждая проверка печатает ok/FAIL.
set -uo pipefail
H="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${H}/.." && pwd)"
B="${ROOT}/bin/bash52"
FX="${ROOT}/stand/fx"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
chk()  { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "ожидалось [$3], получено [$2]"; fi; }

W="$(mktemp -d "${TMPDIR:-/tmp}/hybrid-verify.XXXXXX")"
trap 'rm -rf "$W"' EXIT
cp "${H}/Bash_WP-CLI_Update.sh" "${H}/Find_WP_Senior.sh" "$W/"
cp -R "${H}/tools" "$W/"
chmod +x "$W"/tools/*.sh
cp "${ROOT}/stand/mock/wp" "$W/wp"; chmod +x "$W"/*.sh "$W/wp"
cd "$W" || exit 1
S1="${FX}/site-alpha"; S2="${FX}/site beta.example.com"
printf '%s\n%s\n' "$S1" "$S2" > sites.txt
ARGS=(--wp-bin "$W/wp" --no-user-switch --no-color --log-dir "$W/logs" --sites-file sites.txt)

echo "== 1. CLI-контракт =="
out=$("$B" ./Bash_WP-CLI_Update.sh --version 2>&1); chk "--version rc" "$?" "0"
# Версия не зашита в тест: её берут из самого менеджера, иначе смена версии
# ломает проверку, ничего не сообщая о продукте.
expect_ver="$(grep -m1 -oE 'SCRIPT_VERSION="[^"]+"' ./Bash_WP-CLI_Update.sh | cut -d'"' -f2)"
chk "--version текст" "$out" "Bash_WP-CLI_Update.sh ${expect_ver}"
"$B" ./Bash_WP-CLI_Update.sh --help >/dev/null 2>&1; chk "--help rc" "$?" "0"
for k in --check --print-config --list-sites --verify --only-active --strict; do
  grep -q -- "$k" <("$B" ./Bash_WP-CLI_Update.sh --help 2>&1) && ok "справка упоминает $k" || bad "справка упоминает $k"
done
"$B" ./Bash_WP-CLI_Update.sh --bogus >/dev/null 2>&1; chk "неизвестный ключ rc=2" "$?" "2"
"$B" ./Bash_WP-CLI_Update.sh >/dev/null 2>&1; chk "без режима rc=2" "$?" "2"
# все 17 ключей контракта базы
# ключи со значением проверяются вместе со значением, иначе парсер честно
# отвечает «requires a value» — это корректное поведение, а не отказ ключа
for spec in "-D --help" "-f --help" "-c --help" "-p --help" "-t --help" "-d --help" \
            "-x --help" "-r --help" "-s --help" "-l --help" "-m --help" "-h" \
            "-S $S1 --list-plugins" "-m -A activate -N akismet" "-F --help" "-J --help"; do
  # shellcheck disable=SC2086
  "$B" ./Bash_WP-CLI_Update.sh $spec >/dev/null 2>&1
  rc=$?
  key="${spec%% *}"; [[ "$key" == "-m" ]] && key="-m/-A/-N"
  if [[ "$rc" == "2" ]]; then bad "ключ базы $key" "rc=2 (ключ не принят)"; else ok "ключ базы $key принят"; fi
done

echo "== 2. Конфиг: парсинг, а не source =="
printf 'SKIP_PLUGINS=a; touch /tmp/PWNED_HYBRID\n' > inject.conf; chmod 600 inject.conf
"$B" ./Bash_WP-CLI_Update.sh --config inject.conf --print-config >/dev/null 2>&1
rc=$?; [[ -f /tmp/PWNED_HYBRID ]] && bad "инъекция через конфиг" "файл создан" || ok "инъекция через конфиг не проходит (rc=$rc)"
for m in 0620 0660 0664 0666; do
  printf 'JOBS=2\n' > "perm$m.conf"; chmod "$m" "perm$m.conf"
  "$B" ./Bash_WP-CLI_Update.sh --config "perm$m.conf" --print-config >/dev/null 2>&1
  rc=$?
  [[ "$rc" == "2" ]] && ok "конфиг $m отвергнут" || bad "конфиг $m отвергнут" "rc=$rc"
done
printf 'JOBS=4\n' > ok.conf; chmod 600 ok.conf
out=$("$B" ./Bash_WP-CLI_Update.sh --config ok.conf --print-config 2>&1 | awk '$1=="JOBS"{print $2}')
chk "конфиг 0600 прочитан (JOBS=4)" "$out" "4"
out=$("$B" ./Bash_WP-CLI_Update.sh --config ok.conf --print-config 2>&1 | awk '$1=="JOBS"{print $3}')
chk "слой значения = file" "$out" "file:ok.conf"
out=$("$B" ./Bash_WP-CLI_Update.sh --config ok.conf --jobs 2 --print-config 2>&1 | awk '$1=="JOBS"{ $1=""; $2=""; sub(/^ +/,""); print }')
chk "слой значения = command line" "$out" "command line"
printf 'UNKNOWN_KEY=1\n' > bad.conf; chmod 600 bad.conf
"$B" ./Bash_WP-CLI_Update.sh --config bad.conf --print-config >/dev/null 2>&1
chk "неизвестный ключ rc=5" "$?" "5"
printf 'JOBS=$(touch /tmp/PWNED_CMDSUB)\n' > sub.conf; chmod 600 sub.conf
"$B" ./Bash_WP-CLI_Update.sh --config sub.conf --print-config >/dev/null 2>&1
[[ -f /tmp/PWNED_CMDSUB ]] && bad "подстановка в конфиге" "исполнена" || ok "подстановка в конфиге отвергнута"

echo "== 3. Ключ Astra не попадает в argv =="
printf 'SECRET-HYBRID-KEY-123456\n' > astra.key; chmod 600 astra.key
rm -f mock.log
WP_MOCK_LOG="$W/mock.log" "$B" ./Bash_WP-CLI_Update.sh "${ARGS[@]}" --astra --astra-key-file astra.key >/dev/null 2>&1
if grep -q 'SECRET-HYBRID-KEY-123456' mock.log 2>/dev/null; then bad "ключа нет в argv" "ключ найден в argv вызова wp"; else ok "ключа нет в argv вызова wp"; fi
if grep -rq 'SECRET-HYBRID-KEY-123456' logs/ 2>/dev/null; then bad "ключа нет в логах" "ключ найден в логах"; else ok "ключа нет в логах"; fi
ls "${TMPDIR:-/tmp}"/wp-cli-update.licence.* >/dev/null 2>&1 && bad "файл передачи удалён" "остался файл" || ok "файл передачи удалён после вызова"

echo "== 4. Инъекции =="
rm -rf "$W/evil"; mkdir -p "$W/evil/site;touch /tmp/PWNED_HYBRID2;echo/wp-includes"
printf '<?php\n' > "$W/evil/site;touch /tmp/PWNED_HYBRID2;echo/wp-config.php"
printf '<?php $wp_version="6.6";\n' > "$W/evil/site;touch /tmp/PWNED_HYBRID2;echo/wp-includes/version.php"
printf '%s\n' "$W/evil/site;touch /tmp/PWNED_HYBRID2;echo" > evil-sites.txt
rm -f /tmp/PWNED_HYBRID2
WP_MOCK_LOG="$W/mock2.log" "$B" ./Bash_WP-CLI_Update.sh --wp-bin "$W/wp" --no-user-switch --no-color -p --sites-file evil-sites.txt >/dev/null 2>&1
[[ -f /tmp/PWNED_HYBRID2 ]] && bad "инъекция через путь сайта" "файл создан" || ok "инъекция через путь сайта не проходит"

echo "== 5. Счётчики при -j =="
for j in 1 2 4; do
  rm -f mock.log
  WP_MOCK_LOG="$W/mock.log" "$B" ./Bash_WP-CLI_Update.sh "${ARGS[@]}" -j "$j" -p >/dev/null 2>&1
  n=$(grep -c '^CALL' mock.log 2>/dev/null || echo 0)
  chk "-j $j: вызовов wp" "$n" "2"
done
sum=$(WP_MOCK_LOG="$W/mock.log" "$B" ./Bash_WP-CLI_Update.sh "${ARGS[@]}" -j 2 -p 2>&1 | awk '/WP operations:/{print $3}')
chk "-j 2: счётчик операций в сводке" "$sum" "2"

echo "== 6. Бэкапы во всех режимах =="
for mode in -c -p -t -d; do
  rm -rf backups; mkdir -p backups
  WP_MOCK_LOG="$W/mock.log" "$B" ./Bash_WP-CLI_Update.sh "${ARGS[@]}" "$mode" -b db >/dev/null 2>&1
  n=$(find backups -name '*.sql' 2>/dev/null | wc -l | tr -d ' ')
  [[ "$n" -ge 1 ]] && ok "бэкап в режиме $mode" || bad "бэкап в режиме $mode" "файлов: $n"
done

echo "== 7. Автопоиск при bash < 4.2 в PATH =="
mkdir -p "$W/shim"; printf '#!/bin/bash\nexec /bin/bash "$@"\n' > "$W/shim/bash"; chmod +x "$W/shim/bash"
rm -f "$W/wp-found.txt"
# Суть дефекта HF-01: поисковик запускался через shebang и подхватывал bash из
# PATH. Проверяем интерпретатор, которым он реально исполнен, а не результат
# сканирования (дефолтные корни поисковика не содержат фикстуру).
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "${BASH_VERSION}" >"%s/child-bash.txt"\nexit 0\n' "$W" > "$W/fake-finder.sh"
chmod +x "$W/fake-finder.sh"
rm -f "$W/child-bash.txt" "$W/wp-found.txt"
printf 'DISCOVER_SCRIPT=%s\n' "$W/fake-finder.sh" > "$W/finder.conf"; chmod 600 "$W/finder.conf"
PATH="$W/shim:$PATH" WP_MOCK_LOG="$W/mock.log" "$B" ./Bash_WP-CLI_Update.sh --wp-bin "$W/wp" --no-user-switch --no-color --list-sites \
  --log-dir "$W/logs" --sites-file "$W/absent.txt" --config "$W/finder.conf" >/dev/null 2>&1
child="$(cat "$W/child-bash.txt" 2>/dev/null || echo 'не исполнен')"
case "$child" in
  5.2*) ok "поисковик исполнен bash 5.2 даже при bash 3.2 первым в PATH" ;;
  *)    bad "интерпретатор поисковика" "исполнен: ${child}" ;;
esac

echo "== 8. --check и --list-sites =="
WP_MOCK_LOG="$W/mock.log" "$B" ./Bash_WP-CLI_Update.sh "${ARGS[@]}" --no-user-switch --check >/dev/null 2>&1
rc=$?; [[ "$rc" == "0" || "$rc" == "1" ]] && ok "--check завершается предсказуемо (rc=$rc)" || bad "--check" "rc=$rc"
n=$(WP_MOCK_LOG="$W/mock.log" "$B" ./Bash_WP-CLI_Update.sh "${ARGS[@]}" --list-sites 2>/dev/null | grep -c .)
chk "--list-sites печатает сайты" "$n" "2"
rm -f mock.log
WP_MOCK_LOG="$W/mock.log" "$B" ./Bash_WP-CLI_Update.sh "${ARGS[@]}" --list-sites >/dev/null 2>&1
n=$(grep -c '^CALL' mock.log 2>/dev/null || echo 0)
chk "--list-sites не вызывает wp" "$n" "0"

echo "== 8b. --list-modes и --status (без WP-CLI) =="
out=$("$B" ./Bash_WP-CLI_Update.sh --list-modes 2>&1)
rc=$?
if [[ "$rc" == "0" ]] && printf '%s' "$out" | grep -q '^plugin-manage$'; then ok "--list-modes печатает режимы (rc=0)"; else bad "--list-modes" "rc=$rc"; fi
out=$("$B" ./Bash_WP-CLI_Update.sh --wp-bin /nonexistent --status 2>&1)
rc=$?
if [[ "$rc" == "0" ]] && printf '%s' "$out" | grep -q 'manager log'; then ok "--status работает без WP-CLI (rc=0)"; else bad "--status без WP-CLI" "rc=$rc, вывод: $(printf '%s' "$out" | head -2 | tr '\n' ' ')"; fi

echo "== 8c. Заимствования из QWEN: --health, --secrets, --fail-on, --max-sites, --user-env, таймаут =="
out=$("$B" ./Bash_WP-CLI_Update.sh "${ARGS[@]}" --health 2>&1)
if printf '%s' "$out" | grep -q 'core version'; then ok "--health печатает отчёт по сайту"; else bad "--health" "нет строки core version"; fi
grep -q -- '--health' <("$B" ./Bash_WP-CLI_Update.sh --help 2>&1) && ok "справка упоминает --health" || bad "справка упоминает --health"
grep -q -- '--secrets' <("$B" ./Bash_WP-CLI_Update.sh --help 2>&1) && ok "справка упоминает --secrets" || bad "справка упоминает --secrets"
# --fail-on: три политики на падающем парке
mkdir -p badsite && printf '<?php\n' > badsite/wp-config.php
printf '%s\n%s\n' "$S1" "$W/badsite" > failsites.txt
for pol in any all never; do
  WP_MOCK_MODE=fail WP_MOCK_LOG="$W/mock.log" "$B" ./Bash_WP-CLI_Update.sh --wp-bin "$W/wp" --no-user-switch --no-color \
    --log-dir "$W/logs" --sites-file failsites.txt -p --fail-on "$pol" >/dev/null 2>&1
  rc=$?
  case "$pol" in
    any|all) [[ "$rc" == "1" ]] && ok "--fail-on $pol → rc=1 на полном отказе" || bad "--fail-on $pol" "rc=$rc" ;;
    never)   [[ "$rc" == "0" ]] && ok "--fail-on never → rc=0" || bad "--fail-on never" "rc=$rc" ;;
  esac
done
"$B" ./Bash_WP-CLI_Update.sh --fail-on sometimes --print-config >/dev/null 2>&1
chk "--fail-on с мусором → rc=2" "$?" "2"
# --max-sites
printf '%s\n%s\n' "$S1" "$S2" > two.txt
n=$("$B" ./Bash_WP-CLI_Update.sh "${ARGS[@]}" --list-sites --max-sites 1 2>/dev/null | grep -c .)
chk "--max-sites 1 оставляет один сайт" "$n" "1"
# --user-env: значение из окружения доходит, чужая переменная отклоняется
rm -f mock.log
MY_HYBRID_VAR=passed WP_MOCK_LOG="$W/mock.log" "$B" ./Bash_WP-CLI_Update.sh "${ARGS[@]}" -p --user-env "MY_HYBRID_VAR BAD-NAME!" >/dev/null 2>&1
if grep -q 'refusing an invalid variable name' "$W/logs/wp_cli_manager.log" 2>/dev/null || \
   WP_MOCK_LOG="$W/mock.log" "$B" ./Bash_WP-CLI_Update.sh "${ARGS[@]}" -p --user-env "BAD-NAME!" 2>&1 | grep -q 'invalid variable name'; then
  ok "--user-env отклоняет недопустимое имя"
else
  bad "--user-env отклоняет недопустимое имя"
fi
# --signal/--kill-after: переносимый таймаут без timeout(1)
printf '%s\n' "$S1" > one.txt
# Переносимый таймаут: timeout(1) исключён из PATH, мок «висит» 8 секунд при
# лимите 1. Проверяется и время возврата, и отсутствие осиротевших процессов:
# супервизор убивает группу процесса, иначе осиротевший sleep держал бы pipe
# команды и $(...) в вызывающем коде ждал бы его завершения.
start=$(python3 -c 'import time;print(time.time())')
WP_MOCK_LOG="$W/mock.log" WP_MOCK_SLEEP=8 PATH="/usr/bin:/bin:/usr/sbin:/sbin" "$B" ./Bash_WP-CLI_Update.sh --wp-bin "$W/wp" \
  --no-user-switch --no-color --log-dir "$W/logs" --sites-file one.txt -p --timeout 1 --kill-after 1 >/dev/null 2>&1
rc=$?; el=$(python3 -c "import time;print(f'{(time.time()-$start):.1f}')")
if [[ "$rc" == "1" ]] && python3 -c "import sys;sys.exit(0 if float('$el')<4 else 1)"; then
  ok "зависший wp снят за ${el}s без timeout(1) (rc=$rc)"
else
  bad "переносимый таймаут" "rc=$rc, время=${el}s"
fi
orphans=$(ps -o command -ax 2>/dev/null | grep -c '[s]leep 8' || true)
chk "осиротевших процессов не осталось" "$orphans" "0"
# сканер секретов: обе формы, плейсхолдеры, режим --secrets
mkdir -p "${W}/scansite" && printf '<?php\ndefine("DB_PASSWORD", "real-secret-1234567");\n' > "${W}/scansite/wp-config.php"
printf '%s\n' "${W}/scansite" > scan.txt
WP_MOCK_LOG="$W/mock.log" "$B" ./Bash_WP-CLI_Update.sh --wp-bin "$W/wp" --no-user-switch --no-color --log-dir "$W/logs" --sites-file scan.txt --secrets >/dev/null 2>&1
chk "--secrets находит секрет и возвращает 1" "$?" "1"
printf 'DB_PASSWORD=CHANGEME\n' > clean.env
"$W/tools/scan-secrets.sh" clean.env >/dev/null 2>&1
chk "сканер не шумит на плейсхолдере" "$?" "0"
"$W/tools/scan-secrets.sh" --strict clean.env >/dev/null 2>&1
chk "сканер с --strict на плейсхолдере → 0" "$?" "0"
printf 'DB_PASSWORD=real-secret-1234567\n' > dirty.env
"$W/tools/scan-secrets.sh" --strict dirty.env >/dev/null 2>&1
chk "сканер с --strict на секрете → 1" "$?" "1"
"$W/tools/scan-secrets.sh" --format json dirty.env 2>/dev/null | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null
chk "вывод сканера в JSON разбирается" "$?" "0"
rm -f clean.env dirty.env

echo "== 8d. --fields и --page-limit =="
# мок обязан отвечать валидным JSON: иначе парсер честно вернёт пустой список,
# и падение будет выглядеть как дефект менеджера
WP_MOCK_LOG="$W/mock.log" "$W/wp" --path=/tmp/x plugin list --format=json 2>/dev/null | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null
chk "мок отвечает валидным JSON" "$?" "0"
n=$("$B" ./Bash_WP-CLI_Update.sh "${ARGS[@]}" -l 2>&1 | grep -oE 'Total: [0-9]+' | head -1 | grep -oE '[0-9]+')
chk "менеджер разбирает все три плагина мока" "$n" "3"
out=$("$B" ./Bash_WP-CLI_Update.sh "${ARGS[@]}" -l --fields name,status 2>&1)
if printf '%s' "$out" | grep -q 'NAME' && printf '%s' "$out" | grep -q 'STATUS' && ! printf '%s' "$out" | grep -q 'UPDATE_VERSION'; then
  ok "--fields выбирает колонки отчёта"
else
  bad "--fields выбирает колонки отчёта"
fi
n=$("$B" ./Bash_WP-CLI_Update.sh "${ARGS[@]}" -l --page-limit 1 2>&1 | grep -oE 'Shown: [0-9]+ of [0-9]+' | head -1)
chk "--page-limit усекает вывод и сообщает об этом" "$n" "Shown: 1 of 3"
"$B" ./Bash_WP-CLI_Update.sh --fields name,bogus --list-modes >/dev/null 2>&1
chk "неизвестная колонка → rc=2" "$?" "2"
"$B" ./Bash_WP-CLI_Update.sh --fields 'name;rm -rf /' --list-modes >/dev/null 2>&1
chk "мусор в --fields → rc=2" "$?" "2"

echo "== 9. Opt-out и путь с пробелом =="
opt=$(WP_MOCK_LOG="$W/mock.log" "$B" ./Bash_WP-CLI_Update.sh --wp-bin "$W/wp" --no-user-switch --no-color --sites-file sites.txt --log-dir "$W/logs" --list-sites 2>/dev/null | grep -c 'site beta')
chk "путь с пробелом не потерян" "$opt" "1"

printf '\n== ИТОГ: %s ok, %s FAIL ==\n' "$PASS" "$FAIL"
[[ "$FAIL" == "0" ]]
