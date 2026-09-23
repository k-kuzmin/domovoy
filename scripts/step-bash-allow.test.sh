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

# `gh pr edit` выдан шагу реализации ради тела чернового PR
# (step-implement.md), и запрет стоит на той же команде. Короткие флаги у неё
# буквы l не содержат — но проверяется это здесь, а не рассуждением: сузить
# запрет до подкоманд и уронить шаг на его же ежедневной команде — одна правка.
begin_case 'правка тела PR коротким флагом — молчание'
call_hook "gh pr edit 88 -b 'текст тела'" 'gh pr edit'
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

# ------------------------------------------------------------------
# Сценарий 27. Построчные замечания ревью: поимённый сценарий выдан,
# сам `gh api` — нет.
#
# Эндпоинт `repos/{owner}/{repo}/pulls/<номер>/comments` — единственный
# источник построчных замечаний, и соблазн выдать шагу `gh api` прямой. Выдать
# его нельзя: у команды есть `-X`, `--method` и `--input`, а у gh граница
# разбирает только указатель репозитория, адрес и выражение над ответом
# (сценарий 28) — метод и тело запроса она не видит. Запрет записан строкой
# «Новая команда, нужная шагу» в .claude/CLAUDE.md. Поэтому граница остаётся
# поимённой: `gh api` живёт внутри scripts/review-comments.sh, а наружу выдана
# одна строка.
#
# Обе половины нужны вместе. Без отказа запрет держался бы на том, что команду
# просто не вписали в список; без молчания поимённая выдача выглядела бы
# работающей, оставаясь мёртвой записью, — и шаг узнал бы об этом на первом же
# PR с замечаниями.
# ------------------------------------------------------------------
FIX=('gh pr view' 'gh pr diff' 'gh pr checks' 'gh pr comment' 'gh run view'
    'bash scripts/review-comments.sh')

begin_case 'gh api на шаге починки — отказ'
call_hook 'gh api repos/{owner}/{repo}/pulls/122/comments' "${FIX[@]}"
expect_status 0
expect_deny
expect_output 'gh api repos/{owner}/{repo}/pulls/122/comments'
end_case

begin_case 'gh api с методом записи на шаге починки — отказ'
call_hook 'gh api --method POST repos/{owner}/{repo}/issues/123/comments' "${FIX[@]}"
expect_status 0
expect_deny
end_case

begin_case 'поимённый сценарий чтения замечаний — молчание'
call_hook 'bash scripts/review-comments.sh 122' "${FIX[@]}"
expect_status 0
expect_silence
end_case

# ------------------------------------------------------------------
# Сценарий 28. Разбор аргументов gh (#119): указатель репозитория, адрес
# github.com, выражение над ответом, поиск без своего репозитория.
#
# Свой репозиторий граница выводит из origin каталога CLAUDE_PROJECT_DIR —
# той же переменной, по которой хук находит себя в бою. Поэтому сценарии
# собирают временные репозитории с поддельным origin и передают каталог
# явно, а не полагаются на окружение сессии.
#
# Поддельный слаг — ASCII и содержит q и t: слаг GitHub состоит из
# [A-Za-z0-9._-], а буквы q и t проверяют, что значение после R в сцепке
# коротких флагов не принимается за -q или -t. Кириллица — только в чужих
# значениях, которые обязаны получить отказ.
# ------------------------------------------------------------------
SLUG='acme-qt/tool-repo'
SLUG_UPPER='ACME-QT/Tool-Repo'
FOREIGN='чужой/репо'

ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPOS="$(mktemp -d)"
trap 'rm -rf "$REPOS"' EXIT

make_repo() {
    local dir="$REPOS/$1"
    mkdir -p "$dir"
    git -C "$dir" init -q
    if [ -n "${2:-}" ]; then
        git -C "$dir" remote add origin "$2"
    fi
    printf '%s' "$dir"
}

FAKE="$(make_repo fake "https://github.com/$SLUG.git")"
# Каталог без origin — именно репозиторий после git init: из просто
# временного каталога git поднялся бы к родителю и нашёл бы чужой origin.
NO_ORIGIN="$(make_repo no-origin)"
OTHER_HOST="$(make_repo other-host "https://gitlab.example.invalid/$SLUG.git")"

