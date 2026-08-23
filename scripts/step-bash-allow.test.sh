#!/usr/bin/env bash
#
# Домовой — проверочные сценарии для границы команд Bash на шаге.
#
# ЗАЧЕМ
#
# Хук, который только пропускает, ничем не отличается от отсутствующего
# хука: разрешённая команда проходит и без него. Здесь для каждого запрета
# воспроизводится ровно тот обход, ради которого запрет написан, — и
# отдельно проверяется, что на законной команде хук молчит. Молчание тоже
# сценарий: хук, отказывающий на «dotnet build», остановит работу шага
# целиком, и это заметят позже и дороже.
#
# КАК ЗАПУСКАТЬ
#
#   bash scripts/step-bash-allow.test.sh
#
# Код возврата: 0 — все сценарии прошли, 1 — есть провалившиеся.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/step-bash-allow.sh"

if [ ! -f "$HOOK" ]; then
    printf 'Не найден %s\n' "$HOOK" >&2
    exit 2
fi

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
        printf '        вывод: %s\n' "$OUTPUT"
    fi
}

# Вход хука собирается через jq, а не склейкой строк: команда со кавычками
# внутри сломала бы склейку, и сценарий проверял бы не то, что задумано.
call_hook() {
    command="$1"
    shift
    payload="$(jq -n --arg cmd "$command" \
        '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$cmd}}')"
    OUTPUT="$(printf '%s' "$payload" | bash "$HOOK" "$@" 2>&1)"
    STATUS=$?
}

expect_status() {
    if [ "$STATUS" -ne "$1" ]; then
        fail_case "код возврата $STATUS, ожидался $1"
    fi
}

# Отказ проверяется разбором, а не поиском подстроки: поиск проходил и на
# невалидном JSON — то есть на ответе, который потребитель хука прочитать не
# может и трактует как «решения нет». Утверждение, зеленеющее на сломанном
# ответе, — тот самый бесполезный тест из docs/rules/review-correctness.md.
expect_deny() {
    if ! printf '%s' "$OUTPUT" \
        | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
        fail_case 'ожидался разбираемый отказ, а его нет'
    fi
}

expect_silence() {
    if [ -n "$OUTPUT" ]; then
        fail_case 'ожидалось молчание, а вывод не пуст'
    fi
}

expect_output() {
    # Ключ -- перед искомым обязателен: оно может начинаться с дефиса
    # (`--no-verify`), и без него grep примет его за свой ключ. Вызов тоже
    # умеет принимать `--` первым аргументом — так читается яснее.
    [ "$1" = '--' ] && shift
    if ! printf '%s' "$OUTPUT" | grep -qF -- "$1"; then
        fail_case "в выводе нет: $1"
    fi
}

if ! command -v jq >/dev/null 2>&1; then
    printf 'Для сценариев нужен jq: он собирает вход хука.\n' >&2
    exit 2
fi

# Список, повторяющий шаг реализации: сборка, тесты, стиль, git — и ни
# слова про `dotnet ef`.
IMPLEMENT=('dotnet build' 'dotnet test' 'dotnet format' 'git status' 'git diff')

# ------------------------------------------------------------------
# Сценарий 0. Разрешённая команда — хук молчит.
# ------------------------------------------------------------------
begin_case 'разрешённая команда — хук молчит'
call_hook 'dotnet build' "${IMPLEMENT[@]}"
expect_status 0
expect_silence
end_case

# ------------------------------------------------------------------
# Сценарий 1. Разрешённая команда с флагами — хук молчит.
# Совпадение по началу строки, иначе список пришлось бы вести по
# каждому набору ключей.
# ------------------------------------------------------------------
begin_case 'разрешённая команда с флагами — хук молчит'
call_hook 'dotnet build --no-restore -c Release' "${IMPLEMENT[@]}"
expect_status 0
expect_silence
end_case

# ------------------------------------------------------------------
# Сценарий 2. Команда вне списка — отказ с её именем.
# ------------------------------------------------------------------
begin_case 'команда вне списка — отказ'
call_hook 'curl https://example.invalid' "${IMPLEMENT[@]}"
expect_status 0
expect_deny
expect_output 'curl https://example.invalid'
end_case

