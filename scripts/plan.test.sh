#!/usr/bin/env bash
#
# Домовой — проверочные сценарии для валидатора плана scripts/plan.sh.
#
# ЗАЧЕМ
#
# Валидатор, который только зеленеет, ничего не доказывает: он зеленел бы и
# при пустом теле каждой проверки. Здесь для каждого класса нарушений берётся
# один согласованный план и портится ровно одной точечной мутацией — в
# сценарии видно именно нарушаемое, а не собранный заново «плохой план», в
# котором неверно всё сразу.
#
# Отдельно проверяются четыре вещи, которые классами не покрываются:
#
#   1. на согласованном плане валидатор молчит — проверка, шумящая на
#      нормальной работе, перестаёт читаться;
#   2. согласованная фикстура полна по схеме — вглубь, вместе с полями
#      вложенных объектов и элементов массивов, — иначе инвариант рендера
#      проверялся бы на неполном плане;
#   3. каждое строковое значение фикстуры доезжает до рендера — поле,
#      добавленное в схему без ветки рендера, иначе исчезало бы из
#      опубликованного плана молча;
#   4. рендер вкладывает машиночитаемую форму свёрнутым блоком, и форма из
#      блока равна плану на входе.
#
# ОБРЕЗКА ВЫВОДА
#
# Вложенная форма содержит каждое значение плана дословно, поэтому сценарии из
# пункта 3 и класса 5 искали бы значения в ней, а не в прозе рендера, и
# зеленели бы тривиально. Они смотрят на вывод, обрезанный помощником
# prose_only; сама обрезка проверяется на себе — сценарий «Обрезка вывода по
# началу блока проверяется на себе».
#
# ИСТОРИЧЕСКИЕ ПЛАНЫ
#
# Три реальных плана из истории задач лежат в scripts/fixtures/plans и
# проверяются против того дерева, для которого писались (--at). Что без --at
# план краснеет на разнице деревьев, доказывается не на них, а во временном
# репозитории с двумя коммитами: история этого репозитория меняется, и
# доказательство, опирающееся на её файлы, умирает вместе с ними. Это половина
# критерия «ни одного ложного срабатывания»: класс нарушений можно поймать
# сколь угодно строгой проверкой, и цена строгости видна только на планах,
# которые человек уже одобрил.
#
# Пин, который не разрешается, роняет сценарий, а не пропускает его. Молча
# пропущенная проверка на ложные срабатывания — та самая видимость проверки,
# против которой написан каждый скрипт в scripts/.
#
# КАК ЗАПУСКАТЬ
#
#   bash scripts/plan.test.sh
#
# Код возврата: 0 — все сценарии прошли, 1 — есть провалившиеся.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CHECK="$SCRIPT_DIR/plan.sh"
SCHEMA="$SCRIPT_DIR/plan-schema.json"
FIXTURES="$SCRIPT_DIR/fixtures/plans"
RULES="$ROOT/docs/rules/plan.md"

if [ ! -f "$CHECK" ]; then
    printf 'Не найден %s\n' "$CHECK" >&2
    exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
    printf 'Не найден jq: сценарии собирают планы мутациями через него.\n' >&2
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
    OUTPUT=''
    STATUS=0
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

run_validate() {
    OUTPUT="$(bash "$CHECK" validate "$@" 2>&1)"
    STATUS=$?
}

run_render() {
    OUTPUT="$(bash "$CHECK" render "$@" 2>&1)"
    STATUS=$?
}

expect_status() {
    if [ "$STATUS" -ne "$1" ]; then
        fail_case "код возврата $STATUS, ожидался $1"
    fi
}

expect_output() {
    # Ключ -- обязателен: искомое может начинаться с дефиса.
    if ! printf '%s' "$OUTPUT" | grep -qF -- "$1"; then
        fail_case "в выводе нет: $1"
    fi
}

expect_no_output() {
    if printf '%s' "$OUTPUT" | grep -qF -- "$1"; then
        fail_case "в выводе не должно быть: $1"
    fi
}

# Число разделителей в строке таблицы markdown. Экранированные пайпы из строки
# выбрасываются: считается ровно то, что разрезает строку на ячейки.
expect_cells() {
    local needle="$1" want="$2" row stripped got
    row="$(printf '%s\n' "$OUTPUT" | grep -F -- "$needle" | head -n 1)"
    if [ -z "$row" ]; then
        fail_case "в рендере нет строки с: $needle"
        return
    fi
    stripped="${row//\\|/}"
    got="$(printf '%s' "$stripped" | tr -cd '|' | wc -c | tr -d ' \r')"
    if [ "$got" -ne "$want" ]; then
        fail_case "разделителей в строке таблицы $got, ожидалось $want: $row"
    fi
}

expect_no_violations() {
    if printf '%s' "$OUTPUT" | grep -qF 'нарушение:'; then
        fail_case 'в выводе есть сообщения о нарушениях, а не должно быть ни одного'
    fi
}

# Машиночитаемая форма едет тем же выводом, что и рендер: свёрнутый блок с ней
# печатает сам plan.sh, последним действием do_render. Поэтому сценарий,
# ищущий значения плана в выводе рендера, обязан смотреть на прозу, а не на
# весь вывод: во вложенном JSON каждое значение стоит дословно, и проверка
# «значение доехало до публикации» зазеленела бы, ничего не проверив.
FORM_SUMMARY='<summary>Машиночитаемая форма плана</summary>'

# Вывод до начала блока. Обрезка идёт по двухстрочному якорю, а не по одному
# тегу `<details>`: планы этого проекта пишут про свёрнутые блоки, и литерал
# в значении обрезал бы прозу раньше времени. Якорь безопасен по формату: сырой
# перевод строки внутри строки JSON запрещён, поэтому последовательность из двух
# строк встречается в выводе ровно один раз — там, где блок начинается. Остаток,
# который принят: значение плана, содержащее эти же две строки подряд.
#
# Утверждение обрезки замкнуто в обе стороны и без «первого против последнего»:
# исчезнувший блок якорю не соответствует, `OUTPUT` остаётся целым, и сценарий
# «Обрезка вывода по началу блока проверяется на себе» краснеет литералом
# `"observation":`, оставшимся в прозе.
FORM_ANCHOR="<details>"$'\n'"$FORM_SUMMARY"

prose_only() {
    printf '%s' "${OUTPUT%%"$FORM_ANCHOR"*}"
}

expect_prose() {
    if ! prose_only | grep -qF -- "$1"; then
        fail_case "в прозе рендера (до блока с формой) нет: $1"
    fi
}

# ------------------------------------------------------------------
# Согласованный план. Собирается один раз и полон по схеме: сценарий
# «Полнота согласованной фикстуры» это проверяет, а не принимает на веру.
#
# Пути в нём настоящие, потому что валидатор смотрит на дерево: выдуманный
# путь сделал бы сценарий «согласованный план молчит» проверкой того, что
# проверка не работает.
# ------------------------------------------------------------------
CANON="$SANDBOX/canonical.json"

