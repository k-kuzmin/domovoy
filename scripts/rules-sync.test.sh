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

# Обратное утверждение. Нужно там, где проверяется не сработавшая проверка:
# «сверка промолчала об этом» кодом возврата не выражается, потому что
# промолчать она могла и по другой причине.
expect_absent() {
    if printf '%s' "$OUTPUT" | grep -qF -- "$1"; then
        fail_case "в выводе не должно быть: $1"
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

    # Служебный агент — определение без префикса step-. Шага работы за ним
    # нет, значит нет ни своего файла правил, ни промпта в цикле; ссылка на
    # правило поверх всех шагов требуется наравне с шагами.
    #
    # Он лежит в базовом наборе, а не только в своих сценариях: класс
    # выводится из имени, и каждый сценарий обязан оставаться зелёным при
    # соседстве двух классов в одном каталоге.
    printf -- '---\nname: scout\ntools: Read\n---\n\nЧтение объёмного вывода — `docs/rules/reading.md`.\n' \
        > "$repo/.claude/agents/scout.md"

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


# ------------------------------------------------------------------
# Сценарий 25. Незакавыченное значение верхнего уровня содержит «: ».
#
# Так выглядит правка описания шага, после которой фронтматер перестаёт
# разбираться: для YAML это вложенное отображение, а не текст, харнесс
# определение не загружает и тип шага пропадает из доступных. Наблюдено на
# #97 — все проверки репозитория при этом возвращали ноль.
# ------------------------------------------------------------------
begin_case 'проверка 3в: незакавыченный скаляр с двоеточием в значении'
new_fixture
cat > "$repo/.claude/agents/step-triage.md" <<'EOF'
---
name: step-triage
description: Триаж задачи — вердикт о пригодности и то, чего в задаче нет: вопросы владельцу.
tools: Read
---

Правила шага — `docs/rules/triage.md`.
Чтение объёмного вывода — `docs/rules/reading.md`.
EOF
run_check
expect_status 1
expect_output '.claude/agents/step-triage.md'
expect_output 'незакавыченное значение ключа «description»'
end_case

# ------------------------------------------------------------------
# Сценарий 26. То же двоеточие, но значение в кавычках — законная запись.
#
# Различающий случай, ради которого правило звучит «незакавыченный скаляр», а
# не «скаляр»: в кавычках двоеточие для YAML — часть текста, а не разделитель.
# Правило без этой оговорки роняло бы законную запись, и неважно, лежит такая
# в репозитории сегодня или появится завтра: фикстура проверяет правило, а не
# состояние дерева.
# ------------------------------------------------------------------
begin_case 'проверка 3в: закавыченный скаляр с двоеточием — сверка молчит'
new_fixture
cat > "$repo/.claude/agents/step-triage.md" <<'EOF'
---
name: step-triage
description: 'Триаж задачи — вердикт о пригодности и то, чего в задаче нет: вопросы владельцу.'
tools: Read
---

Правила шага — `docs/rules/triage.md`.
Чтение объёмного вывода — `docs/rules/reading.md`.
EOF
run_check
expect_status 0
expect_output 'сходятся'
end_case

# ------------------------------------------------------------------
# Сценарий 27. Двоеточие во вложенном значении — не верхний уровень.
#
# Проверка смотрит только ключи нулевого отступа, и это её названная
# граница: команда хука с двоеточием законна и краснеть на ней нельзя.
# Признак без привязки к началу строки завалил бы каждое определение с
# подключённой границей команд.
# ------------------------------------------------------------------
begin_case 'проверка 3в: двоеточие во вложенном значении — сверка молчит'
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
# Сценарий 28. Блок hooks: разбирается как YAML, но вложенный hooks: лежит
# рядом с PreToolUse:, а не внутри элемента с матчером.
#
# Проверка 3б такое определение проходит целиком: PreToolUse: на месте, строка
# «- matcher: Bash» на месте, вызов границы и список команд на месте — она
# ищет строки текстом и к отступу нечувствительна. Харнесс при этом читает
# hooks.PreToolUse[].hooks, не находит там ничего и хук не подключает. Отказ
# открытый: шаг доступен, Bash выдан, границы команд нет.
# ------------------------------------------------------------------
begin_case 'проверка 3г: вложенный hooks: лежит вне элемента с матчером'
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
expect_status 1
expect_output '.claude/agents/step-triage.md'
expect_output 'вне списка под ключом PreToolUse'
end_case

# ------------------------------------------------------------------
# Сценарий 29. Весь блок хука уехал на уровень ниже — лежит под чужим
# ключом. YAML это разбирает, харнесс на верхнем уровне hooks: не находит.
# ------------------------------------------------------------------
begin_case 'проверка 3г: блок hooks: не на верхнем уровне фронтматера'
new_fixture
cat > "$repo/.claude/agents/step-triage.md" <<'EOF'
---
name: step-triage
tools: Read, Glob, Grep, Bash
settings:
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
expect_status 1
expect_output 'не лежит на верхнем уровне'
end_case

# ------------------------------------------------------------------
# Сценарий 30. Структура безупречна, но вызов границы висит на другом
# событии: под PreToolUse: пустышка, а step-bash-allow.sh — под PostToolUse:.
#
# Проверка 3б смотрит текст от первого PreToolUse: до конца фронтматера, и
# литерал границы находит в чужом блоке. Поэтому 3г ищет не «где-то есть
# правильная цепочка», а цепочку того самого элемента, в котором лежит вызов
# границы: иначе достаточно приписать рядом безупречный по форме блок.
# ------------------------------------------------------------------
begin_case 'проверка 3г: вызов границы подвешен к другому событию'
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
          command: echo
  PostToolUse:
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
expect_status 1
expect_output 'вне списка под ключом PreToolUse'
end_case

# ------------------------------------------------------------------
# Сценарий 31. Законный вариант записи: элементы списка стоят на том же
# отступе, что и ключ, которому принадлежат.
#
# Для YAML это ровно та же структура, что и с отступом, и харнесс её грузит.
# Правило «элемент вложен глубже ключа» завалило бы такую запись — а проверка,
# краснеющая на правильном определении, кончается тем, что её обходят.
# ------------------------------------------------------------------
begin_case 'проверка 3г: список на отступе ключа — сверка молчит'
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
# Сценарий 32. Матчер опознан по имени ключа, а не по значению: под
# PreToolUse: два элемента, у первого matcher: Bash с безобидной командой, у
# второго matcher: Read — и вызов границы лежит именно во втором.
#
# Проверка 3б сверяет матчер текстом по всему блоку и находит «- matcher: Bash»
# в чужом элементе. Цепочка 3г при этом считается от вызова границы и упирается
# в элемент с matcher: Read — если значение не сверять, элемент считается
# годным. Харнесс вешает границу на Read: Bash у шага есть, границы команд нет.
# ------------------------------------------------------------------
begin_case 'проверка 3г: вызов границы висит на матчере другого инструмента'
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
          command: echo
    - matcher: Read
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
expect_status 1
expect_output '.claude/agents/step-triage.md'
expect_output 'нет matcher: Bash'
end_case

# ------------------------------------------------------------------
# Сценарий 33. Зеркало сценария 29: блок hooks: на верхнем уровне, но
# PreToolUse: лежит не прямо под ним, а через промежуточный ключ.
#
# YAML это разбирает, 3б проходит целиком, а харнесс читает hooks.PreToolUse и
# глубже не заглядывает — хук не подключается. Отказ открытый, как и в
# сценарии 32.
# ------------------------------------------------------------------
begin_case 'проверка 3г: PreToolUse: не прямой потомок блока hooks:'
new_fixture
cat > "$repo/.claude/agents/step-triage.md" <<'EOF'
---
name: step-triage
tools: Read, Glob, Grep, Bash
hooks:
  settings:
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
expect_status 1
expect_output '.claude/agents/step-triage.md'
expect_output 'глубже прямого потомка'
end_case

# ------------------------------------------------------------------
# Сценарий 34. Комментарий YAML в колонке 0 внутри фронтматера — законная
# запись, и определение с ней харнесс грузит.
#
# Для обхода 3г такая строка выглядит ключом нулевого отступа и обрывает его:
# поиск PreToolUse: идёт, пока строки вложены в блок hooks:. Проверка,
# краснеющая на комментарии, кончается тем, что комментарии перестают писать
# либо саму проверку обходят.
# ------------------------------------------------------------------
begin_case 'проверка 3г: комментарий в колонке 0 — сверка молчит'
new_fixture
cat > "$repo/.claude/agents/step-triage.md" <<'EOF'
---
name: step-triage
tools: Read, Glob, Grep, Bash
hooks:
# Граница команд шага: список правится вместе с правилами шага.
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
# Сценарий 35. В каталоге определений живут два класса: шаги и служебные
# агенты. Согласованный набор с обоими — сверка молчит, а служебные
# посчитаны отдельным числом.
#
# Счётчик в отчёте — не украшение: до деления каталога файл вне шаблона
# step-*.md не проверялся вовсе и о его существовании прогон не сообщал
# ничем. Ноль в этой позиции при лежащем в каталоге определении и означал
# бы возврат к той же дыре.
# ------------------------------------------------------------------
begin_case 'служебный агент: согласованный набор — сверка молчит и считает служебных'
new_fixture
run_check
expect_status 0
expect_output 'служебные агенты: 1'
expect_output 'сходятся'
end_case

# ------------------------------------------------------------------
# Сценарий 36. Служебному агенту выдан Bash, а граница команд не
# подключена. То же расхождение, что в сценарии 18, но у второго класса:
# до деления каталога оно не проверялось ничем.
# ------------------------------------------------------------------
begin_case 'служебный агент: Bash выдан, граница команд не подключена'
new_fixture
cat > "$repo/.claude/agents/scout.md" <<'EOF'
---
name: scout
tools: Read, Grep, Bash
---

Чтение объёмного вывода — `docs/rules/reading.md`.
EOF
run_check
expect_status 1
expect_output 'граница команд не подключена'
end_case

# ------------------------------------------------------------------
# Сценарий 37. Ссылка из служебного определения ведёт в пустоту.
#
# Проверка 1 распространена на оба класса, а не только проверки формы:
# битая ссылка на правила стоит одинаково, кем бы её ни оставили.
# ------------------------------------------------------------------
begin_case 'служебный агент: ссылка на правила, которых нет в дереве'
new_fixture
printf -- '---\nname: scout\ntools: Read\n---\n\nПравила — `docs/rules/scout.md`, чтение — `docs/rules/reading.md`.\n' \
    > "$repo/.claude/agents/scout.md"
run_check
expect_status 1
expect_output 'ссылка на несуществующие правила: docs/rules/scout.md'
end_case

# ------------------------------------------------------------------
# Сценарий 38. У служебного определения нет ссылки на общее правило.
# Требование одинаковое у обоих классов: объёмный вывод попадается и
# служебному агенту, а правило, которого он не откроет, для него не
# существует.
# ------------------------------------------------------------------
begin_case 'служебный агент: нет ссылки на общее правило'
new_fixture
printf -- '---\nname: scout\ntools: Read\n---\n\nВыжимка по трекеру.\n' \
    > "$repo/.claude/agents/scout.md"
run_check
expect_status 1
expect_output 'не ссылается на общее правило: docs/rules/reading.md'
end_case

# ------------------------------------------------------------------
# Сценарий 39. Правил своего шага со служебного агента не требуется:
# шага за ним нет.
#
# Проверка кодом возврата здесь недостаточна — промолчать сверка могла бы
# и по другой причине, поэтому сверяется отсутствие самого сообщения.
# Имя выбрано так, чтобы шаг из него выводился: `issue-scout` даёт шаг
# «issue-scout», и распространённая на служебный класс проверка 3
# потребовала бы docs/rules/issue-scout.md.
# ------------------------------------------------------------------
begin_case 'служебный агент: правил своего шага с него не требуется'
new_fixture
printf -- '---\nname: issue-scout\ntools: Read\n---\n\nЧтение объёмного вывода — `docs/rules/reading.md`.\n' \
    > "$repo/.claude/agents/issue-scout.md"
rm -f "$repo/.claude/agents/scout.md"
run_check
expect_status 0
expect_absent 'нет файла правил'
end_case

# ------------------------------------------------------------------
# Сценарий 40. Правило, упомянутое только служебным агентом, по-прежнему
# краснеет.
#
# Это половина проверки 2, которую деление на классы могло ослабить
# молча: массив там остаётся из шагов. Правило, о котором знает цикл и
# служебный агент, но не знает ни один шаг, для живого режима не
# существует ровно так же, как и раньше.
# ------------------------------------------------------------------
begin_case 'служебный агент: правило, упомянутое только им, всё равно краснеет'
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
printf -- '---\nname: scout\ntools: Read\n---\n\nПравила починки — `docs/rules/fix.md`, чтение — `docs/rules/reading.md`.\n' \
    > "$repo/.claude/agents/scout.md"
run_check
expect_status 1
expect_output 'не упомянут ни одним определением'
end_case

# ------------------------------------------------------------------
# Сценарий 41. Служебное имя, затеняющее общее правило, не снимает
# требование ссылки с шагов.
#
# Множество общих правил выводится проходом по шагам. Пущенный по обоим
# классам, тот же проход отдал бы reading.md служебному агенту с именем
# `reading-scout` — правило стало бы «принадлежащим шагу», перестало быть
# общим, и обязательность ссылки на него молча снялась бы со всех
# потребителей, не уронив ни одного прогона.
# ------------------------------------------------------------------
begin_case 'служебный агент: имя, затеняющее общее правило, не снимает его с шагов'
new_fixture
rm -f "$repo/.claude/agents/scout.md"
printf -- '---\nname: reading-scout\ntools: Read\n---\n\nЧтение объёмного вывода — `docs/rules/reading.md`.\n' \
    > "$repo/.claude/agents/reading-scout.md"
printf -- '---\nname: step-triage\ntools: Read\n---\n\nПравила шага — `docs/rules/triage.md`.\n' \
    > "$repo/.claude/agents/step-triage.md"
run_check
expect_status 1
expect_output 'не ссылается на общее правило: docs/rules/reading.md'
end_case

# ------------------------------------------------------------------
# Сценарий 42. Опечатка в префиксе имени переводит шаг в служебные.
#
# `stpe-triage.md` для сверки уже не шаг, и требование ссылки на свои
# правила с него снимается. Ловится это не по имени, а последствием:
# правила шага перестают быть упомянуты хотя бы одним определением шага,
# и краснеет проверка 2.
# ------------------------------------------------------------------
begin_case 'служебный агент: опечатка в префиксе имени шага ловится проверкой 2'
new_fixture
mv "$repo/.claude/agents/step-triage.md" "$repo/.claude/agents/stpe-triage.md"
run_check
expect_status 1
expect_output 'не упомянут ни одним определением'
end_case

# ------------------------------------------------------------------
# Сценарий 43. Пустой список служебных агентов — законное состояние.
#
# Каталог без единого нешагового определения выглядит как сломанный клон,
# но им не является: шаги на месте, а служебный агент в проекте появился
# позже них и завтра может быть вынесен. Кода возврата за пустой список
# служебных нет намеренно — в отличие от пустого списка шагов, за который
# сверка выходит кодом 2 (сценарий 17). Проверяется и число в шапке: ноль
# в этой позиции — состояние, а не отказ печатать.
#
# Чего этот сценарий не проверяет — предел, который важнее его самого.
# Единственное место, где состояние что-то значит для кода, —
# развёртывание пустого массива в rules-sync.sh (`${services[@]+…}`).
# Расхождение, от которого эта форма защищает, существует только на bash
# до 4.4: там пустой `"${x[@]}"` под `set -u` — ошибка, а не пустота.
# И CI, и Git Bash на машине разработчика — bash 5, поэтому откат к
# простому `"${services[@]}"` не уронит ни этот сценарий, ни любой другой
# исполнимый здесь. Строка в сверке — переносимость на bash 3.2 (системный
# на macOS), а не наблюдаемая отсюда регрессия; сценарий закрепляет
# наблюдаемый контракт «пустой список законен», и путать одно с другим
# нельзя.
# ------------------------------------------------------------------
begin_case 'служебный агент: пустой список служебных — законное состояние'
new_fixture
rm -f "$repo/.claude/agents/scout.md"
run_check
expect_status 0
expect_output 'служебные агенты: 0'
expect_output 'сходятся'
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
