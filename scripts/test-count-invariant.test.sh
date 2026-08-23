#!/usr/bin/env bash
#
# Домовой — проверочные сценарии для инварианта числа выполненных тестов
# scripts/test-count-invariant.sh.
#
# ЗАЧЕМ
#
# Проверка, которую никто не проверял, зеленеет и на пустом каталоге
# результатов. Здесь для каждого случая собирается временный каталог с
# рукописными trx-отчётами и снимком — и сверяются код возврата и текст
# сообщения. Главный сценарий — тот, где выполненных случаев стало меньше:
# ради него инвариант и написан.
#
# Отчёты рукописные, dotnet и python не нужны: харнесс должен идти секунду и
# запускаться на машине без SDK. Форма <Counters> взята с настоящего trx,
# полученного командой из ci-fast.yml.
#
# КАК ЗАПУСКАТЬ
#
#   bash scripts/test-count-invariant.test.sh
#
# Код возврата: 0 — все сценарии прошли, 1 — есть провалившиеся.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INVARIANT="$SCRIPT_DIR/test-count-invariant.sh"

if [ ! -f "$INVARIANT" ]; then
    printf 'Не найден %s\n' "$INVARIANT" >&2
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
        printf '        --- вывод проверки ---\n'
        printf '%s\n' "$OUTPUT" | sed 's/^/        /'
        printf '        --- конец вывода ---\n'
    fi
}

# ------------------------------------------------------------------
# Фикстура: каталог результатов и снимок рядом.
#
# new_case присваивает путь глобальной переменной work, а не печатает его:
# через $(new_case) счётчик рос бы в подоболочке и все сценарии получили бы
# один каталог.
# ------------------------------------------------------------------
CASE_SEQ=0
work=''

new_case() {
    CASE_SEQ=$((CASE_SEQ + 1))
    work="$SANDBOX/case-$CASE_SEQ"
    mkdir -p "$work/TestResults" "$work/tests"
}

# Отчёт trx с заданными числами. Форма повторяет настоящий: сводка прогона
# лежит в ResultSummary/Counters, атрибутов у неё много, нужен один.
#
# Элемент Counters пишется одной строкой — так его печатает vstest, и так его
# читает проверка. Разбить его здесь для красоты значило бы проверять формат,
# которого не бывает, а настоящий не проверять вовсе.
write_trx() {
    local path="$1" total="$2" executed="$3" not_executed="$4"
    mkdir -p "$(dirname "$path")"
    cat > "$path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<TestRun id="00000000-0000-0000-0000-000000000000" name="сценарий" xmlns="http://microsoft.com/schemas/VisualStudio/TeamTest/2010">
  <ResultSummary outcome="Completed">
    <Counters total="$total" executed="$executed" passed="$executed" failed="0" error="0" timeout="0" aborted="0" inconclusive="0" passedButRunAborted="0" notRunnable="0" notExecuted="$not_executed" disconnected="0" warning="0" completed="0" inProgress="0" pending="0" />
  </ResultSummary>
</TestRun>
EOF
}

write_baseline() {
    printf '%s\n' "$2" > "$1/tests/test-count.baseline"
}

run_invariant() {
    local target="$1"
    OUTPUT="$(cd "$target" && bash "$INVARIANT" TestResults tests/test-count.baseline 2>&1)"
    STATUS=$?
}

expect_status() {
    local expected="$1"
    if [ "$STATUS" -ne "$expected" ]; then
        fail_case "код возврата $STATUS, ожидался $expected"
    fi
}

expect_output() {
    local needle="$1"
    if ! printf '%s' "$OUTPUT" | grep -qF -- "$needle"; then
        fail_case "в выводе нет: $needle"
    fi
}

# ------------------------------------------------------------------
# Сценарий 1. Число совпало со снимком.
# ------------------------------------------------------------------
begin_case 'число совпало со снимком — код 0 и напечатанное сравнение'
new_case
write_trx "$work/TestResults/tests.trx" 42 42 0
write_baseline "$work" 42
run_invariant "$work"
expect_status 0
expect_output 'Выполнено тестовых случаев: 42'
expect_output 'сходится'
end_case

# ------------------------------------------------------------------
# Сценарий 2. Выполненных меньше снимка — главный сценарий.
#
# Ловит и опустошённый набор [InlineData], и тест, унесённый в проект, не
# попадающий под прогон: оба уменьшают executed, ни один не добавляет в дифф
# строку из перечня подавлений.
# ------------------------------------------------------------------
begin_case 'выполненных меньше снимка — код 1, названы оба числа'
new_case
write_trx "$work/TestResults/tests.trx" 40 40 0
write_baseline "$work" 42
run_invariant "$work"
expect_status 1
expect_output 'стало меньше: 40 против 42'
expect_output 'Метки, снимающей эту проверку, нет'
end_case