call_hook_in() {
    local dir="$1" cmd="$2"
    shift 2
    local payload
    payload="$(jq -n --arg cmd "$cmd" \
        '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$cmd}}')"
    OUTPUT="$(printf '%s' "$payload" | env "CLAUDE_PROJECT_DIR=$dir" bash "$HOOK" "$@" 2>&1)"
    STATUS=$?
}

# Внутри одного случая проверяется несколько написаний: каждое называется
# в сообщении, чтобы провал указывал на форму, а не на случай целиком.
deny_in() {
    local dir="$1" cmd="$2"
    shift 2
    call_hook_in "$dir" "$cmd" "$@"
    if [ "$STATUS" -ne 0 ] || ! printf '%s' "$OUTPUT" \
        | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
        fail_case "ожидался разбираемый отказ: $cmd"
    fi
}

silent_in() {
    local dir="$1" cmd="$2"
    shift 2
    call_hook_in "$dir" "$cmd" "$@"
    if [ "$STATUS" -ne 0 ] || [ -n "$OUTPUT" ]; then
        fail_case "ожидалось молчание: $cmd — вывод: $OUTPUT"
    fi
}

# --- Указатель репозитория: --repo и -R ---------------------------

begin_case 'gh: чужой --repo — отказ'
deny_in "$FAKE" "gh issue view --repo $FOREIGN 1" 'gh issue view'
deny_in "$FAKE" "gh issue view --repo=$FOREIGN 1" 'gh issue view'
deny_in "$FAKE" "gh issue view -R $FOREIGN 1" 'gh issue view'
deny_in "$FAKE" "gh issue view -R$FOREIGN 1" 'gh issue view'
# Однозначное сокращение длинной опции — как у --no-verify.
deny_in "$FAKE" "gh issue view --rep $FOREIGN 1" 'gh issue view'
# Значение с хостом слагу не равно: лишний отказ принят планом.
deny_in "$FAKE" "gh issue view --repo github.com/$SLUG 1" 'gh issue view'
# Указатель без значения — отказ, а не пропуск.
deny_in "$FAKE" 'gh issue view 1 --repo' 'gh issue view'
end_case

begin_case 'gh: свой --repo — молчание'
silent_in "$FAKE" "gh issue view --repo $SLUG 1" 'gh issue view'
silent_in "$FAKE" "gh issue view --repo=$SLUG 1" 'gh issue view'
silent_in "$FAKE" "gh issue view -R $SLUG 1" 'gh issue view'
silent_in "$FAKE" "gh issue view -R$SLUG 1" 'gh issue view'
silent_in "$FAKE" "gh issue view --repo $SLUG_UPPER 1" 'gh issue view'
end_case

begin_case 'gh: -R в сцепке с чужим значением — отказ'
deny_in "$FAKE" "gh issue view -cR $FOREIGN 1" 'gh issue view'
deny_in "$FAKE" "gh issue view -cR$FOREIGN 1" 'gh issue view'
deny_in "$FAKE" "gh issue view -R=$FOREIGN 1" 'gh issue view'
end_case

begin_case 'gh: -R в сцепке со своим значением — молчание'
silent_in "$FAKE" "gh issue view -cR $SLUG 1" 'gh issue view'
silent_in "$FAKE" "gh issue view -cR$SLUG 1" 'gh issue view'
silent_in "$FAKE" "gh issue view -R=$SLUG 1" 'gh issue view'
silent_in "$FAKE" "gh issue view -cR $SLUG_UPPER 1" 'gh issue view'
end_case

# Пришпиленный префикс не освобождает остальные слова: повторный --repo у gh
# переопределяет предыдущий.
begin_case 'gh: второй указатель после своего — отказ'
deny_in "$FAKE" "gh issue view --repo $SLUG --repo $FOREIGN 1" "gh issue view --repo $SLUG"
deny_in "$FAKE" "gh issue view --repo $SLUG -R $FOREIGN 1" "gh issue view --repo $SLUG"
end_case

# --- Адрес github.com ---------------------------------------------

begin_case 'gh: чужой адрес github.com — отказ'
deny_in "$FAKE" "gh pr view https://github.com/$FOREIGN/pull/1" 'gh pr view'
deny_in "$FAKE" 'gh pr view https://github.com/other-org/other-repo/pull/1' 'gh pr view'
end_case