cat > "$CANON" <<'PLAN'
{
  "issue": 4242,
  "current_state": [
    {
      "path": "scripts/plan.sh",
      "line": 20,
      "observation": "валидатор отвергает пустой способ проверки, но пункт «непроверяем» с причиной принимает бессрочно"
    },
    {
      "path": "docs/rules/plan.md",
      "line": 0,
      "observation": "контракт приёмки допускает значение «непроверяем» с причиной и ничего не говорит о сроке"
    }
  ],
  "bug_analysis": {
    "symptom": "план с пунктом «непроверяем» годичной давности проходит валидатор кодом 0",
    "precondition": "пункт помечен «непроверяем» и причина непустая; с пустой причиной валидатор краснеет",
    "root_cause": "scripts/plan.sh:20",
    "rejected_hypotheses": [
      "причина обрезается при разборе — нет: рендер печатает её целиком"
    ]
  },
  "approach": {
    "summary": "Пункт «непроверяем» перестаёт быть бессрочным: причина и срок, валидатор читает обе части, а не только длину причины.",
    "rejected": [
      {
        "option": "отдельный файл со списком непроверяемых пунктов",
        "reason": "второе описание того же множества, разъедется с планами молча"
      }
    ]
  },
  "fork_card": {
    "matches_request": "да: задача просит срок у непроверяемого пункта, и план вводит именно его",
    "alternative": "предупреждение вместо отказа — владелец видел бы зелёный план с просроченным пунктом; цена та же",
    "ripple": "по грепу x-unverifiable: только scripts/plan.sh и схема, других читателей нет",
    "workaround": "нет: срок проверяется там же, где причина",
    "council_signs": ["правка обвязки"],
    "executor": "оркестратор сам: два файла, место найдено",
    "slices": [
      {
        "name": "валидатор",
        "files": ["scripts/plan.sh", "scripts/review-comments.sh"],
        "contract": "пункт «непроверяем» несёт причину и срок; сообщение о просрочке — в форме замечания",
        "after": []
      },
      {
        "name": "правила",
        "files": ["docs/rules/plan.md"],
        "contract": "правило называет срок там же, где причину, словами сообщения валидатора",
        "after": ["валидатор"]
      }
    ],
    "single_slice_reason": "",
    "fork": false
  },
  "files": [
    {
      "path": "scripts/plan.sh",
      "action": "modify",
      "why": "разбор пункта «непроверяем»: причина и срок вместо одной причины"
    },
    {
      "path": "scripts/review-comments.sh",
      "action": "modify",
      "why": "сообщение о просроченном пункте в той же форме, что замечания"
    },
    {
      "path": "docs/rules/plan.md",
      "action": "modify",
      "why": "план называет срок непроверяемого пункта там же, где причину"
    },
    {
      "path": "docs/tasks/4242.md",
      "action": "create",
      "why": "журнал задачи"
    }
  ],
  "boundaries": [
    "scripts/**",
    "docs/rules/**",
    "docs/tasks/**"
  ],
  "flags": {
    "new_dependency": false,
    "new_dependency_reason": ""
  },
  "tests": [
    {
      "name": "непроверяемый пункт без срока не проходит валидатор",
      "file": "scripts/plan.test.sh",
      "new": true,
      "covers": ["marker-reason"],
      "behavior": "пункт с причиной, но без срока даёт код 1 и называет пункт"
    },
    {
      "name": "просроченный непроверяемый пункт назван вслух",
      "file": "scripts/plan.test.sh",
      "new": true,
      "covers": ["marker-expiry"],
      "behavior": "срок в прошлом даёт код 1 и печатает дату"
    }
  ],
  "acceptance": [
    {
      "id": "marker-reason",
      "criterion": "Непроверяемый пункт без срока заворачивается",
      "method": "bash scripts/plan.test.sh",
      "evidence": "сценарий «непроверяемый пункт без срока не проходит валидатор» проходит, итог «провалено: 0»"
    },
    {
      "id": "marker-expiry",
      "criterion": "Просроченный непроверяемый пункт заворачивается",
      "method": "bash scripts/plan.sh validate docs/tasks/4242.plan.json",
      "evidence": "код возврата 1 и дата в выводе"
    },
    {
      "id": "live-session",
      "criterion": "То же поведение в живой сессии",
      "method": "непроверяем",
      "evidence": "живой прогон в новой сессии в эту задачу не входит; расхождение записывается в журнал"
    }
  ],
  "risks": [
    {
      "risk": "Срок непроверяемого пункта превращается в способ отложить работу навсегда.",
      "mitigation": "просроченный срок краснеет так же, как отсутствующая причина"
    }
  ],
  "out_of_scope": [
    "перенос существующих планов на новую форму разом",
    "проверка того, что причина непроверяемости правдива"
  ]
}
PLAN

MUTATION_INDEX=0

# Портит согласованный план одной программой jq и печатает путь к копии.
mutate() {
    MUTATION_INDEX=$((MUTATION_INDEX + 1))
    local out="$SANDBOX/mutation-$MUTATION_INDEX.json"
    jq "$1" "$CANON" > "$out" || return 1
    printf '%s' "$out"
}

# ------------------------------------------------------------------
begin_case 'Согласованный план: валидатор молчит'
run_validate "$CANON"
expect_status 0
expect_no_violations
expect_output 'План сходится'
end_case

# ------------------------------------------------------------------
begin_case 'Наблюдение «как устроено сейчас»: путь и номер строки'
run_validate "$(mutate '.current_state[0].path = "scripts/plan-which-never-was.sh"')"
expect_status 1
expect_output 'наблюдение «как устроено сейчас» ссылается на несуществующий путь: scripts/plan-which-never-was.sh'

run_validate "$(mutate '.current_state[0].line = 999999')"
expect_status 1
expect_output 'наблюдение «как устроено сейчас» ссылается на строку 999999, а в scripts/plan.sh строк'
end_case

# ------------------------------------------------------------------
begin_case 'Класс 1: путь на правку не существует'
run_validate "$(mutate '.files[0].path = "scripts/plan-which-never-was.sh"')"
expect_status 1
expect_output 'путь на modify не существует: scripts/plan-which-never-was.sh'
end_case

# ------------------------------------------------------------------
begin_case 'Класс 2: путь вне границ задачи'
run_validate "$(mutate '.files[0].path = "src/Domovoy.Api/Program.cs"')"
expect_status 1
expect_output 'путь вне границ задачи: src/Domovoy.Api/Program.cs'
expect_output 'scripts/**'
end_case

# ------------------------------------------------------------------
begin_case 'Путь за деревом репозитория отвергается, границы его не спасают'
# Граница «../**» добавлена нарочно: она делает такой путь «в границах», то
# есть план авторизует себя сам. Проверка обязана сработать до класса 2.
run_validate "$(mutate '
    .files[0].path = "../home-agent-source/tz-home-agent.md"
    | .boundaries += ["../**"]')"
expect_status 1
expect_output 'путь вне репозитория: ../home-agent-source/tz-home-agent.md'

run_validate "$(mutate '.files[0].path = "/etc/hosts"')"
expect_status 1
expect_output 'путь вне репозитория: /etc/hosts'
expect_no_output 'путь вне границ задачи: /etc/hosts'
end_case

# ------------------------------------------------------------------
begin_case 'Наблюдение за деревом репозитория отвергается тем же условием'
# Путь из current_state уходил в path_exists и file_line_count без этой
# проверки, и без --at обе ветки считают от корня рабочего каталога. Отчёт
# валидатора едет комментарием в публичную issue, то есть строка «в <путь вне
# дерева> строк N» отвечает на вопрос о файле раннера. Номер строки взят
# заведомо большим: сценарий обязан краснеть одинаково и там, где файл вне
# дерева существует, и там, где его нет.
run_validate "$(mutate '
    .current_state[0].path = "../home-agent-source/tz-home-agent.md"
    | .current_state[0].line = 999999')"
expect_status 1
expect_output 'путь вне репозитория: ../home-agent-source/tz-home-agent.md'
expect_no_output 'а в ../home-agent-source/tz-home-agent.md строк'

