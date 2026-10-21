# Карта проекта (PROJECT_MAP)

Автоматически поддерживается DevAgent. Структура - детерминированная, описания назначения файлов - генерируются моделью. Файл генерируемый: не правьте его вручную - для обновления выполните регенерацию (генератор проекта или write_project_map с полным словарём описаний).

- Обновлено: `2026-10-06T18:32:05+00:00`
- Файлов: **5**
- Python-символов: **7**
- Отпечаток содержимого: `sha256:d324c44afd133a9665569af94b409f9ef2b24a684c5176ef7248f6dc1e634544` - если он не совпадает с `build_project_map()['fingerprint']`, карта устарела: пересоберите её.
- Языки: Markdown: 3, Python: 1, Shell: 4

## Файлы и назначение

| Файл | Язык | Назначение | Зависит от |
| --- | --- | --- | --- |
| `Bash_WP-CLI_Update.sh` | Shell | Main WP-CLI maintenance script (v5.0.0): per-site core/plugin/theme/db/cron/astra operations as the site user, argv-safe command construction, runuser + su fallback, atomic lock, rotating logs, strict mode. | - |
| `Find_WP_Senior.sh` | Shell | WordPress discovery script (v2.0.0): finds wp-config.php roots under webroots, prunes exclusions via one correct find expression, deduplicates and atomically writes site paths. | - |
| `tests/test_suite.py` | Python | Pytest wrapper: bash -n syntax checks, both scenario suites, advisory shfmt check; resolves the Git Bash interpreter. | - |
| `tests/scenarios/test_discovery.sh` | Shell | Scenario suite for Find_WP_Senior.sh on synthetic WP trees (discovery, exclusions, dedupe, atomic output). | - |
| `tests/scenarios/test_main_update.sh` | Shell | Scenario suite for Bash_WP-CLI_Update.sh with fake system binaries proving argv-safe execution, skip-plugins scoping, lock, rotation, su fallback. | - |

## Структура Python-модулей

### `tests/test_suite.py`
- `resolve_bash` (func, строка 22)
- `posix` (func, строка 40)
- `run_bash` (func, строка 51)
- `test_syntax` (func, строка 55)
- `test_discovery_scenarios` (func, строка 62)
- `test_main_update_scenarios` (func, строка 73)
- `test_shfmt_advisory` (func, строка 84)