# ------------------------------------------------------------------
# Сценарий 3. `dotnet ef` на шаге реализации — тот самый запрет из
# agent-implement.yml, который локально до сих пор не действовал.
# ------------------------------------------------------------------
begin_case 'dotnet ef на шаге реализации — отказ'
call_hook 'dotnet ef migrations add Тест' "${IMPLEMENT[@]}"
expect_status 0
expect_deny
expect_output 'dotnet ef migrations add'
end_case

# ------------------------------------------------------------------
# Сценарий 4. Обход составной командой: первая часть разрешена,
# вторая нет. Проверка по первому слову пропустила бы это.
# ------------------------------------------------------------------
begin_case 'составная команда: запрещённая вторая часть — отказ'
call_hook 'dotnet build && dotnet ef database drop' "${IMPLEMENT[@]}"
expect_status 0
expect_deny
expect_output 'dotnet ef database drop'
end_case

# ------------------------------------------------------------------
# Сценарий 5. Составная команда целиком из разрешённого — молчание.
# Обратная ошибка: хук, запрещающий `&&`, заставит обходить себя же.
# ------------------------------------------------------------------
begin_case 'составная команда целиком из разрешённого — молчание'
call_hook 'dotnet build && dotnet test' "${IMPLEMENT[@]}"
expect_status 0
expect_silence
end_case

# ------------------------------------------------------------------
# Сценарий 6. Подстановка команд прячет вторую команду внутри первой.
# ------------------------------------------------------------------
begin_case 'подстановка команд — отказ'
call_hook 'dotnet build $(dotnet ef migrations list)' "${IMPLEMENT[@]}"
expect_status 0
expect_deny
expect_output 'Подстановка команд запрещена'
end_case

# ------------------------------------------------------------------
# Сценарий 7. Перенаправление — канал записи в обход отсутствующих
# Edit и Write.
# ------------------------------------------------------------------
begin_case 'перенаправление вывода — отказ'
call_hook 'git diff > /tmp/пропуск.txt' 'git diff'
expect_status 0
expect_deny
expect_output 'Перенаправление вывода запрещено'
end_case

# ------------------------------------------------------------------
# Сценарий 8. Похожее имя с приклеенным хвостом не проходит:
# «git statuses» — не «git status».
# ------------------------------------------------------------------
begin_case 'похожая команда с приклеенным хвостом — отказ'
call_hook 'git statuses' "${IMPLEMENT[@]}"
expect_status 0
expect_deny
end_case

# ------------------------------------------------------------------
# Сценарий 9. Пустой список — отказ, а не выданный целиком Bash.
# Так выглядит определение, забывшее перечислить свои команды.
# ------------------------------------------------------------------
begin_case 'пустой список разрешённого — отказ'
call_hook 'dotnet build'
expect_status 0
expect_deny
expect_output 'не перечислил разрешённые команды'
end_case

# ------------------------------------------------------------------
# Сценарий 10. Событие не про Bash — хук молчит и уступает.
# ------------------------------------------------------------------
begin_case 'событие не про Bash — молчание'
OUTPUT="$(printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"README.md"}}' \
    | bash "$HOOK" 'dotnet build' 2>&1)"
STATUS=$?
expect_status 0
expect_silence
end_case

# ------------------------------------------------------------------
# Сценарий 11. Нет jq — отказ, а не молчаливый пропуск. Проверка,
# уступающая дорогу при собственной поломке, — видимость проверки.
# ------------------------------------------------------------------
begin_case 'без jq — отказ, а не пропуск'
# Оболочка вызывается абсолютным путём: с пустым PATH её саму было бы не
# найти, и сценарий падал бы до запуска хука.
OUTPUT="$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"dotnet build"}}' \
    | env PATH='' "$BASH" "$HOOK" 'dotnet build' 2>&1)"
STATUS=$?
expect_status 0
expect_deny
expect_output 'не найден jq'
end_case

# ------------------------------------------------------------------
# Сценарий 12. Во входе нет команды — отказ. Так выглядит смена
# контракта хука: поле переименовали, а хук зеленеет.
# ------------------------------------------------------------------
begin_case 'во входе нет команды — отказ'
OUTPUT="$(printf '%s' '{"tool_name":"Bash","tool_input":{}}' \
    | bash "$HOOK" 'dotnet build' 2>&1)"
