#!/usr/bin/env bash
#
# Домовой — проверочные сценарии для сверки обвязки scripts/wiring.sh.
#
# ЗАЧЕМ
#
# Сверка, которую никто не проверял, зеленела бы и при пустом каталоге
# скриптов. Здесь для каждой её проверки собирается временный репозиторий, в
# нём воспроизводится ровно то расхождение, ради которого проверка написана, и
# сверяется код возврата с текстом вывода.
#
# Отдельно проверяется главное: на подключённом наборе сверка молчит. Проверка,
# шумящая на нормальной работе, перестаёт читаться.
#
# КАК ЗАПУСКАТЬ
#
#   bash scripts/wiring.test.sh
#
# Код возврата: 0 — все сценарии прошли, 1 — есть провалившиеся.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECK="$SCRIPT_DIR/wiring.sh"

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
repo=''

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

expect_no_output() {
    if printf '%s' "$OUTPUT" | grep -qF "$1"; then
        fail_case "в выводе есть лишнее: $1"
    fi
}

# Подключённый набор: два скрипта, оба вызываются, плюс один освобождённый с
# причиной. Формы вызова намеренно разные — простая, с префиксом переменной
# окружения и через ./: сверка обязана засчитывать все три.
new_fixture() {
    repo="$SANDBOX/repo-$RANDOM$RANDOM"
    mkdir -p "$repo/.github/workflows" "$repo/scripts"

    printf '#!/usr/bin/env bash\necho гейт\n' > "$repo/scripts/guard.sh"
    printf '#!/usr/bin/env bash\necho сценарии\n' > "$repo/scripts/guard.test.sh"

    cat > "$repo/scripts/manual.sh" <<'EOF'
#!/usr/bin/env bash
#
# БЕЗ ОБВЯЗКИ: ручной инструмент под токеном с правом записи, в CI ему делать
# нечего — он меняет настройки репозитория.
#
echo руками
EOF

    cat > "$repo/.github/workflows/ci-fast.yml" <<'EOF'
name: CI (fast)
jobs:
  checks:
    steps:
      - name: Гейт
        run: bash scripts/guard.sh "origin/$BASE_REF"
      - name: Сценарии гейта
        run: |
          BASE=main bash scripts/guard.test.sh
EOF
}

# ------------------------------------------------------------------
# Сценарий 0. Подключённый набор — сверка молчит.
# ------------------------------------------------------------------
begin_case 'подключённый набор — сверка молчит'
new_fixture
run_check
expect_status 0
expect_output 'Обвязка сходится'
end_case

# ------------------------------------------------------------------
# Сценарий 1. Скрипт есть, вызова нет.
#
# Так выглядит тихо удалённый шаг: проверка лежит в репозитории, выглядит
# работающей и не запускается никогда.
# ------------------------------------------------------------------
begin_case 'проверка 1: скрипт не вызывается ни одним workflow'
new_fixture
sed -i '/guard.test.sh/d' "$repo/.github/workflows/ci-fast.yml"
run_check
expect_status 1
expect_output 'ни один workflow не вызывает: scripts/guard.test.sh'
end_case

# ------------------------------------------------------------------
# Сценарий 2. Упоминание в комментарии вызовом не считается.
#
# Комментарий рядом с удалённым шагом — самый правдоподобный способ обмануть
# текстовый поиск: имя в файле есть, запуска нет.
# ------------------------------------------------------------------
begin_case 'проверка 1: упоминание в комментарии — не вызов'
new_fixture
sed -i 's|BASE=main bash scripts/guard.test.sh|# раньше здесь было: bash scripts/guard.test.sh|' \
    "$repo/.github/workflows/ci-fast.yml"
run_check
expect_status 1
expect_output 'ни один workflow не вызывает: scripts/guard.test.sh'
end_case

# ------------------------------------------------------------------
# Сценарий 3. Освобождение с причиной — сверка молчит и говорит, что знает
# о таком скрипте.
# ------------------------------------------------------------------
begin_case 'освобождение с причиной — скрипт назван освобождённым'
new_fixture
run_check
expect_status 0
expect_output 'scripts/manual.sh'
expect_output 'ручной инструмент'
end_case

# ------------------------------------------------------------------
# Сценарий 4. Освобождение без причины.
#
# Маркер без объяснения — то же молчаливое исключение, только с оправданием.
# ------------------------------------------------------------------
begin_case 'проверка 2: маркер освобождения без причины'
new_fixture
printf '#!/usr/bin/env bash\n#\n# БЕЗ ОБВЯЗКИ:\n#\necho руками\n' \
    > "$repo/scripts/manual.sh"
run_check
expect_status 1
expect_output 'маркер освобождения без причины'
end_case

