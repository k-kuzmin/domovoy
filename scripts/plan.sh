#!/usr/bin/env bash
#
# Домовой — машиночитаемый план: проверка и рендер в markdown.
#
# ЗАЧЕМ
#
# План согласуется человеком и после этого становится обязательством: ревью
# корректности сверяет с ним результат. До сих пор план был прозой в одном
# поле, и всё, что в нём можно было проверить, проверял читающий — включая то,
# что читающий проверяет плохо: существует ли путь, попадает ли он в границы
# задачи, покрыт ли пункт приёмки хотя бы одним тестом. Ошибка такого рода
# доживала до PR и обнаруживалась там, где уже написан код.
#
# Здесь эта половина работы снята с чтения. Детерминированное ловит
# механическое до публикации плана, чтению остаётся замысел.
#
# ЧТО ПРОВЕРЯЕТСЯ
#
#   Форма — по scripts/plan-schema.json: обязательные поля, типы, enum,
#   пустые строки, поля, не описанные схемой. Проверка формы своего списка
#   полей не имеет вовсе: `required`, `properties`, `enum` и `minLength` она
#   читает из схемы — копия разъезжается со схемой молча.
#
#   У рендера имена полей перечислены — иначе ему нечем печатать каждое своё,
#   — и потому вторая половина того же правила стоит там: поле схемы без ветки
#   рендера роняет рендер кодом 2, а не исчезает из плана. Проверяет это
#   сценарий «Полнота согласованной фикстуры» вместе с проверкой пропущенных
#   полей в конце do_render.
#
#   Семь классов содержательных нарушений:
#     1. путь на modify или delete не существует;
#     2. путь не попадает ни под одну границу задачи;
#     3. защищённая зона оформлена неверно — путь без отметки protected,
#        отметка без флага, отметка на незащищённом пути, конфигурация прав
#        шага с owner=implement;
#     4. пункт контракта приёмки не покрыт ни одним тестом — и обратное:
#        tests[].covers ссылается на пункт, которого в плане нет;
#     5. существующий тест выдан за новый;
#     6. флаг не согласован с путями — в обе стороны;
#     7. способ проверки пуст, либо «непроверяем» без причины.
#
#   Сверх классов: наблюдение раздела «Как устроено сейчас» ссылается на
#   несуществующий путь или на строку за концом файла; путь уводит за дерево
#   репозитория — ведущим «/» или сегментом «..», одинаково в files и в
#   current_state; новая зависимость без обоснования со ссылкой на комментарий
#   issue.
#
#   Предупреждением, не отказом: план больше PLAN_FILES_WARN файлов. Жёсткий
#   предел краснел бы на плане, который человек уже одобрил, то есть запрещал
#   бы то, что решает человек.
#
# ЧЕГО НЕ ЛОВИТ
#
#   Замысел. Верен ли подход, полны ли границы, тот ли способ проверки выбран
#   в контракте — это чтение, и оно описано в docs/rules/review-correctness.md,
#   раздел «Предмет ревью — план».
#
#   Соответствие поля boundaries прозе issue. Границы в теле задачи — текст,
#   множество путей из него механически не выводится. Проверяется внутренняя
#   согласованность плана: files ⊆ boundaries. Что сами границы названы верно,
#   проверяет плановый круг ревью.
#
#   Пункт со значением «непроверяем» освобождён от проверки 4: теста у него по
#   определению нет. Отсюда способ обойти проверку — объявить пункт
#   непроверяемым; причина при нём обязательна, и читает её человек.
#
#   Тексты самих планов и журналы задач исключены из поиска существующих тестов
#   (SEARCH_EXCLUDE): план называет новый тест по имени, и машиночитаемый план,
#   лежащий в репозитории, сделал бы каждый такой тест «уже существующим». То
#   же и с docs/tasks: журнал заводится до плана и цитирует имена сценариев
#   дословно, поэтому при повторном планировании собственное имя теста
#   вернулось бы из журнала как «уже существующее».
#
#   Многострочные значения. Разбор идёт построчно, и перевод строки внутри
#   значения план сломает. Поля плана — одна строка каждое.
#
# КАК ЗАПУСКАТЬ
#
#   bash scripts/plan.sh validate plan.json
#   bash scripts/plan.sh validate scripts/fixtures/plans/93.json --at <ref>
#   bash scripts/plan.sh render   plan.json
#
# Флаг --at <ref> проверяет план против того дерева, для которого он писался:
# существование путей и поиск тестов идут по ref, а не по рабочему каталогу.
# Без него план закрытой задачи краснел бы на путях, которых тогда ещё не
# было, и на тестах, которые с тех пор появились.
#
# Код возврата: 0 — сходится (предупреждения не в счёт), 1 — есть нарушения,
# 2 — ошибка запуска.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCHEMA="$SCRIPT_DIR/plan-schema.json"
PATHS_FILE="$SCRIPT_DIR/protected-paths.sh"

