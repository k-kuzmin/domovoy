#!/usr/bin/env bash
#
# Домовой — проверочные сценарии для сверки правил scripts/rules-sync.sh.
#
# ЗАЧЕМ
#
# Сверка, которая только зеленеет, ничего не доказывает: она зеленела бы и
# при пустом каталоге правил. Здесь для каждой из пяти проверок собирается
# временный репозиторий, в нём воспроизводится ровно то расхождение, ради
# которого проверка написана, и сверяется код возврата с текстом вывода.
#
# Отдельно проверяется главное: на согласованном наборе сверка молчит.
# Проверка, шумящая на нормальной работе, перестаёт читаться.
#
# КАК ЗАПУСКАТЬ
#
#   bash scripts/rules-sync.test.sh
#
# Код возврата: 0 — все сценарии прошли, 1 — есть провалившиеся.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECK="$SCRIPT_DIR/rules-sync.sh"

if [ ! -f "$CHECK" ]; then
    printf 'Не найден %s\n' "$CHECK" >&2
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
        printf '        вывод:\n%s\n' "$OUTPUT" | sed 's/^/        /'
    fi
}

run_check() {
    OUTPUT="$(bash "$CHECK" "$repo" 2>&1)"
    STATUS=$?
}

expect_status() {
    if [ "$STATUS" -ne "$1" ]; then
        fail_case "код возврата $STATUS, ожидался $1"
    fi
}

expect_output() {
    if ! printf '%s' "$OUTPUT" | grep -qF "$1"; then
        fail_case "в выводе нет: $1"
    fi
}

# Согласованный набор: два шага, четыре файла правил, указатель, запись
# решения, на которую правила ссылаются.
new_fixture() {
    repo="$SANDBOX/repo-$RANDOM$RANDOM"
    mkdir -p "$repo/.github/workflows" "$repo/docs/rules" \
        "$repo/docs/decisions" "$repo/.claude"

    cat > "$repo/.github/workflows/agent-triage.yml" <<'EOF'
name: agent-triage
jobs:
  triage:
    steps:
      - name: Вердикт
        with:
          prompt: |
            Правила шага — `docs/rules/triage.md`. Прочитай целиком.
EOF

    cat > "$repo/.github/workflows/agent-review.yml" <<'EOF'
name: agent-review
jobs:
  correctness:
    steps:
      - name: Проверка
        with:
          prompt: |
            Правила шага — `docs/rules/review-correctness.md`.
            Уровни замечаний — `docs/rules/README.md`.
  security:
    steps:
      - name: Проверка
        with:
          prompt: |
            Правила шага — `docs/rules/review-security.md`.
EOF

    printf '# Указатель\n\nУровни замечаний.\n' > "$repo/docs/rules/README.md"
    printf '# Триаж\n\nПять критериев.\n' > "$repo/docs/rules/triage.md"
    printf '# Ревью — корректность\n\nСм. [README](README.md).\n' \
        > "$repo/docs/rules/review-correctness.md"
    printf '# Ревью — безопасность\n\nЗапись [0016](../decisions/0016-x.md).\n' \
        > "$repo/docs/rules/review-security.md"
    printf '# 0016\n\nРешение.\n' > "$repo/docs/decisions/0016-x.md"

    cat > "$repo/.claude/CLAUDE.md" <<'EOF'
# Правила проекта

| Шаг | Правила |
|---|---|
| Триаж | docs/rules/triage.md |
| Ревью — корректность | docs/rules/review-correctness.md |
| Ревью — безопасность | docs/rules/review-security.md |
EOF
}

# ------------------------------------------------------------------
# Сценарий 0. Согласованный набор — сверка молчит.
# ------------------------------------------------------------------
begin_case 'согласованный набор — сверка молчит'
new_fixture
run_check
expect_status 0
expect_output 'сходятся'
end_case

