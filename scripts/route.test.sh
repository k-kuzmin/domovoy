#!/usr/bin/env bash
#
# Домовой — проверочные сценарии маршрута по уровню риска scripts/route.sh.
#
# ЗАЧЕМ
#
# Маршрут — утверждение о том, что задачу проверяют иначе, и проверять его надо
# с двух сторон. Сверка, которую никто не проверял, зеленела бы на сломанной
# политике: пустой список «не сокращается никогда», три дословно одинаковых
# маршрута, потребитель, до которого правило не доехало, — всё это выглядит как
# «нарушений нет». Поэтому у каждого инварианта здесь пара: положительный
# прогон на настоящем дереве и отрицательный на временной политике или
# временном дереве.
#
# МАТЕРИАЛ ДЕРЕВА
#
# Отрицательные сценарии работают не на выдуманных файлах, а на копиях
# настоящих потребителей из политики: перечень берётся из pipeline/route.json
# полем consumers, а не из списка в этом файле. Потребитель, добавленный в
# политику без пары сценариев, попадает под них сам.
#
# Пин один и назван вслух: позиция pr-review-rounds. На ней держится сценарий
# «три уровня — три разных маршрута»: различие пары medium/high обязано
# приходиться на неё, а не на позицию, чьё значение опирается на настройку
# репозитория, которой ещё нет. Исчезла из политики — сценарий провален, а не
# пропущен.
#
# ЧТО ДЕЛАТЬ, ЕСЛИ СЦЕНАРИЙ УПАЛ НА МАТЕРИАЛЕ
#
# Исчезнувший потребитель или переименованная позиция роняют сценарий, а не
# пропускают его — по образцу пинов scripts/plan.test.sh и
# scripts/risk-score.test.sh. Починка — привести политику и потребителей в
# согласие, а не ослабить сценарий: ослабленный доказывает лишь то, что текст
# совпал с текстом, который сам и написал.
#
# КАК ЗАПУСКАТЬ
#
#   bash scripts/route.test.sh
#
# Код возврата: 0 — все сценарии прошли, 1 — есть провалившиеся, 2 — запуск не
# состоялся (нет движка, нет политики, нет jq).
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$SCRIPT_DIR/route.sh"

# Расположение политики по умолчанию — оно же строка, наличие которой движок
# сверяет у потребителей. Харнесс знает её потому, что он харнесс именно этой
# политики, а не потому, что маршрут описан здесь.
CONFIG_REL='pipeline/route.json'
CONFIG="$ROOT/$CONFIG_REL"
WORKFLOW="$ROOT/.github/workflows/ci-fast.yml"

# Пин позиции, на которой обязано приходиться различие medium и high.
PINNED_POSITION='pr-review-rounds'

if [ ! -f "$SCRIPT" ]; then
    printf 'Не найден %s\n' "$SCRIPT" >&2
    exit 2
fi

if [ ! -f "$CONFIG" ]; then
    printf 'Не найдена политика маршрута: %s\n' "$CONFIG" >&2
    exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
    printf 'Не найден jq: сценарии портят политику точечными мутациями через него.\n' >&2
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

TREE=''
TREE_N=0

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

