#!/usr/bin/env bash
#
# Домовой — проверочные сценарии статуса доски.
#
# ЗАЧЕМ
#
# `scripts/board.sh` оркестратор зовёт в трёх точках процесса
# (`.claude/CLAUDE.md`), и ошибка в нём тихая: статус, поставленный не той
# опцией или не на ту карточку, выглядит на доске правдоподобно, а код 0 при
# несовпадении прочитанного статуса значит, что доска врёт, а журнал молчит.
#
# В СЕТЬ ЭТИ СЦЕНАРИИ НЕ ХОДЯТ
#
# `gh` подставной (по образцу `scripts/merge-wait.test.sh`): короткий скрипт в
# начале `PATH`. Вид вызова он узнаёт по тексту аргументов (запрос доски,
# `issue view`, добавление карточки, установка поля, чтение статуса) и отдаёт
# заготовленный ответ — уже в том виде, в каком его отдал бы `--jq`. Каждый
# вызов пишется строкой в журнал: аргументы в квадратных скобках, переводы
# строк запроса заменены пробелами. По журналу проверяется порядок и число
# вызовов, то, что id взяты из ответов, и то, что на негодном вызове `gh` не
# зовётся вовсе.
#
# ЧЕГО ЭТИ СЦЕНАРИИ НЕ ЛОВЯТ
#
# Подставной `gh` не исполняет выражения `--jq` и запросы GraphQL: их
# совпадение с живым API проверяется только прогоном на настоящей карточке.
# Что оркестратор позовёт сценарий в нужной точке — правило
# `.claude/CLAUDE.md`, а не механика.
#
# КАК ЗАПУСКАТЬ
#
#   bash scripts/board.test.sh
#
# Код возврата: 0 — все сценарии прошли, 1 — есть провалившиеся,
# 2 — запустить нечем.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$SCRIPT_DIR/board.sh"

if [ ! -f "$TARGET" ]; then
    printf 'Не найден %s\n' "$TARGET" >&2
    exit 2
fi

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

PASSED=0
FAILED=0
FAILED_NAMES=()

CASE_NAME=''
CASE_OK=1
OUT=''
ERR=''
STATUS=0

begin_case() {
    CASE_NAME="$1"
    CASE_OK=1
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
        printf '        stdout:\n%s\n' "$OUT" | sed 's/^/        /'
        printf '        stderr:\n%s\n' "$ERR" | sed 's/^/        /'
        printf '        вызовы gh:\n%s\n' "$(cat "$CALLS")" | sed 's/^/        /'
    fi
}

# ------------------------------------------------------------------
# Подставной `gh`.
#
# Вид вызова — по тексту аргументов:
#   board  — запрос доски (`repositoryOwner`), ответ — файл FAKE_BOARD_FILE;
#   issue  — `issue view`, ответ — FAKE_ISSUE_ID;
#   add    — `addProjectV2ItemById`, ответ — FAKE_ITEM_ID;
#   update — `updateProjectV2ItemFieldValue`, ответ — FAKE_ITEM_ID;
#   read   — `fieldValueByName`, ответ — FAKE_READ.
# FAKE_GH_FAIL_ON — вид вызова, который падает с кодом FAKE_GH_FAIL_CODE и
# пустым stdout. FAKE_CRLF=1 — каждая строка ответа оканчивается на \r\n, как
# бывает у gh в Git Bash на Windows.
# ------------------------------------------------------------------
BIN="$SANDBOX/bin"
mkdir -p "$BIN"

CALLS="$SANDBOX/gh-calls.txt"
: > "$CALLS"

cat > "$BIN/gh" <<'FAKE'
#!/usr/bin/env bash
# Подставной gh для сценариев: в сеть не ходит.
line=''
for a in "$@"; do
    line="$line[$(printf '%s' "$a" | tr '\n\r' '  ')]"
done
printf '%s\n' "$line" >> "$FAKE_GH_CALLS"

case "$line" in
    *repositoryOwner*) kind=board ;;
    '[issue][view]'*) kind=issue ;;
    *addProjectV2ItemById*) kind=add ;;
    *updateProjectV2ItemFieldValue*) kind=update ;;
    *fieldValueByName*) kind=read ;;
    *) printf 'подставной gh: незнакомый вызов %s\n' "$line" >&2; exit 99 ;;
esac

