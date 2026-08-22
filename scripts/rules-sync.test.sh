#!/usr/bin/env bash
#
# Домовой — проверочные сценарии для сверки правил scripts/rules-sync.sh.
#
# ЗАЧЕМ
#
# Сверка, которая только зеленеет, ничего не доказывает: она зеленела бы и
# при пустом каталоге правил. Здесь для каждой из шести проверок собирается
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
    # Ключ -- обязателен: искомое может начинаться с дефиса (`--no-verify`),
    # и без него grep примет его за свой собственный ключ.
    if ! printf '%s' "$OUTPUT" | grep -qF -- "$1"; then
        fail_case "в выводе нет: $1"
    fi
}

# Согласованный набор: два шага, четыре файла правил, указатель, запись
# решения, на которую правила ссылаются. В указателе есть и абзац прозы
# длиннее окна проверки 6: на таблице она не сработала бы никогда, а
# сценарий с копией нужен именно над прозой.
new_fixture() {
    repo="$SANDBOX/repo-$RANDOM$RANDOM"
    mkdir -p "$repo/.github/workflows" "$repo/docs/rules" \
        "$repo/docs/decisions" "$repo/.claude" "$repo/.claude/agents"

    cat > "$repo/.github/workflows/agent-triage.yml" <<'EOF'
name: agent-triage
jobs:
  triage:
    steps:
      - name: Вердикт
        with:
          prompt: |
            Правила шага — `docs/rules/triage.md`. Прочитай целиком.
            Чтение объёмного вывода — `docs/rules/reading.md`.
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
            Чтение объёмного вывода — `docs/rules/reading.md`.
  security:
    steps:
      - name: Проверка
        with:
          prompt: |
            Правила шага — `docs/rules/review-security.md`.
            Чтение объёмного вывода — `docs/rules/reading.md`.
EOF

    printf '# Указатель\n\nУровни замечаний.\n' > "$repo/docs/rules/README.md"
    printf '# Триаж\n\nПять критериев.\n' > "$repo/docs/rules/triage.md"
    printf '# Ревью — корректность\n\nСм. [README](README.md).\n' \
        > "$repo/docs/rules/review-correctness.md"
    printf '# Ревью — безопасность\n\nЗапись [0016](../decisions/0016-x.md).\n' \
        > "$repo/docs/rules/review-security.md"
    printf '# 0016\n\nРешение.\n' > "$repo/docs/decisions/0016-x.md"
    printf '# Чтение\n\nСначала отбор, потом чтение целиком.\n' \
        > "$repo/docs/rules/reading.md"

    # Определения субагентов — второй класс потребителей. Три штуки: шаг с
    # единственным файлом правил и обе половины ревью.
    new_agent() {
        printf -- '---\nname: step-%s\ntools: Read\n---\n\nПравила шага — `docs/rules/%s.md`.\nЧтение объёмного вывода — `docs/rules/reading.md`.\n' \
            "$1" "$1" > "$repo/.claude/agents/step-$1.md"
    }

    new_agent 'triage'
    new_agent 'review-correctness'
    new_agent 'review-security'

    cat > "$repo/.claude/CLAUDE.md" <<'EOF'
# Правила проекта

Проверочный абзац фикстуры: правило записано в указателе один раз, и файл
шага на него ссылается, вместо того чтобы пересказывать его своими словами.

| Шаг | Правила |
|---|---|
| Триаж | docs/rules/triage.md |
| Ревью — корректность | docs/rules/review-correctness.md |
| Ревью — безопасность | docs/rules/review-security.md |
| Любой шаг | docs/rules/reading.md |
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
expect_output 'не упомянут ни одним определением'
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
# Сценарий 7. Абзац правила из указателя лежит копией в файле правил.
# Так выглядит «сделали правило видимым, положив рядом копию».
# ------------------------------------------------------------------
begin_case 'проверка 6: копия формулировки из указателя'
new_fixture
cat >> "$repo/docs/rules/triage.md" <<'EOF'

Проверочный абзац фикстуры: правило записано в указателе один раз, и файл
шага на него ссылается, вместо того чтобы пересказывать его своими словами.
EOF
run_check
expect_status 1
expect_output 'docs/rules/triage.md'
expect_output 'копия формулировки из .claude/CLAUDE.md'
expect_output 'Проверочный абзац фикстуры'
end_case

# ------------------------------------------------------------------
# Сценарий 8. Тот же файл правил ссылается на раздел вместо пересказа.
# Страхует от обратной ошибки: проверка, срабатывающая на законной ссылке,
# заставит завести исключение, а исключение снимает проверку целиком.
#
# Прозы здесь заведомо больше окна: на файле короче десяти слов окон не
# возникает вовсе, и сценарий зеленел бы не потому, что сравнение прошло, а
# потому, что сравнивать было нечего. Такое утверждение выполнится при любой
# реализации — тот самый бесполезный тест из docs/rules/review-correctness.md.
# ------------------------------------------------------------------
begin_case 'проверка 6: ссылка вместо копии — сверка молчит'
new_fixture
printf '# Триаж\n\nПять критериев разбора перечислены в разделе «Правила проекта» указателя, и здесь они не повторяются: у файла шага своя работа — сказать, на что смотреть, а не изложить правило второй раз.\n' \
    > "$repo/docs/rules/triage.md"
run_check
expect_status 0
expect_output 'сходятся'
end_case

# ------------------------------------------------------------------
# Сценарий 9. Общая формулировка короче окна — термин, а не копия.
# Так выглядит ложная тревога, ради которой заводят исключение.
# ------------------------------------------------------------------
begin_case 'проверка 6: короткое совпадение копией не считается'
new_fixture
printf '# Триаж\n\nКритерии триажа: правило записано в указателе один раз.\n' \
    > "$repo/docs/rules/triage.md"
run_check
expect_status 0
expect_output 'сходятся'
end_case

# ------------------------------------------------------------------
# Сценарий 10. Неизвестный каталог — код 2, а не ложное «сходится».
# ------------------------------------------------------------------
begin_case 'запуск: каталога нет — код 2 и понятное сообщение'
repo="$SANDBOX/нет-такого-каталога"
run_check
expect_status 2
expect_output 'Не найден каталог'
end_case

# ------------------------------------------------------------------
# Сценарий 11. Определение ссылается на файл, которого нет.
# Так выглядит переименование правил без правки определения — тот же
# случай, что сценарий 1, но со стороны локального режима.
# ------------------------------------------------------------------
begin_case 'проверка 1: ссылка из определения в пустоту'
new_fixture
sed -i 's#docs/rules/triage.md#docs/rules/triage-rules.md#' \
    "$repo/.claude/agents/step-triage.md"
run_check
expect_status 1
expect_output 'ссылка на несуществующие правила: docs/rules/triage-rules.md'
end_case

# ------------------------------------------------------------------
# Сценарий 12. Правила есть, промпт на них ссылается, определения нет.
# Так выглядит правило, которое существует только для цикла: локальная
# сессия шаг выполнит, но по правилам его никто не пройдёт.
# ------------------------------------------------------------------
begin_case 'проверка 2: правила знает только цикл'
new_fixture
printf '# Починка\n\nПравила.\n' > "$repo/docs/rules/fix.md"
printf '| Починка | docs/rules/fix.md |\n' >> "$repo/.claude/CLAUDE.md"
cat > "$repo/.github/workflows/agent-fix.yml" <<'EOF'
name: agent-fix
jobs:
  fix:
    steps:
      - name: Починка
        with:
          prompt: |
            Правила шага — `docs/rules/fix.md`.
            Чтение объёмного вывода — `docs/rules/reading.md`.
EOF
run_check
expect_status 1
expect_output 'не упомянут ни одним определением'
end_case

# ------------------------------------------------------------------
# Сценарий 13. Определение шага ссылается на чужие правила, но не на
# свои. Так выглядит определение, скопированное с соседнего шага.
# ------------------------------------------------------------------
begin_case 'проверка 3: определение шага не ссылается на свои правила'
new_fixture
sed -i 's#docs/rules/review-security.md#docs/rules/review-correctness.md#' \
    "$repo/.claude/agents/step-review-security.md"
run_check
expect_status 1
expect_output 'определение шага «review-security» не ссылается на свои правила'
end_case

# ------------------------------------------------------------------
# Сценарий 14. Общее правило пропало из одного определения. Именно так
# правило «поверх всех шагов» перестаёт действовать на одном из них —
# молча и без битых ссылок.
# ------------------------------------------------------------------
begin_case 'проверка 3а: определение без общего правила'
new_fixture
sed -i '/reading.md/d' "$repo/.claude/agents/step-triage.md"
run_check
expect_status 1
expect_output 'не ссылается на общее правило: docs/rules/reading.md'
end_case

# ------------------------------------------------------------------
# Сценарий 15. То же со стороны цикла: промпт без общего правила.
# Проверка одна на оба класса потребителей, и это проверяется.
# ------------------------------------------------------------------
begin_case 'проверка 3а: промпт без общего правила'
new_fixture
sed -i '/reading.md/d' "$repo/.github/workflows/agent-triage.yml"
run_check
expect_status 1
expect_output 'не ссылается на общее правило: docs/rules/reading.md'
end_case

# ------------------------------------------------------------------
# Сценарий 16. Подшаг без своего файла правил живёт по правилам шага:
# step-fix-flaky.md ссылается на fix.md, и это не расхождение.
#
# Обратная ошибка дороже прямой: проверка, требующая от каждого
# определения одноимённый файл правил, заставила бы завести
# docs/rules/fix-flaky.md — то есть размножить правила под каждый вызов
# модели вместо шага.
# ------------------------------------------------------------------
begin_case 'проверка 3: подшаг ссылается на правила своего шага — сверка молчит'
new_fixture
printf '# Починка\n\nПравила.\n' > "$repo/docs/rules/fix.md"
printf '| Починка | docs/rules/fix.md |\n' >> "$repo/.claude/CLAUDE.md"
cat > "$repo/.github/workflows/agent-fix.yml" <<'EOF'
name: agent-fix
jobs:
  fix:
    steps:
      - name: Починка
        with:
          prompt: |
            Правила шага — `docs/rules/fix.md`.
            Чтение объёмного вывода — `docs/rules/reading.md`.
EOF
printf -- '---\nname: step-fix\ntools: Read\n---\n\nПравила — `docs/rules/fix.md`, чтение — `docs/rules/reading.md`.\n' \
    > "$repo/.claude/agents/step-fix.md"
printf -- '---\nname: step-fix-flaky\ntools: Read\n---\n\nПравила — `docs/rules/fix.md`, раздел про случайное падение; чтение — `docs/rules/reading.md`.\n' \
    > "$repo/.claude/agents/step-fix-flaky.md"
run_check
expect_status 0
expect_output 'сходятся'
end_case

# ------------------------------------------------------------------
# Сценарий 17. Определений нет вовсе — код 2, а не ложное «сходится».
# Так выглядит клон, в котором каталог определений потеряли: сверка
# обязана сказать об этом, а не промолчать за отсутствием потребителей.
# ------------------------------------------------------------------
begin_case 'запуск: определений нет — код 2 и понятное сообщение'
new_fixture
rm -rf "$repo/.claude/agents"
run_check
expect_status 2
expect_output 'Не найдено ни одного .claude/agents/step-*.md'
end_case


# ------------------------------------------------------------------
# Сценарий 18. Определению выдан Bash, а граница команд не подключена.
#
# Так выглядит убранный при правке блок hooks: субагент получает оболочку
# целиком, ссылки на правила на месте, и до этой проверки всё зеленело.
# ------------------------------------------------------------------
begin_case 'проверка 3б: Bash выдан, граница команд не подключена'
new_fixture
cat > "$repo/.claude/agents/step-triage.md" <<'EOF'
---
name: step-triage
tools: Read, Glob, Grep, Bash
---

Правила шага — `docs/rules/triage.md`.
Чтение объёмного вывода — `docs/rules/reading.md`.
EOF
run_check
expect_status 1
expect_output 'граница команд не подключена'
end_case

# ------------------------------------------------------------------
# Сценарий 19. Хук подключён, но матчер не про оболочку — опечатка,
# после которой хук не срабатывает ни на одном вызове Bash.
# ------------------------------------------------------------------
begin_case 'проверка 3б: граница подключена без матчера Bash'
new_fixture
cat > "$repo/.claude/agents/step-triage.md" <<'EOF'
---
name: step-triage
tools: Read, Glob, Grep, Bash
hooks:
  PreToolUse:
    - matcher: Edit
      hooks:
        - type: command
          command: >-
            bash "$CLAUDE_PROJECT_DIR/scripts/step-bash-allow.sh"
            'gh issue view'
---

Правила шага — `docs/rules/triage.md`.
Чтение объёмного вывода — `docs/rules/reading.md`.
EOF
run_check
expect_status 1
expect_output 'без матчера Bash'
end_case

# ------------------------------------------------------------------
# Сценарий 20. Хук подключён, список разрешённого пуст. Хук и сам такое
# отвергнет, но узнать об этом на сверке дешевле, чем на первом вызове
# шага, который встанет целиком.
# ------------------------------------------------------------------
begin_case 'проверка 3б: граница подключена без списка команд'
new_fixture
cat > "$repo/.claude/agents/step-triage.md" <<'EOF'
---
name: step-triage
tools: Read, Glob, Grep, Bash
hooks:
  PreToolUse:
    - matcher: Bash
      hooks:
        - type: command
          command: bash "$CLAUDE_PROJECT_DIR/scripts/step-bash-allow.sh"
---

Правила шага — `docs/rules/triage.md`.
Чтение объёмного вывода — `docs/rules/reading.md`.
EOF
run_check
expect_status 1
expect_output 'без списка разрешённых команд'
end_case

# ------------------------------------------------------------------
# Сценарий 21. Обратная сторона: Bash выдан, граница подключена как
# положено — сверка молчит. Без этого сценария проверка 3б могла бы
# краснеть на правильном определении, и её начали бы обходить.
# ------------------------------------------------------------------
begin_case 'проверка 3б: Bash с подключённой границей — сверка молчит'
new_fixture
cat > "$repo/.claude/agents/step-triage.md" <<'EOF'
---
name: step-triage
tools: Read, Glob, Grep, Bash
hooks:
  PreToolUse:
    - matcher: Bash
      hooks:
        - type: command
          command: >-
            bash "$CLAUDE_PROJECT_DIR/scripts/step-bash-allow.sh"
            'gh issue view' 'grep'
---

Правила шага — `docs/rules/triage.md`.
Чтение объёмного вывода — `docs/rules/reading.md`.
EOF
run_check
expect_status 0
expect_output 'сходятся'
end_case


# ------------------------------------------------------------------
# Сценарий 22. Событие подменено: PostToolUse вместо PreToolUse.
#
# Путь границы на месте, матчер на месте, список на месте — и граница
# при этом выключена: PostToolUse срабатывает после исполнения и
# отказать уже не может. Проверка, которая смотрит только на путь,
# такое пропускает.
# ------------------------------------------------------------------
begin_case 'проверка 3б: граница подключена не к PreToolUse'
new_fixture
cat > "$repo/.claude/agents/step-triage.md" <<'EOF'
---
name: step-triage
tools: Read, Glob, Grep, Bash
hooks:
  PostToolUse:
    - matcher: Bash
      hooks:
        - type: command
          command: >-
            bash "$CLAUDE_PROJECT_DIR/scripts/step-bash-allow.sh"
            'gh issue view'
---

Правила шага — `docs/rules/triage.md`.
Чтение объёмного вывода — `docs/rules/reading.md`.
EOF
run_check
expect_status 1
expect_output 'хука PreToolUse нет'
end_case

# ------------------------------------------------------------------
# Сценарий 23. Поля tools нет вовсе. Тогда субагент наследует все
# инструменты, включая Bash, — и молчаливый пропуск такого определения
# снимает с него требование границы.
# ------------------------------------------------------------------
begin_case 'проверка 3б: определение без поля tools'
new_fixture
cat > "$repo/.claude/agents/step-triage.md" <<'EOF'
---
name: step-triage
description: Триаж
---

Правила шага — `docs/rules/triage.md`.
Чтение объёмного вывода — `docs/rules/reading.md`.
EOF
run_check
expect_status 1
expect_output 'нет поля tools'
end_case

# ------------------------------------------------------------------
# Сценарий 24. Списочная форма tools: Bash в ней тот же Bash.
# Признак, смотревший только на однострочную запись, пропускал такое
# определение целиком.
# ------------------------------------------------------------------
begin_case 'проверка 3б: Bash списком в tools — требование то же'
new_fixture
cat > "$repo/.claude/agents/step-triage.md" <<'EOF'
---
name: step-triage
tools:
  - Read
  - Bash
---

Правила шага — `docs/rules/triage.md`.
Чтение объёмного вывода — `docs/rules/reading.md`.
EOF
run_check
expect_status 1
expect_output 'граница команд не подключена'
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
