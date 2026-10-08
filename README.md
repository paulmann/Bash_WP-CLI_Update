# Итоговая версия (гибрид) — что унаследовано, откуда и что закрыто

Основа — **Deepseek Harness Flash** (коммит `3904a73`, ветка `SagaAI_DeepSeeek_Flash`): единственная
конфигурация без дефектов уровня critical и с полным набором возможностей. Поверх неё перенесены
решения из **QWEN Hybrid**, **SagaAI DeepSeek Flash**, **AutoClaw GLM 5.3 Flash + RAGRAF**
и **SagaAI DeepSeek Pro + RAGRAF**.

Проверки: **166 из 166** в трёх наборах проходят на macOS без root — `verify.sh` (78),
`tests/compat_test.sh` (49), `verify_build.sh` (39).
Журнал прогона: `research/out/hybrid_verify.txt`.

## 1. Состав поставки

| Файл | Что это |
|---|---|
| `Bash_WP-CLI_Update.sh` | менеджер, 2 481 строка, 101 функция |
| `Find_WP_Senior.sh` | поисковик донора, не изменялся (`sha256` совпадает с донорским) |
| `tools/scan-secrets.sh` | сканер секретов в конфигурации сайта (работает и на bash 3.2) |
| `verify.sh` | 78 проверок на общем стенде, без root |
| `build_from_donor.sh` | воспроизведение сборки из чистого донора |
| `README.md` | этот файл |
| `REFACTORING.md` | что заимствовано, что взято, а что нет и почему |
| `legacy/` | архив исходников базы (байты `main`) |
| `ANALYSIS.md`, `LICENSE`, `tests/`, `wp-maintenance.conf.example` | унаследовано от донора |

Расширение версии: **`6.1.0-hybrid`** (у донора было `6.0.0`); обвязка поисковика — `2.0.0`.

## 2. Что унаследовано откуда

| Возможность | Источник идеи | Как реализовано здесь |
|---|---|---|
| Ядро: режимы, `-j`, бэкапы, `--verify`, `--only-active`, `--list-sites`, `--timeout`, `--no-user-switch` | Deepseek Harness Flash | без изменений (донор) |
| Конфиг читается как **данные**, ключи по белому списку | SagaAI DeepSeek Flash | `parse_config_file()`, `CONFIG_KEYS_RE` (30 ключей) |
| Отказ на метасимволах в значениях конфига | QWEN Hybrid | `config_unsafe_reason()` → rc=5 |
| Маска прав конфига, а не один ниббл | AutoClaw GLM 5.3 Flash + RAGRAF | `((mode & 8#022))` отвергает 0620, 0660, 0664, 0666 |
| Ключ Astra передаётся файлом `0600`, в `argv` — только значение из файла | AutoClaw GLM 5.3 Flash + RAGRAF, QWEN Hybrid | `licence_open`/`licence_value`/`licence_close` |
| Маскирование секрета в любом канале | SagaAI DeepSeek Pro + RAGRAF | `redact()` + `--print-config` печатает длину, не значение |
| Слой значения в диагностике конфигурации | QWEN Hybrid | `--print-config`: `command line` / `environment` / `file:…` / `default` |
| Проверка окружения и сайтов без изменений | AutoClaw GLM 5.3 Flash + RAGRAF, SagaAI DeepSeek Flash | `--check` |
| Машиночитаемые списки для обёрток | AutoClaw GLM 5.3 Flash + RAGRAF | `--list-modes`, `--status` |
| Свёртка счётчиков воркеров при `-j` | журнал интеграции QWEN Hybrid | воркер пишет счётчики в файл, родитель суммирует |
| Права каталога бэкапов и дампов | QWEN Hybrid | каталог `1777` + sticky, дамп `0640` |
| Переносимый таймаут `--signal`/`--kill-after` | QWEN Hybrid (у него — GNU `timeout -k`) | супервизор на perl: TERM группе, затем KILL группе |
| `--user-env` — передача переменных окружения ребёнку | QWEN Hybrid | только по имени, из собственного окружения, с проверкой имени |
| `--fail-on any/all/never` | QWEN Hybrid | `final_exit()` с приоритетом `--strict` |
| `--max-sites` — предохранитель парка | QWEN Hybrid | обрезка списка в `load_sites()` с предупреждением |
| `--json-lines` (синоним `--json`) | QWEN Hybrid | тот же вывод: объект на сайт + итог |
| `--health` — отчёт о состоянии без изменений | QWEN Hybrid | `mode_status()` донора стал доступен как режим |
| Сканер секретов с обеими формами записи | QWEN Hybrid (правило по имени) | `tools/scan-secrets.sh` + режим `--secrets` |

## 3. Что закрыто из реестра дефектов

