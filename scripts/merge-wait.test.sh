#!/usr/bin/env bash
#
# Домовой — проверочные сценарии ожидания мерджа.
#
# ЗАЧЕМ
#
# `scripts/merge-wait.sh` оркестратор ставит в фон в момент, когда отдаёт
# зелёный PR человеку, и по его выводу решает, убирать ли ветку и worktree
# задачи. Ошибка здесь тихая и дорогая: ожидание, которое выходит на первом
# `OPEN`, выглядит как «смерджено», а ожидание, которое крутится на сбое `gh`,
# не кончается никогда.
#
# В СЕТЬ ЭТИ СЦЕНАРИИ НЕ ХОДЯТ
#
# `gh` подставной (по образцу `scripts/review-comments.test.sh`): короткий
# скрипт в начале `PATH`. Он отдаёт состояния PR по очереди из
# `FAKE_GH_STATES` — по одному на вызов — и записывает аргументы каждого
# вызова строкой в журнал. По журналу проверяется и число опросов, и форма
# вызова, и то, что на негодном аргументе `gh` не зовётся вовсе.
# `MERGE_WAIT_INTERVAL=0` — пауза между опросами нулевая.
#
# ЧЕГО ЭТИ СЦЕНАРИИ НЕ ЛОВЯТ
#
# Что ожидание действительно поставят в фон в нужный момент — правило
# `.claude/CLAUDE.md`, а не механика. Совпадение подставных ответов с живым
# `gh` проверяется только прогоном на настоящем PR.
#
# КАК ЗАПУСКАТЬ
#
#   bash scripts/merge-wait.test.sh
#
# Код возврата: 0 — все сценарии прошли, 1 — есть провалившиеся,
# 2 — запустить нечем.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$SCRIPT_DIR/merge-wait.sh"

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
    fi
}

# ------------------------------------------------------------------
# Подставной `gh`.
#
# `FAKE_GH_STATES` — состояния через пробел, по одному на вызов; последнее
# повторяется, если вызовов больше. Слово `FAIL` вместо состояния — вызов
# выходит с кодом `FAKE_GH_FAIL_CODE` (по умолчанию 1) и пустым stdout, как
# `gh` на сетевом сбое или несуществующем PR. Номер вызова держится в файле:
# каждый вызов — отдельный процесс.
# ------------------------------------------------------------------
BIN="$SANDBOX/bin"
mkdir -p "$BIN"

CALLS="$SANDBOX/gh-calls.txt"
COUNTER="$SANDBOX/gh-counter.txt"

cat > "$BIN/gh" <<'FAKE'
#!/bin/sh
# Подставной gh для сценариев: в сеть не ходит.
printf '%s\n' "$*" >> "$FAKE_GH_CALLS"
n=0
if [ -f "$FAKE_GH_COUNTER" ]; then
    read -r n < "$FAKE_GH_COUNTER"
fi
n=$((n + 1))
printf '%s\n' "$n" > "$FAKE_GH_COUNTER"
i=0
state=''
for s in $FAKE_GH_STATES; do
    i=$((i + 1))
    state="$s"
    if [ "$i" -eq "$n" ]; then
        break
    fi
done
if [ "$state" = 'FAIL' ]; then
    printf 'подставной gh: сбой\n' >&2
    exit "${FAKE_GH_FAIL_CODE:-1}"
fi
printf '%s\n' "$state"
FAKE
chmod +x "$BIN/gh"