run_route() {
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

# jq под Windows пишет CRLF, и возврат каретки уезжает внутрь значения:
# ожидание сценария перестаёт равняться значению из политики. Тот же tr стоит
# в самом движке и по той же причине.
pjq() {
    jq -r "$@" "$CONFIG" | tr -d '\r'
}

policy_consumers() {
    pjq '.consumers[]'
}

# Точечная мутация политики: портится ровно одно, остальное настоящее.
mutate_policy() {
    local out="$SANDBOX/policy-$RANDOM$RANDOM.json"
    if ! jq "$@" "$CONFIG" > "$out"; then
        printf 'Мутация политики не собралась: %s\n' "$*" >&2
        exit 2
    fi
    printf '%s' "$out"
}

# ------------------------------------------------------------------
# Временное дерево: копии настоящих потребителей и записи решения. Отрицательные
# сценарии портят копию, а не репозиторий.
# ------------------------------------------------------------------
copy_into_tree() {
    local src="$ROOT/$1" dest="$TREE/$1"
    if [ ! -f "$src" ]; then
        fail_case "материал дерева исчез: $1 — сценарий провален, а не пропущен"
        return 1
    fi
    mkdir -p "$(dirname "$dest")"
    cat "$src" > "$dest"
    return 0
}

new_tree() {
    local rel ok=0
    TREE_N=$((TREE_N + 1))
    TREE="$SANDBOX/tree-$TREE_N"
    mkdir -p "$TREE"
    while IFS= read -r rel; do
        [ -z "$rel" ] && continue
        copy_into_tree "$rel" || ok=1
    done < <(pjq '.consumers[], .decision')
    return "$ok"
}

# Первый потребитель, который на политику уже ссылается: сценарии про копии
# значений портят именно его — до проверки копий движок доходит только у того
# потребителя, у кого ссылка есть.
consumer_with_link() {
    local rel
    while IFS= read -r rel; do
        [ -z "$rel" ] && continue
        if grep -qF -- "$CONFIG_REL" "$ROOT/$rel"; then
            printf '%s' "$rel"
            return 0
        fi
    done < <(policy_consumers)
    return 1
}

# Блок «Маршрут:» вывода: сравнивать выводы целиком бесполезно — строка
# «Уровень: …» различает любые два, включая дословно одинаковые маршруты.
route_section() {
    printf '%s\n' "$1" | sed -n '/^Маршрут:/,/^$/p'
}

# Значение позиции из вывода: строка сразу за заголовком позиции.
position_value() {
    printf '%s\n' "$1" | grep -A1 -E "^  \[[^]]+\] $2 — " | tail -n 1
}

# ------------------------------------------------------------------
begin_case 'Материал сценариев на месте: политика, пин позиции и потребители'
if ! jq empty "$CONFIG" >/dev/null 2>&1; then
    fail_case "политика не разбирается как JSON: $CONFIG"
else
    if ! jq -e --arg id "$PINNED_POSITION" \
        '.positions | map(select(.id == $id)) | length == 1' "$CONFIG" >/dev/null; then
        fail_case "пин исчез: позиции $PINNED_POSITION в политике нет — сценарий medium/high проверять нечем"
    fi
    CONSUMER_COUNT=0
    while IFS= read -r rel; do
        [ -z "$rel" ] && continue
        CONSUMER_COUNT=$((CONSUMER_COUNT + 1))
        if [ ! -f "$ROOT/$rel" ]; then
            fail_case "потребителя из политики нет в дереве: $rel"
        fi
    done < <(policy_consumers)
    if [ "$CONSUMER_COUNT" -eq 0 ]; then
        fail_case 'в политике нет ни одного потребителя — сверять правило не с чем'
    fi
    if [ ! -f "$WORKFLOW" ]; then
        fail_case "не найден $WORKFLOW — подключение прогонов проверять нечем"
    fi
fi
end_case

# ------------------------------------------------------------------
begin_case 'Три уровня — три разных маршрута, и различие medium/high несёт пин позиции'
POS_TOTAL="$(pjq '.positions | length')"
ROUTE_OUT_LOW=''
ROUTE_OUT_MEDIUM=''
ROUTE_OUT_HIGH=''
for lvl in low medium high; do
    run_route level "$lvl"
    expect_status 0
    if [ "$(printf '%s\n' "$OUTPUT" | head -n 1)" != "Уровень: $lvl" ]; then
        fail_case "первая строка «$(printf '%s\n' "$OUTPUT" | head -n 1)», ожидалась «Уровень: $lvl»"
    fi
    # Число позиций в выводе берётся из политики, а не из списка здесь.
    SHOWN="$(printf '%s\n' "$OUTPUT" | grep -cE '^  \[[^]]+\] [a-z0-9-]+ — ')"
    if [ "$SHOWN" -ne "$POS_TOTAL" ]; then
        fail_case "на уровне $lvl напечатано позиций $SHOWN, в политике $POS_TOTAL"
    fi
    case "$lvl" in
        low) ROUTE_OUT_LOW="$OUTPUT" ;;
        medium) ROUTE_OUT_MEDIUM="$OUTPUT" ;;
        high) ROUTE_OUT_HIGH="$OUTPUT" ;;
    esac
done

if [ "$(route_section "$ROUTE_OUT_LOW")" = "$(route_section "$ROUTE_OUT_MEDIUM")" ]; then
    fail_case 'маршруты low и medium совпали блоком «Маршрут:» — уровень ничего не меняет'
fi
if [ "$(route_section "$ROUTE_OUT_LOW")" = "$(route_section "$ROUTE_OUT_HIGH")" ]; then
    fail_case 'маршруты low и high совпали блоком «Маршрут:»'
fi
if [ "$(route_section "$ROUTE_OUT_MEDIUM")" = "$(route_section "$ROUTE_OUT_HIGH")" ]; then
    fail_case 'маршруты medium и high совпали блоком «Маршрут:»'
fi