run_validate "$(mutate '.current_state[0].path = "/etc/hosts" | .current_state[0].line = 999999')"
expect_status 1
expect_output 'путь вне репозитория: /etc/hosts'
expect_no_output 'а в /etc/hosts строк'
end_case

# ------------------------------------------------------------------
begin_case 'Класс 3: пункт приёмки без покрывающего теста'
run_validate "$(mutate '.tests[0].covers = ["marker-expiry"]')"
expect_status 1
expect_output 'пункт приёмки «marker-reason» не покрыт ни одним тестом'
end_case

# ------------------------------------------------------------------
begin_case 'Класс 3 с обратной стороны: covers ссылается в пустоту'
# Оба настоящих пункта остаются покрытыми, поэтому прямая проверка молчит —
# видно ровно опечатку в идентификаторе, а не её последствие.
run_validate "$(mutate '.tests += [{
    "name": "пункт без срока называет дату отсечения",
    "file": "scripts/plan.test.sh",
    "new": true,
    "covers": ["marker-expiery"],
    "behavior": "в сообщении стоит дата, после которой пункт считается просроченным"
  }]')"
expect_status 1
expect_output 'покрывает несуществующий пункт приёмки: «marker-expiery»'
expect_output 'пункт без срока называет дату отсечения'
expect_no_output 'не покрыт ни одним тестом'
end_case

# ------------------------------------------------------------------
begin_case 'Класс 4: существующий тест выдан за новый'
run_validate "$(mutate '.tests[0].name = "MobileLayeringTests"')"
expect_status 1
expect_output 'тест объявлен новым, но имя уже встречается: MobileLayeringTests'
expect_output 'tests/Domovoy.Tests/MobileLayeringTests.cs'
end_case

# ------------------------------------------------------------------
begin_case 'Класс 5: пустая ячейка против «непроверяем»'
run_validate "$(mutate '.acceptance[1].method = ""')"
expect_status 1
expect_output 'пункт приёмки «marker-expiry» без способа проверки'

run_validate "$(mutate '.acceptance[2].evidence = ""')"
expect_status 1
expect_output 'пункт приёмки «live-session» помечен «непроверяем» без причины'

# Третий подслучай — тот же пункт с причиной. Он в согласованном плане уже
# есть, и проверяется здесь не код возврата, а то, что причина доезжает до
# рендера: непроверяемый пункт, потерявший причину при публикации, ничем не
# отличается от забытого. Смотреть надо на прозу: в машиночитаемой форме,
# вложенной в тот же вывод, причина стоит дословно и зазеленила бы сценарий
# при рендере, потерявшем её из таблицы.
run_render "$CANON"
expect_status 0
expect_prose 'непроверяем'
expect_prose 'живой прогон в новой сессии в эту задачу не входит'
end_case

# ------------------------------------------------------------------
begin_case 'Форма: обязательное поле схемы отсутствует'
run_validate "$(mutate 'del(.risks)')"
expect_status 1
expect_output 'план.risks: обязательное поле схемы отсутствует'
expect_output 'содержательные проверки не запускались'
end_case

# ------------------------------------------------------------------
begin_case 'Форма: поле не описано схемой'
run_validate "$(mutate '.estimate = "три дня"')"
expect_status 1
expect_output 'план.estimate: поле не описано схемой'
end_case

# ------------------------------------------------------------------
begin_case 'Форма: значение вне enum схемы'
run_validate "$(mutate '.files[0].action = "rename"')"
expect_status 1
expect_output 'план.files[0].action: значение «rename» вне enum схемы'
end_case