begin_case 'gh: чужой адрес github.com в другом написании — отказ'
deny_in "$FAKE" 'gh pr view HTTPS://GitHub.COM/other-org/other-repo/pull/1' 'gh pr view'
deny_in "$FAKE" 'gh pr view https://www.github.com/other-org/other-repo/pull/1' 'gh pr view'
deny_in "$FAKE" 'gh pr view https://github.com:443/other-org/other-repo/pull/1' 'gh pr view'
deny_in "$FAKE" 'gh pr view https://acme-qt@github.com/other-org/other-repo/pull/1' 'gh pr view'
deny_in "$FAKE" 'gh pr view github.com/other-org/other-repo/pull/1' 'gh pr view'
deny_in "$FAKE" 'gh pr view git@github.com:other-org/other-repo.git' 'gh pr view'
end_case

begin_case 'gh: свой адрес github.com — молчание'
silent_in "$FAKE" "gh pr view https://github.com/$SLUG/pull/1" 'gh pr view'
silent_in "$FAKE" 'gh pr view HTTPS://GitHub.COM/ACME-QT/Tool-Repo/pull/1' 'gh pr view'
silent_in "$FAKE" "gh pr view https://www.github.com/$SLUG/pull/1" 'gh pr view'
silent_in "$FAKE" "gh pr view https://github.com:443/$SLUG/pull/1" 'gh pr view'
silent_in "$FAKE" "gh pr view https://github.com/$SLUG.git" 'gh pr view'
end_case

begin_case 'gh: префикс-подделка своего слага в адресе — отказ'
deny_in "$FAKE" "gh pr view https://github.com/$SLUG-evil/pull/1" 'gh pr view'
deny_in "$FAKE" 'gh pr view https://github.com/acme-qt-evil/tool-repo/pull/1' 'gh pr view'
# Адрес без репозитория в пути своим не считается.
deny_in "$FAKE" 'gh pr view https://github.com/acme-qt' 'gh pr view'
end_case

begin_case 'gh: адрес другого хоста и слово github.com без пути — молчание'
silent_in "$FAKE" 'gh issue view 1 --json url' 'gh issue view'
silent_in "$FAKE" "gh pr comment 1 --body 'см. github.com и example.invalid/a/b'" 'gh pr comment'
end_case

# --- Выражение над ответом ----------------------------------------

EXPR_LIST=('gh issue view' 'gh issue list' 'gh pr view')

begin_case 'gh: выражение над ответом — отказ'
deny_in "$FAKE" "gh issue view 1 --json title --jq '\$ENV'" "${EXPR_LIST[@]}"
deny_in "$FAKE" 'gh issue view 1 --json title --jq=.title' "${EXPR_LIST[@]}"
deny_in "$FAKE" 'gh issue list --json title -q .[].title' "${EXPR_LIST[@]}"
deny_in "$FAKE" 'gh issue list --json title -q.[].title' "${EXPR_LIST[@]}"
deny_in "$FAKE" 'gh issue view 1 --json title -cq .title' "${EXPR_LIST[@]}"
deny_in "$FAKE" "gh issue view 1 --json title --template '{{.title}}'" "${EXPR_LIST[@]}"
deny_in "$FAKE" 'gh issue view 1 --json title --template={{.title}}' "${EXPR_LIST[@]}"
# Сокращение: у --jq отличного от него сокращения длиной от четырёх нет,
# поэтому оно проверяется на --template.
deny_in "$FAKE" 'gh issue view 1 --json title --templ {{.title}}' "${EXPR_LIST[@]}"
deny_in "$FAKE" "gh issue view 1 --json title -t '{{.title}}'" "${EXPR_LIST[@]}"
deny_in "$FAKE" 'gh issue view 1 --json title -t{{.title}}' "${EXPR_LIST[@]}"
deny_in "$FAKE" 'gh issue view 1 --json title "--jq" .title' "${EXPR_LIST[@]}"
deny_in "$FAKE" "$(printf 'gh issue view 1 --json title\t--jq .title')" "${EXPR_LIST[@]}"
end_case

