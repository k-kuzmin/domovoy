#!/usr/bin/env bash
#
# Домовой — проверочные сценарии входа планового круга ревью.
#
# ЗАЧЕМ
#
# Агентский цикл выключен (`vars.AGENT_LOOP_ENABLED` не заведена), и живым
# прогоном плановый круг не проверяется ничем. Поэтому проверяется то, что
# проверяется без запуска: арифметика счётчика кругов — прогоном самого
# скрипта, а провод в workflow — чтением условий и команд на месте.
#
# У каждой проверки провода есть отрицательный сценарий: та же проверка на
# временной копии файла с вырезанной строкой обязана покраснеть. Проверка,
# зеленеющая и на сломанном файле, проверяет собственное существование.
#
# ОБЛАСТЬ И ГРАНИЦА
#
# Читается ТЕКСТ условия и команд, а не их исполнение GitHub. YAML не
# разбирается: блок job и блок шага выделяются по отступу и по строке
# заголовка. Отсюда прямое следствие — синтаксическую ошибку в YAML эти
# сценарии не поймают (actionlint в проекте нет), и что условие, признанное
# здесь верным, действительно отсечёт чужую метку, знает только GitHub.
#
# КАК ЗАПУСКАТЬ
#
#   bash scripts/plan-review-round.test.sh
#
# Код возврата: 0 — все сценарии прошли, 1 — есть провалившиеся.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COUNTER="$SCRIPT_DIR/plan-review-round.sh"
REVIEW_WF="$ROOT/.github/workflows/agent-review.yml"
PLAN_WF="$ROOT/.github/workflows/agent-plan.yml"

for required in "$COUNTER" "$REVIEW_WF" "$PLAN_WF"; do
    if [ ! -f "$required" ]; then
        printf 'Не найден %s\n' "$required" >&2
        exit 2
    fi
done

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
# Прогон счётчика. Метки приходят по одной в строке на stdin — так же, как их
# отдаёт `gh issue view --json labels --jq '.labels[].name'`.
# ------------------------------------------------------------------
run_counter() {
    printf '%s' "$1" > "$SANDBOX/labels.txt"
    bash "$COUNTER" < "$SANDBOX/labels.txt" > "$SANDBOX/out.txt" 2> "$SANDBOX/err.txt"
    STATUS=$?
    OUT="$(< "$SANDBOX/out.txt")"
    ERR="$(< "$SANDBOX/err.txt")"
}

expect_status() {
    if [ "$STATUS" -ne "$1" ]; then
        fail_case "код возврата $STATUS, ожидался $1"
    fi
}

expect_stdout_line() {
    if ! printf '%s\n' "$OUT" | grep -qxF "$1"; then
        fail_case "в stdout нет строки: $1"
    fi
}

# Строк на stdout ровно две: шаг workflow дописывает их в $GITHUB_OUTPUT как
# есть, и человекочитаемая строка рядом с ними испортила бы вывод job.
expect_stdout_pure() {
    local lines
    lines="$(printf '%s\n' "$OUT" | grep -c '')"
    if [ "$lines" -ne 2 ]; then
        fail_case "на stdout $lines строк, ожидалось 2 — только round= и stop="
    fi
}

# ------------------------------------------------------------------
# Сценарий 1. Меток нет — круг первый, остановки нет.
#
# Счётчик, начинающий с нуля или останавливающий круг на первом же запуске,
# ронял бы плановое ревью, ни разу его не выполнив.
# ------------------------------------------------------------------
begin_case 'Первый круг планового ревью: меток нет — круг первый, остановки нет'
run_counter ''
expect_status 0
expect_stdout_line 'round=1'
expect_stdout_line 'stop=false'
expect_stdout_pure
end_case

# ------------------------------------------------------------------
# Сценарий 2. Одна метка круга — круг второй, остановки нет.
# ------------------------------------------------------------------
begin_case 'Потолок планового круга: одна метка — круг второй, остановки нет'
run_counter 'plan-review/1
'
expect_status 0
expect_stdout_line 'round=2'
expect_stdout_line 'stop=false'
end_case

