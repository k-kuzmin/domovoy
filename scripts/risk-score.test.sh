#!/usr/bin/env bash
#
# Домовой — проверочные сценарии риск-скора scripts/risk-score.sh.
#
# ЗАЧЕМ
#
# Уровень риска — это утверждение о задаче, и проверять его надо с двух сторон.
# Скрипт, который только зеленеет, доказывал бы ровно ничего: он зеленел бы и с
# пустой таблицей сигналов. Поэтому у каждого включённого сигнала конфига здесь
# пара сценариев — срабатывание и молчание, — а перечень сигналов берётся из
# pipeline/risk.json, а не из списка в этом файле: сигнал, добавленный в конфиг
# без пары сценариев, роняет харнесс.
#
# МАТЕРИАЛ ДЕРЕВА
#
# Половина сценариев работает не на выдуманных путях и не на строках, которые
# харнесс сам же и напечатал, а на настоящих файлах репозитория:
#
#   src/Domovoy.Api/Security/DeviceTokenAuthenticationHandler.cs — путь и
#       содержимое зоны авторизации;
#   tests/Domovoy.Tests/ConfigurationExampleTests.cs:22-27 — настоящие строки с
#       именами секретных настроек внутри области keyword_paths;
#   tests/Domovoy.Tests/MobileLayeringTests.cs и
#   src/Domovoy.Core/Models/HaEntityState.cs — молчаливая пара к ним: внутри той
#       же области, без единого слова чувствительной зоны.
#
# ЧТО ДЕЛАТЬ, ЕСЛИ СЦЕНАРИЙ УПАЛ НА МАТЕРИАЛЕ
#
# Исчезнувший или переписанный файл-источник роняет сценарий, а не пропускает
# его — по образцу пинов scripts/plan.test.sh. Починка — обновить материал под
# новое дерево: взять другой настоящий файл той же зоны. Ослаблять сценарий или
# заменять материал строкой, напечатанной здесь же, нельзя: тогда сценарий
# доказывает лишь то, что регулярка совпала с текстом, который сам и написал.
#
# ОТДЕЛЬНО
#
# Режимы diff и history проверяются на репозитории, собранном во временном
# каталоге, а не на истории этого репозитория: сценарий, зависящий от того, что
# вчера смерджили, краснеет по чужой причине.
#
# КАК ЗАПУСКАТЬ
#
#   bash scripts/risk-score.test.sh
#
# Код возврата: 0 — все сценарии прошли, 1 — есть провалившиеся, 2 — запуск не
# состоялся (нет скрипта, нет jq, нет git).
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$SCRIPT_DIR/risk-score.sh"
CONFIG="$ROOT/pipeline/risk.json"
PROTECTED="$SCRIPT_DIR/protected-paths.sh"
FIXTURES="$SCRIPT_DIR/fixtures/plans"

if [ ! -f "$SCRIPT" ]; then
    printf 'Не найден %s\n' "$SCRIPT" >&2
    exit 2
fi

if [ ! -f "$CONFIG" ]; then
    printf 'Не найден конфиг сигналов: %s\n' "$CONFIG" >&2
    exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
    printf 'Не найден jq: сценарии портят конфиг точечными мутациями через него.\n' >&2
    exit 2
fi

if ! command -v git >/dev/null 2>&1; then
    printf 'Не найден git: режимы diff и history считают факты по репозиторию.\n' >&2
    exit 2
fi

SANDBOX="$(mktemp -d)"
if [ ! -d "$SANDBOX" ]; then
    printf 'Не удалось создать временный каталог — сценарии не запускались.\n' >&2
    exit 2
fi
trap 'rm -rf "$SANDBOX"' EXIT

PASSED=0
FAILED=0
FAILED_NAMES=()

CASE_NAME=''
CASE_OK=1
OUTPUT=''
STATUS=0

# Перечень сигналов, у которых сценарии предъявили срабатывание и молчание.
# Сверяется с конфигом последним сценарием.
FIRED_IDS=''
SILENT_IDS=''

REPO=''
REPO_N=0

begin_case() {
    CASE_NAME="$1"
    CASE_OK=1
    OUTPUT=''
    STATUS=0
    printf '\n[ ... ] %s\n' "$CASE_NAME"
}

fail_case() {
    CASE_OK=0
    printf '        ! %s\n' "$1"
}

end_case() {
    if [ "$CASE_OK" -eq 1 ]; then
        PASSED=$((PASSED + 1))
        printf '[ ok  ] %s\n' "$CASE_NAME"
    else
        FAILED=$((FAILED + 1))
        FAILED_NAMES+=("$CASE_NAME")
        printf '[ FAIL] %s\n' "$CASE_NAME"
        printf '        вывод:\n%s\n' "$OUTPUT" | sed 's/^/        /'
    fi
}

run_score() {
    OUTPUT="$(bash "$SCRIPT" "$@" 2>&1)"
    STATUS=$?
}

expect_status() {
    if [ "$STATUS" -ne "$1" ]; then
        fail_case "код возврата $STATUS, ожидался $1"
    fi
}