# Ориентир из docs/rules/triage.md — «до 10 файлов». Порог поднят с запасом:
# предупреждение должно отмечать необычный план, а не каждый второй.
PLAN_FILES_WARN=15

# Пути, в которых имя теста — это текст плана или журнала, а не код.
# См. «ЧЕГО НЕ ЛОВИТ».
SEARCH_EXCLUDE=(
    ':(exclude)scripts/fixtures/plans'
    ':(exclude)scripts/plan.test.sh'
    ':(exclude)docs/tasks'
)

die() {
    printf '%s\n' "$1" >&2
    exit 2
}

usage() {
    printf 'Использование: %s <validate|render> <файл плана> [--at <ref>]\n' "$0" >&2
    exit 2
}

COMMAND="${1:-}"
PLAN="${2:-}"
REF=''

case "$COMMAND" in
    validate|render) ;;
    *) usage ;;
esac

[ -n "$PLAN" ] || usage

shift 2
while [ "$#" -gt 0 ]; do
    case "$1" in
        --at)
            REF="${2:-}"
            [ -n "$REF" ] || die 'Ключ --at требует ref.'
            shift 2
            ;;
        *) usage ;;
    esac
done

command -v jq >/dev/null 2>&1 || die 'Не найден jq: без него схему не прочитать.'
[ -f "$SCHEMA" ] || die "Не найдена схема плана: $SCHEMA"
[ -f "$PLAN" ] || die "Не найден файл плана: $PLAN"

PLAN="$(cd "$(dirname "$PLAN")" && pwd)/$(basename "$PLAN")"

jq -e . "$PLAN" >/dev/null 2>&1 || die "Файл плана не разбирается как JSON: $PLAN"
jq -e . "$SCHEMA" >/dev/null 2>&1 || die "Схема не разбирается как JSON: $SCHEMA"

cd "$ROOT" || die "Не удалось перейти в корень репозитория: $ROOT"

# ------------------------------------------------------------------
# Общий список защищённых путей. Пустой или ненайденный список — это не
# «нет защищённых путей», а сломанная проверка.
# ------------------------------------------------------------------
[ -f "$PATHS_FILE" ] || die "Не найден список защищённых путей: $PATHS_FILE"
# shellcheck source=protected-paths.sh
. "$PATHS_FILE"
[ "${#PROTECTED_PATTERNS[@]}" -gt 0 ] || die 'Список защищённых путей пуст.'

PROTECTED_RE="$(protected_regex)"

# Подмножества того же списка, которым соответствуют отдельные метки. Маски
# здесь не переписываются, а сверяются с общим списком по точному совпадению:
# пропажа маски из списка роняет запуск, а не оставляет проверку тихо пустой.
CONTRACT_PATTERNS=(
    'contracts/.+'
    'src/Domovoy\.Mobile\.Core/Generated/.+'
)
MIGRATION_PATTERNS=(
    'src/Domovoy\.Data/Migrations/.+'
)
# Конфигурация прав шага: её правит только оркестратор (запись 0018).
STEP_CONFIG_RE='^\.claude/agents/.+$'