| Дефект | Суть | Как закрыт | Подтверждение |
|---|---|---|---|
| **HF-01** | Поисковик запускался через shebang и подхватывал `bash` 3.2 из PATH | вызов `"${BASH}" "${DISCOVER_SCRIPT}"` | при `bash` 3.2 первым в PATH поисковик исполнен bash 5.2 |
| **HF-02** | При `-j>1` счётчики операций терялись: «0 ok» при реальных вызовах | воркер сохраняет счётчики, родитель сворачивает | `-j 1` и `-j 2` дают одинаковый результат |
| **HF-03** | `--backup db` молча ничего не делал вне `--full` | `maybe_backup` из `core`/`plugins`/`themes`/`db-optimize` | бэкап создаётся во всех четырёх режимах |
| **HF-04** | Гвардия конфига смотрела только other-ниббл: 0660/0620 сорсился и исполнялся | парсинг как данных + маска `022` | 0620/0660/0664/0666 отвергнуты с rc=2 |
| **HF-06** | Ключ в `argv` процесса `wp` вопреки собственной шапке | файл `0600`, в `argv` уходит результат чтения файла | ключа нет в мок-логе и логах, файл удалён после вызова |
| **F2-13** | Конфиг `source` исполнял код | тот же парсер | зонд `SKIP_PLUGINS=a; touch /tmp/PWNED` → файл не создан, rc=5 |
| **QW-06** | `find -printf` (GNU-only) ломал ротацию бэкапов на BSD | ротация на переносимом пути | 5 прогонов с `--keep-backups 2` → 2 файла на сайт |
| **QW-10** | `--strict` не мог вернуть 0 на хосте без `flock` | предупреждение о переносимости не считается предупреждением | `--strict` на macOS без `flock`/`timeout` → rc=0 |
| **QW-07** | Файлы поставки без бита выполнения | в гибриде исполняемые файлы имеют `+x` | `ls -l`: менеджер, поисковик, сканер, проверки |

Сверх реестра закрыты два дефекта, найденные при портировании (см. REFACTORING.md, раздел 4):
HG-01 (`mapfile` в `prune_backups` не существует в bash 3.2) и HG-02 (права каталога бэкапов
делали выгрузку невозможной для пользователя сайта).

## 4. Что гибрид НЕ наследует и почему

| Не взято | Откуда | Причина |
|---|---|---|
| Ключ Astra аргументом `wp` | база, SagaAI DeepSeek Pro, SagaAI DeepSeek Flash + RAGRAF, SagaAI DeepSeek Pro + RAGRAF, AutoClaw GLM 5.3 Flash + RAGRAF, Deepseek Harness Flash | виден в `ps` |
| `source` конфига | SagaAI DeepSeek Pro, SagaAI DeepSeek Flash + RAGRAF, Deepseek Harness Flash | исполнение кода с привилегиями менеджера |
| Сборка команды строкой и `su -c` | база | RCE (воспроизведено) |
| `printf %q` для оператора `&&` | SagaAI DeepSeek Pro + RAGRAF | ломает запуск WP-CLI, отказ бесшумный |
| Маски исключений по полному пути | база | молчаливая потеря сайтов |
| Авторский список плагинов в дефолте | шесть поставок | чужое требование в каждом вызове |
| Значения `--user-env` из конфига или `argv` | — | это был бы канал инъекции в окружение `wp`; принимаются только имена, значения берутся из своего окружения |
| `--fields`, `--page-limit`, `--allow-root auto/always`, `--log-level`, `--lock-file`, `--error-log-file` | QWEN Hybrid | интерфейсные удобства; `--log-dir` уже покрывает сценарий, а `--lock-file` дублирует безопасный лок в `TMPDIR` |

## 5. Чего в гибриде всё ещё нет

| Пробел | Номер | Почему оставлен |
|---|---|---|
| Документация `ANALYSIS.md` донора описывает `source`-конфиг | **HY-01** | аудит базы не переписывается: он описывает состояние базы, а не гибрида; расхождение зафиксировано |
| Набор `tests/smoke_test.sh` донора не обновлён | **HY-02** | проверяет старое поведение конфига; вместо него независимый `verify.sh` (72 проверки) |
| 3 note ShellCheck класса info | **HY-03** | намеренные шаблоны (`'$'*`) и обработчик через `trap` |
| Реальная смена пользователя не проверена | — | нужен root, которого на стенде нет |
| Сканер секретов не читает бинарные файлы и значения, собранные из фрагментов | — | заявлено в его `--help` явно |

## 6. Как воспроизвести

```bash
# проверки (72), общий стенд, без root
bash research/hybrid/verify.sh && bash research/hybrid/tests/compat_test.sh && bash research/hybrid/verify_build.sh

# статика
research/bin/shellcheck -f gcc research/hybrid/Bash_WP-CLI_Update.sh research/hybrid/Find_WP_Senior.sh research/hybrid/tools/scan-secrets.sh

# диагностика без установленного WP-CLI
research/bin/bash52 research/hybrid/Bash_WP-CLI_Update.sh --print-config
research/bin/bash52 research/hybrid/Bash_WP-CLI_Update.sh --status
research/bin/bash52 research/hybrid/Bash_WP-CLI_Update.sh --list-modes

# сканер секретов отдельно (работает и на bash 3.2)
research/hybrid/tools/scan-secrets.sh --strict /var/www/example.com
```

## 7. Оговорка о сопоставимости

Гибрид — работа другого рода, чем поставка агента по замеру: он собран после того, как все дефекты
шести конфигураций были найдены и описаны в реестре, и использует чужой код как основу и как источник
идей. Его «стоимость поставки» несопоставима с токенами и минутами сессий 1—6, поэтому в рейтинге он
идёт строкой **вне конкурса**, а балл приведён справочно.