expect_output() {
    # Ключ -- обязателен: искомое может начинаться с дефиса.
    if ! printf '%s\n' "$OUTPUT" | grep -qF -- "$1"; then
        fail_case "в выводе нет: $1"
    fi
}

expect_no_output() {
    if printf '%s\n' "$OUTPUT" | grep -qF -- "$1"; then
        fail_case "в выводе не должно быть: $1"
    fi
}

first_line() {
    printf '%s\n' "$OUTPUT" | head -n 1
}

expect_level() {
    local got
    got="$(first_line)"
    if [ "$got" != "Уровень: $1" ]; then
        fail_case "первая строка «$got», ожидалась «Уровень: $1»"
    fi
}

expect_level_below_high() {
    local got
    got="$(first_line)"
    case "$got" in
        'Уровень: low' | 'Уровень: medium') ;;
        *) fail_case "ожидался уровень ниже high, получено «$got»" ;;
    esac
}

# Сработавший сигнал печатается строкой «  [<уровень>] <id> — <заголовок>».
# Выключенный — «  [выключен] <id> — …», и под этот шаблон он не подпадает:
# иначе «сигнал молчит» и «сигнал выключен» были бы одним утверждением.
signal_line() {
    printf '^  \\[(low|medium|high)\\] %s —' "$1"
}

expect_signal() {
    FIRED_IDS="$FIRED_IDS$1"$'\n'
    if ! printf '%s\n' "$OUTPUT" | grep -qE "$(signal_line "$1")"; then
        fail_case "в выводе нет сработавшего сигнала: $1"
    fi
}

expect_signal_silent() {
    SILENT_IDS="$SILENT_IDS$1"$'\n'
    if printf '%s\n' "$OUTPUT" | grep -qE "$(signal_line "$1")"; then
        fail_case "сигнал сработал, а должен был молчать: $1"
    fi
}

signal_ids() {
    printf '%s\n' "$1" \
        | grep -oE '^  \[(low|medium|high)\] [a-z0-9-]+' \
        | grep -oE '[a-z0-9-]+$' \
        | sort -u
}

# jq под Windows пишет CRLF, и возврат каретки уезжает внутрь значения:
# ожидание сценария перестаёт равняться уровню из конфига. Тот же tr стоит в
# самом скрипте и по той же причине.
config_level() {
    jq -r --arg id "$1" '.signals[] | select(.id == $id) | .level' "$CONFIG" | tr -d '\r'
}

# Точечная мутация конфига: портится ровно одно, остальное настоящее.
mutate_config() {
    local out="$SANDBOX/config-$RANDOM$RANDOM.json"
    if ! jq "$1" "$CONFIG" > "$out"; then
        printf 'Мутация конфига не собралась: %s\n' "$1" >&2
        exit 2
    fi
    printf '%s' "$out"
}

# ------------------------------------------------------------------
# Временный репозиторий: один коммит базы, один коммит правок.
# ------------------------------------------------------------------
new_repo() {
    REPO_N=$((REPO_N + 1))
    REPO="$SANDBOX/repo-$REPO_N"
    mkdir -p "$REPO"
    if ! git -C "$REPO" init -q -b main >/dev/null 2>&1; then
        git -C "$REPO" init -q >/dev/null 2>&1
        git -C "$REPO" checkout -q -b main >/dev/null 2>&1
    fi
    printf 'база\n' > "$REPO/README.md"
    commit_repo 'база'
}

commit_repo() {
    git -C "$REPO" add -A >/dev/null 2>&1
    # Личность задаётся ключами: на раннере глобальной может не быть, и коммит
    # отказал бы там, где локально проходит.
    git -C "$REPO" \
        -c user.email='harness@example.invalid' \
        -c user.name='risk-score harness' \
        -c commit.gpgsign=false \
        commit -q -m "$1" >/dev/null 2>&1
}

put() {
    local path="$REPO/$1"
    shift
    mkdir -p "$(dirname "$path")"
    if [ "$#" -eq 0 ]; then
        printf 'строка без единого слова чувствительной зоны\n' > "$path"
    else
        printf '%s\n' "$@" > "$path"
    fi
}

# Копия настоящего файла дерева целиком. Исчез — сценарий провален.
put_from_tree() {
    local dest="$REPO/$1" src="$ROOT/$2"
    if [ ! -f "$src" ]; then
        fail_case "материал дерева исчез: $2 — сценарий провален, а не пропущен"
        return 1
    fi
    mkdir -p "$(dirname "$dest")"
    cat "$src" > "$dest"
    return 0
}

# Копия диапазона строк настоящего файла дерева.
put_lines_from_tree() {
    local dest="$REPO/$1" src="$ROOT/$2" from="$3" to="$4"
    if [ ! -f "$src" ]; then
        fail_case "материал дерева исчез: $2 — сценарий провален, а не пропущен"
        return 1
    fi
    mkdir -p "$(dirname "$dest")"
    sed -n "${from},${to}p" "$src" > "$dest"
    if [ ! -s "$dest" ]; then
        fail_case "материал дерева пуст: $2, строки $from-$to"
        return 1
    fi
    return 0
}