begin_case 'gh: тот же вызов без выражения над ответом — молчание'
silent_in "$FAKE" 'gh issue list --json number' "${EXPR_LIST[@]}"
silent_in "$FAKE" 'gh issue view 1 --json url' "${EXPR_LIST[@]}"
silent_in "$FAKE" 'gh issue view 1 --json title,body --comments' "${EXPR_LIST[@]}"
end_case

# --- Поиск ----------------------------------------------------------

begin_case 'gh search без своего --repo — отказ'
deny_in "$FAKE" 'gh search issues слово' 'gh search issues'
deny_in "$FAKE" "gh search issues --repo $FOREIGN слово" 'gh search issues'
deny_in "$FAKE" 'gh search issues --owner acme-qt слово' 'gh search issues'
deny_in "$FAKE" "gh search issues --repo $SLUG \"repo:$FOREIGN слово\"" 'gh search issues'
deny_in "$FAKE" "gh search issues --repo $SLUG org:other-org" 'gh search issues'
deny_in "$FAKE" "gh search issues --repo $SLUG user:other-user" 'gh search issues'
deny_in "$FAKE" "gh search issues --repo $SLUG REPO:other-org/other-repo" 'gh search issues'
end_case

begin_case 'gh search со своим --repo — молчание'
silent_in "$FAKE" "gh search issues --repo $SLUG гейт" 'gh search issues'
silent_in "$FAKE" "gh search issues --repo $SLUG \"гейт\" --limit 20" 'gh search issues'
end_case

# --- Слаг не выведен ----------------------------------------------

begin_case 'gh: слаг не выведен — отказ на всё, что требует слага'
for dir in "$NO_ORIGIN" "$OTHER_HOST"; do
    deny_in "$dir" "gh issue view --repo $SLUG 1" 'gh issue view'
    if ! printf '%s' "$OUTPUT" | grep -qF 'слаг не выведен'; then
        fail_case "в причине нет «слаг не выведен» (${dir##*/})"
    fi
    deny_in "$dir" "gh pr view https://github.com/$SLUG/pull/1" 'gh pr view'
    deny_in "$dir" "gh search issues --repo $SLUG слово" 'gh search issues'
done
end_case

begin_case 'gh: слаг не выведен — голая команда проходит'
silent_in "$NO_ORIGIN" 'gh issue view 1' 'gh issue view'
silent_in "$OTHER_HOST" 'gh issue view 1 --comments' 'gh issue view'
end_case

# ------------------------------------------------------------------
# Сценарий 29. Пришпиливание issue-scout — по записям из самого
# определения, а не из копии в тесте, при настоящем origin в корне
# (в CI его выставляет actions/checkout).
# ------------------------------------------------------------------
SCOUT_DEF="$ROOT_DIR/.claude/agents/issue-scout.md"
SCOUT=()
while IFS= read -r entry; do
    SCOUT+=("$entry")
done < <(awk 'NR == 1 && /^---[[:space:]]*$/ { inside = 1; next }
              inside && /^---[[:space:]]*$/ { exit }
              inside { print }' "$SCOUT_DEF" \
    | grep -oE "'gh [^']* --repo [^']*'" | tr -d "'")

scout_tail() {
    case "$1" in
        'gh issue list'*) printf '%s' ' --state all --limit 300 --json number,title,labels,state' ;;
        'gh search issues'*) printf '%s' ' "гейт"' ;;
        'gh issue view'*) printf '%s' ' 91' ;;
        *) printf '%s' '' ;;
    esac
}

begin_case 'issue-scout: пришпиленные команды проходят границу'
if [ "${#SCOUT[@]}" -ne 3 ]; then
    fail_case "записей gh … --repo в issue-scout.md: ${#SCOUT[@]}, ожидалось 3"
fi
for entry in "${SCOUT[@]}"; do
    silent_in "$ROOT_DIR" "$entry$(scout_tail "$entry")" "${SCOUT[@]}" 'grep' 'head' 'tail' 'pwd'
done
end_case

begin_case 'issue-scout: второй указатель репозитория после пришпиленного — отказ'
if [ "${#SCOUT[@]}" -ne 3 ]; then
    fail_case "записей gh … --repo в issue-scout.md: ${#SCOUT[@]}, ожидалось 3"