# ------------------------------------------------------------------
# Обход схемы идёт вглубь: поле, объявленное во вложенном объекте или в items
# массива, обязано быть заполнено — иначе инвариант рендера проверялся бы на
# плане, в котором этого поля нет вовсе, и обещание «поле схемы без ветки
# рендера роняет этот харнесс» держалось бы только на первом уровне.
#
# Для массива поле считается пропущенным, когда его нет ни в одном элементе:
# ровно этого требует цель обхода — чтобы значение доехало до рендера хотя бы
# раз. Пустой массив считается пропуском по той же причине — значению из него
# нечего доезжать до рендера, — поэтому в фикстуре council_signs и
# rejected_hypotheses непусты. Необязательное поле верхнего уровня
# (bug_analysis) обход тоже требует: его ветку рендера проверяет только
# фикстура, в которой оно есть.
#
# У поля с вариантами (oneOf) обход идёт по варианту, под который план
# подходит по обязательным полям, а не подходит ни под один — по самому
# полному: пропуск поля карточки обязан быть назван. Вариант trivial карточки
# развилки проверяется отдельным сценарием.
WALK_PROGRAM='
def walk($s; $v; $p):
  if (($s.oneOf // null) != null) then
    ( [ $s.oneOf[] | . as $b
        | select((($v | type) == "object")
                 and (($b.required // []) | all(. as $r | $v | has($r)))) ] ) as $fit
    | if ($fit | length) > 0 then walk($fit[0]; $v; $p)
      else walk(($s.oneOf | max_by(.properties | length)); $v; $p) end
  elif ($s.type == "object") then
    [ (($s.properties // {}) | keys_unsorted)[] as $k
      | if (($v | type) == "object") and ($v | has($k))
        then walk($s.properties[$k]; $v[$k]; "\($p).\($k)")[]
        else "\($p).\($k)" end ]
  elif ($s.type == "array") then
    ( if (($v | type) != "array") or (($v | length) == 0)
      then ["\($p)[]"]
      else ([ $v[] | walk($s.items; .; "\($p)[]") ]) as $lists
        | [ $lists[0][] | select(. as $m | ($lists | map(index($m) != null) | all)) ]
      end )
  else [] end;

walk($schema_in[0]; $plan_in[0]; "план") | .[]
'

missing_fields() {
    jq -rn --slurpfile schema_in "$SCHEMA" --slurpfile plan_in "$1" "$WALK_PROGRAM" | tr -d '\r'
}

begin_case 'Полнота согласованной фикстуры: заполнены и вложенные поля схемы'
while IFS= read -r key; do
    [ -z "$key" ] && continue
    fail_case "в согласованной фикстуре нет поля схемы: $key"
done < <(missing_fields "$CANON")

# Обход проверяется на себе. Проверка полноты, которая молчит всегда, — это
# ровно та видимость проверки, против которой написан харнесс.
TRIMMED="$SANDBOX/trimmed.json"
jq 'del(.files[].why)' "$CANON" > "$TRIMMED"
if ! missing_fields "$TRIMMED" | grep -qxF 'план.files[].why'; then
    fail_case 'обход не заметил вложенное поле, удалённое из всех элементов массива'
fi

# То же для поля с вариантами: пропуск в карточке не должен прятаться за тем,
# что вариант с этим полем больше не подходит по обязательным.
jq 'del(.fork_card.ripple)' "$CANON" > "$TRIMMED"
if ! missing_fields "$TRIMMED" | grep -qxF 'план.fork_card.ripple'; then
    fail_case 'обход не заметил поле карточки развилки, удалённое из плана'
fi
end_case

# ------------------------------------------------------------------
begin_case 'Инвариант рендера: каждое строковое значение доезжает до вывода'
run_render "$CANON"
expect_status 0
# Проза, а не весь вывод: вложенная машиночитаемая форма содержит каждое
# значение плана дословно, и поиск по всему выводу проверял бы наличие блока,
# а не то, что у поля есть ветка рендера.
PROSE="$(prose_only)"
while IFS= read -r value; do
    [ -z "$value" ] && continue
    if ! printf '%s' "$PROSE" | grep -qF -- "$value"; then
        fail_case "в рендере нет значения из плана: $value"
    fi
done < <(jq -r '[.. | strings] | .[]' "$CANON" | tr -d '\r')
end_case

# ------------------------------------------------------------------
begin_case 'Рендер: пайп в значении не разъезжает строку таблицы'
# Способ проверки вида grep -nE "a|b" — не выдумка сценария: ровно такой стоит
# в контракте приёмки настоящих задач. В согласованную фикстуру пайп не
# кладётся: инвариант рендера ищет значения дословно, и там он поймал бы
# экранирование как пропажу значения.
run_render "$(mutate '
    .files[0].why = "разбор пункта: причина|срок вместо одной причины"
    | .tests[0].name = "пункт без срока|без причины не проходит валидатор"
    | .acceptance[0].id = "marker|reason"
    | .tests[0].covers = ["marker|reason"]
    | .acceptance[0].method = "grep -nE \"curl|anthropic\" scripts/plan.sh"')"
expect_status 0
expect_cells 'причина\|срок' 4
expect_cells 'срока\|без причины' 6
expect_cells 'marker\|reason' 6
expect_cells 'curl\|anthropic' 4
end_case

# ------------------------------------------------------------------
begin_case 'Порядок разделов рендера: заголовки взяты из docs/rules/plan.md'
run_render "$CANON"
expect_status 0
EXPECTED_HEADINGS="$(grep -oE '^[0-9]+\. \*\*[^*]+\*\*' "$RULES" \
    | sed -E 's/^([0-9]+)\. \*\*(.+)\.\*\*$/## \1. \2/')"
ACTUAL_HEADINGS="$(printf '%s\n' "$OUTPUT" | grep '^## ')"
if [ "$EXPECTED_HEADINGS" != "$ACTUAL_HEADINGS" ]; then
    fail_case 'заголовки рендера разошлись с разделами docs/rules/plan.md'
    printf '        ожидалось:\n%s\n' "$EXPECTED_HEADINGS" | sed 's/^/        /'
fi
HEADING_COUNT="$(printf '%s\n' "$ACTUAL_HEADINGS" | grep -c '^## ')"
if [ "$HEADING_COUNT" -ne 7 ]; then
    fail_case "разделов в рендере $HEADING_COUNT, а не семь"
fi
end_case

# ------------------------------------------------------------------
begin_case 'Рендер вкладывает машиночитаемую форму: блок последний и равен входу'
run_render "$CANON"
expect_status 0
expect_output "$FORM_SUMMARY"

# Блок обязан быть последним. Всё, что напечатано после него, в комментарии
# окажется за свёрнутой формой, а само наличие блока перестанет быть признаком
# рендера, дошедшего до конца.
LAST_LINE="$(printf '%s\n' "$OUTPUT" | grep -v '^[[:space:]]*$' | tail -n 1)"
if [ "$LAST_LINE" != '</details>' ]; then
    fail_case "последняя непустая строка рендера «$LAST_LINE», а не закрытие блока с формой"
fi

# Извлечение механическое — ровно то, что сделает читающий опубликованный
# комментарий, если захочет прогнать план валидатором ещё раз.
EXTRACTED="$SANDBOX/extracted.json"
printf '%s\n' "$OUTPUT" | awk '
    index($0, "<summary>") && index($0, "Машиночитаемая форма плана") { block = 1; next }
    block && $0 == "```json" { body = 1; next }
    body && $0 == "```" { body = 0; block = 0; next }
    body { print }
' > "$EXTRACTED"

if [ ! -s "$EXTRACTED" ]; then
    fail_case 'из блока с формой ничего не извлеклось: рендер его не напечатал'
elif ! jq -e . "$EXTRACTED" >/dev/null 2>&1; then
    fail_case 'извлечённая из блока форма не разбирается как JSON'
elif [ "$(jq -S . "$EXTRACTED")" != "$(jq -S . "$CANON")" ]; then
    fail_case 'форма из блока не совпадает с планом, который уходил в рендер'
else
    # Код возврата валидатора отвечает только на «это валидный план»: выпавший
    # элемент массива или обрезанную строку он бы пропустил. На «доехал тот
    # самый план целиком» отвечает сравнение канонизированных форм выше.
    run_validate "$EXTRACTED"
    expect_status 0
    expect_no_violations
fi
end_case

# ------------------------------------------------------------------
begin_case 'Обрезка вывода по началу блока проверяется на себе'
run_render "$CANON"
expect_status 0
# Два утверждения на одном прогоне, и второе без первого вырождается:
# «в обрезанном выводе нет "observation":» верно и тогда, когда блока нет
# вовсе. Вместе они доказывают и что блок напечатан, и что обрезка работает.
expect_output '"observation":'
if prose_only | grep -qF -- '"observation":'; then
    fail_case 'обрезка не работает: в прозе рендера остался литерал из машиночитаемой формы'
fi
end_case

# ------------------------------------------------------------------
begin_case 'Карточка развилки: обязательна, пустая строка и смешанная форма отвергаются'
run_validate "$(mutate 'del(.fork_card)')"
expect_status 1
expect_output 'план.fork_card: обязательное поле схемы отсутствует'

# Ошибка печатается по ближайшему варианту: «пусто поле ripple» читается,
# «не подошло ни под одну форму» без подробностей — нет.
run_validate "$(mutate '.fork_card.ripple = ""')"
expect_status 1
expect_output 'план.fork_card.ripple: пусто'
expect_output 'план.fork_card: не подходит ни под один вариант схемы'

# Смешанная форма: строка trivial поверх полной карточки. Варианты закрыты
# additionalProperties, поэтому она не проходит ни один.
run_validate "$(mutate '.fork_card.trivial = "опечатка в сообщении"')"
expect_status 1
expect_output 'план.fork_card: не подходит ни под один вариант схемы'

run_validate "$(mutate '.fork_card = {"trivial": ""}')"
expect_status 1
expect_output 'план.fork_card.trivial: пусто'
end_case

# ------------------------------------------------------------------
begin_case 'Карточка развилки: тривиальная правка — одна строка, и она доезжает до рендера'
TRIVIAL="$(mutate '.fork_card = {"trivial": "опечатка в сообщении валидатора, второго способа нет"}')"
run_validate "$TRIVIAL"
expect_status 0
expect_no_violations
run_render "$TRIVIAL"
expect_status 0
expect_prose '**Карточка развилки.**'
expect_prose 'Тривиальная правка: опечатка в сообщении валидатора, второго способа нет'
end_case

# ------------------------------------------------------------------
begin_case 'Карточка развилки: пустые признаки совета — «нет», развилка — предупреждение, а не отказ'
NO_SIGNS="$(mutate '.fork_card.council_signs = []')"
run_validate "$NO_SIGNS"
expect_status 0
expect_no_violations
run_render "$NO_SIGNS"
expect_status 0
expect_prose '**Сработавшие признаки совета:** нет'

# Развилка — триггер «позвать человека», а не дефект плана: код возврата 0,
# но сказано вслух и в отчёте валидатора, и в рендере.
FORKED="$(mutate '.fork_card.fork = true')"
run_validate "$FORKED"
expect_status 0
expect_no_violations
expect_output 'предупреждение: в карточке развилки есть развилка'
run_render "$FORKED"
expect_status 0
expect_prose '**Развилка:** да — триггер «позвать человека»'
end_case

# ------------------------------------------------------------------
begin_case 'Разбор бага: необязателен, а заполненный проверяется по форме и по дереву'
NO_BUG="$(mutate 'del(.bug_analysis)')"
run_validate "$NO_BUG"
expect_status 0
expect_no_violations
# Отсутствующий разбор не печатает ни подписи, ни пустого блока — и не роняет
# рендер проверкой пропущенных полей.
run_render "$NO_BUG"
expect_status 0
expect_no_output '**Разбор бага.**'
run_render "$CANON"
expect_prose '**Разбор бага.**'

run_validate "$(mutate 'del(.bug_analysis.precondition)')"
expect_status 1
expect_output 'план.bug_analysis.precondition: обязательное поле схемы отсутствует'

run_validate "$(mutate '.bug_analysis.root_cause = "scripts/plan.sh"')"
expect_status 1
expect_output 'план.bug_analysis.root_cause: значение «scripts/plan.sh» не по образцу схемы'

run_validate "$(mutate '.bug_analysis.root_cause = "scripts/plan-which-never-was.sh:3"')"
expect_status 1
expect_output 'первопричина разбора бага ссылается на несуществующий путь: scripts/plan-which-never-was.sh'

run_validate "$(mutate '.bug_analysis.root_cause = "scripts/plan.sh:999999"')"
expect_status 1
expect_output 'первопричина разбора бага ссылается на строку 999999, а в scripts/plan.sh строк'

run_validate "$(mutate '.bug_analysis.root_cause = "../home-agent-source/tz-home-agent.md:1"')"
expect_status 1
expect_output 'путь вне репозитория: ../home-agent-source/tz-home-agent.md'

NO_HYP="$(mutate '.bug_analysis.rejected_hypotheses = []')"
run_validate "$NO_HYP"
expect_status 0
expect_no_violations
run_render "$NO_HYP"
expect_status 0
expect_prose '**Отвергнутые гипотезы:** нет'
end_case

# ------------------------------------------------------------------
begin_case 'Предупреждение о размере плана не меняет код возврата'
# Двадцать копий одного файла сужают множество files до scripts/plan.sh, и
# срезы согласованной фикстуры называли бы файлы, которых в плане больше нет.
# Сценарию дан один согласованный срез с причиной: утверждения о размере те же,
# карточка остаётся полной.
run_validate "$(mutate '.files as $f | .files = [range(0; 20) | $f[0]]
    | .fork_card.slices = [{
        "name": "валидатор",
        "files": ["scripts/plan.sh"],
        "contract": "разбор пункта «непроверяем» в одном файле",
        "after": []
      }]
    | .fork_card.single_slice_reason = "один файл — резать нечего"')"
expect_status 0
expect_output 'предупреждение: файлов в плане 20'
expect_no_violations
end_case

# ------------------------------------------------------------------
begin_case 'Новая зависимость: без обоснования отказ, с обоснованием проход'
run_validate "$(mutate '.flags.new_dependency = true')"
expect_status 1
expect_output 'новая зависимость без обоснования'

run_validate "$(mutate '
    .flags.new_dependency = true
    | .flags.new_dependency_reason = "нужна библиотека разбора cron, своего планировщика не пишем"')"
expect_status 1
expect_output 'новая зависимость без ссылки на комментарий issue'

run_validate "$(mutate '
    .flags.new_dependency = true
    | .flags.new_dependency_reason = "разбор cron, обоснование в комментарии #4242"')"
expect_status 0
expect_no_violations
end_case

# ------------------------------------------------------------------
# Срезы. Полная карточка раскладывает файлы плана на срезы — fork_card.slices.
# Согласованная фикстура несёт два среза: «правила» ждёт «валидатор». Каждый
# сценарий портит раскладку одной мутацией и ждёт свой отказ дословно.
# ------------------------------------------------------------------
begin_case 'Срезы: полная карточка без срезов отвергается'
run_validate "$(mutate 'del(.fork_card.slices, .fork_card.single_slice_reason)')"
expect_status 1
expect_output 'нарушение: срезы: в полной карточке развилки нет fork_card.slices — файлы плана раскладываются на срезы'
end_case

# ------------------------------------------------------------------
begin_case 'Срезы: файл в двух срезах отвергается'
run_validate "$(mutate '.fork_card.slices[1].files += ["scripts/plan.sh"]')"
expect_status 1
expect_output 'нарушение: срезы: файл отдан нескольким срезам: scripts/plan.sh — «валидатор», «правила»'
end_case

# ------------------------------------------------------------------
begin_case 'Срезы: объединение срезов не равно files плана'
# Журнал задачи (docs/tasks/**) ни в одном срезе фикстуры не назван — и отказа
# на него нет: журнал ведёт оркестратор, а не срез.
run_validate "$(mutate '.fork_card.slices[0].files -= ["scripts/review-comments.sh"]')"
expect_status 1
expect_output 'нарушение: срезы: файл плана не отдан ни одному срезу: scripts/review-comments.sh'
expect_no_output 'docs/tasks/4242.md'

run_validate "$(mutate '.fork_card.slices[1].files += ["scripts/risk.sh"]')"
expect_status 1
expect_output 'нарушение: срезы: срез «правила» называет файл, которого нет в files плана: scripts/risk.sh'

# Обратная сторона того же исключения: журнал и план задачи ни одному срезу не
# принадлежат, и срез, назвавший их, отвергается — даже когда путь есть в files
# плана. Отказ один: ветка «нет в files плана» на него не срабатывает.
run_validate "$(mutate '.fork_card.slices[0].files += ["docs/tasks/4242.md"]')"
expect_status 1
expect_output 'нарушение: срезы: срез «валидатор» называет журнал или план задачи — их правит оркестратор: docs/tasks/4242.md'
expect_no_output 'нет в files плана: docs/tasks/4242.md'
end_case

# ------------------------------------------------------------------
begin_case 'Срезы: after на несуществующий срез и цикл отвергаются'
run_validate "$(mutate '.fork_card.slices[1].after = ["тексты"]')"
expect_status 1
expect_output 'нарушение: срезы: срез «правила» ждёт несуществующий срез «тексты»'
expect_no_output 'цикл в after'

run_validate "$(mutate '.fork_card.slices[0].after = ["правила"]')"
expect_status 1
expect_output 'нарушение: срезы: цикл в after — не упорядочиваются срезы: «валидатор», «правила»'

# After на себя: остаток — ровно сам срез, упорядоченный «валидатор» в него не
# попадает.
run_validate "$(mutate '.fork_card.slices[1].after = ["правила"]')"
expect_status 1
expect_output 'нарушение: срезы: цикл в after — не упорядочиваются срезы: «правила»'
expect_no_output '«валидатор», «правила»'
end_case

# ------------------------------------------------------------------
begin_case 'Срезы: повторяющееся имя среза отвергается'
run_validate "$(mutate '.fork_card.slices[1].name = "валидатор" | .fork_card.slices[1].after = []')"
expect_status 1
expect_output 'нарушение: срезы: имя среза повторяется: «валидатор»'
end_case

# ------------------------------------------------------------------
begin_case 'Срезы: один срез без причины отвергается, с причиной проходит и доезжает до рендера'
run_validate "$(mutate '.fork_card.slices = [{
        "name": "всё сразу",
        "files": ["scripts/plan.sh", "scripts/review-comments.sh", "docs/rules/plan.md"],
        "contract": "пункт «непроверяем» несёт причину и срок",
        "after": []
      }]')"
expect_status 1
expect_output 'нарушение: срезы: срез один, а single_slice_reason пуст — почему задачу нельзя разрезать, не сказано'

ONE_SLICE="$(mutate '.fork_card.slices = [{
        "name": "всё сразу",
        "files": ["scripts/plan.sh", "scripts/review-comments.sh", "docs/rules/plan.md"],
        "contract": "пункт «непроверяем» несёт причину и срок",
        "after": []
      }]
    | .fork_card.single_slice_reason = "сообщение валидатора и текст правила пишутся одной фразой — разрезанные, они разъедутся"')"
run_validate "$ONE_SLICE"
expect_status 0
expect_no_violations
run_render "$ONE_SLICE"
expect_status 0
expect_prose 'сообщение валидатора и текст правила пишутся одной фразой — разрезанные, они разъедутся'
end_case

# ------------------------------------------------------------------
begin_case 'Срезы: форма среза проверяется схемой'
run_validate "$(mutate '.fork_card.slices = []')"
expect_status 1
expect_output 'план.fork_card.slices: элементов 0, схема требует не меньше 1'

run_validate "$(mutate 'del(.fork_card.slices[0].contract)')"
expect_status 1
expect_output 'план.fork_card.slices[0].contract: обязательное поле схемы отсутствует'
end_case

# ------------------------------------------------------------------
begin_case 'Срезы: trivial без срезов проходит, trivial со срезами отвергается'
run_validate "$(mutate '.fork_card = {"trivial": "опечатка в сообщении валидатора, второго способа нет"}')"
expect_status 0
expect_no_violations

run_validate "$(mutate '.fork_card = {
        "trivial": "опечатка в сообщении валидатора, второго способа нет",
        "slices": .fork_card.slices
      }')"
expect_status 1
expect_output 'план.fork_card.slices: поле не описано схемой'
expect_output 'план.fork_card: не подходит ни под один вариант схемы'
end_case

# ------------------------------------------------------------------
begin_case 'Срезы: номер задачи ниже 148 от срезов не освобождает'
# Порога по номеру нет: номер задачи — не время написания плана.
run_validate "$(mutate '.issue = 9 | del(.fork_card.slices, .fork_card.single_slice_reason)')"
expect_status 1
expect_output 'нарушение: срезы: в полной карточке развилки нет fork_card.slices'
end_case

# ------------------------------------------------------------------
begin_case 'Срезы: при --at проверка срезов не выполняется'
# Один и тот же файл с ключом и без: разницу в выводе даёт ключ, а не план.
# Исторический режим сверяет план с деревом, для которого он писался, а правила
# срезов тогда не было.
NO_SLICES="$(mutate '.issue = 9 | del(.fork_card.slices, .fork_card.single_slice_reason)')"
run_validate "$NO_SLICES" --at HEAD
expect_status 0
expect_no_violations
expect_no_output 'нарушение: срезы:'

run_validate "$NO_SLICES"
expect_status 1
expect_output 'нарушение: срезы: в полной карточке развилки нет fork_card.slices'
end_case

# ------------------------------------------------------------------
# Исторические планы. Пин — база PR, которым задача уехала в main: то самое
# дерево, для которого план писался.
# ------------------------------------------------------------------
# Что каждый пин означает и почему у #83 он не «база PR» — README рядом с
# фикстурами. Короткое правило: пин — вершина main на день, когда план писался.
PIN_93='f2ae89b8c31acdce57c5a4a65654a9bbe0e7d893'
PIN_83='314016dab8d938fc3c4f2bdf606e3777bbe0a1ea'
PIN_81='314016dab8d938fc3c4f2bdf606e3777bbe0a1ea'

begin_case 'Пины исторических планов разрешаются'
for pin in "$PIN_93" "$PIN_83" "$PIN_81"; do
    if ! git -C "$ROOT" rev-parse --verify --quiet "$pin^{commit}" >/dev/null 2>&1; then
        fail_case "пин не разрешается: $pin — сценарий провален, а не пропущен"
    fi
done
end_case

check_historical() {
    local number="$1" pin="$2"
    local fixture="$FIXTURES/$number.json"

    begin_case "Исторический план #$number при --at: ни одного ложного срабатывания"
    if [ ! -f "$fixture" ]; then
        fail_case "нет фикстуры: $fixture"
        end_case
        return
    fi
    run_validate "$fixture" --at "$pin"
    expect_status 0
    expect_no_violations
    end_case
}

check_historical 93 "$PIN_93"
check_historical 83 "$PIN_83"
check_historical 81 "$PIN_81"

# ------------------------------------------------------------------
begin_case 'Без --at план краснеет на разнице деревьев, с --at — нет'
# Доказательство строится во временном репозитории из двух коммитов, а не на
# истории этого: файлы, на которых оно держалось раньше, удаляются, и сценарий
# позеленел бы вместе с ними молча. Коммит A — дерево, для которого план
# писался: файл на правку есть, теста с объявленным именем нет. Коммит B —
# сегодняшнее дерево: файл удалён, тест с тем же именем появился. Разница
# деревьев берётся в обе стороны — путь пропал, имя появилось.
#
# Git здесь пишет только во временный каталог песочницы. Глобальная и
# системная конфигурация отключены: подпись коммитов или хуки на машине
# владельца, как и отсутствие имени автора в CI, иначе роняли бы сценарий
# не по делу.
HIST="$SANDBOX/history"
mkdir -p "$HIST/scripts" "$HIST/docs" "$HIST/tests"
cp "$CHECK" "$SCHEMA" "$HIST/scripts/"

hist_git() {
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$HIST" \
        -c user.name=plan-test -c user.email=plan-test@example.invalid \
        -c commit.gpgsign=false -c core.hooksPath=/dev/null \
        -c core.autocrlf=false -c init.defaultBranch=main "$@"
}

HIST_OK=1
printf 'раздел, который позже удалят\n' > "$HIST/docs/old.md"
printf 'код, который план читает\n' > "$HIST/tests/base.txt"
{ hist_git init -q && hist_git add -A && hist_git commit -q -m 'A'; } >/dev/null 2>&1 || HIST_OK=0
PIN_A="$(hist_git rev-parse HEAD 2>/dev/null | tr -d '\r')"
rm -f "$HIST/docs/old.md"
printf 'сценарий, появившийся позже\n' > "$HIST/tests/later.test.sh"
{ hist_git add -A && hist_git commit -q -m 'B'; } >/dev/null 2>&1 || HIST_OK=0

HPLAN="$SANDBOX/history-plan.json"
jq '.current_state = [{"path": "tests/base.txt", "line": 1, "observation": "код, на который план опирается"}]
    | del(.bug_analysis)
    | .files = [{"path": "docs/old.md", "action": "modify", "why": "раздел, который позже удалят"}]
    | .boundaries = ["docs/**"]
    | .tests = [{
        "name": "сценарий, появившийся позже",
        "file": "tests/later.test.sh",
        "new": true,
        "covers": ["marker-reason", "marker-expiry"],
        "behavior": "имя, которого в дереве плана ещё нет"
      }]' "$CANON" > "$HPLAN"

if [ "$HIST_OK" -ne 1 ] || [ -z "$PIN_A" ]; then
    fail_case 'временный репозиторий не собрался — сценарий провален, а не пропущен'
else
    OUTPUT="$(bash "$HIST/scripts/plan.sh" validate "$HPLAN" --at "$PIN_A" 2>&1)"
    STATUS=$?
    expect_status 0
    expect_no_violations

    OUTPUT="$(bash "$HIST/scripts/plan.sh" validate "$HPLAN" 2>&1)"
    STATUS=$?
    expect_status 1
    expect_output 'путь на modify не существует: docs/old.md'
    expect_output 'тест объявлен новым, но имя уже встречается: сценарий, появившийся позже — в tests/later.test.sh'
fi
end_case

# ------------------------------------------------------------------
begin_case 'Отказ разбора плана роняет валидатор, а не зеленит его молча'
# Содержательные циклы читали план подстановкой процесса, а pipefail на неё не
# распространяется: умерший jq отдал бы циклу ноль строк — ни одного нарушения
# и «План сходится» кодом 0 на плане, который никто не проверял. Подставной jq
# отказывает ровно на одном запросе, поэтому форма разбирается настоящим и
# проходит, а падает первый содержательный цикл.
SHIM_DIR="$SANDBOX/bin"
mkdir -p "$SHIM_DIR"
JQ_REAL="$(command -v jq)"
cat > "$SHIM_DIR/jq" <<SHIM
#!/usr/bin/env bash
for arg in "\$@"; do
    case "\$arg" in
        *current_state*) exit 3 ;;
    esac
done
exec "$JQ_REAL" "\$@"
SHIM
chmod +x "$SHIM_DIR/jq"

OUTPUT="$(PATH="$SHIM_DIR:$PATH" bash "$CHECK" validate "$CANON" 2>&1)"
STATUS=$?
expect_status 2
expect_output 'Разбор плана не отработал'
expect_no_output 'План сходится'
end_case

# ------------------------------------------------------------------
begin_case 'Неразрешимый ref роняет проверку, а не пропускает её'
run_validate "$CANON" --at '0000000000000000000000000000000000000000'
expect_status 2
expect_output 'Ref не разрешается'
end_case

# ------------------------------------------------------------------
begin_case 'Рендер отказывается печатать план, не разбирающийся как JSON'
printf 'это не json\n' > "$SANDBOX/broken.json"
run_render "$SANDBOX/broken.json"
expect_status 2
expect_output 'не разбирается как JSON'
end_case

# ------------------------------------------------------------------
# Сверка плана с диффом — режим drift. Каждый сценарий строит свой временный
# репозиторий в песочнице: без сети, без удалённых репозиториев, git с
# отключённой глобальной и системной конфигурацией — как hist_git выше. Копия
# plan.sh и схемы ложится в первый коммит, поэтому в дифф она не попадает и
# «вне плана» не становится.
# ------------------------------------------------------------------
DRIFT_DIR=''
DRIFT_OK=1
REV=''

drift_git() {
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$DRIFT_DIR" \
        -c user.name=plan-test -c user.email=plan-test@example.invalid \
        -c commit.gpgsign=false -c core.hooksPath=/dev/null \
        -c core.autocrlf=false -c init.defaultBranch=main "$@"
}

drift_init() {
    DRIFT_DIR="$SANDBOX/drift-$1"
    DRIFT_OK=1
    mkdir -p "$DRIFT_DIR/scripts"
    cp "$CHECK" "$SCHEMA" "$DRIFT_DIR/scripts/"
    drift_git init -q >/dev/null 2>&1 || DRIFT_OK=0
}

# Коммит всего дерева; SHA — в REV. Провал сборки репозитория — провал
# сценария, а не пропуск: DRIFT_OK проверяется перед утверждениями.
drift_commit() {
    { drift_git add -A && drift_git commit -q --allow-empty -m "$1"; } >/dev/null 2>&1 || DRIFT_OK=0
    REV="$(drift_git rev-parse HEAD 2>/dev/null | tr -d '\r')"
    [ -n "$REV" ] || DRIFT_OK=0
}

drift_put() {
    mkdir -p "$(dirname "$DRIFT_DIR/$1")"
    printf '%s\n' "$2" > "$DRIFT_DIR/$1"
}

# План сценария — рядом с его репозиторием, а не через mutate: mutate зовётся
# в подстановке, его счётчик в родителе не растёт, и следующая мутация
# перезаписала бы план, который сценарий ещё держит.
drift_plan() {
    local out="$DRIFT_DIR.plan.json"
    jq "$1" "$CANON" > "$out" || return 1
    printf '%s' "$out"
}

run_drift() {
    OUTPUT="$(bash "$DRIFT_DIR/scripts/plan.sh" drift "$@" 2>&1)"
    STATUS=$?
}

drift_ready() {
    if [ "$DRIFT_OK" -ne 1 ]; then
        fail_case 'временный репозиторий не собрался — сценарий провален, а не пропущен'
        return 1
    fi
    return 0
}

expect_last_line() {
    local last
    last="$(printf '%s\n' "$OUTPUT" | tail -n 1 | tr -d '\r')"
    if [ "$last" != "$1" ]; then
        fail_case "последняя строка «$last», ожидалась «$1»"
    fi
}

# Тест-заглушка для планов, где тесты не сверяются: схема требует хотя бы один.
DRIFT_OLD_TEST='{"name": "старый сценарий", "file": "scripts/plan.test.sh", "new": false, "covers": ["marker-reason"], "behavior": "уже есть"}'

# ------------------------------------------------------------------
begin_case 'Сверка с диффом: файл плана без правки и удалённый вместо правки'
drift_init deleted
drift_put a.txt 'a'
drift_put c.txt 'c'
drift_put 'файл.txt' 'было'
drift_commit base
D_BASE="$REV"
drift_put b.txt 'b'
rm -f "$DRIFT_DIR/c.txt"
drift_put 'файл.txt' 'стало'
drift_commit head
D_HEAD="$REV"
D_PLAN="$(drift_plan '.files = [
        {"path": "a.txt", "action": "modify", "why": "x"},
        {"path": "b.txt", "action": "create", "why": "x"},
        {"path": "c.txt", "action": "modify", "why": "x"},
        {"path": "файл.txt", "action": "modify", "why": "x"}
      ] | .tests = ['"$DRIFT_OLD_TEST"']')"
if drift_ready; then
    run_drift "$D_PLAN" "$D_BASE" "$D_HEAD"
    expect_status 0
    expect_output 'расхождение: файл плана не изменён в диффе: a.txt (в плане modify)'
    expect_output 'расхождение: файл плана удалён, а в плане modify: c.txt'
    expect_no_output 'b.txt'
    expect_no_output 'файл.txt'
    expect_last_line 'Расхождений: 2.'
fi
end_case

# ------------------------------------------------------------------
begin_case 'Сверка с диффом: файл на удаление не удалён'
drift_init delete
drift_put old.txt 'было'
drift_commit base
D_BASE="$REV"
drift_put old.txt 'стало'
drift_commit modified
D_MODIFIED="$REV"
rm -f "$DRIFT_DIR/old.txt"
drift_commit deleted
D_DELETED="$REV"
D_PLAN="$(drift_plan '.files = [{"path": "old.txt", "action": "delete", "why": "x"}]
      | .tests = ['"$DRIFT_OLD_TEST"']')"
if drift_ready; then
    run_drift "$D_PLAN" "$D_BASE" "$D_MODIFIED"
    expect_status 0
    expect_output 'расхождение: файл на удаление не удалён: old.txt'

    run_drift "$D_PLAN" "$D_BASE" "$D_DELETED"
    expect_status 0
    expect_no_output 'расхождение: файл на удаление не удалён'
    expect_last_line 'Расхождений нет.'
fi
end_case

# ------------------------------------------------------------------
begin_case 'Сверка с диффом: файл вне плана, журнал и план своей задачи не в счёт'
# Ветка base после точки ветвления получает свой коммит: при диапазоне от
# merge-base (три точки) его файл в дифф не попадает, при base..head — попал бы.
drift_init outside
drift_put p.txt 'было'
drift_commit fork
drift_git checkout -q -b feature >/dev/null 2>&1 || DRIFT_OK=0
drift_put p.txt 'стало'
drift_put extra.txt 'лишнее'
drift_put docs/tasks/4242.md 'журнал своей задачи'
drift_put docs/tasks/4242.plan.json '{}'
drift_put docs/tasks/77.md 'журнал чужой задачи'
drift_commit feature
D_HEAD="$REV"
drift_git checkout -q main >/dev/null 2>&1 || DRIFT_OK=0
drift_put main-only.txt 'ушло в main после ветвления'
drift_commit main
D_BASE="$REV"
D_PLAN="$(drift_plan '.files = [{"path": "p.txt", "action": "modify", "why": "x"}]
      | .tests = ['"$DRIFT_OLD_TEST"']')"
if drift_ready; then
    run_drift "$D_PLAN" "$D_BASE" "$D_HEAD"
    expect_status 0
    expect_output 'расхождение: файл изменён вне плана: extra.txt'
    expect_output 'расхождение: файл изменён вне плана: docs/tasks/77.md'
    expect_no_output 'docs/tasks/4242.md'
    expect_no_output 'docs/tasks/4242.plan.json'
    expect_no_output 'main-only.txt'
    expect_no_output 'p.txt'
    expect_last_line 'Расхождений: 2.'
fi
end_case

# ------------------------------------------------------------------
begin_case 'Сверка с диффом: новый тест без имени в добавленных строках'
# Имя есть в файле на base и удалено на head: в диффе -U0 оно только в строке
# «-», и удалённая строка за добавленную не считается.
drift_init tests
drift_put tests/x.test.sh "begin_case 'сценарий икс'"
drift_commit base
D_BASE="$REV"
drift_put tests/x.test.sh "begin_case 'другой сценарий'"
drift_commit removed
D_REMOVED="$REV"
drift_put tests/x.test.sh "begin_case 'другой сценарий'
begin_case 'сценарий икс'"
drift_commit readded
D_READDED="$REV"
D_PLAN="$(drift_plan '.files = [{"path": "tests/x.test.sh", "action": "modify", "why": "x"}]
      | .tests = [
          {"name": "сценарий икс", "file": "tests/x.test.sh", "new": true, "covers": ["marker-reason"], "behavior": "x"},
          {"name": "сценарий, которого нет нигде", "file": "tests/x.test.sh", "new": false, "covers": ["marker-expiry"], "behavior": "x"}
        ]')"
if drift_ready; then
    run_drift "$D_PLAN" "$D_BASE" "$D_REMOVED"
    expect_status 0
    expect_output 'расхождение: новый тест не найден в добавленных строках tests/x.test.sh: «сценарий икс»'
    expect_no_output 'сценарий, которого нет нигде'
    expect_last_line 'Расхождений: 1.'

    run_drift "$D_PLAN" "$D_REMOVED" "$D_READDED"
    expect_status 0
    expect_no_output 'расхождение:'
    expect_last_line 'Расхождений нет.'
fi
end_case

# ------------------------------------------------------------------
begin_case 'Сверка с диффом: полное совпадение печатает «Расхождений нет.»'
drift_init match
drift_put m.txt 'было'
drift_put gone.txt 'уйдёт'
drift_commit base
D_BASE="$REV"
drift_put m.txt 'стало'
drift_put new.txt 'новое'
rm -f "$DRIFT_DIR/gone.txt"
drift_put tests/y.test.sh "begin_case 'сценарий игрек'"
drift_put docs/tasks/4242.md 'журнал'
drift_commit head
D_HEAD="$REV"
D_PLAN="$(drift_plan '.files = [
        {"path": "m.txt", "action": "modify", "why": "x"},
        {"path": "new.txt", "action": "create", "why": "x"},
        {"path": "gone.txt", "action": "delete", "why": "x"},
        {"path": "tests/y.test.sh", "action": "create", "why": "x"}
      ] | .tests = [{"name": "сценарий игрек", "file": "tests/y.test.sh", "new": true, "covers": ["marker-reason"], "behavior": "x"}]')"
if drift_ready; then
    run_drift "$D_PLAN" "$D_BASE" "$D_HEAD"
    expect_status 0
    if [ -z "$OUTPUT" ]; then
        fail_case 'вывод пуст, а должен нести итоговую строку'
    fi
    expect_no_output 'расхождение:'
    expect_last_line 'Расхождений нет.'
fi
end_case

# ------------------------------------------------------------------
begin_case 'Сверка с диффом: отказы вызова и плана кодом 2'
# Репозиторий и план — из сценария о полном совпадении. У каждого отказа
# проверяется и причина: неизвестный режим тоже даёт код 2, и без текста
# сценарий проходил бы на скрипте, который drift не знает вовсе.
if drift_ready; then
    run_drift "$D_PLAN" "$D_BASE"
    expect_status 2
    expect_output 'drift <файл плана> <base> <head>'
    expect_no_output 'Расхождений'

    run_drift "$D_PLAN" "$D_BASE" "$D_HEAD" лишний
    expect_status 2
    expect_output 'drift <файл плана> <base> <head>'
    expect_no_output 'Расхождений'

    run_drift "$D_PLAN" "$D_BASE" "$D_HEAD" --at "$D_BASE"
    expect_status 2
    expect_output 'drift <файл плана> <base> <head>'
    expect_no_output 'Расхождений'

    run_drift "$D_PLAN" "$D_BASE" --at
    expect_status 2
    expect_output 'drift <файл плана> <base> <head>'
    expect_no_output 'Расхождений'

    run_drift "$D_PLAN" '0000000000000000000000000000000000000000' "$D_HEAD"
    expect_status 2
    expect_output 'Ref не разрешается: 0000000000000000000000000000000000000000'
    expect_no_output 'Расхождений'

    # Коммит без родителей с тем же деревом: общего предка с head у него нет,
    # и диапазон от merge-base не строится — это отказ, а не пустой дифф.
    D_LONELY="$(drift_git commit-tree "$D_BASE^{tree}" -m lonely 2>/dev/null | tr -d '\r')"
    if [ -z "$D_LONELY" ]; then
        fail_case 'коммит без родителей не собрался — сценарий провален, а не пропущен'
    else
        run_drift "$D_PLAN" "$D_LONELY" "$D_HEAD"
        expect_status 2
        expect_output 'нет общего предка'
        expect_no_output 'Расхождений'
    fi

    run_drift "$SANDBOX/drift-нет-такого-плана.json" "$D_BASE" "$D_HEAD"
    expect_status 2
    expect_output 'Не найден файл плана'
    expect_no_output 'Расхождений'

    printf 'это не json\n' > "$SANDBOX/drift-broken.json"
    run_drift "$SANDBOX/drift-broken.json" "$D_BASE" "$D_HEAD"
    expect_status 2
    expect_output 'не разбирается как JSON'
    expect_no_output 'Расхождений'

    run_drift "$(mutate 'del(.files)')" "$D_BASE" "$D_HEAD"
    expect_status 2
    expect_output 'план.files: обязательное поле схемы отсутствует'
    expect_output 'bash scripts/plan.sh validate'
    expect_no_output 'Расхождений'

    # Код не зависит от числа расхождений: тот же план на обращённом
    # диапазоне расходится в каждом файле и всё равно завершается кодом 0.
    run_drift "$D_PLAN" "$D_HEAD" "$D_BASE"
    expect_status 0
    expect_output 'расхождение:'
    expect_no_output 'Расхождений нет.'
fi
end_case

# ------------------------------------------------------------------
printf '\n'
if [ "$FAILED" -gt 0 ]; then
    printf 'Провалившиеся сценарии:\n'
    for name in "${FAILED_NAMES[@]}"; do
        printf '  - %s\n' "$name"
    done
    printf '\n'
fi
printf 'Пройдено: %d, провалено: %d, пропущено: 0\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ] || exit 1
exit 0