# Прогон проверяемого сценария. `timeout` страхует от бесконечного цикла:
# зависший сценарий обязан стать красным случаем, а не повесить прогон.
run_script() {
    local states="$1"
    shift
    : > "$CALLS"
    rm -f "$COUNTER"
    env "PATH=$BIN:$PATH" \
        "MERGE_WAIT_INTERVAL=${TEST_INTERVAL:-0}" \
        "FAKE_GH_STATES=$states" \
        "FAKE_GH_CALLS=$CALLS" \
        "FAKE_GH_COUNTER=$COUNTER" \
        "FAKE_GH_FAIL_CODE=${FAKE_GH_FAIL_CODE:-1}" \
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

expect_out_exact() {
    if [ "$OUT" != "$1" ]; then
        fail_case "stdout «$OUT», ожидался ровно «$1»"
    fi
}

expect_err() {
    if ! printf '%s\n' "$ERR" | grep -qF -- "$1"; then
        fail_case "в stderr нет: $1"
    fi
}

expect_err_nonempty() {
    if [ -z "$ERR" ]; then
        fail_case 'stderr пуст — отказ без диагностики'
    fi
}

expect_calls() {
    local n
    n="$(grep -c '' "$CALLS")"
    if [ "$n" -ne "$1" ]; then
        fail_case "gh вызван $n раз, ожидалось $1"
    fi
}

expect_every_call() {
    local line
    while IFS= read -r line; do
        if [ "$line" != "$1" ]; then
            fail_case "вызов gh «$line», ожидался «$1»"
        fi
    done < "$CALLS"
}

# ==================================================================
# Сценарий 1. OPEN, OPEN, MERGED: ожидание не выходит на OPEN и повторяет
# запрос, пока PR не смерджен.
# ==================================================================
begin_case 'OPEN, затем MERGED — код 0, ровно MERGED, три опроса'
run_script 'OPEN OPEN MERGED' 150
expect_status 0
expect_out_exact 'MERGED'
expect_calls 3
expect_every_call 'pr view 150 --json state --jq .state'
end_case

# ==================================================================
# Сценарий 2. CLOSED без мерджа — тоже конец ожидания, но другой вывод:
# по нему оркестратор задаёт вопрос человеку, а не убирает ветку.
# ==================================================================
begin_case 'CLOSED — код 0, ровно CLOSED, один опрос'
run_script 'CLOSED' 150
expect_status 0
expect_out_exact 'CLOSED'
expect_calls 1
expect_every_call 'pr view 150 --json state --jq .state'
end_case

# ==================================================================
# Сценарий 3. Сбой gh — конец ожидания с кодом 1, а не цикл на пустом
# значении.
# ==================================================================
begin_case 'сбой gh на первом вызове — код 1, диагностика, stdout пуст'
run_script 'FAIL' 999999
expect_status 1
expect_err 'gh pr view: код 1'
expect_out_exact ''
expect_calls 1
end_case

begin_case 'сбой gh после OPEN — код 1, диагностика, stdout пуст'
run_script 'OPEN FAIL' 150
expect_status 1
expect_err 'gh pr view: код 1'
expect_out_exact ''
expect_calls 2
end_case

begin_case 'сбой gh с другим кодом — код в диагностике дословно'
FAKE_GH_FAIL_CODE=4 run_script 'FAIL' 150
expect_status 1
expect_err 'gh pr view: код 4'
expect_out_exact ''
end_case

# ==================================================================
# Сценарий 4. Иное состояние (или пустой ответ при коде 0) — код 1 с
# диагностикой: незнакомое значение не считается ни OPEN, ни концом.
# ==================================================================
begin_case 'незнакомое состояние — код 1, диагностика, stdout пуст'
run_script 'DRAFT' 150
expect_status 1
expect_err_nonempty
expect_out_exact ''
expect_calls 1
end_case

begin_case 'пустой ответ при коде 0 — код 1, а не бесконечный цикл'
run_script '' 150
expect_status 1
expect_err_nonempty
expect_out_exact ''
expect_calls 1
end_case

# ==================================================================
# Сценарий 5. Негодный аргумент — код 2 до вызова gh.
# ==================================================================
for bad in 'abc' '' '12a' '-1' '150 ' '--repo x/y'; do
    begin_case "негодный аргумент «$bad» — код 2 без вызова gh"
    run_script 'MERGED' "$bad"
    expect_status 2
    expect_err_nonempty
    expect_calls 0
    end_case
done

begin_case 'без аргументов — код 2 без вызова gh'
run_script 'MERGED'
expect_status 2
expect_err_nonempty
expect_calls 0
end_case

begin_case 'два аргумента — код 2 без вызова gh'
run_script 'MERGED' 150 151
expect_status 2
expect_err_nonempty
expect_calls 0
end_case

# Нечисловая пауза роняла бы `sleep` и превращала ожидание в опрос без
# паузы до упора в лимит API.
for bad in 'abc' '1m' '-5'; do
    begin_case "негодная пауза «$bad» — код 2 без вызова gh"
    TEST_INTERVAL="$bad" run_script 'OPEN MERGED' 150
    expect_status 2
    expect_err_nonempty
    expect_calls 0
    end_case
done

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

printf 'Ожидание мерджа различает MERGED, CLOSED, сбой gh и негодный аргумент.\n'
exit 0
