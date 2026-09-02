#!/usr/bin/env bash
#
# БЕЗ ОБВЯЗКИ: локальный инструмент, ТЗ фазы 2 требует запуска руками на всех
# фазах; из CI зовётся только его харнесс scripts/risk-score.test.sh.
#
# Домовой — риск-скор: уровень задачи считается по фактам, а не по мнению.
#
# ЗАЧЕМ
#
# Маршрут задачи — насколько внимательно её читают, сколько кругов ревью, что
# требует апрува — должен зависеть от того, что задача трогает, а не от того,
# как она выглядит. Здесь считается ровно уровень и список сработавших
# сигналов. Маршрутизации, кода возврата по уровню и любой блокировки нет: это
# фаза 7, а до неё скрипт сообщает факт.
#
# ГДЕ ЛЕЖИТ ЗНАНИЕ
#
# Ни одного пути, слова и порога в этом файле нет: всё в pipeline/risk.json.
# Скрипт — движок, конфиг — таблица сигналов. Формат JSON, а не risk.yaml из
# буквы ТЗ: парсера YAML в обвязке нет, jq уже обязателен и для валидатора
# плана, и для хука границ шага. Обоснование —
# docs/decisions/0019-risk-config-json-not-yaml.md.
#
# ТРИ СБОРЩИКА ФАКТОВ, ОДИН ДВИЖОК
#
#   plan <файл>          — до реализации: files[].path и flags машиночитаемого
#                          плана. Диффа ещё нет, поэтому размер и ключевые
#                          слова не считаются, и режим это печатает.
#   diff <base> <head>   — после реализации: имена файлов, добавленные строки,
#                          numstat.
#   history              — по коммитам ветки, заголовок которых оканчивается
#                          номером PR: состав корпуса по путям, распределение
#                          размеров с процентилями и таблица «PR → уровень →
#                          сигналы». Первые два блока от порогов не зависят —
#                          из них пороги и берутся.
#
# КАК ЗАПУСКАТЬ
#
#   bash scripts/risk-score.sh plan scripts/fixtures/plans/93.json
#   bash scripts/risk-score.sh diff main HEAD
#   bash scripts/risk-score.sh history
#
# Ключи: --config <файл> (другая таблица сигналов), --repo <каталог> (другой
# репозиторий — так работают сценарии харнесса), --base <ref> (ветка истории).
#
# Код возврата: 0 — посчитано, 2 — запуск не состоялся (аргументы, конфиг,
# неразрешимый ref). Кода возврата, зависящего от уровня, нет и не будет до
# фазы 7: сейчас это факт, а не решение.
#
# О ЧИСЛЕ ПРОЦЕССОВ
#
# Сопоставление путей и разбор глобов сделаны средствами оболочки, а регулярные
# выражения собраны один раз на старте, а не на каждый сигнал и коммит. Причина
# не в красоте: под Windows запуск процесса стоит на два порядка дороже, чем под
# Linux, а движок в режиме history зовётся на каждый коммит корпуса. Наивная
# версия того же кода считала историю тринадцать минут.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CONFIG="$ROOT/pipeline/risk.json"
REPO="$ROOT"
BASE_REF='main'

# Разделители внутренних склеек. Печатных здесь быть не может: регулярки
# ключевых слов содержат «|», глобы — «*» и «.», и любой видимый символ однажды
# встретится внутри значения. В jq они уезжают через --arg, а не литералом.
JOIN=$'\001'
FS=$'\002'

die() {
    printf '%s\n' "$1" >&2
    exit 2
}

usage() {
    printf 'Использование:\n'
    printf '  bash scripts/risk-score.sh plan <файл плана> [--config <файл>]\n'
    printf '  bash scripts/risk-score.sh diff <base> <head> [--config <файл>] [--repo <каталог>]\n'
    printf '  bash scripts/risk-score.sh history [--base <ref>] [--config <файл>] [--repo <каталог>]\n'
}

# ------------------------------------------------------------------
# Аргументы
# ------------------------------------------------------------------
MODE="${1:-}"
if [ -z "$MODE" ]; then
    usage >&2
    exit 2
fi
shift

POSITIONAL=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --config)
            [ "$#" -ge 2 ] || die 'Ключу --config нужен файл.'
            CONFIG="$2"
            shift 2
            ;;
        --repo)
            [ "$#" -ge 2 ] || die 'Ключу --repo нужен каталог.'
            REPO="$2"
            shift 2
            ;;
        --base)
            [ "$#" -ge 2 ] || die 'Ключу --base нужен ref.'
            BASE_REF="$2"
            shift 2
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        -*)
            usage >&2
            die "Неизвестный ключ: $1"
            ;;
        *)
            POSITIONAL+=("$1")
            shift
            ;;
    esac