if [ "$kind" = "${FAKE_GH_FAIL_ON:-}" ]; then
    printf 'подставной gh: сбой\n' >&2
    exit "${FAKE_GH_FAIL_CODE:-1}"
fi

emit() {
    if [ "${FAKE_CRLF:-0}" = 1 ]; then
        sed 's/$/\r/'
    else
        cat
    fi
}

case "$kind" in
    board) emit < "$FAKE_BOARD_FILE" ;;
    issue) printf '%s\n' "$FAKE_ISSUE_ID" | emit ;;
    add|update) printf '%s\n' "$FAKE_ITEM_ID" | emit ;;
    read) printf '%s\n' "$FAKE_READ" | emit ;;
esac
FAKE
chmod +x "$BIN/gh"

TAB="$(printf '\t')"

# Доска по умолчанию: id доски, id поля, затем опции «id<TAB>имя» — так их
# отдаёт выражение --jq сценария.
BOARD_FULL="$SANDBOX/board-full.txt"
{
    printf 'proj-1\n'
    printf 'fld-status\n'
    printf 'opt-b%sBacklog\n' "$TAB"
    printf 'opt-r%sReady\n' "$TAB"
    printf 'opt-ip%sIn progress\n' "$TAB"
    printf 'opt-rv%sReview\n' "$TAB"
    printf 'opt-d%sDone\n' "$TAB"
} > "$BOARD_FULL"

BOARD_NO_PROJECT="$SANDBOX/board-no-project.txt"
printf '\n\n' > "$BOARD_NO_PROJECT"

BOARD_NO_FIELD="$SANDBOX/board-no-field.txt"
printf 'proj-1\n\n' > "$BOARD_NO_FIELD"

# Прогон проверяемого сценария. Настройка подставного gh — переменными
# окружения вызывающего: FAKE_BOARD_FILE, FAKE_ISSUE_ID, FAKE_ITEM_ID,
# FAKE_READ, FAKE_GH_FAIL_ON, FAKE_GH_FAIL_CODE, FAKE_CRLF, TEST_BOARD_NUMBER.
run_script() {
    : > "$CALLS"
    env "PATH=$BIN:$PATH" \
        "BOARD_OWNER=owner-x" \
        "BOARD_NUMBER=${TEST_BOARD_NUMBER:-7}" \
        "FAKE_GH_CALLS=$CALLS" \
        "FAKE_BOARD_FILE=${FAKE_BOARD_FILE:-$BOARD_FULL}" \
        "FAKE_ISSUE_ID=${FAKE_ISSUE_ID-I_issue159}" \
        "FAKE_ITEM_ID=${FAKE_ITEM_ID-ITEM_159}" \
        "FAKE_READ=${FAKE_READ-}" \
        "FAKE_GH_FAIL_ON=${FAKE_GH_FAIL_ON:-}" \
        "FAKE_GH_FAIL_CODE=${FAKE_GH_FAIL_CODE:-1}" \
        "FAKE_CRLF=${FAKE_CRLF:-0}" \
        timeout 20 "$BASH" "$TARGET" "$@" > "$SANDBOX/out.txt" 2> "$SANDBOX/err.txt"
    STATUS=$?
    OUT="$(< "$SANDBOX/out.txt")"
    ERR="$(< "$SANDBOX/err.txt")"
}

expect_status() {
    if [ "$STATUS" -ne "$1" ]; then
        fail_case "код возврата $STATUS, ожидался $1"
    fi
}

expect_out() {
    if ! printf '%s\n' "$OUT" | grep -qF -- "$1"; then
        fail_case "в stdout нет: $1"
    fi
}

expect_out_empty() {
    if [ -n "$OUT" ]; then
        fail_case "stdout не пуст: $OUT"
    fi
}

expect_out_lines() {
    local n
    n="$(printf '%s' "$OUT" | grep -c '')"
    if [ "$n" -ne "$1" ]; then
        fail_case "в stdout $n строк, ожидалось $1"
    fi
}

expect_err() {
    if ! printf '%s\n' "$ERR" | grep -qF -- "$1"; then
        fail_case "в stderr нет: $1"
    fi
}

expect_calls() {
    local n
    n="$(grep -c '' "$CALLS")"
    if [ "$n" -ne "$1" ]; then
        fail_case "gh вызван $n раз, ожидалось $1"
    fi
}

# Вид вызова по номеру строки журнала.
call_line() {
    sed -n "${1}p" "$CALLS"
}