# Минимальный план: риск-скору нужны files[].path и flags, остальные разделы
# согласованного плана на уровень не влияют.
make_plan() {
    local out="$SANDBOX/plan-$RANDOM$RANDOM.json"
    local flags="$1"
    shift
    local paths='[]'
    if [ "$#" -gt 0 ]; then
        paths="$(printf '%s\n' "$@" | jq -R . | jq -s 'map({path: .})')"
    fi
    jq -n --argjson files "$paths" --argjson flags "$flags" \
        '{issue: 4242, files: $files, flags: $flags}' > "$out"
    printf '%s' "$out"
}

FLAGS_NONE='{"allow_protected":false,"allow_contract":false,"destructive_migration":false,"new_dependency":false,"new_dependency_reason":""}'

# ------------------------------------------------------------------
begin_case 'Материал дерева на месте: пины сценариев разрешаются'
for material in \
    'src/Domovoy.Api/Security/DeviceTokenAuthenticationHandler.cs' \
    'tests/Domovoy.Tests/ConfigurationExampleTests.cs' \
    'tests/Domovoy.Tests/MobileLayeringTests.cs' \
    'src/Domovoy.Core/Models/HaEntityState.cs'; do
    if [ ! -f "$ROOT/$material" ]; then
        fail_case "материал дерева исчез: $material"
    fi
done
# Строки 22-27 первого файла — тот самый массив имён секретных настроек.
# Уехал по файлу — сценарий краснеет здесь, а не даёт ложное молчание ниже.
if ! sed -n '22,27p' "$ROOT/tests/Domovoy.Tests/ConfigurationExampleTests.cs" \
    | grep -qF 'SecretSettingPaths'; then
    fail_case 'строки 22-27 ConfigurationExampleTests.cs больше не тот массив: материал уехал'
fi
if ! grep -qF 'Authorization' "$ROOT/src/Domovoy.Api/Security/DeviceTokenAuthenticationHandler.cs"; then
    fail_case 'в обработчике аутентификации больше нет разбора заголовка: материал уехал'
fi
end_case

# ------------------------------------------------------------------
begin_case 'Затронутая миграция даёт high, соседний файл проекта данных молчит'
new_repo
put 'src/Domovoy.Data/Migrations/20260101000000_Init.cs' \
    'public sealed partial class Init' '{' '}'
put 'src/Domovoy.Data/DomovoyDbContext.cs' 'public sealed class DomovoyDbContext' '{' '}'
commit_repo 'правка'
run_score diff HEAD~1 HEAD --repo "$REPO"
expect_status 0
expect_level "$(config_level db-migration)"
expect_signal db-migration
expect_output 'путь: src/Domovoy.Data/Migrations/20260101000000_Init.cs'
expect_no_output 'путь: src/Domovoy.Data/DomovoyDbContext.cs'
end_case

# ------------------------------------------------------------------
begin_case 'Публичный контракт API даёт high, документация рядом молчит'
new_repo
put 'contracts/openapi.yaml' 'openapi: 3.0.3' 'paths: {}'
put 'src/Domovoy.Mobile.Core/Generated/ApiClient.cs' 'public sealed class ApiClient' '{' '}'
put 'README.md' 'строка документации'
commit_repo 'правка'
run_score diff HEAD~1 HEAD --repo "$REPO"
expect_status 0
expect_level "$(config_level api-contract)"
expect_signal api-contract
expect_output 'путь: contracts/openapi.yaml'
expect_output 'путь: src/Domovoy.Mobile.Core/Generated/ApiClient.cs'
expect_no_output 'путь: README.md'
end_case

# ------------------------------------------------------------------
begin_case 'Путевая половина зоны авторизации проверяется настоящим файлом дерева'
new_repo
if put_from_tree 'src/Domovoy.Api/Security/DeviceTokenAuthenticationHandler.cs' \
    'src/Domovoy.Api/Security/DeviceTokenAuthenticationHandler.cs' \
    && put_from_tree 'src/Domovoy.Core/Models/HaEntityState.cs' \
        'src/Domovoy.Core/Models/HaEntityState.cs'; then
    commit_repo 'правка'
    run_score diff HEAD~1 HEAD --repo "$REPO"
    expect_status 0
    expect_level "$(config_level sensitive-area)"
    expect_signal sensitive-area
    expect_output 'путь: src/Domovoy.Api/Security/DeviceTokenAuthenticationHandler.cs'
    expect_no_output 'путь: src/Domovoy.Core/Models/HaEntityState.cs'

    # Режим plan отделяет путевую половину от словарной: строк он не читает.
    PLAN_AUTH="$(make_plan "$FLAGS_NONE" \
        'src/Domovoy.Api/Security/DeviceTokenAuthenticationHandler.cs' \
        'src/Domovoy.Core/Models/HaEntityState.cs')"
    run_score plan "$PLAN_AUTH"
    expect_status 0
    expect_level "$(config_level sensitive-area)"
    expect_signal sensitive-area
    expect_output 'путь: src/Domovoy.Api/Security/DeviceTokenAuthenticationHandler.cs'
fi
end_case