PIN_MEDIUM="$(position_value "$ROUTE_OUT_MEDIUM" "$PINNED_POSITION")"
PIN_HIGH="$(position_value "$ROUTE_OUT_HIGH" "$PINNED_POSITION")"
if [ -z "$PIN_MEDIUM" ] || [ -z "$PIN_HIGH" ]; then
    fail_case "значение позиции $PINNED_POSITION не напечатано ни на medium, ни на high"
elif [ "$PIN_MEDIUM" = "$PIN_HIGH" ]; then
    fail_case "медиум и хай различаются не на $PINNED_POSITION: политика, где эти уровни расходятся только инертной позицией, сценарий не проходит"
fi
end_case

# ------------------------------------------------------------------
begin_case 'Равные маршруты двух уровней краснеют на сверке'
MUT_EQUAL="$(mutate_policy '.positions |= map(.levels.low.value = .levels.medium.value)')"
run_route check --config "$MUT_EQUAL"
expect_status 1
expect_output 'маршруты уровней low и medium не различаются ни одной позицией'
end_case

# ------------------------------------------------------------------
begin_case 'Незнакомый уровень маршрута не получает'
run_route level lowish
expect_status 2
expect_output 'Незнакомый уровень: lowish'
expect_output 'Использование:'
expect_no_output 'Маршрут:'

run_route level
expect_status 2
expect_output 'Использование:'
expect_no_output 'Маршрут:'

run_route
expect_status 2
expect_output 'Использование:'

run_route маршрут
expect_status 2
expect_output 'Незнакомая подкоманда'
end_case

# ------------------------------------------------------------------
begin_case 'Маршрут меняется вместе с политикой, а не с кодом'
INVENTED='выдуманное значение временной политики, которого в дереве нет нигде'
MUT_VALUE="$(mutate_policy --arg v "$INVENTED" '.positions[0].levels.low.value = $v')"
run_route level low --config "$MUT_VALUE"
expect_status 0
expect_output "$INVENTED"
# Настоящее значение той же позиции на том же уровне из вывода исчезло: маршрут
# пришёл из политики, а не из движка.
REAL_VALUE="$(pjq '.positions[0].levels.low.value')"
expect_no_output "$REAL_VALUE"

MUT_NO_POSITIONS="$(mutate_policy '.positions = []')"
run_route level low --config "$MUT_NO_POSITIONS"
expect_status 2
expect_output 'ни одной позиции маршрута'
expect_no_output 'Уровень: low'
end_case

# ------------------------------------------------------------------
begin_case 'Сломанная политика роняет движок, а не выдаёт маршрут'
FIRST_ID="$(pjq '.positions[0].id')"

BROKEN="$SANDBOX/broken.json"
printf '{ "positions": [ ' > "$BROKEN"
run_route level low --config "$BROKEN"
expect_status 2
expect_output 'не разбирается как JSON'
expect_no_output 'Уровень: low'

run_route level low --config "$SANDBOX/нет-такой-политики.json"
expect_status 2
expect_no_output 'Уровень:'

MUT_NO_MEDIUM="$(mutate_policy '.positions[0].levels |= del(.medium)')"
run_route level low --config "$MUT_NO_MEDIUM"
expect_status 2
expect_output "позиция $FIRST_ID"
expect_output 'не совпадают с low|medium|high'
expect_no_output 'Уровень: low'

MUT_EXTRA_LEVEL="$(mutate_policy \
    '.positions[0].levels.lowish = {"value": "лишний уровень сверх трёх", "reduced": false}')"
run_route level low --config "$MUT_EXTRA_LEVEL"
expect_status 2
expect_output "позиция $FIRST_ID"
expect_no_output 'Уровень: low'

MUT_EMPTY_VALUE="$(mutate_policy '.positions[0].levels.medium.value = ""')"
run_route level low --config "$MUT_EMPTY_VALUE"
expect_status 2
expect_output 'пустое или нестроковое value'
expect_output "позиция $FIRST_ID"
expect_no_output 'Уровень: low'

MUT_STRING_REDUCED="$(mutate_policy '.positions[0].levels.low.reduced = "true"')"
run_route level low --config "$MUT_STRING_REDUCED"
expect_status 2
expect_output 'reduced должно быть true или false'
expect_no_output 'Уровень: low'

MUT_NO_REDUCED="$(mutate_policy 'del(.positions[0].levels.low.reduced)')"
run_route level low --config "$MUT_NO_REDUCED"
expect_status 2
expect_output 'reduced должно быть true или false'
expect_no_output 'Уровень: low'

MUT_NO_CONSUMERS="$(mutate_policy '.consumers = []')"
run_route check --config "$MUT_NO_CONSUMERS"
expect_status 2
expect_output 'список consumers пуст'