# ------------------------------------------------------------------
# Сценарий 3. Две метки — остановка, третьего круга нет.
#
# Это ровно та развилка, по которой job решает, звать модель или поставить
# `agent/needs-human`. Потолок два — запись 0016.
# ------------------------------------------------------------------
begin_case 'Потолок планового круга: две метки — остановка, третьего круга нет'
run_counter 'plan-review/1
plan-review/2
'
expect_status 0
expect_stdout_line 'round=3'
expect_stdout_line 'stop=true'
end_case

# ------------------------------------------------------------------
# Сценарий 4. Посторонние метки задачи на счёт не влияют.
#
# Главная из них — `review/1`: она занята семантикой PR, и счётчик, считающий
# её, смешал бы круги плана с кругами диффа.
# ------------------------------------------------------------------
begin_case 'Потолок планового круга: посторонние метки на счёт не влияют'
run_counter 'agent
agent/ready
review/1
review/2
plan/proposed
'
expect_status 0
expect_stdout_line 'round=1'
expect_stdout_line 'stop=false'
end_case

begin_case 'Потолок планового круга: своя метка среди посторонних сосчитана'
run_counter 'agent
review/2
plan-review/1
plan/proposed
'
expect_status 0
expect_stdout_line 'round=2'
expect_stdout_line 'stop=false'
end_case

# ==================================================================
# Провод: то, что арифметике не видно.
#
# Дальше проверяется не поведение скрипта, а текст workflow: гейт доступа,
# вызов счётчика, токен публикации плана и ветка вердикта. Каждая проверка
# параметризована путём к файлу — иначе отрицательный сценарий на временной
# копии собрать нечем.
# ==================================================================

# Условие job: от строки заголовка до `steps:`. Именно там живёт `if`, и
# только там его и следует искать: `grep` по файлу целиком нашёл бы конъюнкт
# соседнего job и признал бы гейт стоящим там, где его нет.
job_head() {
    awk -v job="$2" '
        $0 == "  " job ":" { inside = 1; next }
        inside && $0 ~ /^    steps:/ { inside = 0 }
        inside { print }
    ' "$1"
}

# Тело job целиком — до следующего заголовка того же уровня.
job_body() {
    awk -v job="$2" '
        $0 == "  " job ":" { inside = 1; next }
        inside && /^  [^[:space:]]/ { inside = 0 }
        inside { print }
    ' "$1"
}

# Блок шага по его имени — до следующего шага.
step_block() {
    awk -v name="$2" '
        $0 == "      - name: " name { inside = 1; next }
        inside && /^      - name:/ { inside = 0 }
        inside { print }
    ' "$1"
}

PROBLEMS=0

require() {
    # $1 — текст блока, $2 — искомая строка, $3 — о чём речь.
    if ! printf '%s\n' "$1" | grep -qF -- "$2"; then
        printf 'нет: %s — %s\n' "$3" "$2"
        PROBLEMS=$((PROBLEMS + 1))
    fi
}

forbid() {
    if printf '%s\n' "$1" | grep -qF -- "$2"; then
        printf 'лишнее: %s — %s\n' "$3" "$2"
        PROBLEMS=$((PROBLEMS + 1))
    fi
}

require_block() {
    if [ -z "$1" ]; then
        printf 'пустой блок: %s\n' "$2"
        PROBLEMS=$((PROBLEMS + 1))
        return 1
    fi
    return 0
}

# Пять конъюнктов гейта плановой половины. Первые четыре дословно повторяют
# agent-plan.yml:44-50, пятый добавлен потому, что agent-review.yml обслуживает
# три события, а agent-plan.yml — одно.
GATE_CONJUNCTS=(
    "vars.AGENT_LOOP_ENABLED == 'true'"
    "github.event_name == 'issues'"
    "github.event.label.name == 'plan/proposed'"
    "github.event.issue.author_association == 'OWNER'"
    "!contains(github.event.issue.labels.*.name, 'agent/needs-human')"
)