# ------------------------------------------------------------------
begin_case 'Включённая половина keyword_paths проверяется настоящими строками из tests и src'
new_repo
# Настоящие строки, положенные путями вне списка paths сигнала: срабатывает
# ровно словарная половина, а не путевая.
if put_lines_from_tree 'tests/Domovoy.Tests/SecretPathsMaterial.cs' \
    'tests/Domovoy.Tests/ConfigurationExampleTests.cs' 22 27 \
    && put_lines_from_tree 'src/Domovoy.Api/Wiring.cs' \
        'src/Domovoy.Api/Security/DeviceTokenAuthenticationHandler.cs' 29 45; then
    commit_repo 'правка'
    run_score diff HEAD~1 HEAD --repo "$REPO"
    expect_status 0
    expect_level "$(config_level sensitive-area)"
    expect_signal sensitive-area
    expect_output 'слово:'
    expect_output 'tests/Domovoy.Tests/SecretPathsMaterial.cs'
    expect_output 'src/Domovoy.Api/Wiring.cs'
fi
end_case

# ------------------------------------------------------------------
begin_case 'Настоящие строки без слов чувствительной зоны внутри той же области молчат'
new_repo
if put_from_tree 'tests/Domovoy.Tests/MobileLayeringTests.cs' \
    'tests/Domovoy.Tests/MobileLayeringTests.cs' \
    && put_from_tree 'src/Domovoy.Core/Models/HaEntityState.cs' \
        'src/Domovoy.Core/Models/HaEntityState.cs'; then
    commit_repo 'правка'
    run_score diff HEAD~1 HEAD --repo "$REPO"
    expect_status 0
    expect_signal_silent sensitive-area
    expect_level_below_high
fi
end_case

# ------------------------------------------------------------------
begin_case 'Слово чувствительной области вне keyword_paths уровня не поднимает'
new_repo
# Те же настоящие строки — но в правилах, скриптах и самом конфиге. Плюс копия
# pipeline/risk.json: регулярки чувствительной зоны лежат в нём текстом.
if put_lines_from_tree 'docs/rules/выдержка.md' \
    'tests/Domovoy.Tests/ConfigurationExampleTests.cs' 22 27 \
    && put_lines_from_tree 'scripts/выдержка.sh' \
        'src/Domovoy.Api/Security/DeviceTokenAuthenticationHandler.cs' 29 45 \
    && put_from_tree 'pipeline/risk.json' 'pipeline/risk.json'; then
    commit_repo 'правка'
    run_score diff HEAD~1 HEAD --repo "$REPO"
    expect_status 0
    expect_signal_silent sensitive-area
    expect_level_below_high
fi
end_case

# ------------------------------------------------------------------
begin_case 'Дифф самой этой задачи не получает high'
new_repo
# Набор путей ровно тот, которым едет PR задачи #103: ни одного файла под
# src/** или tests/**, зато конфиг с регулярками и журнал с их пересказом.
if put_from_tree 'pipeline/risk.json' 'pipeline/risk.json' \
    && put_from_tree 'scripts/risk-score.test.sh' 'scripts/risk-score.test.sh'; then
    if [ -f "$ROOT/scripts/risk-score.sh" ]; then
        put_from_tree 'scripts/risk-score.sh' 'scripts/risk-score.sh'
    fi
    if [ -f "$ROOT/docs/tasks/103.md" ]; then
        put_from_tree 'docs/tasks/103.md' 'docs/tasks/103.md'
    fi
    if [ -f "$ROOT/docs/decisions/0019-risk-config-json-not-yaml.md" ]; then
        put_from_tree 'docs/decisions/0019-risk-config-json-not-yaml.md' \
            'docs/decisions/0019-risk-config-json-not-yaml.md'
    fi
    # Правки, а не создание: в PR это несколько добавленных строк.
    put '.github/workflows/ci-fast.yml' \
        '      - name: Сценарии риск-скора' \
        '        run: bash scripts/risk-score.test.sh'
    put 'docs/pipeline.md' \
        '| Поведение риск-скора | — | `scripts/risk-score.test.sh` |'
    put 'docs/decisions/README.md' '| 0019 | конфиг риск-скора в JSON |'
    commit_repo 'правка'
    run_score diff HEAD~1 HEAD --repo "$REPO"
    expect_status 0
    expect_level_below_high
    expect_signal_silent sensitive-area
fi
end_case

# ------------------------------------------------------------------
begin_case 'Сигнал с ключевыми словами и пустой областью роняет скрипт кодом 2'
new_repo
put 'src/Domovoy.Core/Models/Thing.cs' 'public sealed class Thing;'
commit_repo 'правка'

MUT_EMPTY_SCOPE="$(mutate_config '.signals |= map(if .id == "sensitive-area" then .keyword_paths = [] else . end)')"
run_score diff HEAD~1 HEAD --repo "$REPO" --config "$MUT_EMPTY_SCOPE"
expect_status 2
expect_output 'пустой области keyword_paths'
expect_no_output 'Уровень:'