subset_regex() {
    local -n names="$1"
    local pattern known found joined=''
    for pattern in "${names[@]}"; do
        found=0
        for known in "${PROTECTED_PATTERNS[@]}"; do
            if [ "$known" = "$pattern" ]; then
                found=1
                break
            fi
        done
        [ "$found" -eq 1 ] \
            || die "Маска «$pattern» пропала из $PATHS_FILE — проверка флагов стала бы пустой."
        if [ -z "$joined" ]; then
            joined="$pattern"
        else
            joined="$joined|$pattern"
        fi
    done
    printf '^(%s)$' "$joined"
}

CONTRACT_RE="$(subset_regex CONTRACT_PATTERNS)" || exit 2
MIGRATION_RE="$(subset_regex MIGRATION_PATTERNS)" || exit 2

# ------------------------------------------------------------------
# Доступ к дереву: рабочий каталог или ref.
# ------------------------------------------------------------------
if [ -n "$REF" ]; then
    git rev-parse --verify --quiet "$REF^{commit}" >/dev/null 2>&1 \
        || die "Ref не разрешается: $REF"
fi

path_exists() {
    if [ -n "$REF" ]; then
        git cat-file -e "$REF:$1" 2>/dev/null
    else
        [ -e "$1" ]
    fi
}

file_line_count() {
    if [ -n "$REF" ]; then
        git show "$REF:$1" 2>/dev/null | wc -l
    else
        wc -l < "$1" 2>/dev/null
    fi
}

# Печатает файлы, в которых встречается литерал. Код 2 от git grep — это
# сломанный поиск, и он обязан ронять проверку, а не читаться как «не нашли».
search_tree() {
    local literal="$1" out status
    if [ -n "$REF" ]; then
        out="$(git grep -l -F -e "$literal" "$REF" -- "${SEARCH_EXCLUDE[@]}" 2>/dev/null)"
    else
        out="$(git grep -l -F -e "$literal" -- "${SEARCH_EXCLUDE[@]}" 2>/dev/null)"
    fi
    status=$?
    if [ "$status" -gt 1 ]; then
        die "Поиск по дереву не отработал (git grep, код $status)."
    fi
    printf '%s' "$out"
}

glob_to_regex() {
    local glob="$1" out='' ch i n
    n=${#glob}
    i=0
    while [ "$i" -lt "$n" ]; do
        ch="${glob:$i:1}"
        if [ "$ch" = '*' ]; then
            if [ "${glob:$i:2}" = '**' ]; then
                out+='.*'
                i=$((i + 2))
                continue
            fi
            out+='[^/]*'
            i=$((i + 1))
            continue
        fi
        case "$ch" in
            '.'|'['|']'|'('|')'|'^'|'$'|'+'|'?'|'{'|'}'|'|'|'\')
                out+="\\$ch"
                ;;
            *)
                out+="$ch"
                ;;
        esac
        i=$((i + 1))
    done
    printf '^%s$' "$out"
}

matches() {
    printf '%s' "$1" | grep -qE "$2"
}

# Путь пишется от корня репозитория. Ведущий «/» и сегмент «..» выводят план за
# дерево, и проверки, которые должны были бы это поймать, молчат: существование
# без --at считается от корня рабочего каталога, а границы плана такой путь
# авторизуют сами — граница «../**» покрывает «../..». Отсюда отказ до
# остальных проверок: разбирать путь, которого в репозитории быть не может,
# незачем, а file_line_count на нём превращает отчёт валидатора — он едет
# комментарием в публичную issue — в ответ о файле на раннере.
#
# Условие здесь одно на оба места, где путь приходит из плана: files и
# current_state. Второй список тех же двух признаков разъехался бы с первым.
escapes_tree() {
    [ "${1#/}" != "$1" ] || matches "$1" '(^|/)\.\.(/|$)'
}

