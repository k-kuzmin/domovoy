#!/usr/bin/env bash
#
# Домовой — проверочные сценарии для валидатора плана scripts/plan.sh.
#
# ЗАЧЕМ
#
# Валидатор, который только зеленеет, ничего не доказывает: он зеленел бы и
# при пустом теле каждой проверки. Здесь для каждого класса нарушений берётся
# один согласованный план и портится ровно одной точечной мутацией — в
# сценарии видно именно нарушаемое, а не собранный заново «плохой план», в
# котором неверно всё сразу.
#
# Отдельно проверяются три вещи, которые классами не покрываются:
#
#   1. на согласованном плане валидатор молчит — проверка, шумящая на
#      нормальной работе, перестаёт читаться;
#   2. согласованная фикстура полна по схеме, иначе инвариант рендера
#      проверялся бы на неполном плане;
#   3. каждое строковое значение фикстуры доезжает до рендера — поле,
#      добавленное в схему без ветки рендера, иначе исчезало бы из
#      опубликованного плана молча.
#
# ИСТОРИЧЕСКИЕ ПЛАНЫ
#
# Три реальных плана из истории задач лежат в scripts/fixtures/plans и
# проверяются против того дерева, для которого писались (--at). Это половина
# критерия «ни одного ложного срабатывания»: класс нарушений можно поймать
# сколь угодно строгой проверкой, и цена строгости видна только на планах,
# которые человек уже одобрил.
#
# Пин, который не разрешается, роняет сценарий, а не пропускает его. Молча
# пропущенная проверка на ложные срабатывания — та самая видимость проверки,
# против которой написан каждый скрипт в scripts/.
#
# КАК ЗАПУСКАТЬ
#
#   bash scripts/plan.test.sh
#
# Код возврата: 0 — все сценарии прошли, 1 — есть провалившиеся.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CHECK="$SCRIPT_DIR/plan.sh"
SCHEMA="$SCRIPT_DIR/plan-schema.json"
FIXTURES="$SCRIPT_DIR/fixtures/plans"
RULES="$ROOT/docs/rules/plan.md"

if [ ! -f "$CHECK" ]; then
    printf 'Не найден %s\n' "$CHECK" >&2
    exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
    printf 'Не найден jq: сценарии собирают планы мутациями через него.\n' >&2
    exit 2
fi

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

PASSED=0
FAILED=0
FAILED_NAMES=()

CASE_NAME=''
CASE_OK=1
OUTPUT=''
STATUS=0

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

run_validate() {
    OUTPUT="$(bash "$CHECK" validate "$@" 2>&1)"
    STATUS=$?
}

run_render() {
    OUTPUT="$(bash "$CHECK" render "$@" 2>&1)"
    STATUS=$?
}

expect_status() {
    if [ "$STATUS" -ne "$1" ]; then
        fail_case "код возврата $STATUS, ожидался $1"
    fi
}

expect_output() {
    # Ключ -- обязателен: искомое может начинаться с дефиса.
    if ! printf '%s' "$OUTPUT" | grep -qF -- "$1"; then
        fail_case "в выводе нет: $1"
    fi
}

expect_no_violations() {
    if printf '%s' "$OUTPUT" | grep -qF 'нарушение:'; then
        fail_case 'в выводе есть сообщения о нарушениях, а не должно быть ни одного'
    fi
}

# ------------------------------------------------------------------
# Согласованный план. Собирается один раз и полон по схеме: сценарий
# «Полнота согласованной фикстуры» это проверяет, а не принимает на веру.
#
# Пути в нём настоящие, потому что валидатор смотрит на дерево: выдуманный
# путь сделал бы сценарий «согласованный план молчит» проверкой того, что
# проверка не работает.
# ------------------------------------------------------------------
CANON="$SANDBOX/canonical.json"