check_gate() {
    PROBLEMS=0
    local job block conjunct
    for job in plan-round plan-correctness; do
        block="$(job_head "$1" "$job")"
        require_block "$block" "условие job $job" || continue
        for conjunct in "${GATE_CONJUNCTS[@]}"; do
            require "$block" "$conjunct" "конъюнкт гейта в job $job"
        done
    done
    [ "$PROBLEMS" -eq 0 ]
}

check_ceiling_wiring() {
    PROBLEMS=0
    local round_body correctness_head
    round_body="$(job_body "$1" plan-round)"
    if require_block "$round_body" 'тело job plan-round'; then
        # Скрипт лежит в репозитории, и без checkout шаг упал бы на
        # отсутствующем файле: у PR-половины job `round` чекаута нет вовсе,
        # и копирование её формы даёт неработающий job.
        require "$round_body" 'actions/checkout@' 'checkout в job plan-round'
        require "$round_body" 'bash scripts/plan-review-round.sh' 'вызов счётчика'
        require "$round_body" "--add-label \"plan-review/\$ROUND\"" 'метка круга'
        require "$round_body" "steps.count.outputs.stop == 'true'" 'ветка остановки'
        require "$round_body" "--add-label 'agent/needs-human'" 'остановка отдаёт задачу человеку'
    fi
    correctness_head="$(job_head "$1" plan-correctness)"
    if require_block "$correctness_head" 'условие job plan-correctness'; then
        require "$correctness_head" "needs.plan-round.outputs.stop == 'false'" \
            'ревью под условием отсутствия остановки'
    fi
    [ "$PROBLEMS" -eq 0 ]
}

check_publish_token() {
    PROBLEMS=0
    local block
    block="$(step_block "$1" 'Публикация плана')"
    if require_block "$block" 'шаг «Публикация плана»'; then
        require "$block" 'GH_TOKEN: ${{ secrets.AGENT_TOKEN }}' 'токен шага публикации'
        # Комментарий от штатного токена приходит от бота, чей
        # authorAssociation не равен OWNER, — фильтр предмета ревью не нашёл бы
        # плана ни на одной задаче.
        forbid "$block" 'secrets.GITHUB_TOKEN' 'штатный токен внутри шага публикации'
        require "$block" 'gh issue comment' 'публикация комментария внутри того же шага'
        require "$block" "--add-label 'plan/proposed'" 'постановка метки внутри того же шага'
        require "$block" "--add-label 'agent/needs-clarification'" \
            'ветки gh issue edit внутри того же шага'
    fi
    [ "$PROBLEMS" -eq 0 ]
}

check_verdict() {
    PROBLEMS=0
    local body block edits
    body="$(job_body "$1" plan-correctness)"
    if require_block "$body" 'тело job plan-correctness'; then
        # При approve метки не трогаются вовсе: апрув остаётся человеческим.
        # Поэтому команда с метками в job ровно одна — та, что под условием
        # changes_requested.
        edits="$(printf '%s\n' "$body" | grep -cF 'gh issue edit')"
        if [ "$edits" -ne 1 ]; then
            printf 'команд gh issue edit в job plan-correctness: %s, ожидалась 1\n' "$edits"
            PROBLEMS=$((PROBLEMS + 1))
        fi
        require "$body" "steps.publish.outputs.verdict == 'changes_requested'" \
            'ветка вердикта под условием changes_requested'
    fi
    block="$(step_block "$1" 'Замечания — план возвращается владельцу')"
    if require_block "$block" 'шаг вердикта changes_requested'; then
        require "$block" "--add-label 'agent/needs-clarification'" 'операция 1 вердикта'
        require "$block" "--remove-label 'plan/proposed'" 'операция 2 вердикта'
        # Без снятия `agent/ready` перезапуск невозможен: agent-triage.yml:59
        # отсекает задачу по этой метке, а agent-plan.yml:47 ждёт события
        # `labeled` с ней же — повторная постановка висящей метки события не
        # порождает.
        require "$block" "--remove-label 'agent/ready'" 'операция 3 вердикта'
    fi
    [ "$PROBLEMS" -eq 0 ]
}