MUT_NO_SCOPE="$(mutate_config '.signals |= map(if .id == "sensitive-area" then del(.keyword_paths) else . end)')"
run_score diff HEAD~1 HEAD --repo "$REPO" --config "$MUT_NO_SCOPE"
expect_status 2
expect_output 'keyword_paths'
expect_no_output 'Уровень:'
end_case

# ------------------------------------------------------------------
begin_case 'DI-композиция и конфигурация приложения дают medium, правка скрипта пайплайна не даёт ничего'
new_repo
put 'src/Domovoy.Api/Program.cs' 'var builder = WebApplication.CreateBuilder(args);'
put 'src/Domovoy.Api/appsettings.json' '{' '  "Serilog": {}' '}'
commit_repo 'правка'
run_score diff HEAD~1 HEAD --repo "$REPO"
expect_status 0
expect_level "$(config_level di-composition)"
expect_signal di-composition
expect_signal app-configuration
expect_output 'путь: src/Domovoy.Api/Program.cs'
expect_output 'путь: src/Domovoy.Api/appsettings.json'

new_repo
put 'scripts/что-нибудь.sh' '#!/usr/bin/env bash' 'printf "ok\\n"'
put '.github/workflows/что-нибудь.yml' 'name: что-нибудь'
put 'docs/rules/implement.md' 'строка правил'
commit_repo 'правка'
run_score diff HEAD~1 HEAD --repo "$REPO"
expect_status 0
expect_level low
expect_output 'ни один не сработал'
expect_signal_silent di-composition
expect_signal_silent app-configuration
end_case

# ------------------------------------------------------------------
begin_case 'Платформенный код даёт medium, а Mobile.Core остаётся молчаливым'
new_repo
put 'src/Domovoy.Mobile.App/Platforms/Android/MainActivity.cs' 'public sealed class MainActivity;'
put 'src/Domovoy.Mobile.Core/ViewModels/HomeViewModel.cs' 'public sealed class HomeViewModel;'
commit_repo 'правка'
run_score diff HEAD~1 HEAD --repo "$REPO"
expect_status 0
expect_level "$(config_level platform-code)"
expect_signal platform-code
expect_output 'путь: src/Domovoy.Mobile.App/Platforms/Android/MainActivity.cs'
expect_no_output 'путь: src/Domovoy.Mobile.Core/ViewModels/HomeViewModel.cs'
end_case

# ------------------------------------------------------------------
begin_case 'Новая внешняя зависимость видна и по пути пакетов, и по флагу плана'
new_repo
put 'Directory.Packages.props' '<Project>' '</Project>'
commit_repo 'правка'
run_score diff HEAD~1 HEAD --repo "$REPO"
expect_status 0
expect_level "$(config_level new-dependency)"
expect_signal new-dependency
expect_output 'путь: Directory.Packages.props'

PLAN_DEP="$(make_plan \
    '{"allow_protected":false,"allow_contract":false,"destructive_migration":false,"new_dependency":true,"new_dependency_reason":"разбор cron, обоснование в комментарии #4242"}' \
    'src/Domovoy.Core/Ports/IScheduler.cs')"
run_score plan "$PLAN_DEP"
expect_status 0
expect_level "$(config_level new-dependency)"
expect_signal new-dependency
expect_output 'флаг плана: new_dependency'

PLAN_PLAIN="$(make_plan "$FLAGS_NONE" 'src/Domovoy.Core/Ports/IScheduler.cs')"
run_score plan "$PLAN_PLAIN"
expect_status 0
expect_signal_silent new-dependency
expect_level low
end_case

# ------------------------------------------------------------------
begin_case 'Размер диффа выше порога даёт medium, а на строку ниже порога сигнала нет'
THRESHOLD_LINES="$(jq -r '.thresholds.diff_lines' "$CONFIG" | tr -d '\r')"
if [ "$THRESHOLD_LINES" = 'null' ] || [ -z "$THRESHOLD_LINES" ]; then
    fail_case 'порог размера в pipeline/risk.json не заполнен: прогон history ещё не записал процентиль'
else
    new_repo
    ABOVE=$((THRESHOLD_LINES + 1))
    BELOW=$((THRESHOLD_LINES - 1))
    seq 1 "$ABOVE" | sed 's/^/\/\/ строка /' > "$REPO/src/Domovoy.Core/Bulk.cs" 2>/dev/null \
        || { mkdir -p "$REPO/src/Domovoy.Core"; seq 1 "$ABOVE" | sed 's/^/\/\/ строка /' > "$REPO/src/Domovoy.Core/Bulk.cs"; }
    commit_repo 'правка выше порога'
    run_score diff HEAD~1 HEAD --repo "$REPO"
    expect_status 0
    expect_level "$(config_level diff-size)"
    expect_signal diff-size
    expect_output "строк: $ABOVE"

    new_repo
    mkdir -p "$REPO/src/Domovoy.Core"
    seq 1 "$BELOW" | sed 's/^/\/\/ строка /' > "$REPO/src/Domovoy.Core/Bulk.cs"
    commit_repo 'правка ниже порога'
    run_score diff HEAD~1 HEAD --repo "$REPO"
    expect_status 0
    expect_signal_silent diff-size
    expect_level low