STATUS=$?
expect_status 0
expect_deny
expect_output 'нет tool_input.command'
end_case

# ------------------------------------------------------------------
# Сценарий 13. Точка с запятой внутри сообщения коммита — часть текста,
# а не разделитель. Наивная замена разделителей ломается здесь на первом
# же настоящем коммите, и запрет начинают обходить.
# ------------------------------------------------------------------
begin_case 'точка с запятой внутри кавычек не делит команду'
call_hook 'git commit -m "fix: убрать X; добавить Y"' 'git commit'
expect_status 0
expect_silence
end_case

# ------------------------------------------------------------------
# Сценарий 14. Знак перенаправления внутри кавычек — тоже текст.
# ------------------------------------------------------------------
begin_case 'знак перенаправления внутри кавычек не считается записью'
call_hook 'git commit -m "было > стало"' 'git commit'
expect_status 0
expect_silence
end_case

# ------------------------------------------------------------------
# Сценарий 15. Обратная ошибка: разделитель после закрытой кавычки —
# настоящий разделитель, и вторая команда проверяется.
# ------------------------------------------------------------------
begin_case 'разделитель после закрытой кавычки делит команду'
call_hook 'git commit -m "правка" ; dotnet ef database drop' 'git commit'
expect_status 0
expect_deny
expect_output 'dotnet ef database drop'
end_case

# ------------------------------------------------------------------
# Сценарий 16. Фоновый запуск: результат не виден ни шагу, ни проверке.
# ------------------------------------------------------------------
begin_case 'фоновый запуск — отказ'
call_hook 'dotnet build &' "${IMPLEMENT[@]}"
expect_status 0
expect_deny
expect_output 'Фоновый запуск запрещён'
end_case

# ------------------------------------------------------------------
# Сценарий 17. Незакрытая кавычка: разобрать нельзя, пропускать нельзя.
# ------------------------------------------------------------------
begin_case 'незакрытая кавычка — отказ'
call_hook 'git commit -m "правка без конца' 'git commit'
expect_status 0
expect_deny
expect_output 'Незакрытая кавычка'
end_case

# ------------------------------------------------------------------
# Сценарий 18. Ключ --filter в кавычках: чтение одного упавшего теста
# из docs/rules/reading.md проходит целиком.
# ------------------------------------------------------------------
begin_case 'чтение одного теста по --filter — молчание'
call_hook 'dotnet test --no-build -c Release --filter "FullyQualifiedName~Имя"' "${IMPLEMENT[@]}"
expect_status 0
expect_silence
end_case

# ------------------------------------------------------------------
# Сценарий 19. Отбор по признакам в объёмном выводе: конвейер из двух
# разрешённых команд проходит, из разрешённой и чужой — нет.
# ------------------------------------------------------------------
begin_case 'конвейер из разрешённых команд — молчание'
call_hook 'gh run view 1 --log | grep -nE "error|Failed"' 'gh run view' 'grep'
expect_status 0
expect_silence
end_case

begin_case 'конвейер с чужой командой — отказ'
call_hook 'gh run view 1 --log | tee /tmp/лог.txt' 'gh run view' 'grep'
expect_status 0
expect_deny
expect_output 'tee'
end_case

# ------------------------------------------------------------------
# Сценарий 20. Подстановка процесса: команда прячется в «<(…)», и
# проверка по первому слову видит только разрешённый grep.
# ------------------------------------------------------------------
begin_case 'подстановка процесса — отказ'
call_hook 'grep -n error <(dotnet ef migrations list)' 'grep'
expect_status 0
expect_deny
expect_output 'Перенаправление ввода запрещено'
end_case

# ------------------------------------------------------------------
# Сценарий 21. Знак «меньше» внутри кавычек — снова текст, не канал.
# ------------------------------------------------------------------
begin_case 'знак «меньше» внутри кавычек не считается перенаправлением'
call_hook 'git commit -m "стало < было"' 'git commit'
expect_status 0
expect_silence
end_case