# Единственный способ звать jq в этом скрипте. На Windows jq отдаёт CRLF, и
# хвостовой возврат каретки превращал бы сравнение путей и идентификаторов в
# ложное: `scripts/**` и `scripts/**` с CR — разные строки, а на глаз
# одинаковые. На Linux tr не меняет ничего, поэтому обёртка одна на обе
# платформы, а не ветка по системе.
pjq() {
    jq --raw-output "$@" | tr -d '\r'
}

# Разделитель полей при разборе строк jq. Табуляция не годится: она входит в
# IFS-пробелы, и `read` схлопывает две подряд идущие в одну — пустая ячейка
# посреди строки сдвинула бы все следующие поля влево, а именно пустую ячейку
# контракта приёмки здесь и ищут. U+001F — разделитель единиц, в тексте плана
# его быть не может. В программах jq он собирается через implode, чтобы в
# исходнике не лежал управляющий байт.
SEP=$'\037'
JOIN='join([31] | implode)'

# ------------------------------------------------------------------
# Отчёт.
# ------------------------------------------------------------------
VIOLATIONS=0

report() {
    printf 'нарушение: %s\n' "$1"
    VIOLATIONS=$((VIOLATIONS + 1))
}

warn() {
    printf 'предупреждение: %s\n' "$1"
}