expect_call_has() {
    local line
    line="$(call_line "$1")"
    if [[ "$line" != *"$2"* ]]; then
        fail_case "вызов gh №$1 не содержит «$2»: $line"
    fi
}

expect_no_call_with() {
    if grep -qF -- "$1" "$CALLS"; then
        fail_case "в журнале gh есть вызов с «$1»"
    fi
}

expect_count_with() {
    local n
    n="$(grep -cF -- "$1" "$CALLS")"
    if [ "$n" -ne "$2" ]; then
        fail_case "вызовов с «$1»: $n, ожидалось $2"
    fi
}

# ==================================================================
# Сценарий 1. Негодные аргументы — код 2, gh не вызывается.
# ==================================================================
begin_case 'без аргументов — код 2, использование, gh не вызывается'
run_script
expect_status 2
expect_err 'Использование'
expect_calls 0
end_case

begin_case 'один аргумент — код 2, использование, gh не вызывается'
run_script 159
expect_status 2
expect_err 'Использование'
expect_calls 0
end_case

begin_case 'три аргумента (статус без кавычек) — код 2, gh не вызывается'
run_script 159 In progress
expect_status 2
expect_err 'Использование'
expect_calls 0
end_case

for bad in 'abc' '#159' ''; do
    begin_case "номер задачи «$bad» — код 2, значение названо, gh не вызывается"
    run_script "$bad" Review
    expect_status 2
    expect_err "«$bad»"
    expect_calls 0
    end_case
done

begin_case 'пустой статус — код 2, gh не вызывается'
run_script 159 ''
expect_status 2
expect_err 'Статус'
expect_calls 0
end_case

begin_case 'BOARD_NUMBER=x — код 2, значение названо, gh не вызывается'
TEST_BOARD_NUMBER=x run_script 159 Review
expect_status 2
expect_err 'BOARD_NUMBER'
expect_err '«x»'
expect_calls 0
end_case

# ==================================================================
# Сценарий 2. Статус ставится опцией, найденной по имени: id доски, поля,
# опции, issue и карточки берутся из ответов, а не зашиты.
# ==================================================================
begin_case 'Review — код 0, update с fld-status и opt-rv, порядок вызовов'
FAKE_READ="opt-rv${TAB}Review" run_script 159 Review
expect_status 0
expect_calls 5
expect_call_has 1 'repositoryOwner(login:'
expect_call_has 1 'field(name: "Status")'
expect_call_has 1 '[owner=owner-x]'
expect_call_has 1 '[number=7]'
expect_call_has 2 '[issue][view][159]'
expect_call_has 3 'addProjectV2ItemById'
expect_call_has 3 '[project=proj-1]'
expect_call_has 3 '[content=I_issue159]'
expect_call_has 4 'updateProjectV2ItemFieldValue'
expect_call_has 4 '[project=proj-1]'
expect_call_has 4 '[item=ITEM_159]'
expect_call_has 4 '[field=fld-status]'
expect_call_has 4 '[option=opt-rv]'
expect_call_has 5 'fieldValueByName(name: "Status")'
expect_call_has 5 '[item=ITEM_159]'
expect_count_with 'updateProjectV2ItemFieldValue' 1
expect_out '159'
expect_out 'Review'
expect_out_lines 1
end_case

# ==================================================================
# Сценарий 3. Регистр имени статуса не важен, в выводе — имя с доски.
# ==================================================================
begin_case "'in progress' — опция opt-ip, в stdout имя с доски"
FAKE_READ="opt-ip${TAB}In progress" run_script 159 'in progress'
expect_status 0
expect_call_has 4 '[option=opt-ip]'
expect_out 'In progress'
expect_out_lines 1
end_case

# ==================================================================
# Сценарий 4. Ответы gh с CRLF: \r не попадает в id и не ломает сравнение.
# ==================================================================
begin_case 'CRLF в ответах — Done ставится opt-d без \r, чтение засчитано'
FAKE_CRLF=1 FAKE_READ="opt-d${TAB}Done" run_script 159 Done
expect_status 0
expect_call_has 3 '[content=I_issue159]'
expect_call_has 4 '[option=opt-d]'
expect_call_has 4 '[item=ITEM_159]'
expect_call_has 4 '[field=fld-status]'
expect_out 'Done'
if printf '%s' "$OUT" | grep -q "$(printf '\r')"; then
    fail_case 'в stdout есть \r'