fi
end_case

# ------------------------------------------------------------------
begin_case 'Выключенный сигнал покрытия печатается выключенным и на уровень не влияет'
new_repo
put 'src/Domovoy.Api/Program.cs' 'var builder = WebApplication.CreateBuilder(args);'
commit_repo 'правка'
run_score diff HEAD~1 HEAD --repo "$REPO"
expect_status 0
WITH_COVERAGE="$(first_line)"
if ! printf '%s\n' "$OUTPUT" | grep -qE '^  \[выключен\] coverage-drop —'; then
    fail_case 'выключенный сигнал покрытия не напечатан строкой «[выключен] coverage-drop»'
fi
expect_output 'фазы 3'

MUT_NO_COVERAGE="$(mutate_config '.signals |= map(select(.id != "coverage-drop"))')"
run_score diff HEAD~1 HEAD --repo "$REPO" --config "$MUT_NO_COVERAGE"
expect_status 0
if [ "$(first_line)" != "$WITH_COVERAGE" ]; then
    fail_case "уровень изменился при удалении выключенного сигнала: «$WITH_COVERAGE» против «$(first_line)»"
fi
expect_no_output 'coverage-drop'
end_case

# ------------------------------------------------------------------
begin_case 'Дифф только в тестах и изолированной логике даёт low без единого сигнала'
new_repo
if put_from_tree 'tests/Domovoy.Tests/MobileLayeringTests.cs' \
    'tests/Domovoy.Tests/MobileLayeringTests.cs' \
    && put_from_tree 'src/Domovoy.Core/Models/HaEntityState.cs' \
        'src/Domovoy.Core/Models/HaEntityState.cs'; then
    commit_repo 'правка'
    run_score diff HEAD~1 HEAD --repo "$REPO"
    expect_status 0
    expect_level low
    expect_output 'ни один не сработал'
    # Молчание каждого путевого сигнала на честном диффе — вторая половина
    # пары. Соседний путь в своём сценарии показывает то же точечно, но
    # перечень для сверки с конфигом собирается здесь.
    expect_signal_silent db-migration
    expect_signal_silent api-contract
    expect_signal_silent platform-code
    expect_signal_silent sensitive-area
fi
end_case

# ------------------------------------------------------------------
begin_case 'Уровень равен максимуму сработавших, а список печатается целиком'
new_repo
put 'src/Domovoy.Data/Migrations/20260101000000_Init.cs' 'public sealed partial class Init;'
put 'src/Domovoy.Api/Program.cs' 'var builder = WebApplication.CreateBuilder(args);'
commit_repo 'правка'
run_score diff HEAD~1 HEAD --repo "$REPO"
expect_status 0
expect_level high
expect_signal db-migration
expect_signal di-composition
end_case

# ------------------------------------------------------------------
begin_case 'Режим plan называет, чего он не мерил'
PLAN_ANY="$(make_plan "$FLAGS_NONE" 'src/Domovoy.Core/Models/Thing.cs')"
run_score plan "$PLAN_ANY"
expect_status 0
expect_output 'Не измерялось в режиме plan'
expect_output 'размер диффа'
expect_output 'ключевые слова'

new_repo
put 'src/Domovoy.Core/Models/Thing.cs' 'public sealed class Thing;'
commit_repo 'правка'
run_score diff HEAD~1 HEAD --repo "$REPO"
expect_status 0
expect_no_output 'Не измерялось в режиме plan'
end_case

# ------------------------------------------------------------------
begin_case 'Режим plan работает на реальных согласованных планах из фикстур'
FIXTURE_COUNT=0
if [ ! -d "$FIXTURES" ]; then
    fail_case "нет каталога фикстур планов: $FIXTURES"