MUT_NO_DECISION="$(mutate_policy 'del(.decision)')"
run_route level low --config "$MUT_NO_DECISION"
expect_status 2
expect_output 'нет обязательного поля decision'
expect_no_output 'Уровень: low'
end_case

# ------------------------------------------------------------------
begin_case 'Низкий уровень называет сокращения поимённо'
run_route level low
expect_status 0
expect_output 'Сокращено на уровне low:'
expect_no_output 'ни одной позиции'

REDUCED_EXPECTED="$(pjq '.positions[] | select(.levels.low.reduced == true) | .id')"
if [ -z "$REDUCED_EXPECTED" ]; then
    fail_case 'в политике нет ни одной сокращённой позиции на low — называть нечего'
fi
while IFS= read -r id; do
    [ -z "$id" ] && continue
    expect_output "  - $id"
done <<< "$REDUCED_EXPECTED"

# Список «не сокращается никогда» — теми же пунктами, что в политике, и непустой.
NEVER_COUNT=0
while IFS= read -r item; do
    [ -z "$item" ] && continue
    NEVER_COUNT=$((NEVER_COUNT + 1))
    expect_output "$item"
done < <(pjq '.never_reduced[]')
if [ "$NEVER_COUNT" -eq 0 ]; then
    fail_case 'список «не сокращается никогда» в политике пуст'
fi
expect_output 'Не сокращается никогда:'
expect_output 'Советник (фаза 4) не введён'
end_case

# ------------------------------------------------------------------
begin_case 'Пустой список «не сокращается никогда» краснеет'
MUT_NO_NEVER="$(mutate_policy '.never_reduced = []')"
run_route check --config "$MUT_NO_NEVER"
expect_status 1
expect_output 'список never_reduced пуст'

MUT_NOTHING_REDUCED="$(mutate_policy '.positions |= map(.levels.low.reduced = false)')"
run_route check --config "$MUT_NOTHING_REDUCED"
expect_status 1
expect_output 'на низком уровне не сокращается ни одна позиция'
end_case

# ------------------------------------------------------------------
begin_case 'Запись решения из политики существует'
if new_tree; then
    MUT_DECISION="$(mutate_policy \
        '.decision = "docs/decisions/9999-записи-с-таким-номером-нет.md"')"
    run_route check --repo "$TREE" --config "$MUT_DECISION"
    expect_status 1
    expect_output 'запись решения из поля decision не найдена в дереве'
    expect_output '9999-записи-с-таким-номером-нет.md'
fi
end_case

# ------------------------------------------------------------------
begin_case 'Потребитель без ссылки на политику краснеет'
CUT_CASES=0
while IFS= read -r consumer; do
    [ -z "$consumer" ] && continue
    grep -qF -- "$CONFIG_REL" "$ROOT/$consumer" || continue
    new_tree || break
    # Ссылка вырезается из копии: остальной текст потребителя настоящий.
    grep -vF -- "$CONFIG_REL" "$ROOT/$consumer" > "$TREE/$consumer"
    if grep -qF -- "$CONFIG_REL" "$TREE/$consumer"; then
        fail_case "ссылка осталась в копии $consumer — сценарий ничего не проверяет"
        continue
    fi
    CUT_CASES=$((CUT_CASES + 1))
    run_route check --repo "$TREE"
    expect_status 1
    expect_output 'нет ссылки на политику маршрута'
    expect_output "$consumer"
done < <(policy_consumers)
if [ "$CUT_CASES" -eq 0 ]; then
    fail_case 'ни один потребитель политики на неё не ссылается: вырезать нечего, и сверка ничего не держит'
fi
end_case

# ------------------------------------------------------------------
begin_case 'Потребитель из политики отсутствует в дереве'
if new_tree; then
    MUT_TYPO="$(mutate_policy \
        '.consumers += ["docs/rules/потребителя-с-таким-именем-нет.md"]')"
    run_route check --repo "$TREE" --config "$MUT_TYPO"
    expect_status 1
    expect_output 'потребителя из политики нет в дереве'
    expect_output 'потребителя-с-таким-именем-нет.md'
fi
end_case

# ------------------------------------------------------------------
begin_case 'Дословная копия значения позиции у потребителя краснеет'
LINKED="$(consumer_with_link)" || LINKED=''
if [ -z "$LINKED" ]; then
    fail_case 'ни один потребитель не ссылается на политику: до сверки копий движок не доходит'