# ------------------------------------------------------------------
# Сценарий 22. Обратный слеш перед кавычкой — обход на один символ.
#
# Для bash `\'` это литеральная кавычка, и разбор продолжается вне кавычек.
# Разбор, который считал такую кавычку открывающей, объявлял весь хвост
# текстом и терял разом разделители, подстановку и перенаправление. Три
# сценария на три потерянные проверки.
# ------------------------------------------------------------------
begin_case 'экранированная кавычка не прячет разделитель'
call_hook "head -1 README.md \' ; dotnet ef database drop ; echo \'" 'head'
expect_status 0
expect_deny
expect_output 'dotnet ef database drop'
end_case

begin_case 'экранированная кавычка не прячет перенаправление'
call_hook "grep -n x README.md \' > out.txt \'" 'grep'
expect_status 0
expect_deny
expect_output 'Перенаправление вывода запрещено'
end_case

begin_case 'экранированная кавычка не прячет подстановку'
call_hook "grep -n x README.md \' \$(dotnet ef migrations list) \'" 'grep'
expect_status 0
expect_deny
expect_output 'Подстановка команд запрещена'
end_case

# ------------------------------------------------------------------
# Сценарий 23. Экранированный разделитель — это текст, а не разделитель:
# обратная ошибка к сценарию 22.
# ------------------------------------------------------------------
begin_case 'экранированная точка с запятой не делит команду'
call_hook 'grep -n a\;b README.md' 'grep'
expect_status 0
expect_silence
end_case

# ------------------------------------------------------------------
# Сценарий 24. Управляющий символ в команде: отказ обязан остаться
# разбираемым. Ручная сборка JSON здесь ломалась, и отказ читался как
# «решения нет» — то есть как разрешение.
# ------------------------------------------------------------------
begin_case 'таб в команде — отказ остаётся разбираемым JSON'
call_hook "$(printf 'dotnet\tef database drop')" 'dotnet build'
expect_status 0
expect_deny
end_case

# ------------------------------------------------------------------
# Сценарий 25. Флаги, которые список команд не видит: он смотрит на
# начало строки, а флаг стоит где угодно.
#
# Проверка идёт по словам нормализованной части, и сценарии перечисляют
# ровно то, чем её обходили: кавычки вокруг флага и внутри него,
# табуляция вместо пробела, однозначное сокращение длинной опции и
# короткий синоним. Голое написание — только первый из шести.
# ------------------------------------------------------------------
begin_case 'git commit --no-verify — отказ'
call_hook 'git commit --no-verify -m "мимо хуков"' 'git commit'
expect_status 0
expect_deny
expect_output -- '--no-verify'
end_case

begin_case 'флаг в кавычках — отказ'
call_hook 'git commit "--no-verify" -m x' 'git commit'
expect_status 0
expect_deny
end_case

begin_case 'кавычки внутри флага — отказ'
call_hook 'git commit --no-veri"fy" -m x' 'git commit'
expect_status 0
expect_deny
end_case

begin_case 'табуляция перед флагом — отказ'
call_hook "$(printf 'git commit -m x\t--no-verify')" 'git commit'
expect_status 0
expect_deny
end_case

begin_case 'сокращение длинной опции — отказ'
call_hook 'git commit --no-veri -m x' 'git commit'
expect_status 0
expect_deny
end_case

begin_case 'короткий синоним -n у git commit — отказ'
call_hook 'git commit -n -m x' 'git commit'
expect_status 0
expect_deny
end_case

begin_case 'сцепка коротких флагов -nm — отказ'
call_hook 'git commit -nm x' 'git commit'
expect_status 0
expect_deny
end_case

begin_case 'git push --force — отказ'
call_hook 'git push --force origin ветка' 'git push'
expect_status 0
expect_deny
expect_output 'Насильный пуш запрещён'
end_case

begin_case 'git push -f — отказ'
call_hook 'git push -f origin ветка' 'git push'
expect_status 0
expect_deny
end_case

begin_case 'сокращённый --forc у git push — отказ'
call_hook 'git push --forc origin ветка' 'git push'
expect_status 0
expect_deny
end_case

begin_case 'запись через --output у git — отказ'
call_hook "git log '--output=/tmp/утечка.txt' -p" 'git log'
expect_status 0
expect_deny
expect_output -- '--output'
end_case