# ------------------------------------------------------------------
# Форма плана — по схеме. Список полей, типы и enum берутся из файла схемы,
# а не описаны здесь второй раз.
# ------------------------------------------------------------------
FORM_PROGRAM='
def vtype($s; $v):
  ($s.type // null) as $t
  | if $t == null then true
    elif $t == "object"  then ($v | type) == "object"
    elif $t == "array"   then ($v | type) == "array"
    elif $t == "string"  then ($v | type) == "string"
    elif $t == "boolean" then ($v | type) == "boolean"
    elif $t == "integer" then ($v | type) == "number"
    else true
    end;

def check($s; $v; $p):
  if $v == null then
    ["\($p): значение null, схема этого не допускает"]
  elif (vtype($s; $v) | not) then
    ["\($p): ожидался тип \($s.type), в плане \($v | type)"]
  elif ($s.type == "object") then
    ( [ ($s.required // [])[] as $r
        | select(($v | has($r)) | not)
        | "\($p).\($r): обязательное поле схемы отсутствует" ]
    + ( if ($s.additionalProperties == false)
        then [ ($v | keys_unsorted)[] as $k
               | select((($s.properties // {}) | has($k)) | not)
               | "\($p).\($k): поле не описано схемой" ]
        else [] end )
    + [ ($v | keys_unsorted)[] as $k
        | if (($s.properties // {}) | has($k))
          then check($s.properties[$k]; $v[$k]; "\($p).\($k)")[]
          else empty end ] )
  elif ($s.type == "array") then
    ( ( if (($v | length) < ($s.minItems // 0))
        then ["\($p): элементов \($v | length), схема требует не меньше \($s.minItems)"]
        else [] end )
    + [ range(0; $v | length) as $i
        | check($s.items; $v[$i]; "\($p)[\($i)]")[] ] )
  else
    ( ( if (($s.enum // null) != null) and (($s.enum | index($v)) == null)
        then ["\($p): значение «\($v)» вне enum схемы: \($s.enum | join(", "))"]
        else [] end )
    + ( if (($s.minLength // 0) > 0)
           and (($v | type) == "string")
           and (($v | length) < $s.minLength)
        then ["\($p): пусто, схема требует не меньше \($s.minLength) символов"]
        else [] end ) )
  end;

check($schema_in[0]; $plan_in[0]; "план") | .[]
'

check_form() {
    local errors line
    # Файлами, а не --argjson: план и схема целиком в аргументе упираются в
    # предел длины командной строки, и проверка формы отказывала бы ровно на
    # больших планах — то есть там, где нужнее всего.
    errors="$(pjq -n \
        --slurpfile schema_in "$SCHEMA" \
        --slurpfile plan_in "$PLAN" \
        "$FORM_PROGRAM")" || die 'Проверка формы не отработала.'

    [ -z "$errors" ] && return 0

    while IFS= read -r line; do
        [ -n "$line" ] && report "$line"
    done <<< "$errors"
    return 1
}

# ------------------------------------------------------------------
# Содержательные проверки.
# ------------------------------------------------------------------
check_current_state() {
    local path line observation lines rows
    rows="$(pjq ".current_state[] | [.path, (.line | tostring), .observation] | $JOIN" "$PLAN")" \
        || die 'Разбор плана не отработал (current_state).'
    while IFS="$SEP" read -r path line observation; do
        [ -z "$path" ] && continue
        if escapes_tree "$path"; then
            report "наблюдение «как устроено сейчас» ссылается на путь вне репозитория: $path — путь пишется от корня, без ведущего «/» и без сегмента «..»"
            continue
        fi
        if ! path_exists "$path"; then
            report "наблюдение «как устроено сейчас» ссылается на несуществующий путь: $path"
            continue
        fi
        [ "$line" -eq 0 ] && continue
        lines="$(file_line_count "$path")"
        lines="${lines// /}"
        if [ -n "$lines" ] && [ "$line" -gt "$lines" ]; then
            report "наблюдение ссылается на строку $line, а в $path строк $lines"
        fi
    done <<< "$rows"
}

check_flag() {
    local name="$1" value="$2" seen="$3" what="$4"
    if [ "$seen" -eq 1 ] && [ "$value" != 'true' ]; then
        report "флаг $name не заявлен, а в плане есть $what"
    fi
    if [ "$seen" -eq 0 ] && [ "$value" = 'true' ]; then
        report "флаг $name заявлен, но ни один путь плана под него не подпадает"
    fi
}

check_files() {
    local path action owner protected why boundary covered rows
    local total=0
    local -a boundaries=()

    rows="$(pjq '.boundaries[]' "$PLAN")" || die 'Разбор плана не отработал (boundaries).'
    while IFS= read -r boundary; do
        [ -n "$boundary" ] && boundaries+=("$boundary")
    done <<< "$rows"

    local allow_protected allow_contract destructive
    allow_protected="$(pjq '.flags.allow_protected' "$PLAN")"
    allow_contract="$(pjq '.flags.allow_contract' "$PLAN")"
    destructive="$(pjq '.flags.destructive_migration' "$PLAN")"

    local seen_protected=0 seen_contract=0 seen_migration=0

    rows="$(pjq ".files[] | [.path, .action, .owner, (.protected | tostring), .why] | $JOIN" "$PLAN")" \
        || die 'Разбор плана не отработал (files).'
    while IFS="$SEP" read -r path action owner protected why; do
        [ -z "$path" ] && continue
        total=$((total + 1))

        # Условие вынесено в escapes_tree — там же причина, по которой отказ
        # стоит до остальных проверок.
        if escapes_tree "$path"; then
            report "путь вне репозитория: $path — путь пишется от корня, без ведущего «/» и без сегмента «..»"
            continue
        fi

        # Класс 1. Править можно только то, что есть. Для create проверки нет
        # намеренно: план пишется до кода, и «файл уже существует» на
        # историческом плане означало бы, что задача сделана, а не что план
        # неверен.
        if [ "$action" != 'create' ] && ! path_exists "$path"; then
            report "путь на $action не существует: $path"
        fi

        # Класс 2.
        covered=0
        for boundary in "${boundaries[@]}"; do
            if matches "$path" "$(glob_to_regex "$boundary")"; then
                covered=1
                break
            fi
        done
        if [ "$covered" -eq 0 ]; then
            report "путь вне границ задачи: $path — ни одна граница не покрывает: ${boundaries[*]}"
        fi

        # Класс 3.
        if matches "$path" "$PROTECTED_RE"; then
            seen_protected=1
            if [ "$protected" != 'true' ]; then
                report "защищённый путь без отметки protected: $path"
            fi
            if [ "$allow_protected" != 'true' ]; then
                report "защищённый путь при flags.allow_protected=false: $path — гейт целостности завернёт PR"
            fi
        elif [ "$protected" = 'true' ]; then
            report "отметка protected на незащищённом пути: $path"
        fi

        if matches "$path" "$STEP_CONFIG_RE" && [ "$owner" != 'orchestrator' ]; then
            report "конфигурация прав шага с owner=$owner: $path — такую правку делает оркестратор, запись 0018"
        fi

        matches "$path" "$CONTRACT_RE" && seen_contract=1
        matches "$path" "$MIGRATION_RE" && seen_migration=1
    done <<< "$rows"

    # Класс 6. Флаг и пути сверяются в обе стороны: заявленный без повода флаг
    # просит у человека метку, которая ничего не разрешает.
    check_flag 'allow_protected' "$allow_protected" "$seen_protected" 'защищённый путь'
    check_flag 'allow_contract' "$allow_contract" "$seen_contract" 'путь контракта API'
    check_flag 'destructive_migration' "$destructive" "$seen_migration" 'путь под миграциями'

    if [ "$total" -gt "$PLAN_FILES_WARN" ]; then
        warn "файлов в плане $total, ориентир — до $PLAN_FILES_WARN. Если размер принят осознанно, это просто отметка"
    fi
}

check_acceptance() {
    local unverifiable id criterion method evidence rows
    local -a ids=()
    unverifiable="$(pjq '.properties.acceptance["x-unverifiable"]' "$SCHEMA")"
    [ -n "$unverifiable" ] && [ "$unverifiable" != 'null' ] \
        || die 'В схеме нет значения x-unverifiable: различать «способа нет» и «забыли» стало нечем.'

    local -a covered=()
    rows="$(pjq '.tests[].covers[]' "$PLAN")" || die 'Разбор плана не отработал (tests[].covers).'
    while IFS= read -r id; do
        [ -n "$id" ] && covered+=("$id")
    done <<< "$rows"

    local found c
    rows="$(pjq ".acceptance[] | [.id, .criterion, .method, .evidence] | $JOIN" "$PLAN")" \
        || die 'Разбор плана не отработал (acceptance).'
    while IFS="$SEP" read -r id criterion method evidence; do
        [ -z "$id" ] && continue
        ids+=("$id")

        # Класс 7.
        if [ -z "$method" ]; then
            report "пункт приёмки «$id» без способа проверки: пустую ячейку не отличить от забытой, «$unverifiable» с причиной — отличить"
            continue
        fi
        if [ "$method" = "$unverifiable" ]; then
            if [ -z "$evidence" ]; then
                report "пункт приёмки «$id» помечен «$unverifiable» без причины"
            fi
            # Класс 4 к непроверяемому пункту неприменим: теста у него нет по
            # определению. Названо в шапке, раздел «ЧЕГО НЕ ЛОВИТ».
            continue
        fi
        if [ -z "$evidence" ]; then
            report "пункт приёмки «$id» без доказательства: способ есть, а что считать пройденным — нет"
        fi

        # Класс 4.
        found=0
        for c in ${covered[@]+"${covered[@]}"}; do
            if [ "$c" = "$id" ]; then
                found=1
                break
            fi
        done
        [ "$found" -eq 1 ] || report "пункт приёмки «$id» не покрыт ни одним тестом"
    done <<< "$rows"

    # Обратная сторона класса 4. Опечатка в tests[].covers ссылается в пустоту
    # и молчит, пока каждый настоящий пункт покрыт другим тестом: покрытие
    # выглядит полным, а один тест на самом деле не закрывает ничего.
    local test_name cover
    rows="$(pjq ".tests[] | .name as \$n | .covers[] | [\$n, .] | $JOIN" "$PLAN")" \
        || die 'Разбор плана не отработал (tests[].name + covers).'
    while IFS="$SEP" read -r test_name cover; do
        [ -z "$cover" ] && continue
        found=0
        for c in ${ids[@]+"${ids[@]}"}; do
            if [ "$c" = "$cover" ]; then
                found=1
                break
            fi
        done
        [ "$found" -eq 1 ] \
            || report "тест «$test_name» покрывает несуществующий пункт приёмки: «$cover»"
    done <<< "$rows"
}

check_tests() {
    local name file new behavior hits rows
    rows="$(pjq ".tests[] | [.name, .file, (.new | tostring), .behavior] | $JOIN" "$PLAN")" \
        || die 'Разбор плана не отработал (tests).'
    while IFS="$SEP" read -r name file new behavior; do
        [ -z "$name" ] && continue
        [ "$new" = 'true' ] || continue

        # Класс 5.
        hits="$(search_tree "$name" | tr '\n' ' ')"
        hits="${hits% }"
        if [ -n "$hits" ]; then
            report "тест объявлен новым, но имя уже встречается: $name — в $hits"
        fi
    done <<< "$rows"
}

check_dependency() {
    local declared reason
    declared="$(pjq '.flags.new_dependency' "$PLAN")"
    reason="$(pjq '.flags.new_dependency_reason' "$PLAN")"
    [ "$declared" = 'true' ] || return 0

    if [ -z "$reason" ]; then
        report 'новая зависимость без обоснования: правила проекта требуют обоснования в комментарии к issue до установки'
        return 0
    fi
    if ! printf '%s' "$reason" | grep -qE '(#[0-9]+|https?://)'; then
        report "новая зависимость без ссылки на комментарий issue: «$reason»"
    fi
}

do_validate() {
    if ! check_form; then
        printf '\nФорма плана не сходится со схемой — содержательные проверки не запускались.\n'
        printf 'Нарушений: %d\n' "$VIOLATIONS"
        exit 1
    fi

    check_current_state
    check_files
    check_acceptance
    check_tests
    check_dependency

    printf '\n'
    if [ "$VIOLATIONS" -gt 0 ]; then
        printf 'Нарушений: %d. План согласовывать рано.\n' "$VIOLATIONS"
        exit 1
    fi
    printf 'План сходится: нарушений нет.\n'
    exit 0
}

# ------------------------------------------------------------------
# Рендер. Заголовки и порядок разделов берутся из схемы: поле, добавленное в
# схему без ветки рендера, обязано ронять рендер, а не исчезать из
# опубликованного плана молча.
# ------------------------------------------------------------------
RENDERED=''

# Значение, попадающее в ячейку таблицы markdown. Пайп внутри значения
# разъезжает строку таблицы в опубликованном комментарии, и на способе
# проверки вида `grep -nE 'a|b'` это не гипотеза. Экранирование — только для
# ячеек: в списках и абзацах «\|» было бы видно как мусор. split/join, а не
# gsub: в замене gsub обратный слэш разбирается, и правило пришлось бы
# держать в голове при каждой правке.
CELL='def cell: split("|") | join("\\|");'

render_field() {
    local key="$1"
    case "$key" in
        issue)
            pjq '"**Задача:** #\(.issue)"' "$PLAN"
            ;;
        current_state)
            pjq '.current_state[]
                | "- `\(.path)`" + (if .line > 0 then ":\(.line)" else "" end)
                  + " — \(.observation)"' "$PLAN"
            ;;
        approach)
            pjq '.approach.summary' "$PLAN"
            if [ "$(pjq '.approach.rejected | length' "$PLAN")" -gt 0 ]; then
                printf '\n**Отвергнутые варианты.**\n\n'
                pjq '.approach.rejected[] | "- \(.option) — \(.reason)"' "$PLAN"
            fi
            ;;
        files)
            printf '| Файл | Действие | Кто правит | Защищённый | Зачем |\n'
            printf '|---|---|---|---|---|\n'
            pjq "$CELL"'
                .files[]
                | "| `\(.path | cell)` | \(.action) | \(.owner) | "
                  + (if .protected then "да" else "нет" end)
                  + " | \(.why | cell) |"' "$PLAN"
            ;;
        boundaries)
            pjq '.boundaries[] | "- `\(.)`"' "$PLAN"
            ;;
        flags)
            # Перебором ключей, а не списком: новый флаг схемы печатается сам.
            pjq '.flags | to_entries[]
                | if (.value | type) == "boolean"
                  then "- `\(.key)` — " + (if .value then "да" else "нет" end)
                  elif (.value | length) > 0
                  then "- `\(.key)` — \(.value)"
                  else empty end' "$PLAN"
            ;;
        tests)
            printf '| Тест | Файл | Новый | Покрывает | Проверяемое поведение |\n'
            printf '|---|---|---|---|---|\n'
            pjq "$CELL"'
                .tests[]
                | "| \(.name | cell) | `\(.file | cell)` | "
                  + (if .new then "да" else "нет" end)
                  + " | \(.covers | map(cell) | join(", ")) | \(.behavior | cell) |"' "$PLAN"
            ;;
        acceptance)
            printf '| Пункт критерия | Способ проверки | Что считается доказательством |\n'
            printf '|---|---|---|\n'
            pjq "$CELL"'
                .acceptance[]
                | "| **\(.id | cell).** \(.criterion | cell) | \(.method | cell) | \(.evidence | cell) |"' "$PLAN"
            ;;
        risks)
            pjq '.risks | to_entries[]
                | "\(.key + 1). \(.value.risk) **Мера:** \(.value.mitigation)"' "$PLAN"
            ;;
        out_of_scope)
            pjq '.out_of_scope[] | "- \(.)"' "$PLAN"
            ;;
        *)
            die "Нет ветки рендера для поля схемы «$key»: раздел молча исчез бы из опубликованного плана."
            ;;
    esac
    RENDERED="$RENDERED$key"$'\n'
}

do_render() {
    local num key title label into missed=''

    # Поля, печатающиеся до первого раздела.
    while IFS= read -r key; do
        [ -z "$key" ] && continue
        render_field "$key"
        printf '\n'
    done < <(pjq '.properties | to_entries[]
        | select(.value["x-render-into"] == 0) | .key' "$SCHEMA")

    while IFS="$SEP" read -r num key title; do
        [ -z "$key" ] && continue
        printf '## %s. %s\n\n' "$num" "$title"
        render_field "$key"

        while IFS="$SEP" read -r into label; do
            [ -z "$into" ] && continue
            printf '\n**%s.**\n\n' "$label"
            render_field "$into"
        done < <(pjq --argjson n "$num" ".properties | to_entries[]
            | select(.value[\"x-render-into\"] == \$n)
            | [.key, (.value[\"x-label\"] // .key)] | $JOIN" "$SCHEMA")

        printf '\n'
    done < <(pjq ".properties | to_entries
        | map(select(.value[\"x-section\"] != null))
        | sort_by(.value[\"x-section\"])[]
        | [(.value[\"x-section\"] | tostring), .key, .value[\"x-title\"]] | $JOIN" "$SCHEMA")

    # Поле схемы, до которого рендер не дошёл, — это потерянный раздел.
    while IFS= read -r key; do
        [ -z "$key" ] && continue
        printf '%s' "$RENDERED" | grep -qxF -- "$key" || missed="$missed $key"
    done < <(pjq '.properties | keys_unsorted[]' "$SCHEMA")

    [ -z "$missed" ] || die "Поля схемы не попали в рендер:$missed"
    exit 0
}

case "$COMMAND" in
    validate) do_validate ;;
    render) do_render ;;
esac