else
    for fixture in "$FIXTURES"/*.json; do
        [ -f "$fixture" ] || continue
        FIXTURE_COUNT=$((FIXTURE_COUNT + 1))
        run_score plan "$fixture"
        expect_status 0
        if ! first_line | grep -qE '^Уровень: (low|medium|high)$'; then
            fail_case "на фикстуре $(basename "$fixture") первая строка не «Уровень: …»: $(first_line)"
        fi
    done
    if [ "$FIXTURE_COUNT" -eq 0 ]; then
        fail_case 'в каталоге фикстур нет ни одного плана — вход режима plan не предъявлен'
    fi
fi
end_case

# ------------------------------------------------------------------
begin_case 'Оба входа на одних и тех же фактах дают один уровень'
new_repo
put 'src/Domovoy.Data/Migrations/20260101000000_Init.cs' 'public sealed partial class Init;'
put 'src/Domovoy.Api/Program.cs' 'var builder = WebApplication.CreateBuilder(args);'
commit_repo 'правка'
run_score diff HEAD~1 HEAD --repo "$REPO"
expect_status 0
DIFF_LEVEL="$(first_line)"
DIFF_IDS="$(signal_ids "$OUTPUT" | grep -v '^diff-size$')"

PLAN_SAME="$(make_plan "$FLAGS_NONE" \
    'src/Domovoy.Data/Migrations/20260101000000_Init.cs' \
    'src/Domovoy.Api/Program.cs')"
run_score plan "$PLAN_SAME"
expect_status 0
if [ "$(first_line)" != "$DIFF_LEVEL" ]; then
    fail_case "уровни входов расходятся: diff «$DIFF_LEVEL», plan «$(first_line)»"
fi
PLAN_IDS="$(signal_ids "$OUTPUT" | grep -v '^diff-size$')"
if [ "$DIFF_IDS" != "$PLAN_IDS" ]; then
    fail_case "наборы сигналов расходятся: diff «$(printf '%s' "$DIFF_IDS" | tr '\n' ' ')», plan «$(printf '%s' "$PLAN_IDS" | tr '\n' ' ')»"
fi
end_case

# ------------------------------------------------------------------
begin_case 'Режим history во временном репозитории печатает состав корпуса, распределение и таблицу'
new_repo
put 'src/Domovoy.Api/Program.cs' 'var builder = WebApplication.CreateBuilder(args);'
commit_repo 'feat: первый смерженный (#11)'
put 'tests/Domovoy.Tests/Thing.cs' 'public sealed class ThingTests;'
commit_repo 'docs: коммит без номера PR'
put 'scripts/что-нибудь.sh' '#!/usr/bin/env bash'
put 'docs/pipeline.md' 'строка реестра'
commit_repo 'ci: второй смерженный (#22)'
put 'src/Domovoy.Data/Migrations/20260101000000_Init.cs' 'public sealed partial class Init;'
commit_repo 'feat: третий смерженный (#33)'
put 'README.md' 'ещё строка'
commit_repo 'docs: снова без номера'
run_score history --repo "$REPO" --base main
expect_status 0
expect_output 'Состав корпуса'
expect_output 'Отобрано коммитов: 3'
expect_output 'Правило отбора'
expect_output 'Распределение размеров'
expect_output 'Метод процентиля'
expect_output 'PR → уровень → сигналы'
expect_output '| #11 |'
expect_output '| #22 |'
expect_output '| #33 |'
ROWS="$(printf '%s\n' "$OUTPUT" | grep -cE '^\| #[0-9]+ \|')"
if [ "$ROWS" -ne 3 ]; then
    fail_case "строк таблицы $ROWS, а коммитов с номером PR во временном репозитории три"
fi
# Разбивка по верхним каталогам считает настоящие пути временного репозитория.
expect_output 'src:'
expect_output 'scripts:'
if ! printf '%s\n' "$OUTPUT" | grep -qE '^\| #33 \| high \|'; then
    fail_case 'PR с миграцией не получил high в таблице истории'
fi
end_case

# ------------------------------------------------------------------
begin_case 'Зоны, названные в обоих списках, опознаются и как защищённые'
if [ ! -f "$PROTECTED" ]; then
    fail_case "нет источника защищённых путей: $PROTECTED"
else
    # shellcheck source=protected-paths.sh
    . "$PROTECTED"
    if [ "${#PROTECTED_PATTERNS[@]}" -eq 0 ]; then
        fail_case 'список защищённых путей пуст — сверять нечего'
    else
        PROT_RE="$(protected_regex)"
        # Ожидаемый уровень берётся из конфига, а не пишется здесь: у зоны
        # платформенного кода он medium — так эта зона стоит и в таблице фазы 2
        # ТЗ, — и захардкоженный high проверял бы не сверку списков, а память
        # автора сценария.
        for pair in \
            'src/Domovoy.Data/Migrations/20260101000000_Init.cs|db-migration' \
            'contracts/openapi.yaml|api-contract' \
            'src/Domovoy.Mobile.App/Platforms/Android/MainActivity.cs|platform-code'; do
            sample="${pair%%|*}"
            zone_signal="${pair##*|}"
            PLAN_ZONE="$(make_plan "$FLAGS_NONE" "$sample")"
            run_score plan "$PLAN_ZONE"
            expect_status 0
            if [ "$(first_line)" != "Уровень: $(config_level "$zone_signal")" ]; then
                fail_case "образец зоны не дал уровень сигнала $zone_signal: $sample"
            fi
            expect_signal "$zone_signal"
            if ! printf '%s' "$sample" | grep -qE "$PROT_RE"; then
                fail_case "путь зоны не покрыт protected_regex: $sample — списки разъехались"
            fi
        done

        # Названный разрыв: зона авторизации сигналом опознаётся, а защищённым
        # путём не считается. Внесут в CODEOWNERS — сценарий упадёт здесь, и
        # правка будет осознанной, а не незамеченной.
        AUTH='src/Domovoy.Api/Security/DeviceTokenAuthenticationHandler.cs'
        PLAN_AUTH_ZONE="$(make_plan "$FLAGS_NONE" "$AUTH")"
        run_score plan "$PLAN_AUTH_ZONE"
        if [ "$(first_line)" != 'Уровень: high' ]; then
            fail_case "зона авторизации не даёт high: $AUTH"
        fi
        if printf '%s' "$AUTH" | grep -qE "$PROT_RE"; then
            fail_case "зона авторизации теперь под защитой путей: обнови сценарий и запись о разрыве"
        fi
    fi
fi
end_case

# ------------------------------------------------------------------
begin_case 'Сломанный конфиг роняет скрипт кодом 2, а не выдаёт low молча'
new_repo
put 'src/Domovoy.Core/Models/Thing.cs' 'public sealed class Thing;'
commit_repo 'правка'

BROKEN="$SANDBOX/broken.json"
printf '{ "signals": [ ' > "$BROKEN"
run_score diff HEAD~1 HEAD --repo "$REPO" --config "$BROKEN"
expect_status 2
expect_no_output 'Уровень: low'

NO_SIGNALS="$SANDBOX/no-signals.json"
printf '{ "thresholds": { "diff_lines": 100, "diff_files": 5 } }\n' > "$NO_SIGNALS"
run_score diff HEAD~1 HEAD --repo "$REPO" --config "$NO_SIGNALS"
expect_status 2
expect_output 'signals'
expect_no_output 'Уровень: low'

run_score diff HEAD~1 HEAD --repo "$REPO" --config "$SANDBOX/нет-такого-файла.json"
expect_status 2
expect_no_output 'Уровень:'
end_case

# ------------------------------------------------------------------
begin_case 'Отказ разбора конфига роняет скрипт, а не зеленит его молча'
# Проверка конфига идёт одним запросом jq, и её отказ обязан ронять счёт.
# Первая версия запроса падала на каждом конфиге, а вывод уезжал в /dev/null:
# скрипт печатал «Уровень: low» и ни одного нарушения на конфиге, у которого
# сигнал с ключевыми словами не имел области. Подставной jq отказывает ровно на
# запросе проверки — по имени переменной $required в программе, — поэтому форма
# разбирается настоящим, а падает именно проверка.
SHIM_DIR="$SANDBOX/bin"
mkdir -p "$SHIM_DIR"
JQ_REAL="$(command -v jq)"
cat > "$SHIM_DIR/jq" <<SHIM
#!/usr/bin/env bash
for arg in "\$@"; do
    case "\$arg" in
        *required*) exit 3 ;;
    esac
done
exec "$JQ_REAL" "\$@"
SHIM
chmod +x "$SHIM_DIR/jq"

PLAN_SHIM="$(make_plan "$FLAGS_NONE" 'src/Domovoy.Core/Models/Thing.cs')"
OUTPUT="$(PATH="$SHIM_DIR:$PATH" bash "$SCRIPT" plan "$PLAN_SHIM" 2>&1)"
STATUS=$?
expect_status 2
expect_output 'не отработал'
expect_no_output 'Уровень:'
end_case

# ------------------------------------------------------------------
begin_case 'Сверка обвязки видит риск-скор освобождённым, а его харнесс вызванным'
OUTPUT="$(bash "$SCRIPT_DIR/wiring.sh" "$ROOT" 2>&1)"
STATUS=$?
expect_status 0
expect_output 'освобождён: scripts/risk-score.sh'
expect_no_output 'ни один workflow не вызывает: scripts/risk-score.test.sh'
if ! grep -qF 'scripts/risk-score.test.sh' "$ROOT/docs/pipeline.md"; then
    fail_case 'в реестре сверок docs/pipeline.md нет строки харнесса риск-скора'
fi
end_case

# ------------------------------------------------------------------
# Последним: полнота. Перечень берётся из конфига, а не из списка здесь.
# ------------------------------------------------------------------
begin_case 'У каждого включённого сигнала конфига есть пара сценариев'
ENABLED_IDS="$(jq -r '.signals[] | select(.enabled == true) | .id' "$CONFIG" | tr -d '\r')"
if [ -z "$ENABLED_IDS" ]; then
    fail_case 'в конфиге нет ни одного включённого сигнала — проверять нечего'
fi
while IFS= read -r id; do
    [ -z "$id" ] && continue
    if ! printf '%s' "$FIRED_IDS" | grep -qxF "$id"; then
        fail_case "у сигнала нет сценария срабатывания: $id"
    fi
    if ! printf '%s' "$SILENT_IDS" | grep -qxF "$id"; then
        fail_case "у сигнала нет сценария молчания: $id"
    fi
done <<< "$ENABLED_IDS"

# Обратная сторона: сценарий на сигнал, которого в конфиге нет, — опечатка.
while IFS= read -r id; do
    [ -z "$id" ] && continue
    if ! printf '%s' "$ENABLED_IDS" | grep -qxF "$id"; then
        fail_case "сценарий ссылается на сигнал, которого нет среди включённых: $id"
    fi
done <<< "$(printf '%s%s' "$FIRED_IDS" "$SILENT_IDS" | sort -u)"
end_case

# ------------------------------------------------------------------
printf '\n'
printf 'Пройдено: %d, провалено: %d, пропущено: 0\n' "$PASSED" "$FAILED"

if [ "$FAILED" -gt 0 ]; then
    printf '\nПровалились:\n'
    for name in "${FAILED_NAMES[@]}"; do
        printf '  - %s\n' "$name"
    done
    exit 1
fi

exit 0