# ------------------------------------------------------------------
# Сценарий 3. Выполненных больше снимка — тоже отказ.
# ------------------------------------------------------------------
begin_case 'выполненных больше снимка — код 1 и число, которое надо вписать'
new_case
write_trx "$work/TestResults/tests.trx" 45 45 0
write_baseline "$work" 42
run_invariant "$work"
expect_status 1
expect_output 'стало больше: 45 против 42'
expect_output 'впишите 45'
end_case

# ------------------------------------------------------------------
# Сценарий 4. Снимка нет — сравнить не с чем.
# ------------------------------------------------------------------
begin_case 'снимок отсутствует — код 1 и «сравнить не с чем»'
new_case
write_trx "$work/TestResults/tests.trx" 42 42 0
run_invariant "$work"
expect_status 1
expect_output 'сравнить не с чем'
expect_output 'Выполнено случаев: 42'
end_case

# ------------------------------------------------------------------
# Сценарий 5. Снимок есть, но числа в нём нет.
# ------------------------------------------------------------------
begin_case 'снимок нечисловой — код 1'
new_case
write_trx "$work/TestResults/tests.trx" 42 42 0
printf 'сорок два\n' > "$work/tests/test-count.baseline"
run_invariant "$work"
expect_status 1
expect_output 'нет строки, целиком состоящей из цифр'
end_case

begin_case 'снимок пустой — код 1'
new_case
write_trx "$work/TestResults/tests.trx" 42 42 0
: > "$work/tests/test-count.baseline"
run_invariant "$work"
expect_status 1
expect_output 'нет строки, целиком состоящей из цифр'
end_case

begin_case 'снимок из одних комментариев — код 1'
new_case
write_trx "$work/TestResults/tests.trx" 42 42 0
printf '# число будет позже\n# честное слово\n' > "$work/tests/test-count.baseline"
run_invariant "$work"
expect_status 1
expect_output 'нет строки, целиком состоящей из цифр'
end_case

# ------------------------------------------------------------------
# Сценарий 6. Ни одного trx — громкий отказ, а не зелёный прогон.
# ------------------------------------------------------------------
begin_case 'в каталоге результатов нет trx — код 1'
new_case
write_baseline "$work" 42
run_invariant "$work"
expect_status 1
expect_output 'не найдены'
expect_output 'разобраться, а не расширять шаблон поиска'
end_case

# ------------------------------------------------------------------
# Сценарий 7. В trx нет атрибута executed — сменился формат отчёта.
# ------------------------------------------------------------------
begin_case 'в trx нет атрибута executed — код 1'
new_case
cat > "$work/TestResults/tests.trx" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<TestRun id="00000000-0000-0000-0000-000000000000">
  <ResultSummary outcome="Completed">
    <Counters total="42" passed="42" failed="0" notExecuted="0" />
  </ResultSummary>
</TestRun>
EOF
write_baseline "$work" 42
run_invariant "$work"
expect_status 1
expect_output 'нет атрибута executed'
end_case

# ------------------------------------------------------------------
# Сценарий 8. Два отчёта — числа складываются.
#
# Второй лежит на уровень глубже: так проверяется и суммирование, и второй
# уровень поиска, который сегодня пуст, а завтра может стать раскладкой.
# ------------------------------------------------------------------
begin_case 'два trx — числа складываются'
new_case
write_trx "$work/TestResults/tests.trx" 30 30 0
write_trx "$work/TestResults/mobile/mobile.trx" 12 12 0
write_baseline "$work" 42
run_invariant "$work"
expect_status 0
expect_output 'Выполнено тестовых случаев: 42'
end_case

# ------------------------------------------------------------------
# Сценарий 9. Пропущенные случаи не считаются выполненными.
#
# Добавленный Skip краснеет дважды: шаблоном в guard.sh и здесь. Второе
# срабатывание важнее — оно не зависит от того, знаком ли гейту приём.
# ------------------------------------------------------------------
begin_case 'notExecuted не считается выполненным'
new_case
write_trx "$work/TestResults/tests.trx" 42 40 2
write_baseline "$work" 42
run_invariant "$work"
expect_status 1
expect_output 'стало меньше: 40 против 42'
end_case

# ------------------------------------------------------------------
# Сценарий 10. Снимок с комментариями, пустыми строками и \r.
# ------------------------------------------------------------------
begin_case 'снимок с комментариями и пустыми строками читается'
new_case
write_trx "$work/TestResults/tests.trx" 42 42 0
printf '# Снимок числа выполненных случаев.\r\n\r\n42\r\n\r\n# конец\r\n' \
    > "$work/tests/test-count.baseline"
run_invariant "$work"
expect_status 0
expect_output 'сходится'
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
printf 'Инвариант числа тестов ведёт себя как задумано.\n'
exit 0