elif new_tree; then
    COPIED="$(pjq '.positions[0].levels.high.value')"
    # Перенос по ширине в предельной форме: каждое слово на своей строке.
    # Сверка нормализует пробелы, поэтому вёрстка её не обманывает.
    printf '\n' >> "$TREE/$LINKED"
    printf '%s\n' "$COPIED" | tr ' ' '\n' >> "$TREE/$LINKED"
    run_route check --repo "$TREE"
    expect_status 1
    expect_output 'дословное значение позиции'
    expect_output "$LINKED"

    # Значение короче порога в сверку копий не попадает и печатается списком.
    SHORT='значение короче порога'
    MUT_SHORT="$(mutate_policy --arg v "$SHORT" '.positions[0].levels.high.value = $v')"
    new_tree
    printf '\n%s\n' "$SHORT" >> "$TREE/$LINKED"
    run_route check --repo "$TREE" --config "$MUT_SHORT"
    expect_output 'В сверку копий не попали значения короче'
    expect_output "$SHORT"
    expect_no_output 'дословное значение позиции'
fi
end_case

# ------------------------------------------------------------------
begin_case 'Движок не содержит знания о маршруте'
# Перечень берётся из политики, а не из списка здесь: позиция, значение или
# потребитель, переехавший в код движка, роняет сценарий сам.
while IFS= read -r token; do
    [ -z "$token" ] && continue
    if grep -qF -- "$token" "$SCRIPT"; then
        fail_case "знание из политики лежит в движке: «$token»"
    fi
done < <(pjq '.positions[].id, .positions[].levels[].value, .consumers[], .decision, .applied_by')
end_case

# ------------------------------------------------------------------
begin_case 'Оба прогона маршрута подключены к работе «Проверки обвязки»'
# Вызов ищется строкой шага, а не подстрокой файла: закомментированный шаг
# остаётся в тексте дословно, и поиск подстрокой считал бы его подключённым.
# Префикс run: необязателен — блочная форма (run: | и вызов строкой ниже)
# подключена ровно так же. Обязательно другое: до вызова в строке нет ничего,
# кроме пробелов, то есть строка не комментарий и не рассказ о вызове.
workflow_runs_call() {
    local call="$1" file="$2" esc
    esc="${call//./\\.}"
    grep -qE "^[[:space:]]*(run:[[:space:]]+)?${esc}([[:space:]]|\$)" "$file"
}

for call in 'bash scripts/route.sh check' 'bash scripts/route.test.sh'; do
    if ! workflow_runs_call "$call" "$WORKFLOW"; then
        fail_case "в .github/workflows/ci-fast.yml нет шага, запускающего: $call"
    fi
done

# Та же проверка на копии, где шаг харнесса закомментирован на месте. Копия с
# вырезанной строкой была бы тавтологией — не находилось бы то, что сценарий сам
# и удалил; закомментированный шаг отличает подключённый вызов от текста о нём.
CUT_WORKFLOW="$SANDBOX/ci-fast-с-закомментированным-харнессом.yml"
sed 's|^\([[:space:]]*\)\(run:[[:space:]]*bash scripts/route\.test\.sh\)|\1# \2|' \
    "$WORKFLOW" > "$CUT_WORKFLOW"
if cmp -s "$WORKFLOW" "$CUT_WORKFLOW"; then
    fail_case 'мутация не состоялась: копия совпала с исходником, комментировать оказалось нечего'
elif workflow_runs_call 'bash scripts/route.test.sh' "$CUT_WORKFLOW"; then
    fail_case 'закомментированный шаг сошёл за подключённый — проверка не отличает вызов от текста о вызове'
fi

# И сверка обвязки не считает ни движок, ни харнесс неподключёнными.
OUTPUT="$(bash "$SCRIPT_DIR/wiring.sh" "$ROOT" 2>&1)"
STATUS=$?
expect_status 0
expect_no_output 'ни один workflow не вызывает: scripts/route.sh'
expect_no_output 'ни один workflow не вызывает: scripts/route.test.sh'
expect_no_output 'освобождён: scripts/route.sh'
expect_no_output 'освобождён: scripts/route.test.sh'
end_case

# ------------------------------------------------------------------
# Последним: положительный прогон на настоящем дереве. Проверка, красная
# всегда, столь же бесполезна, как зелёная всегда.
# ------------------------------------------------------------------
begin_case 'Сверка маршрута сходится на настоящем дереве'
run_route check
expect_status 0
expect_output 'Маршрут сходится:'
expect_output 'Применяет:'
expect_output 'Запись решения на месте:'
while IFS= read -r consumer; do
    [ -z "$consumer" ] && continue
    expect_output "Потребитель сходится: $consumer"
done < <(policy_consumers)
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