fi
for entry in "${SCOUT[@]}"; do
    deny_in "$ROOT_DIR" "$entry --repo $FOREIGN 1" "${SCOUT[@]}"
    deny_in "$ROOT_DIR" "$entry -R $FOREIGN" "${SCOUT[@]}"
    deny_in "$ROOT_DIR" "$entry https://github.com/$FOREIGN/issues/1" "${SCOUT[@]}"
done
end_case

# ------------------------------------------------------------------
# Сценарий 30. Команды, которые шаги вызывают по своим правилам
# (docs/rules/**, тела .claude/agents/**), — в той форме, в какой их
# предписывают, каждая при списке своего шага. Таблица поиска — в журнале
# docs/tasks/119.md.
# ------------------------------------------------------------------
STEP_IMPLEMENT=('gh issue view' 'gh pr create' 'gh pr view' 'gh pr edit' 'grep' 'head' 'tail')
STEP_REVIEW=('gh pr diff' 'gh pr view' 'gh pr checks' 'gh issue view' 'grep' 'head' 'tail' 'pwd'
    'bash scripts/owner-comments.sh')
STEP_FIX=('gh pr view' 'gh pr diff' 'gh pr checks' 'gh pr comment' 'gh run view' 'grep' 'head' 'tail'
    'bash scripts/review-comments.sh')

begin_case 'команды из правил шагов — молчание'
silent_in "$ROOT_DIR" 'gh issue view 119 --comments' "${STEP_IMPLEMENT[@]}"
silent_in "$ROOT_DIR" "gh pr create --draft --title 'feat: #119 — граница' --body-file /tmp/body.md" "${STEP_IMPLEMENT[@]}"
silent_in "$ROOT_DIR" 'gh pr edit 128 --body-file /tmp/body.md' "${STEP_IMPLEMENT[@]}"
silent_in "$ROOT_DIR" 'gh issue view 119 --json url' "${STEP_REVIEW[@]}"
silent_in "$ROOT_DIR" 'gh pr view 128 --comments' "${STEP_REVIEW[@]}"
silent_in "$ROOT_DIR" 'gh pr diff 128' "${STEP_REVIEW[@]}"
silent_in "$ROOT_DIR" 'gh pr checks 128' "${STEP_REVIEW[@]}"
silent_in "$ROOT_DIR" 'bash scripts/owner-comments.sh 119' "${STEP_REVIEW[@]}"
silent_in "$ROOT_DIR" 'gh run view 123 --log | grep -nE "error|Failed"' "${STEP_FIX[@]}"
silent_in "$ROOT_DIR" 'bash scripts/review-comments.sh 122' "${STEP_FIX[@]}"
silent_in "$ROOT_DIR" 'gh pr comment 128 --body-file /tmp/comment.md' "${STEP_FIX[@]}"
end_case

# ------------------------------------------------------------------
# Сценарий 31. Слова, которые собирает оболочка (ревью #128, круг 1).
#
# Поимённые флаги проверяются по нормализованной части: кавычки сняты, но
# оболочка не исполнена. Слово, которое bash соберёт из обратного слеша,
# подстановки параметра, ANSI- или локализуемых кавычек, фигурных скобок, до
# проверки доходит неузнанным — и это касается всех поимённых флагов, а не
# только gh. ANSI-кавычки к тому же ломают сам разбор на части: `$'\''` — это
# одна литеральная кавычка для bash, а разбор видел в ней открытую строку и
# склеивал три команды в одну часть с разрешённым началом.
#
# Отказ ставится по признаку сборки, а не по узнанному флагу: угадывать, что
# соберёт оболочка, — значит исполнять её, а граница этого не делает.
# ------------------------------------------------------------------
begin_case 'gh: флаг, собранный оболочкой, — отказ'
deny_in "$FAKE" 'gh issue view 1 --json title --j\q .title' "${EXPR_LIST[@]}"
deny_in "$FAKE" 'gh issue view 1 --json title --j${x:-q} .title' "${EXPR_LIST[@]}"
deny_in "$FAKE" "gh issue view 1 --json title \$'--jq' .title" "${EXPR_LIST[@]}"
deny_in "$FAKE" 'gh issue view 1 --json title $"--jq" .title' "${EXPR_LIST[@]}"
deny_in "$FAKE" 'gh issue view 1 --json title --jq$@ .title' "${EXPR_LIST[@]}"
deny_in "$FAKE" 'gh issue view 1 --json title --{jq,x} .title' "${EXPR_LIST[@]}"
deny_in "$FAKE" "gh issue view --rep\\o $FOREIGN 1" "${EXPR_LIST[@]}"
# Пробел в кавычках раскрытие скобок не останавливает: bash отдаст
# `--jq ' env'`, а по словам видны только `{--jq,` и `env}`.
deny_in "$FAKE" "gh issue view 1 --json title {--jq,' env'}" "${EXPR_LIST[@]}"
deny_in "$FAKE" 'gh issue view 1 --json title --{jq,"x y"}' "${EXPR_LIST[@]}"
end_case