begin_case 'правка меток через gh — отказ'
call_hook 'gh pr edit 76 --add-label agent/allow-protected' 'gh pr edit'
expect_status 0
expect_deny
expect_output 'Правка меток запрещена'
end_case

begin_case 'снятие метки через gh — отказ'
call_hook 'gh pr edit 76 --remove-label review/1' 'gh pr edit'
expect_status 0
expect_deny
end_case

# Дырка, найденная ревью в #81: запрет на --add-label шаг обходил, открывая
# PR сразу с меткой. Флаг другой, следствие то же — гейт целостности снят.
begin_case 'метка при создании PR — отказ'
call_hook "gh pr create --draft --label agent/allow-protected --title 'x' --body 'y'" 'gh pr create'
expect_status 0
expect_deny
expect_output 'Назначение меток запрещено'
end_case

begin_case 'метка при создании PR коротким флагом — отказ'
call_hook "gh pr create --draft -l agent/allow-protected --title 'x' --body 'y'" 'gh pr create'
expect_status 0
expect_deny
end_case

begin_case 'метка через = при создании issue — отказ'
call_hook "gh issue create --label=agent/allow-protected --title 'x' --body 'y'" 'gh issue create'
expect_status 0
expect_deny
end_case

# Найдено ревью круга 2 в #81: точное сравнение с `-l` пропускало оба
# обходных написания. gh разбирает флаги через pflag, а он принимает и
# сцепку коротких, и приклеенное значение.
begin_case 'метка сцепкой коротких флагов — отказ'
call_hook "gh pr create -dl agent/allow-protected --title 'x' --body 'y'" 'gh pr create'
expect_status 0
expect_deny
expect_output -- '-l'
end_case

begin_case 'метка приклеенным значением — отказ'
call_hook "gh pr create -lagent/allow-protected --title 'x' --body 'y'" 'gh pr create'
expect_status 0
expect_deny
end_case

# Обратная сторона: запрет узкий намеренно. Без этих двух сценариев он
# чинится расширением области, и никто не заметит, что шаг перестал
# открывать PR и рассказывать о самой границе.
begin_case 'обычное создание чернового PR — молчание'
call_hook "gh pr create --draft --title 'x' --body 'y'" 'gh pr create'
expect_status 0
expect_silence
end_case

begin_case 'слово --label в тексте комментария — молчание'
call_hook "gh pr comment 88 --body 'запрещены --label и -l'" 'gh pr comment'
expect_status 0
expect_silence
end_case

# ------------------------------------------------------------------
# Сценарий 26. Обратная сторона запретов: то, что шагам нужно каждый
# день, проходит. Без этих сценариев запрет флага чинится расширением
# запрета, а выдача — мёртвой записью в списке, чего никто не заметит.
# ------------------------------------------------------------------
begin_case 'dotnet build --output — молчание: запрет только у git и gh'
call_hook 'dotnet build --output bin/Release' 'dotnet build'
expect_status 0
expect_silence
end_case

begin_case 'обычный git commit — молчание'
call_hook 'git commit -m "правка по существу"' 'git commit'
expect_status 0
expect_silence
end_case

begin_case 'обычный git push — молчание'
call_hook 'git push origin ветка' 'git push'
expect_status 0
expect_silence
end_case

begin_case 'правка тела PR через gh pr edit — молчание'
call_hook 'gh pr edit 76 --body-file /tmp/body.md' 'gh pr edit'
expect_status 0
expect_silence
end_case

begin_case 'ключи grep с дефисами — молчание'
call_hook 'grep -n --color=never образец README.md' 'grep'
expect_status 0
expect_silence
end_case

begin_case 'поимённый сценарий обвязки — молчание'
call_hook 'bash scripts/rules-sync.test.sh' 'bash scripts/rules-sync.test.sh' 'bash scripts/guard.test.sh'
expect_status 0
expect_silence
end_case

begin_case 'посторонний скрипт под scripts/ — отказ'
call_hook 'bash scripts/чужой.sh' 'bash scripts/rules-sync.test.sh'
expect_status 0
expect_deny
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

printf 'Граница команд шага ведёт себя как задумано.\n'
exit 0