fi
end_case

# ==================================================================
# Сценарий 5. Неизвестный статус — код 2, перечень имеющихся, карточка не
# трогается.
# ==================================================================
begin_case 'Blocked — код 2, перечень опций, только запрос доски'
run_script 159 Blocked
expect_status 2
expect_err 'Blocked'
for name in Backlog Ready 'In progress' Review Done; do
    expect_err "$name"
done
expect_calls 1
expect_call_has 1 'repositoryOwner'
expect_no_call_with 'addProjectV2ItemById'
expect_no_call_with 'updateProjectV2ItemFieldValue'
expect_out_empty
end_case

# ==================================================================
# Сценарий 6. Нет доски, поля Status или issue — код 1 без add и update.
# ==================================================================
begin_case 'нет доски — код 1, сказано, add и update не вызываются'
FAKE_BOARD_FILE="$BOARD_NO_PROJECT" run_script 159 Review
expect_status 1
expect_err 'Доска'
expect_no_call_with 'addProjectV2ItemById'
expect_no_call_with 'updateProjectV2ItemFieldValue'
expect_out_empty
end_case

begin_case 'нет поля Status — код 1, сказано, add и update не вызываются'
FAKE_BOARD_FILE="$BOARD_NO_FIELD" run_script 159 Review
expect_status 1
expect_err 'Status'
expect_no_call_with 'addProjectV2ItemById'
expect_no_call_with 'updateProjectV2ItemFieldValue'
expect_out_empty
end_case

begin_case 'пустой node id issue — код 1, сказано, add и update не вызываются'
FAKE_ISSUE_ID='' run_script 159 Review
expect_status 1
expect_err '#159'
expect_no_call_with 'addProjectV2ItemById'
expect_no_call_with 'updateProjectV2ItemFieldValue'
expect_out_empty
end_case

# ==================================================================
# Сценарий 7. Сбой gh на каждом вызове — код 1 с именем вызова и кодом,
# последующих вызовов нет.
# ==================================================================
check_fail_on() {
    local kind="$1" name="$2" calls="$3"
    begin_case "сбой gh на «$kind» — код 1, «$name: код 4», дальше не идёт"
    FAKE_GH_FAIL_ON="$kind" FAKE_GH_FAIL_CODE=4 FAKE_READ="opt-rv${TAB}Review" \
        run_script 159 Review
    expect_status 1
    expect_err "$name: код 4"
    expect_calls "$calls"
    expect_out_empty
    end_case
}

check_fail_on board 'запрос доски' 1
check_fail_on issue 'gh issue view' 2
check_fail_on add 'addProjectV2ItemById' 3
check_fail_on update 'updateProjectV2ItemFieldValue' 4
check_fail_on read 'чтение статуса' 5

begin_case 'add вернул пустой id карточки — код 1, update не вызывается'
FAKE_ITEM_ID='' run_script 159 Review
expect_status 1
expect_err 'карточк'
expect_calls 3
expect_no_call_with 'updateProjectV2ItemFieldValue'
expect_out_empty
end_case

# ==================================================================
# Сценарий 8. Прочитанный после установки статус не совпал — код 1,
# фактический и ожидаемый в stderr, повторной установки нет.
# ==================================================================
begin_case 'чтение отдало Backlog вместо Review — код 1, без повтора'
FAKE_READ="opt-b${TAB}Backlog" run_script 159 Review
expect_status 1
expect_err 'Backlog'
expect_err 'Review'
expect_count_with 'updateProjectV2ItemFieldValue' 1
expect_count_with 'fieldValueByName' 1
expect_calls 5
expect_out_empty
end_case

begin_case 'чтение отдало пустой статус — код 1, а не «поставлено»'
FAKE_READ='' run_script 159 Review
expect_status 1
expect_err 'Review'
expect_out_empty
end_case

# ------------------------------------------------------------------
# Итог
# ------------------------------------------------------------------
printf '\n==================================================\n'
printf 'Сценариев пройдено: %s, провалено: %s\n' "$PASSED" "$FAILED"
if [ "$FAILED" -ne 0 ]; then
    printf 'Провалились:\n'
    for name in "${FAILED_NAMES[@]}"; do
        printf '  - %s\n' "$name"
    done
    exit 1
fi

printf 'Статус доски ставится опцией по имени, подтверждается чтением и отказывает понятно.\n'
exit 0