# ------------------------------------------------------------------
# Сценарий 5. Причина есть, но отписка.
# ------------------------------------------------------------------
begin_case 'проверка 2: причина в три буквы — не причина'
new_fixture
printf '#!/usr/bin/env bash\n#\n# БЕЗ ОБВЯЗКИ: так\n#\necho руками\n' \
    > "$repo/scripts/manual.sh"
run_check
expect_status 1
expect_output 'маркер освобождения без причины'
end_case

# ------------------------------------------------------------------
# Сценарий 6. Зеркальный случай: workflow зовёт скрипт, которого нет.
#
# Так выглядит переименование скрипта без правки шага. Шаг красный в CI, но
# узнать об этом можно только запустив весь пайплайн.
# ------------------------------------------------------------------
begin_case 'проверка 3: workflow вызывает несуществующий скрипт'
new_fixture
mv "$repo/scripts/guard.sh" "$repo/scripts/gate.sh"
sed -i 's#^      - name: Гейт#      - name: Гейт\n        run: bash scripts/gate.sh base#' \
    "$repo/.github/workflows/ci-fast.yml"
run_check
expect_status 1
expect_output 'вызов несуществующего скрипта: scripts/guard.sh'
end_case

# ------------------------------------------------------------------
# Сценарий 7. Освобождённый скрипт, который всё-таки вызывается.
#
# Это не нарушение, а устаревшее освобождение: маркер пора снять. Сверка
# говорит об этом и не краснеет — иначе она заставляла бы выбирать между
# правдой в шапке и зелёным CI.
# ------------------------------------------------------------------
begin_case 'освобождённый скрипт вызывается — сверка предупреждает, но не краснеет'
new_fixture
printf '      - name: Руками\n        run: bash scripts/manual.sh\n' \
    >> "$repo/.github/workflows/ci-fast.yml"
run_check
expect_status 0
expect_output 'освобождение устарело'
end_case

# ------------------------------------------------------------------
# Сценарий 8. Ошибка запуска: нет каталога скриптов.
# ------------------------------------------------------------------
begin_case 'запуск: нет каталога скриптов — код 2'
repo="$SANDBOX/пусто-$RANDOM"
mkdir -p "$repo/.github/workflows"
run_check
expect_status 2
expect_output 'Не найден каталог скриптов'
end_case

# ------------------------------------------------------------------
# Сценарий 9. Ошибка запуска: нет каталога workflow.
#
# Пустой каталог workflow — не «всё сходится», а сломанное окружение: без
# него сверка объявила бы неподключённым каждый скрипт.
# ------------------------------------------------------------------
begin_case 'запуск: нет каталога workflow — код 2'
repo="$SANDBOX/без-workflow-$RANDOM"
mkdir -p "$repo/scripts"
printf '#!/usr/bin/env bash\necho x\n' > "$repo/scripts/x.sh"
run_check
expect_status 2
expect_output 'Не найдено ни одного workflow'
end_case

# ------------------------------------------------------------------
# Сценарий 10. Сама сверка и её сценарии — часть проверяемого набора.
#
# Собственный шаг сверка защитить не может: удалили его — никто не запустится.
# А вот удаление шага с её харнессом она поймать обязана, иначе харнесс
# оказался бы в том же положении, из которого эта задача вытаскивала
# guard.test.sh.
# ------------------------------------------------------------------
begin_case 'сверка и её харнесс сами входят в проверяемый набор'
new_fixture
printf '#!/usr/bin/env bash\necho сверка\n' > "$repo/scripts/wiring.sh"
printf '#!/usr/bin/env bash\necho сценарии сверки\n' > "$repo/scripts/wiring.test.sh"
printf '      - name: Обвязка\n        run: bash scripts/wiring.sh\n' \
    >> "$repo/.github/workflows/ci-fast.yml"
run_check
expect_status 1
expect_output 'ни один workflow не вызывает: scripts/wiring.test.sh'
expect_no_output 'ни один workflow не вызывает: scripts/wiring.sh'
end_case

# ------------------------------------------------------------------
# Сценарий 11. Маркер, приведённый в шапке как пример, объявлением не
# считается.
#
# Найдено на живом репозитории: сверка освободила от обвязки сама себя —
# в её шапке маркер показан как образец. Объявление — комментарий,
# начинающийся с маркера, а не любое его упоминание.
# ------------------------------------------------------------------
begin_case 'маркер в примере документации — не объявление'
new_fixture
cat > "$repo/scripts/guard.test.sh" <<'EOF'
#!/usr/bin/env bash
#
# Скрипт, которому в CI делать нечего, объявляет это так:
#
#   # БЕЗ ОБВЯЗКИ: причина, по которой запускать его в CI незачем.
#
echo сценарии
EOF
sed -i '/guard.test.sh/d' "$repo/.github/workflows/ci-fast.yml"
run_check
expect_status 1
expect_output 'ни один workflow не вызывает: scripts/guard.test.sh'
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

printf 'Сверка обвязки ведёт себя как задумано.\n'
exit 0