# Слеш перед знаком препинания тоже снимается оболочкой, а адрес и
# квалификатор поиска читаются по `.`, `/` и `:`.
begin_case 'gh: адрес и квалификатор, собранные слешем, — отказ'
deny_in "$FAKE" 'gh pr view https:\/\/github.com/other-org/other-repo/pull/1' 'gh pr view'
deny_in "$FAKE" 'gh pr view https://github\.com/other-org/other-repo/pull/1' 'gh pr view'
deny_in "$FAKE" "gh search issues --repo $SLUG repo\\:other-org/other-repo" 'gh search issues'
end_case

begin_case 'git commit: --no-verify, собранный оболочкой, — отказ'
deny_in "$FAKE" 'git commit --no-veri\fy -m x' 'git commit'
deny_in "$FAKE" "git commit \$'--no-verify' -m x" 'git commit'
deny_in "$FAKE" 'git commit --no-verif${x:-y} -m x' 'git commit'
deny_in "$FAKE" "$(printf 'git commit --no-veri\\\nfy -m x')" 'git commit'
# Отказ обязан называть сборку: до правки это написание получало отказ
# случайно — разбор резал часть на переводе строки, и `fy -m x` просто не
# было в списке. Со списком, где продолжение разрешено, оно прошло бы.
expect_output 'собирает оболочка'
deny_in "$FAKE" "$(printf 'git commit "--no-veri\\\nfy" -m x')" 'git commit'
end_case

# Фигурные скобки (ревью #128, круг 2). `}`, которую bash закрывающей не
# считает, — экранированная, в кавычках или закрывающая вложенную пару, —
# обрывала поиск запятой на первой сырой `}`. bash раскрывает все три
# написания в два слова, и второе — флаг. Запятая теперь ищется до последней
# `}` команды; лишние отказы приняты решением владельца.
begin_case 'скобки: запятая после ложной закрывающей — отказ'
deny_in "$FAKE" 'git commit -m {\},--no-verify}' 'git commit'
deny_in "$FAKE" 'git commit -m {"}",--no-verify}' 'git commit'
deny_in "$FAKE" 'git commit -m {{a},--no-verify}' 'git commit'
deny_in "$FAKE" 'gh issue list --json title --search {\},--jq} .title' "${EXPR_LIST[@]}"
deny_in "$FAKE" 'gh issue list --json title --search {"}",--jq} .title' "${EXPR_LIST[@]}"
deny_in "$FAKE" 'gh issue list --json title --search {{a},--jq} .title' "${EXPR_LIST[@]}"
end_case

# Обратная сторона: скобки без запятой (`{owner}` у gh api) оболочка не
# трогает, скобки в одиночных кавычках — тоже.
begin_case 'скобки без запятой и в одиночных кавычках — молчание'
silent_in "$FAKE" 'gh api repos/{owner}/{repo}/pulls/1/comments' 'gh api'
silent_in "$FAKE" "gh issue list --search 'label:{a,b}'" "${EXPR_LIST[@]}"
end_case

# Перевод строки внутри кавычек (ревью #128, круг 2). На части команда по
# нему не делится — он в кавычках, — а слова части разбора gh читались
# встроенным read, который останавливается на первой строке. Всё после
# перевода строки до веток разбора не доходило, а bash отдаёт эти слова gh.
begin_case 'gh: слова после перевода строки в кавычках — отказ'
deny_in "$FAKE" "$(printf 'gh search issues --repo %s "слово\n" --jq %s' "$SLUG" "'\$ENV'")" 'gh search issues'
deny_in "$FAKE" "$(printf 'gh pr comment 1 --body "текст\n" --repo %s' "$FOREIGN")" 'gh pr comment'
deny_in "$FAKE" "$(printf 'gh search issues --repo %s "слово\nrepo:other-org/other-repo"' "$SLUG")" 'gh search issues'
end_case