run_check() {
    OUT="$("$1" "$2" 2>&1)"
    STATUS=$?
    ERR=''
}

# Временная копия файла с вырезанной строкой — материал отрицательных
# сценариев.
copy_without() {
    local source="$1" pattern="$2" target
    target="$SANDBOX/copy-$RANDOM$RANDOM.yml"
    grep -vF -- "$pattern" "$source" > "$target"
    printf '%s' "$target"
}

# ------------------------------------------------------------------
# Сценарий 6. Гейт планового круга: пять конъюнктов на месте в обоих job.
#
# Гейт, стоящий только в первом job, снимается одной правкой второго.
# ------------------------------------------------------------------
begin_case 'Гейт планового круга: пять конъюнктов на месте в обоих job'
run_check check_gate "$REVIEW_WF"
expect_status 0
end_case

# ------------------------------------------------------------------
# Сценарий 7. Вырезанный конъюнкт авторства ловится.
#
# Без отрицательного случая проверка зеленела бы и на выключенном гейте — то
# есть проверяла бы собственное существование.
# ------------------------------------------------------------------
begin_case 'Гейт планового круга: вырезанный конъюнкт авторства ловится'
run_check check_gate "$(copy_without "$REVIEW_WF" 'issue.author_association')"
expect_status 1
end_case

# ------------------------------------------------------------------
# Сценарий 8. Проводка потолка: счётчик вызван, ревью под условием остановки.
# ------------------------------------------------------------------
begin_case 'Проводка потолка: счётчик вызван, ревью стоит под отсутствием остановки'
run_check check_ceiling_wiring "$REVIEW_WF"
expect_status 0
end_case

# ------------------------------------------------------------------
# Сценарий 9. Пропажа вызова счётчика ловится.
# ------------------------------------------------------------------
begin_case 'Проводка потолка: пропажа вызова счётчика ловится'
run_check check_ceiling_wiring "$(copy_without "$REVIEW_WF" 'bash scripts/plan-review-round.sh')"
expect_status 1
end_case

# ------------------------------------------------------------------
# Сценарий 10. Токен публикации плана: весь шаг под AGENT_TOKEN.
#
# Правка, переведшая на AGENT_TOKEN одну лишь постановку метки, оставила бы
# автором комментария бота: круг стартовал бы, искал план среди комментариев
# владельца и не находил ни одного — на каждой задаче.
# ------------------------------------------------------------------
begin_case 'Токен публикации плана: весь шаг под AGENT_TOKEN'
run_check check_publish_token "$PLAN_WF"
expect_status 0
end_case

# ------------------------------------------------------------------
# Сценарий 11. Возврат к штатному токену ловится.
# ------------------------------------------------------------------
begin_case 'Токен публикации плана: возврат к штатному токену ловится'
sed 's/secrets.AGENT_TOKEN/secrets.GITHUB_TOKEN/' "$PLAN_WF" > "$SANDBOX/plan-штатный.yml"
run_check check_publish_token "$SANDBOX/plan-штатный.yml"
expect_status 1
end_case

# ------------------------------------------------------------------
# Сценарий 12. Вердикт changes_requested: три операции с метками.
# ------------------------------------------------------------------
begin_case 'Вердикт changes_requested: три операции с метками одной командой'
run_check check_verdict "$REVIEW_WF"
expect_status 0
end_case

# ------------------------------------------------------------------
# Сценарий 13. Пропажа снятия agent/ready ловится.
# ------------------------------------------------------------------
begin_case 'Вердикт changes_requested: пропажа снятия agent/ready ловится'
run_check check_verdict "$(copy_without "$REVIEW_WF" "--remove-label 'agent/ready'")"
expect_status 1
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

printf 'Вход планового круга ревью на месте.\n'
exit 0