# ------------------------------------------------------------------
# Сценарий 1. Промпт ссылается на файл, которого нет.
# Так выглядит переименование правил без правки промпта.
# ------------------------------------------------------------------
begin_case 'проверка 1: ссылка из промпта в пустоту'
new_fixture
mv "$repo/docs/rules/triage.md" "$repo/docs/rules/triage-rules.md"
run_check
expect_status 1
expect_output 'ссылка на несуществующие правила: docs/rules/triage.md'
end_case

# ------------------------------------------------------------------
# Сценарий 2. Файл правил не упомянут ни одним промптом.
# Так выглядит правило, которое существует только на бумаге.
# ------------------------------------------------------------------
begin_case 'проверка 2: правила, на которые никто не ссылается'
new_fixture
printf '# Починка\n\nПравила.\n' > "$repo/docs/rules/fix.md"
printf '| Починка | docs/rules/fix.md |\n' >> "$repo/.claude/CLAUDE.md"
run_check
expect_status 1
expect_output 'не упомянут ни одним промптом'
end_case

# ------------------------------------------------------------------
# Сценарий 3. Промпт шага ссылается на чужие правила, но не на свои.
# Так выглядит потерянная при правке половина ревью.
# ------------------------------------------------------------------
begin_case 'проверка 3: промпт шага не ссылается на свои правила'
new_fixture
sed -i 's#docs/rules/review-security.md#docs/rules/review-correctness.md#' \
    "$repo/.github/workflows/agent-review.yml"
run_check
expect_status 1
expect_output 'не ссылается на свои правила: docs/rules/review-security.md'
end_case

# ------------------------------------------------------------------
# Сценарий 4. Файл правил есть, в указателе его нет.
# Так выглядят правила, невидимые для локальной сессии.
# ------------------------------------------------------------------
begin_case 'проверка 4: правила отсутствуют в указателе'
new_fixture
sed -i '/review-security/d' "$repo/.claude/CLAUDE.md"
run_check
expect_status 1
expect_output 'не указаны в файле правил проекта: docs/rules/review-security.md'
end_case

# ------------------------------------------------------------------
# Сценарий 5. Битая относительная ссылка внутри правил.
# Так выглядит запись решения, переименованная без правки ссылок.
# ------------------------------------------------------------------
begin_case 'проверка 5: битая ссылка внутри правил'
new_fixture
rm "$repo/docs/decisions/0016-x.md"
run_check
expect_status 1
expect_output 'битая ссылка: ../decisions/0016-x.md'
end_case

# ------------------------------------------------------------------
# Сценарий 6. У шага нет файла правил вовсе.
# Так выглядит новый шаг цикла, заведённый без правил.
# ------------------------------------------------------------------
begin_case 'проверка 3: шаг без файла правил'
new_fixture
cat > "$repo/.github/workflows/agent-plan.yml" <<'EOF'
name: agent-plan
jobs:
  plan:
    steps:
      - name: План
        with:
          prompt: |
            Составь план. Правила — `docs/rules/triage.md`.
EOF
run_check
expect_status 1
expect_output 'у шага «plan» нет файла правил'
end_case

# ------------------------------------------------------------------
# Сценарий 7. Неизвестный каталог — код 2, а не ложное «сходится».
# ------------------------------------------------------------------
begin_case 'запуск: каталога нет — код 2 и понятное сообщение'
repo="$SANDBOX/нет-такого-каталога"
run_check
expect_status 2
expect_output 'Не найден каталог'
end_case

printf '\n%s\n' '=================================================='
printf 'Сценариев пройдено: %d, провалено: %d\n' "$PASSED" "$FAILED"

if [ "$FAILED" -gt 0 ]; then
    printf 'Провалились:\n'
    for name in "${FAILED_NAMES[@]}"; do
        printf '  - %s\n' "$name"
    done
    exit 1
fi

printf 'Сверка правил ведёт себя как задумано.\n'
exit 0