cat > "$CANON" <<'PLAN'
{
  "issue": 4242,
  "current_state": [
    {
      "path": "scripts/wiring.sh",
      "line": 16,
      "observation": "сверка обвязки требует, чтобы каждый scripts/*.sh вызывался хотя бы одним workflow либо был освобождён маркером с причиной"
    },
    {
      "path": "docs/rules/plan.md",
      "line": 13,
      "observation": "разделов плана семь, и их порядок задан здесь"
    }
  ],
  "approach": {
    "summary": "Освобождение от обвязки перестаёт быть строкой в шапке и становится записью с причиной и сроком: сверка читает обе части, а не только длину причины.",
    "rejected": [
      {
        "option": "отдельный файл со списком освобождений",
        "reason": "второе описание того же множества, разъедется с шапками молча"
      }
    ]
  },
  "files": [
    {
      "path": "scripts/wiring.sh",
      "action": "modify",
      "owner": "implement",
      "protected": true,
      "why": "разбор маркера освобождения: причина и срок вместо одной причины"
    },
    {
      "path": "docs/rules/plan.md",
      "action": "modify",
      "owner": "implement",
      "protected": true,
      "why": "план называет срок освобождения там же, где перечисляет файлы"
    },
    {
      "path": ".claude/agents/step-plan.md",
      "action": "modify",
      "owner": "orchestrator",
      "protected": true,
      "why": "шагу планирования нужна новая команда в списке хука"
    },
    {
      "path": "docs/tasks/4242.md",
      "action": "create",
      "owner": "implement",
      "protected": false,
      "why": "журнал задачи"
    }
  ],
  "boundaries": [
    "scripts/**",
    "docs/rules/**",
    ".claude/agents/**",
    "docs/tasks/**"
  ],
  "flags": {
    "allow_protected": true,
    "allow_contract": false,
    "destructive_migration": false,
    "new_dependency": false,
    "new_dependency_reason": ""
  },
  "tests": [
    {
      "name": "освобождение без срока не проходит сверку",
      "file": "scripts/wiring.test.sh",
      "new": true,
      "covers": ["marker-reason"],
      "behavior": "маркер с причиной, но без срока даёт код 1 и называет файл"
    },
    {
      "name": "просроченное освобождение названо вслух",
      "file": "scripts/wiring.test.sh",
      "new": true,
      "covers": ["marker-expiry"],
      "behavior": "срок в прошлом даёт код 1 и печатает дату"
    }
  ],
  "acceptance": [
    {
      "id": "marker-reason",
      "criterion": "Маркер освобождения без причины заворачивается",
      "method": "bash scripts/wiring.test.sh",
      "evidence": "сценарий «освобождение без срока не проходит сверку» проходит, итог «провалено 0»"
    },
    {
      "id": "marker-expiry",
      "criterion": "Просроченное освобождение заворачивается",
      "method": "bash scripts/wiring.sh",
      "evidence": "код возврата 1 и дата в выводе"
    },
    {
      "id": "loop-half",
      "criterion": "То же поведение в агентском цикле",
      "method": "непроверяем",
      "evidence": "цикл выключен переменной AGENT_LOOP_ENABLED, живого прогона нет; расхождение записывается в журнал"
    }
  ],
  "risks": [
    {
      "risk": "Срок освобождения превращается в способ отложить работу навсегда.",
      "mitigation": "просроченный срок краснеет так же, как отсутствующая причина"
    }
  ],
  "out_of_scope": [
    "перенос существующих освобождений на новую форму разом",
    "проверка того, что причина освобождения правдива"
  ]
}
PLAN

MUTATION_INDEX=0

# Портит согласованный план одной программой jq и печатает путь к копии.
mutate() {
    MUTATION_INDEX=$((MUTATION_INDEX + 1))
    local out="$SANDBOX/mutation-$MUTATION_INDEX.json"
    jq "$1" "$CANON" > "$out" || return 1
    printf '%s' "$out"
}

# ------------------------------------------------------------------
begin_case 'Согласованный план: валидатор молчит'
run_validate "$CANON"
expect_status 0
expect_no_violations
expect_output 'План сходится'
end_case

# ------------------------------------------------------------------
begin_case 'Класс 1: путь на правку не существует'
run_validate "$(mutate '.files[0].path = "scripts/wiring-which-never-was.sh"')"
expect_status 1
expect_output 'путь на modify не существует: scripts/wiring-which-never-was.sh'
end_case

# ------------------------------------------------------------------
begin_case 'Класс 2: путь вне границ задачи'
run_validate "$(mutate '.files[0].path = "src/Domovoy.Api/Program.cs" | .files[0].protected = false')"
expect_status 1
expect_output 'путь вне границ задачи: src/Domovoy.Api/Program.cs'
expect_output 'scripts/**'
end_case

# ------------------------------------------------------------------
begin_case 'Класс 3: защищённая зона оформлена неверно, два подслучая'
run_validate "$(mutate '.files[0].protected = false | .files[2].owner = "implement"')"
expect_status 1
expect_output 'защищённый путь без отметки protected: scripts/wiring.sh'
expect_output 'конфигурация прав шага с owner=implement: .claude/agents/step-plan.md'
end_case