done

command -v jq >/dev/null 2>&1 || die 'Не найден jq: таблица сигналов читается им.'

# jq под Windows пишет CRLF, и возврат каретки уезжает внутрь значения: «true»
# перестаёт равняться «true», а порог перестаёт быть числом. Ломается это
# молча — уровень выходит low на задаче, которую никто не мерил, — поэтому
# чтение конфига идёт через одну обёртку, а не через jq напрямую.
jq_r() {
    jq -r "$@" | tr -d '\r'
}

# ------------------------------------------------------------------
# Конфиг: разбирается и проверяется до любого счёта. Сломанная таблица сигналов
# обязана ронять скрипт, а не давать «low» на задаче, которую никто не мерил.
# ------------------------------------------------------------------
[ -f "$CONFIG" ] || die "Не найден конфиг сигналов: $CONFIG"

if ! jq empty "$CONFIG" >/dev/null 2>&1; then
    die "Конфиг сигналов не разбирается как JSON: $CONFIG"
fi

# Отказ разбора здесь не глушится и не сходит за «нарушений нет»: проверка,
# которая молча не состоялась, зеленит любой конфиг. Ровно на этом первая
# версия запроса и попалась — `has(.)` внутри конвейера получает не имя поля, а
# сам объект сигнала, запрос падал, а вывод уезжал в /dev/null.
if ! CONFIG_ERRORS="$(jq_r '
    ["id","title","level","enabled","kind","paths","plan_flags","keywords","keyword_paths","note"] as $required
    | if (.signals | type) != "array" then
          "в конфиге нет массива signals"
      elif (.signals | length) == 0 then
          "в конфиге пустой массив signals"
      else
          (.signals | to_entries[]) as $e
          | $e.value as $s
          | ($s.id // "№\($e.key)") as $name
          | (
              ($required[] as $field | select(($s | has($field)) | not)
                  | "сигнал \($name): нет обязательного поля \($field)"),
              (select(["low","medium","high"] | index($s.level // "") | not)
                  | "сигнал \($name): уровень «\($s.level)» не из low|medium|high"),
              (select(["match","size","metric"] | index($s.kind // "") | not)
                  | "сигнал \($name): вид «\($s.kind)» не из match|size|metric"),
              (select(($s.enabled | type) != "boolean")
                  | "сигнал \($name): enabled должен быть true или false"),
              (select((($s.keywords // []) | length) > 0
                      and (($s.keyword_paths // []) | length) == 0)
                  | "сигнал \($name): непустой keywords при пустой области keyword_paths. Область действия ключевых слов обязательна: без неё сигнал срабатывает на тексте правил, журналов и самого конфига"),
              (select((($s.paths // []) + ($s.keyword_paths // []))
                      | any((type != "string") or (. == "")))
                  | "сигнал \($name): пустой или нестроковый шаблон пути в paths или keyword_paths. Проверка выше смотрит на длину списка, и «[\"\"]» её проходит: длина 1, а сборка регулярки пустой элемент выбрасывает, альтернатива выходит пустой, и половина сигнала выключается молча"),
              (select(($s.keywords // []) | any((type != "string") or (. == "")))
                  | "сигнал \($name): пустой или нестроковый элемент keywords. Слова склеиваются в одну альтернативу как есть, без выбрасывания пустых: висячая черта совпадает с любой строкой области, и сигнал даёт ложное срабатывание с пустым словом в качестве причины. Единственный пустой элемент даёт обратное — альтернатива выходит пустой, и словарная половина выключается молча")
            )
      end
' "$CONFIG")"; then
    die "Разбор конфига сигналов не отработал: $CONFIG — проверка не состоялась."
fi

if [ -n "$CONFIG_ERRORS" ]; then
    printf 'Конфиг сигналов не сходится:\n' >&2
    printf '%s\n' "$CONFIG_ERRORS" >&2
    exit 2
fi

IFS="$FS" read -r THRESHOLD_LINES THRESHOLD_FILES PERCENTILE PERCENTILE_METHOD \
    <<< "$(jq_r --arg fs "$FS" '[
        ((.thresholds.diff_lines // "нет") | tostring),
        ((.thresholds.diff_files // "нет") | tostring),
        ((.thresholds.percentile // 75) | tostring),
        (.thresholds.percentile_method // "nearest-rank")
    ] | join($fs)' "$CONFIG")"

# Пороги — единственные значения конфига, которые уезжают в арифметику test, а
# `[ 2110 -gt "1538 строк" ]` не ошибка сравнения: test возвращает 2, оба
# условия сигнала размера становятся ложными, и крупный дифф объявляется low
# без единой строчки о том, что порог не прочитан. Проверка полей сигналов
# thresholds не смотрит вовсе, поэтому отбивается здесь — сразу после чтения.
# «нет» законно: это первый проход, когда порогов ещё не мерили.
case "$THRESHOLD_LINES" in
    'нет') ;;
    '' | *[!0-9]*) die "Порог строк в конфиге не число: «$THRESHOLD_LINES» ($CONFIG)." ;;
esac

case "$THRESHOLD_FILES" in
    'нет') ;;
    '' | *[!0-9]*) die "Порог файлов в конфиге не число: «$THRESHOLD_FILES» ($CONFIG)." ;;
esac

# Процентиль тем же read читается и так же молча ломает счёт: он уезжает в
# `awk -v p="$PERCENTILE"`, нечисловое значение даёт p/100 = 0, индекс
# зажимается в единицу, и первый проход history печатает минимум корпуса под
# подписью p75. Отказа нет, кода возврата нет — а из этого числа берётся порог,
# на котором держится единственный сработавший в истории сигнал.
case "$PERCENTILE" in
    '' | *[!0-9]*) die "Процентиль в конфиге не число: «$PERCENTILE» ($CONFIG)." ;;
esac

# Метод зашит в percentile(): nearest-rank без интерполяции. Поле в конфиге
# остаётся потому, что отчёт печатает его как метод расчёта, — и ровно поэтому
# чужое значение отбивается: иначе отчёт назвал бы метод, которым не считали.
case "$PERCENTILE_METHOD" in
    'nearest-rank') ;;
    *) die "Метод процентиля в конфиге не поддержан: «$PERCENTILE_METHOD» ($CONFIG). Допустим ровно nearest-rank — интерполяции в percentile() нет." ;;
esac

# ------------------------------------------------------------------
# Глоб → тело регулярного выражения. Поддержаны * (внутри сегмента) и **
# (любая глубина) — те же две формы, что у границ плана в scripts/plan.sh.
# Средствами оболочки, без sed: функция зовётся на каждый глоб каждого сигнала.
# ------------------------------------------------------------------
GLOB_RE=''
glob_to_re() {
    local g="$1" out='' i ch
    local len="${#g}"
    for ((i = 0; i < len; i++)); do
        ch="${g:i:1}"
        case "$ch" in
            '*')
                if [ "${g:i+1:1}" = '*' ]; then
                    out+='.*'
                    i=$((i + 1))
                else
                    out+='[^/]*'
                fi
                ;;
            '.' | '^' | '$' | '(' | ')' | '[' | ']' | '{' | '}' | '?' | '+' | '|' | '\')
                out+="\\$ch"
                ;;
            *)
                out+="$ch"
                ;;
        esac
    done
    GLOB_RE="$out"
}

# Склеенный список глобов → тело альтернативы. Пустой список — пустой ответ:
# у сигнала этой половины просто нет.
GLOBS_RE=''
globs_to_re() {
    local joined="$1" glob out=''
    local -a parts=()
    IFS="$JOIN" read -r -a parts <<< "$joined"
    for glob in "${parts[@]:-}"; do
        [ -z "$glob" ] && continue
        glob_to_re "$glob"
        [ -n "$out" ] && out+='|'
        out+="$GLOB_RE"
    done
    GLOBS_RE="$out"
}

# ------------------------------------------------------------------
# Таблица сигналов читается одним запросом: движок в режиме history зовётся на
# каждый коммит корпуса, и чтение по полю на сигнал стоило бы сотен процессов.
# Регулярные выражения собираются здесь же — один раз, а не на каждый вызов.
# ------------------------------------------------------------------
SIG_ID=()
SIG_TITLE=()
SIG_LEVEL=()
SIG_ENABLED=()
SIG_KIND=()
SIG_NOTE=()
SIG_PATHS_RE=()
SIG_FLAGS=()
SIG_KW_RE=()
SIG_KWSCOPE_RE=()

# Объединение областей всех включённых словарных сигналов: по нему видно, нужен
# ли вообще дорогой дифф с добавленными строками.
KW_SCOPE_UNION=''

while IFS= read -r row; do
    [ -z "$row" ] && continue
    IFS="$FS" read -r c_id c_title c_level c_enabled c_kind c_paths c_flags c_kw c_kwpaths c_note \
        <<< "$row"

    SIG_ID+=("$c_id")
    SIG_TITLE+=("$c_title")
    SIG_LEVEL+=("$c_level")
    SIG_ENABLED+=("$c_enabled")
    SIG_KIND+=("$c_kind")
    SIG_NOTE+=("$c_note")
    SIG_FLAGS+=("$c_flags")

    globs_to_re "$c_paths"
    SIG_PATHS_RE+=("$GLOBS_RE")

    globs_to_re "$c_kwpaths"
    SIG_KWSCOPE_RE+=("$GLOBS_RE")

    if [ -n "$c_kw" ] && [ "$c_enabled" = 'true' ] && [ -n "$GLOBS_RE" ]; then
        [ -n "$KW_SCOPE_UNION" ] && KW_SCOPE_UNION+='|'
        KW_SCOPE_UNION+="$GLOBS_RE"
    fi

    # Ключевые слова — уже регулярки; альтернатива из них собирается как есть.
    # Пустой элемент здесь не выбрасывается, в отличие от globs_to_re: висячая
    # черта совпала бы с любой строкой области. Отбивается он проверкой конфига
    # выше — до того, как из него соберут регулярку.
    SIG_KW_RE+=("${c_kw//"$JOIN"/|}")
done < <(jq_r --arg fs "$FS" --arg sep "$JOIN" '.signals[] | [
        .id, .title, .level, (.enabled | tostring), .kind,
        (.paths | join($sep)),
        (.plan_flags | join($sep)),
        (.keywords | join($sep)),
        (.keyword_paths | join($sep)),
        .note
    ] | join($fs)' "$CONFIG")

SIGNAL_COUNT="${#SIG_ID[@]}"
[ "$SIGNAL_COUNT" -gt 0 ] || die "Таблица сигналов не прочиталась: $CONFIG"

# Инвариант на сам разбор: строк прочитано столько же, сколько сигналов в
# конфиге. Значение с переводом строки внутри (в JSON это законная строка
# "a\nb") разрезало бы запись пополам, поля разъехались бы, и уровень стал бы
# мусором — то есть «low» на задаче, которую никто не мерил. Разъехавшийся
# разбор обязан отказывать, а не считать дальше.
CONFIG_SIGNALS="$(jq_r '.signals | length' "$CONFIG")"
if [ "$SIGNAL_COUNT" != "$CONFIG_SIGNALS" ]; then
    die "Разбор таблицы сигналов разъехался: прочитано $SIGNAL_COUNT записей, в конфиге $CONFIG_SIGNALS сигналов ($CONFIG)."
fi

level_rank() {
    case "$1" in
        high) printf '2' ;;
        medium) printf '1' ;;
        *) printf '0' ;;
    esac
}

rank_level() {
    case "$1" in
        2) printf 'high' ;;
        1) printf 'medium' ;;
        *) printf 'low' ;;
    esac
}

# ------------------------------------------------------------------
# Сборщики фактов. Каждый заполняет одни и те же переменные — движок ниже не
# знает, откуда они пришли.
# ------------------------------------------------------------------
FACT_PATHS=''   # изменённые пути, по одному на строку
FACT_ADDED=''   # добавленные строки в виде «путь<TAB>содержимое»
FACT_LINES=0
FACT_FILES=0
FACT_KIND=''    # plan | diff
declare -A FACT_FLAGS=()

git_repo_check() {
    [ -d "$REPO" ] || die "Не найден каталог репозитория: $REPO"
    git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 \
        || die "Каталог не репозиторий git: $REPO"
}

resolve_ref() {
    git -C "$REPO" rev-parse --verify --quiet "$1^{commit}" >/dev/null 2>&1 \
        || die "Ref не разрешается: $1"
}

count_nonempty() {
    local n=0 line
    while IFS= read -r line; do
        [ -n "$line" ] && n=$((n + 1))
    done <<< "$1"
    printf '%d' "$n"
}

collect_plan_facts() {
    local plan="$1" flag
    [ -f "$plan" ] || die "Не найден файл плана: $plan"
    jq empty "$plan" >/dev/null 2>&1 || die "План не разбирается как JSON: $plan"

    FACT_KIND='plan'
    # Умерший jq отдал бы пустой список путей — то есть «сигналов нет» на
    # плане, который никто не читал. Отказ разбора роняет счёт.
    if ! FACT_PATHS="$(jq_r '[.files[]?.path] | map(select(. != null)) | .[]' "$plan")"; then
        die "Разбор плана не отработал: $plan — счёт не состоялся."
    fi
    FACT_ADDED=''
    FACT_LINES=0
    FACT_FILES="$(count_nonempty "$FACT_PATHS")"

    local flags_raw
    if ! flags_raw="$(jq_r '(.flags // {}) | to_entries[] | select(.value == true) | .key' "$plan")"; then
        die "Разбор флагов плана не отработал: $plan — счёт не состоялся."
    fi

    FACT_FLAGS=()
    while IFS= read -r flag; do
        [ -n "$flag" ] && FACT_FLAGS["$flag"]=1
    done <<< "$flags_raw"
}

collect_diff_facts() {
    local base="$1" head="$2" path scope_needed=0

    FACT_KIND='diff'
    FACT_FLAGS=()
    FACT_ADDED=''

    # Упавший git отдал бы пустой список путей и ноль строк — то есть «сигналов
    # нет» на диффе, который не прочитан. Здесь стоит `set -uo pipefail` без
    # `-e`, поэтому код возврата проверяется руками, как у сборщика плана.
    #
    # core.quotepath=false во всех трёх вызовах: по умолчанию git отдаёт
    # не-ASCII путь как «"src/Domovoy.Ha/\320\235…"», и ни глоб сигнала, ни
    # область keyword_paths такую строку не опознают. Это молчание сигнала
    # уровня high на файле, который просто назван по-русски.
    if ! FACT_PATHS="$(git -C "$REPO" -c core.quotepath=false diff --name-only --no-ext-diff "$base" "$head")"; then
        die "Дифф не прочитан: git diff --name-only $base $head в $REPO — счёт не состоялся."
    fi
    FACT_FILES="$(count_nonempty "$FACT_PATHS")"
    if ! FACT_LINES="$(git -C "$REPO" -c core.quotepath=false diff --numstat --no-ext-diff "$base" "$head" | awk '
        {
            added = ($1 == "-") ? 0 : $1
            removed = ($2 == "-") ? 0 : $2
            total += added + removed
        }
        END { printf "%d", total + 0 }
    ')"; then
        die "Размер диффа не посчитан: git diff --numstat $base $head в $REPO — счёт не состоялся."
    fi

    # Добавленные строки нужны только словарной половине сигналов. Если ни один
    # изменённый путь не попадает в её область, дорогой дифф не запускается
    # вовсе: в этом репозитории большинство PR не трогает ни src, ни tests.
    if [ -n "$KW_SCOPE_UNION" ]; then
        local union_re="^($KW_SCOPE_UNION)$"
        while IFS= read -r path; do
            [ -z "$path" ] && continue
            if [[ "$path" =~ $union_re ]]; then
                scope_needed=1
                break
            fi
        done <<< "$FACT_PATHS"
    fi

    if [ "$scope_needed" -eq 1 ]; then
        # Тот же отказ, что выше, и та же цена: пустые добавленные строки — это
        # молчание словарной половины на диффе, который не прочитан.
        if ! FACT_ADDED="$(git -C "$REPO" -c core.quotepath=false diff -U0 --no-color --no-ext-diff "$base" "$head" | awk '
            /^\+\+\+ /{
                # Путь берётся остатком строки, а не вторым полем: $2 обрезает
                # его по первому пробелу, и строка «слово:» называла бы файл,
                # которого нет. Ровно четыре символа заголовка «+++ ».
                p = substr($0, 5)
                sub(/^b\//, "", p)
                next
            }
            /^\+/{
                if (p != "" && p != "/dev/null") {
                    print p "\t" substr($0, 2)
                }
            }
        ')"; then
            die "Добавленные строки не прочитаны: git diff -U0 $base $head в $REPO — счёт не состоялся."
        fi
    fi
}

# ------------------------------------------------------------------
# Движок. Отвечает через глобальные переменные: уровень печатается первой
# строкой — раньше, чем известны причины.
# ------------------------------------------------------------------
EVAL_LEVEL='low'
EVAL_IDS=''
EVAL_REPORT=''
EVAL_DISABLED=''

evaluate() {
    local i id title level enabled kind note
    local paths_re reasons flag path hit hits word line
    local -a flag_parts=()
    local -A seen_paths=()
    local rank=0 max_rank=0 shown

    EVAL_LEVEL='low'
    EVAL_IDS=''
    EVAL_REPORT=''
    EVAL_DISABLED=''

    for ((i = 0; i < SIGNAL_COUNT; i++)); do
        id="${SIG_ID[$i]}"
        title="${SIG_TITLE[$i]}"
        level="${SIG_LEVEL[$i]}"
        enabled="${SIG_ENABLED[$i]}"
        kind="${SIG_KIND[$i]}"
        note="${SIG_NOTE[$i]}"

        if [ "$enabled" != 'true' ]; then
            EVAL_DISABLED+="  [выключен] $id — $title: $note"$'\n'
            continue
        fi

        if [ "$kind" = 'metric' ]; then
            # Включён, но источника метрики нет: на уровень не влияет, и об
            # этом сказано вслух, а не молча посчитано нулём.
            EVAL_DISABLED+="  [не измерено] $id — $title: $note"$'\n'
            continue
        fi

        reasons=''

        if [ "$kind" = 'size' ]; then
            if [ "$FACT_KIND" = 'diff' ] \
                && [ "$THRESHOLD_LINES" != 'нет' ] && [ "$THRESHOLD_FILES" != 'нет' ]; then
                if [ "$FACT_LINES" -gt "$THRESHOLD_LINES" ] \
                    || [ "$FACT_FILES" -gt "$THRESHOLD_FILES" ]; then
                    reasons+="      размер диффа: строк: $FACT_LINES (порог $THRESHOLD_LINES), файлов: $FACT_FILES (порог $THRESHOLD_FILES)"$'\n'
                fi
            fi
        else
            # Путевая половина.
            if [ -n "${SIG_PATHS_RE[$i]}" ]; then
                paths_re="^(${SIG_PATHS_RE[$i]})$"
                while IFS= read -r path; do
                    [ -z "$path" ] && continue
                    if [[ "$path" =~ $paths_re ]]; then
                        reasons+="      путь: $path"$'\n'
                    fi
                done <<< "$FACT_PATHS"
            fi

            # Половина по объявлениям плана.
            if [ -n "${SIG_FLAGS[$i]}" ] && [ "${#FACT_FLAGS[@]}" -gt 0 ]; then
                flag_parts=()
                IFS="$JOIN" read -r -a flag_parts <<< "${SIG_FLAGS[$i]}"
                for flag in "${flag_parts[@]:-}"; do
                    [ -z "$flag" ] && continue
                    if [ -n "${FACT_FLAGS[$flag]+есть}" ]; then
                        reasons+="      флаг плана: $flag"$'\n'
                    fi
                done
            fi

            # Словарная половина — только внутри keyword_paths и только по
            # добавленным строкам. В режиме plan строк нет вовсе.
            #
            # Область применяется к пути, а не к строке: у альтернативы стоит
            # табуляция, которой путь отделён от содержимого. Путей с
            # табуляцией внутри git не отдаёт.
            if [ -n "${SIG_KW_RE[$i]}" ] && [ -n "$FACT_ADDED" ] \
                && [ -n "${SIG_KWSCOPE_RE[$i]}" ]; then
                hits="$(printf '%s\n' "$FACT_ADDED" \
                    | grep -iE -- "^(${SIG_KWSCOPE_RE[$i]})"$'\t'".*(${SIG_KW_RE[$i]})")"
                if [ -n "$hits" ]; then
                    seen_paths=()
                    shown=0
                    while IFS= read -r line; do
                        [ -z "$line" ] && continue
                        [ "$shown" -ge 5 ] && break
                        path="${line%%$'\t'*}"
                        [ -n "${seen_paths[$path]+есть}" ] && continue
                        seen_paths["$path"]=1
                        shown=$((shown + 1))
                        word="$(printf '%s' "${line#*$'\t'}" \
                            | grep -m1 -ioE -- "${SIG_KW_RE[$i]}")"
                        reasons+="      слово: $word — $path"$'\n'
                    done <<< "$hits"
                fi
            fi
        fi

        if [ -n "$reasons" ]; then
            EVAL_IDS+="$id"$'\n'
            EVAL_REPORT+="  [$level] $id — $title"$'\n'"$reasons"
            rank="$(level_rank "$level")"
            if [ "$rank" -gt "$max_rank" ]; then
                max_rank="$rank"
            fi
        fi
    done

    EVAL_LEVEL="$(rank_level "$max_rank")"
}

fired_ids_inline() {
    local out='' id
    if [ -z "$EVAL_IDS" ]; then
        printf '—'
        return
    fi
    while IFS= read -r id; do
        [ -z "$id" ] && continue
        [ -n "$out" ] && out+=', '
        out+="$id"
    done <<< "$EVAL_IDS"
    printf '%s' "$out"
}

print_verdict() {
    printf 'Уровень: %s\n' "$EVAL_LEVEL"
    printf '%s\n' "$1"
    printf 'Конфиг: %s\n' "$CONFIG"
    if [ "$FACT_KIND" = 'diff' ]; then
        printf 'Факты: файлов %s, строк изменено %s\n' "$FACT_FILES" "$FACT_LINES"
    else
        printf 'Факты: файлов в плане %s\n' "$FACT_FILES"
    fi

    if [ -n "$EVAL_REPORT" ]; then
        printf 'Сигналы:\n'
        printf '%s' "$EVAL_REPORT"
    else
        printf 'Сигналы: ни один не сработал\n'
    fi

    if [ -n "$EVAL_DISABLED" ]; then
        printf 'Сигналы вне счёта:\n'
        printf '%s' "$EVAL_DISABLED"
    fi

    if [ "$FACT_KIND" = 'plan' ]; then
        printf 'Не измерялось в режиме plan: размер диффа и ключевые слова по '
        printf 'добавленным строкам — диффа ещё нет.\n'
    fi

    if [ "$FACT_KIND" = 'diff' ] \
        && { [ "$THRESHOLD_LINES" = 'нет' ] || [ "$THRESHOLD_FILES" = 'нет' ]; }; then
        printf 'Порог размера в конфиге не задан: сигнал размера не считался. '
        printf 'Его печатает первый проход подкомандой history.\n'
    fi
}

# ------------------------------------------------------------------
# Процентиль методом nearest-rank: индекс — округление вверх от p/100 × N.
# Интерполяции нет намеренно: порог должен быть числом из корпуса, а не
# средним между двумя PR, которых не было.
# ------------------------------------------------------------------
percentile() {
    printf '%s\n' "$2" | grep -v '^$' | sort -n | awk -v p="$1" '
        { v[NR] = $1 + 0 }
        END {
            if (NR == 0) { print "—"; exit }
            rank = (p / 100) * NR
            idx = int(rank)
            if (idx < rank) idx += 1
            if (idx < 1) idx = 1
            if (idx > NR) idx = NR
            print v[idx]
        }
    '
}

# ------------------------------------------------------------------
# Режимы
# ------------------------------------------------------------------
case "$MODE" in
    plan)
        [ "${#POSITIONAL[@]}" -ge 1 ] || {
            usage >&2
            die 'Режиму plan нужен файл машиночитаемого плана.'
        }
        collect_plan_facts "${POSITIONAL[0]}"
        evaluate
        print_verdict "Режим: plan ${POSITIONAL[0]}"
        exit 0
        ;;

    diff)
        [ "${#POSITIONAL[@]}" -ge 2 ] || {
            usage >&2
            die 'Режиму diff нужны два ref: base и head.'
        }
        git_repo_check
        resolve_ref "${POSITIONAL[0]}"
        resolve_ref "${POSITIONAL[1]}"
        collect_diff_facts "${POSITIONAL[0]}" "${POSITIONAL[1]}"
        evaluate
        print_verdict "Режим: diff ${POSITIONAL[0]}..${POSITIONAL[1]} (репозиторий: $REPO)"
        exit 0
        ;;

    history)
        git_repo_check
        resolve_ref "$BASE_REF"

        SELECT_RULE="коммиты ветки $BASE_REF, заголовок которых оканчивается на «(#<номер>)»"
        ALL_COUNT="$(count_nonempty "$(git -C "$REPO" log --format='%H' "$BASE_REF")")"
        # %P — родители: по нему видно и мерж, и корневой коммит, без rev-parse
        # на каждый коммит корпуса.
        SELECTED="$(git -C "$REPO" log --format='%H|%P|%s' "$BASE_REF" \
            | grep -E '\(#[0-9]+\)$')"
        SELECTED_COUNT="$(count_nonempty "$SELECTED")"

        if [ "$SELECTED_COUNT" -eq 0 ]; then
            printf 'Состав корпуса\n'
            printf '  Правило отбора: %s\n' "$SELECT_RULE"
            printf '  Отобрано коммитов: 0\n'
            printf '  Всего коммитов в ветке: %s\n' "$ALL_COUNT"
            printf '\nНи один коммит не подпадает под правило отбора — корпуса нет.\n'
            exit 0
        fi

        EMPTY_TREE=''
        TABLE=''
        LINES_LIST=''
        FILES_LIST=''
        TOPDIRS=''
        MERGE_COMMITS=0

        while IFS= read -r entry; do
            [ -z "$entry" ] && continue
            sha="${entry%%|*}"
            rest="${entry#*|}"
            parents="${rest%%|*}"
            subject="${rest#*|}"
            number="${subject##*(#}"
            number="${number%)}"

            case "$parents" in
                *' '*)
                    MERGE_COMMITS=$((MERGE_COMMITS + 1))
                    ;;
            esac

            if [ -n "$parents" ]; then
                # Первый родитель и для мержа: дифф мержа против первого
                # родителя — это ровно то, что принёс PR. `git show` на мерже
                # печатает пустоту, и PR молча получил бы нулевой размер.
                parent="${parents%% *}"
            else
                # Корневой коммит: сравнение с пустым деревом.
                if [ -z "$EMPTY_TREE" ]; then
                    EMPTY_TREE="$(git -C "$REPO" hash-object -t tree /dev/null)"
                fi
                parent="$EMPTY_TREE"
            fi

            collect_diff_facts "$parent" "$sha"
            evaluate

            LINES_LIST+="$FACT_LINES"$'\n'
            FILES_LIST+="$FACT_FILES"$'\n'

            while IFS= read -r path; do
                [ -z "$path" ] && continue
                case "$path" in
                    */*) TOPDIRS+="${path%%/*}"$'\n' ;;
                    *) TOPDIRS+='корень'$'\n' ;;
                esac
            done <<< "$FACT_PATHS"

            TABLE+="| #$number | $EVAL_LEVEL | $(fired_ids_inline) | $FACT_LINES | $FACT_FILES |"$'\n'
        done <<< "$SELECTED"

        printf 'Состав корпуса\n'
        printf '  Правило отбора: %s\n' "$SELECT_RULE"
        printf '  Отобрано коммитов: %s\n' "$SELECTED_COUNT"
        printf '  Всего коммитов в ветке: %s\n' "$ALL_COUNT"
        printf '  Из отобранных коммитов-мержей: %s (дифф считается против первого родителя)\n' \
            "$MERGE_COMMITS"
        printf '  Затронутые файлы по верхним каталогам:\n'
        printf '%s' "$TOPDIRS" | grep -v '^$' | sort | uniq -c | sort -rn | awk '
            { printf "    %s: %s\n", $2, $1 }
        '

        printf '\nРаспределение размеров\n'
        printf '  Метод процентиля: %s\n' "$PERCENTILE_METHOD"
        printf '  Строк изменено на PR: p50 = %s, p%s = %s, p90 = %s, максимум = %s\n' \
            "$(percentile 50 "$LINES_LIST")" \
            "$PERCENTILE" "$(percentile "$PERCENTILE" "$LINES_LIST")" \
            "$(percentile 90 "$LINES_LIST")" \
            "$(percentile 100 "$LINES_LIST")"
        printf '  Файлов на PR: p50 = %s, p%s = %s, p90 = %s, максимум = %s\n' \
            "$(percentile 50 "$FILES_LIST")" \
            "$PERCENTILE" "$(percentile "$PERCENTILE" "$FILES_LIST")" \
            "$(percentile 90 "$FILES_LIST")" \
            "$(percentile 100 "$FILES_LIST")"
        printf '  Порог в конфиге сейчас: строк %s, файлов %s\n' \
            "$THRESHOLD_LINES" "$THRESHOLD_FILES"

        printf '\nPR → уровень → сигналы\n'
        printf '| PR | Уровень | Сигналы | Строк | Файлов |\n'
        printf '|---|---|---|---|---|\n'
        printf '%s' "$TABLE"

        if [ "$THRESHOLD_LINES" = 'нет' ] || [ "$THRESHOLD_FILES" = 'нет' ]; then
            printf '\nПорог размера в конфиге не задан: сигнал размера в таблице не считался.\n'
            printf 'Это первый проход — процентиль из блока выше идёт в pipeline/risk.json.\n'
        fi
        exit 0
        ;;

    *)
        usage >&2
        die "Неизвестный режим: $MODE"
        ;;
esac