begin_case 'gh: перевод строки в кавычках без запретного — молчание'
silent_in "$FAKE" "$(printf 'gh pr comment 1 --body "строка\nвторая"')" 'gh pr comment'
end_case

begin_case 'ANSI-кавычки прячут вторую команду в разрешённой части — отказ'
deny_in "$FAKE" "git status \$'\\'' ; dotnet ef database drop ; echo '" 'git status' 'echo'
end_case

# Обратная сторона: `$` и `\` в одиночных кавычках, `$` перед закрывающей
# двойной кавычкой и `\` перед обычной буквой внутри двойных оболочка не
# трогает. Шагу починки такие регулярки нужны каждый день.
begin_case 'регулярки с $ и \ в кавычках — молчание'
silent_in "$ROOT_DIR" "gh run view 123 --log | grep -nE 'error\$'" "${STEP_FIX[@]}"
silent_in "$ROOT_DIR" 'gh run view 123 --log | grep -nE "error$"' "${STEP_FIX[@]}"
silent_in "$ROOT_DIR" 'gh run view 123 --log | grep -nE "error$|Failed"' "${STEP_FIX[@]}"
silent_in "$ROOT_DIR" 'gh run view 123 --log | grep -n "\bслово"' "${STEP_FIX[@]}"
silent_in "$ROOT_DIR" "grep -nE '\\\$\\{x\\}' README.md" "${STEP_FIX[@]}"
silent_in "$ROOT_DIR" "git commit -m 'fix: стоит \$5, \${x} и --{jq,x}'" 'git commit'
end_case

# Комментарий (ревью #128, круг 3). Для bash `#` в начале слова открывает
# комментарий до конца строки, и кавычка после него ничего не открывает. Разбор
# видел в `#'` начало одиночной кавычки: строки до парной `#'` уходили в
# разрешённую часть, а bash исполнял их отдельными командами. Поимённые флаги
# при этом проверялись по началу части — у `grep` ни `--jq`, ни `--repo`, ни
# `-n` у `git commit` не сверяются.
HIDE_LIST=('grep' 'gh issue view' 'git commit')
begin_case 'комментарий прячет вторую команду в разрешённой части — отказ'
deny_in "$FAKE" "$(printf "grep x README.md #'\ndotnet ef database drop\n#'")" "${HIDE_LIST[@]}"
expect_output 'комментарий'
deny_in "$FAKE" "$(printf "grep x README.md #'\ngh issue view 1 --json title --jq .title\n#'")" "${HIDE_LIST[@]}"
expect_output 'комментарий'
deny_in "$FAKE" "$(printf "grep x README.md #'\ngh issue view --repo %s 1\n#'" "$FOREIGN")" "${HIDE_LIST[@]}"
expect_output 'комментарий'
deny_in "$FAKE" "$(printf "grep x README.md #'\ngit commit -n -m x\n#'")" "${HIDE_LIST[@]}"
expect_output 'комментарий'
# Сразу после разделителя часть и раньше не проходила — она начиналась с `#`
# и не совпадала со списком. Отказ обязан называть комментарий, а не список.
deny_in "$FAKE" "$(printf "grep x README.md;#'\ndotnet ef database drop\n#'")" "${HIDE_LIST[@]}"
expect_output 'комментарий'
deny_in "$FAKE" "$(printf "grep x README.md &&#'\ndotnet ef database drop\n#'")" "${HIDE_LIST[@]}"
expect_output 'комментарий'
end_case

begin_case '# в кавычках и после слеша — молчание'
silent_in "$ROOT_DIR" "grep -n '#' README.md" 'grep'
silent_in "$ROOT_DIR" 'grep -n "#" README.md' 'grep'
silent_in "$ROOT_DIR" 'grep -n \# README.md' 'grep'
silent_in "$ROOT_DIR" 'gh pr view 128 --comments | grep -n "## Решение"' "${STEP_FIX[@]}"
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