# ------------------------------------------------------------------
begin_case 'Класс 4: пункт приёмки без покрывающего теста'
run_validate "$(mutate '.tests[0].covers = ["marker-expiry"]')"
expect_status 1
expect_output 'пункт приёмки «marker-reason» не покрыт ни одним тестом'
end_case

# ------------------------------------------------------------------
begin_case 'Класс 5: существующий тест выдан за новый'
run_validate "$(mutate '.tests[0].name = "MobileLayeringTests"')"
expect_status 1
expect_output 'тест объявлен новым, но имя уже встречается: MobileLayeringTests'
expect_output 'tests/Domovoy.Tests/MobileLayeringTests.cs'
end_case

# ------------------------------------------------------------------
begin_case 'Класс 6: флаги не согласованы с путями, в обе стороны'
run_validate "$(mutate '
    .boundaries += ["src/Domovoy.Data/Migrations/**"]
    | .files += [{
        "path": "src/Domovoy.Data/Migrations/20240101120000_Init.cs",
        "action": "create",
        "owner": "implement",
        "protected": true,
        "why": "первая миграция"
      }]
    | .flags.allow_contract = true')"
expect_status 1
expect_output 'флаг destructive_migration не заявлен, а в плане есть путь под миграциями'
expect_output 'флаг allow_contract заявлен, но ни один путь плана под него не подпадает'
end_case

# ------------------------------------------------------------------
begin_case 'Класс 7: пустая ячейка против «непроверяем»'
run_validate "$(mutate '.acceptance[1].method = ""')"
expect_status 1
expect_output 'пункт приёмки «marker-expiry» без способа проверки'

run_validate "$(mutate '.acceptance[2].evidence = ""')"
expect_status 1
expect_output 'пункт приёмки «loop-half» помечен «непроверяем» без причины'

# Третий подслучай — тот же пункт с причиной. Он в согласованном плане уже
# есть, и проверяется здесь не код возврата, а то, что причина доезжает до
# рендера: непроверяемый пункт, потерявший причину при публикации, ничем не
# отличается от забытого.
run_render "$CANON"
expect_status 0
expect_output 'непроверяем'
expect_output 'цикл выключен переменной AGENT_LOOP_ENABLED'
end_case

# ------------------------------------------------------------------
begin_case 'Форма: обязательное поле схемы отсутствует'
run_validate "$(mutate 'del(.risks)')"
expect_status 1
expect_output 'план.risks: обязательное поле схемы отсутствует'
expect_output 'содержательные проверки не запускались'
end_case

# ------------------------------------------------------------------
begin_case 'Форма: поле не описано схемой'
run_validate "$(mutate '.estimate = "три дня"')"
expect_status 1
expect_output 'план.estimate: поле не описано схемой'
end_case

# ------------------------------------------------------------------
begin_case 'Форма: значение вне enum схемы'
run_validate "$(mutate '.files[0].owner = "human"')"
expect_status 1
expect_output 'вне enum схемы'
end_case

# ------------------------------------------------------------------
begin_case 'Полнота согласованной фикстуры: каждое поле схемы заполнено'
while IFS= read -r key; do
    [ -z "$key" ] && continue
    if ! jq -e --arg k "$key" 'has($k)' "$CANON" >/dev/null 2>&1; then
        fail_case "в согласованной фикстуре нет поля схемы: $key"
    fi
done < <(jq -r '.properties | keys_unsorted[]' "$SCHEMA" | tr -d '\r')
end_case

# ------------------------------------------------------------------
begin_case 'Инвариант рендера: каждое строковое значение доезжает до вывода'
run_render "$CANON"
expect_status 0
while IFS= read -r value; do
    [ -z "$value" ] && continue
    if ! printf '%s' "$OUTPUT" | grep -qF -- "$value"; then
        fail_case "в рендере нет значения из плана: $value"
    fi
done < <(jq -r '[.. | strings] | .[]' "$CANON" | tr -d '\r')
end_case

# ------------------------------------------------------------------
begin_case 'Порядок разделов рендера: заголовки взяты из docs/rules/plan.md'
run_render "$CANON"
expect_status 0
EXPECTED_HEADINGS="$(grep -oE '^[0-9]+\. \*\*[^*]+\*\*' "$RULES" \
    | sed -E 's/^([0-9]+)\. \*\*(.+)\.\*\*$/## \1. \2/')"
ACTUAL_HEADINGS="$(printf '%s\n' "$OUTPUT" | grep '^## ')"
if [ "$EXPECTED_HEADINGS" != "$ACTUAL_HEADINGS" ]; then
    fail_case 'заголовки рендера разошлись с разделами docs/rules/plan.md'
    printf '        ожидалось:\n%s\n' "$EXPECTED_HEADINGS" | sed 's/^/        /'
fi
HEADING_COUNT="$(printf '%s\n' "$ACTUAL_HEADINGS" | grep -c '^## ')"
if [ "$HEADING_COUNT" -ne 7 ]; then
    fail_case "разделов в рендере $HEADING_COUNT, а не семь"
fi
end_case

# ------------------------------------------------------------------
begin_case 'Предупреждение о размере плана не меняет код возврата'
run_validate "$(mutate '.files as $f | .files = [range(0; 20) | $f[0]]')"
expect_status 0
expect_output 'предупреждение: файлов в плане 20'
expect_no_violations
end_case

# ------------------------------------------------------------------
begin_case 'Новая зависимость: без обоснования отказ, с обоснованием проход'
run_validate "$(mutate '.flags.new_dependency = true')"
expect_status 1
expect_output 'новая зависимость без обоснования'

run_validate "$(mutate '
    .flags.new_dependency = true
    | .flags.new_dependency_reason = "нужна библиотека разбора cron, своего планировщика не пишем"')"
expect_status 1
expect_output 'новая зависимость без ссылки на комментарий issue'

run_validate "$(mutate '
    .flags.new_dependency = true
    | .flags.new_dependency_reason = "разбор cron, обоснование в комментарии #4242"')"
expect_status 0
expect_no_violations
end_case

# ------------------------------------------------------------------
# Исторические планы. Пин — база PR, которым задача уехала в main: то самое
# дерево, для которого план писался.
# ------------------------------------------------------------------
PIN_93='f2ae89b8c31acdce57c5a4a65654a9bbe0e7d893'
PIN_83='314016dab8d938fc3c4f2bdf606e3777bbe0a1ea'
PIN_81='314016dab8d938fc3c4f2bdf606e3777bbe0a1ea'

begin_case 'Пины исторических планов разрешаются'
for pin in "$PIN_93" "$PIN_83" "$PIN_81"; do
    if ! git -C "$ROOT" rev-parse --verify --quiet "$pin^{commit}" >/dev/null 2>&1; then
        fail_case "пин не разрешается: $pin — сценарий провален, а не пропущен"
    fi
done
end_case

check_historical() {
    local number="$1" pin="$2"
    local fixture="$FIXTURES/$number.json"

    begin_case "Исторический план #$number при --at: ни одного ложного срабатывания"
    if [ ! -f "$fixture" ]; then
        fail_case "нет фикстуры: $fixture"
        end_case
        return
    fi
    run_validate "$fixture" --at "$pin"
    expect_status 0
    expect_no_violations
    end_case
}

check_historical 93 "$PIN_93"
check_historical 83 "$PIN_83"
check_historical 81 "$PIN_81"

# ------------------------------------------------------------------
begin_case 'Без --at исторический план краснеет: флаг существует не для красоты'
# План #83 объявляет новыми ровно те сценарии, которые с тех пор появились в
# дереве. Против своего ref он зелёный, против сегодняшнего — красный, и это
# не строгость валидатора, а разница деревьев. Без этого сценария отличить
# одно от другого было бы нечем.
if [ ! -f "$FIXTURES/83.json" ]; then
    fail_case "нет фикстуры: $FIXTURES/83.json"
else
    run_validate "$FIXTURES/83.json"
    expect_status 1
    expect_output 'тест объявлен новым, но имя уже встречается'
fi
end_case

# ------------------------------------------------------------------
begin_case 'Неразрешимый ref роняет проверку, а не пропускает её'
run_validate "$CANON" --at '0000000000000000000000000000000000000000'
expect_status 2
expect_output 'Ref не разрешается'
end_case

# ------------------------------------------------------------------
begin_case 'Рендер отказывается печатать план, не разбирающийся как JSON'
printf 'это не json\n' > "$SANDBOX/broken.json"
run_render "$SANDBOX/broken.json"
expect_status 2
expect_output 'не разбирается как JSON'
end_case

# ------------------------------------------------------------------
printf '\n'
if [ "$FAILED" -gt 0 ]; then
    printf 'Провалившиеся сценарии:\n'
    for name in "${FAILED_NAMES[@]}"; do
        printf '  - %s\n' "$name"
    done
    printf '\n'
fi
printf 'Пройдено: %d, провалено: %d, пропущено: 0\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ] || exit 1
exit 0
