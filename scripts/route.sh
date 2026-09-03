#!/usr/bin/env bash
#
# Домовой — маршрут задачи по её уровню риска: что проверяется и кем.
#
# ЗАЧЕМ
#
# Уровень задачи считает scripts/risk-score.sh, и до этой задачи у ответа не
# было ни одного потребителя: обряд был один и тот же для правки одного
# предложения и для миграции базы. Здесь у уровня появляется потребитель —
# маршрут: подкоманда level печатает, что на этом уровне идёт, что сокращено и
# что не сокращается никогда, а подкоманда check сверяет политику с теми
# файлами, до которых правило обязано доехать.
#
# Блокировок и кода возврата, зависящего от уровня, здесь нет: движок печатает
# факт, а решение остаётся человеку и оркестратору. Кто применяет уровень,
# напечатано полем applied_by самой политики.
#
# ГДЕ ЛЕЖИТ ЗНАНИЕ
#
# Ни одной позиции, ни одного значения и ни одного пути потребителя в этом
# файле нет: всё в pipeline/route.json. Скрипт — движок, конфиг — политика.
# Своего у скрипта два: набор уровней low|medium|high (как в
# scripts/risk-score.sh, и по той же причине — поле levels в конфиге стояло бы
# обещанием настройки, которой нет) и расположение политики по умолчанию.
#
# Строка, наличие которой сверяется у потребителей, — это и есть расположение
# политики по умолчанию, pipeline/route.json. Ключ --config меняет только то,
# откуда читается политика, а не то, на что потребитель ссылается: иначе
# временная копия политики в сверке требовала бы ссылки на временный путь.
#
# КАК ЗАПУСКАТЬ
#
#   bash scripts/route.sh level low
#   bash scripts/route.sh level medium
#   bash scripts/route.sh check
#
# Ключи: --config <файл> (другая политика), --repo <каталог> (другое дерево —
# так работают сценарии харнесса scripts/route.test.sh).
#
# Код возврата: 0 — маршрут напечатан либо сверка сошлась, 1 — сверка нашла
# расхождения, 2 — запуск не состоялся (аргументы, незнакомый уровень,
# сломанная политика).
#
# ЧЕГО НЕ ЛОВИТ
#
# Сверка сравнивает тексты, а не поведение:
#
#   - она не отличает работающее значение позиции от инертного. Позиция, чьё
#     значение опирается на настройку репозитория, которой ещё нет, пройдёт
#     сверку зелёной. Инертность называется полем note позиции, и читает её
#     человек: нового поля политики под несуществующую настройку здесь нет,
#     потому что это была бы та же настройка, которой нет;
#   - она не ловит пересказ значения другими словами. Запрещена дословная
#     копия — та, которая расходится с источником молча;
#   - значения короче порога в сверку копий не попадают вовсе: короткая фраза
#     встречается у потребителя по совпадению, а не по копированию. Такие
#     значения печатаются списком, а не молча выбрасываются;
#   - ссылку у потребителя она проверяет по наличию строки с расположением
#     политики, а не по тому, правда ли написана вокруг неё;
#   - второй режим работы — агентский цикл — политику не читает, и сверять там
#     нечего. Это отсутствие потребителя, а не сошедшаяся сверка, и напечатано
#     оно полем applied_by.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CONFIG_REL='pipeline/route.json'
CONFIG="$ROOT/$CONFIG_REL"
REPO="$ROOT"

# Разделитель внутренних склеек. Печатного здесь быть не может: значения
# позиций — фразы с любой пунктуацией, и любой видимый символ однажды
# встретится внутри значения. В jq он уезжает через --arg, а не литералом.
FS=$'\002'

# Значение короче этого числа слов в сверку копий не попадает: короткая фраза
# встречается у потребителя по совпадению. Порог именно в словах, а не в
# байтах: длина в байтах у кириллицы и латиницы разная, а сравниваются фразы.
COPY_MIN_WORDS=6

die() {
    printf '%s\n' "$1" >&2
    exit 2
}

usage() {
    printf 'Использование:\n'
    printf '  bash scripts/route.sh level <low|medium|high> [--config <файл>]\n'
    printf '  bash scripts/route.sh check [--config <файл>] [--repo <каталог>]\n'
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

command -v jq >/dev/null 2>&1 || die 'Не найден jq: политика маршрута читается им.'

# jq под Windows пишет CRLF, и возврат каретки уезжает внутрь значения: «true»
# перестаёт равняться «true», а значение позиции перестаёт совпадать с самим
# собой. Ломается это молча, поэтому чтение политики идёт через одну обёртку.
jq_r() {
    jq -r "$@" | tr -d '\r'
}

# ------------------------------------------------------------------
# Политика: разбирается и проверяется до того, как напечатан хоть один маршрут.
# Разъехавшаяся политика обязана отказывать, а не выдавать маршрут задачи,
# которую никто не мерил.
# ------------------------------------------------------------------
[ -f "$CONFIG" ] || die "Не найдена политика маршрута: $CONFIG"

if ! jq empty "$CONFIG" >/dev/null 2>&1; then
    die "Политика маршрута не разбирается как JSON: $CONFIG"
fi

# Отказ самого запроса проверки не глушится и не сходит за «нарушений нет»:
# проверка, которая молча не состоялась, зеленит любую политику.
if ! POLICY_ERRORS="$(jq_r '
    ["low","medium","high"] as $levels
    | ($levels | sort) as $expected
    | (
        (["version","about","decision","applied_by","consumers","never_reduced","positions"][]
            as $field | select((. | has($field)) | not)
            | "в политике нет обязательного поля \($field)"),
        (select((.decision // "" | type) != "string" or (.decision // "") == "")
            | "поле decision пустое или не строка: путь к записи решения нужен целиком"),
        (select((.applied_by // "" | type) != "string" or (.applied_by // "") == "")
            | "поле applied_by пустое или не строка: кто применяет уровень, читается из политики"),
        (select((.about // "" | type) != "string" or (.about // "") == "")
            | "поле about пустое или не строка"),
        (select((.consumers | type) != "array")
            | "поле consumers не массив"),
        (select((.consumers | type) == "array" and (.consumers | length) == 0)
            | "список consumers пуст: правило не с чем сверять, и сверка зеленела бы ни на чём"),
        (select((.consumers | type) == "array"
                and (.consumers | any((type != "string") or (. == ""))))
            | "пустой или нестроковый путь в consumers"),
        (select((.never_reduced | type) != "array")
            | "поле never_reduced не массив"),
        (select((.never_reduced | type) == "array"
                and (.never_reduced | any((type != "string") or (. == ""))))
            | "пустой или нестроковый пункт в never_reduced"),
        (select((.positions | type) != "array")
            | "поле positions не массив"),
        (select((.positions | type) == "array" and (.positions | length) == 0)
            | "в политике нет ни одной позиции маршрута: печатать нечего"),
        (select((.positions | type) == "array")
            | (.positions | to_entries[]) as $e
            | $e.value as $p
            | ($p.id // "№\($e.key)") as $name
            | (
                (["id","title","phase","note","levels"][] as $field
                    | select(($p | has($field)) | not)
                    | "позиция \($name): нет обязательного поля \($field)"),
                (["id","title","phase","note"][] as $field
                    | select((($p[$field] // "") | type) != "string" or ($p[$field] // "") == "")
                    | "позиция \($name): поле \($field) пустое или не строка"),
                (select(($p.levels | type) != "object")
                    | "позиция \($name): поле levels не объект"),
                (select(($p.levels | type) == "object" and ($p.levels | keys) != $expected)
                    | "позиция \($name): уровни политики «\($p.levels | keys | join(", "))» не совпадают с \($levels | join("|"))"),
                (select(($p.levels | type) == "object")
                    | $levels[] as $lvl
                    | select($p.levels | has($lvl))
                    | (
                        (select(($p.levels[$lvl] | type) != "object")
                            | "позиция \($name), уровень \($lvl): значение не объект {value, reduced}"),
                        (select(($p.levels[$lvl] | type) == "object")
                            | (
                                (select((($p.levels[$lvl].value // "") | type) != "string"
                                        or ($p.levels[$lvl].value // "") == "")
                                    | "позиция \($name), уровень \($lvl): пустое или нестроковое value"),
                                (select(($p.levels[$lvl].reduced | type) != "boolean")
                                    | "позиция \($name), уровень \($lvl): reduced должно быть true или false")
                              )
                        )
                      )
                )
              )
        )
      )
' "$CONFIG")"; then
    die "Разбор политики маршрута не отработал: $CONFIG — проверка не состоялась."
fi

if [ -n "$POLICY_ERRORS" ]; then
    printf 'Политика маршрута не сходится:\n' >&2
    printf '%s\n' "$POLICY_ERRORS" >&2
    exit 2
fi

DECISION="$(jq_r '.decision' "$CONFIG")"
APPLIED_BY="$(jq_r '.applied_by' "$CONFIG")"

CONSUMERS=()
while IFS= read -r line; do
    [ -n "$line" ] && CONSUMERS+=("$line")
done < <(jq_r '.consumers[]' "$CONFIG")

NEVER=()
while IFS= read -r line; do
    [ -n "$line" ] && NEVER+=("$line")
done < <(jq_r '.never_reduced[]' "$CONFIG")

POS_ID=()
POS_TITLE=()
POS_PHASE=()
VAL_LOW=()
RED_LOW=()
VAL_MEDIUM=()
RED_MEDIUM=()
VAL_HIGH=()
RED_HIGH=()

while IFS= read -r row; do
    [ -z "$row" ] && continue
    IFS="$FS" read -r c_id c_title c_phase c_vl c_rl c_vm c_rm c_vh c_rh <<< "$row"
    POS_ID+=("$c_id")
    POS_TITLE+=("$c_title")
    POS_PHASE+=("$c_phase")
    VAL_LOW+=("$c_vl")
    RED_LOW+=("$c_rl")
    VAL_MEDIUM+=("$c_vm")
    RED_MEDIUM+=("$c_rm")
    VAL_HIGH+=("$c_vh")
    RED_HIGH+=("$c_rh")
done < <(jq_r --arg fs "$FS" '.positions[] | [
        .id, .title, .phase,
        .levels.low.value, (.levels.low.reduced | tostring),
        .levels.medium.value, (.levels.medium.reduced | tostring),
        .levels.high.value, (.levels.high.reduced | tostring)
    ] | join($fs)' "$CONFIG")

POS_COUNT="${#POS_ID[@]}"
[ "$POS_COUNT" -gt 0 ] || die "Политика маршрута не прочиталась: $CONFIG"

# Инвариант на сам разбор: строк прочитано столько же, сколько позиций в
# политике. Значение с переводом строки внутри (в JSON это законная строка
# "a\nb") разрезало бы запись пополам, поля разъехались бы, и маршрут стал бы
# мусором. Разъехавшийся разбор обязан отказывать, а не печатать дальше.
CONFIG_POSITIONS="$(jq_r '.positions | length' "$CONFIG")"
if [ "$POS_COUNT" != "$CONFIG_POSITIONS" ]; then
    die "Разбор политики разъехался: прочитано $POS_COUNT записей, в политике $CONFIG_POSITIONS позиций ($CONFIG)."
fi

level_known() {
    case "$1" in
        low | medium | high) return 0 ;;
        *) return 1 ;;
    esac
}

level_value() {
    case "$2" in
        low) printf '%s' "${VAL_LOW[$1]}" ;;
        medium) printf '%s' "${VAL_MEDIUM[$1]}" ;;
        high) printf '%s' "${VAL_HIGH[$1]}" ;;
    esac
}

level_reduced() {
    case "$2" in
        low) printf '%s' "${RED_LOW[$1]}" ;;
        medium) printf '%s' "${RED_MEDIUM[$1]}" ;;
        high) printf '%s' "${RED_HIGH[$1]}" ;;
    esac
}

# ------------------------------------------------------------------
# Подкоманда level: маршрут одного уровня целиком.
# ------------------------------------------------------------------
print_level() {
    local lvl="$1" i reduced_ids='' item
    printf 'Уровень: %s\n' "$lvl"
    printf 'Применяет: %s\n' "$APPLIED_BY"
    printf 'Политика: %s\n' "$CONFIG"
    printf 'Решение: %s\n' "$DECISION"
    printf 'Позиций в маршруте: %s\n' "$POS_COUNT"

    printf '\nМаршрут:\n'
    for ((i = 0; i < POS_COUNT; i++)); do
        printf '  [%s] %s — %s\n' "${POS_PHASE[$i]}" "${POS_ID[$i]}" "${POS_TITLE[$i]}"
        printf '      %s\n' "$(level_value "$i" "$lvl")"
        if [ "$(level_reduced "$i" "$lvl")" = 'true' ]; then
            printf '      сокращено на этом уровне\n'
            reduced_ids+="  - ${POS_ID[$i]}"$'\n'
        fi
    done

    printf '\nСокращено на уровне %s:\n' "$lvl"
    if [ -n "$reduced_ids" ]; then
        printf '%s' "$reduced_ids"
    else
        printf '  - ни одной позиции\n'
    fi

    printf '\nНе сокращается никогда:\n'
    for item in "${NEVER[@]:-}"; do
        [ -z "$item" ] && continue
        printf '  - %s\n' "$item"
    done

    printf '\nСоветник (фаза 4) не введён: правило «советник может блокировать, '
    printf 'но не одобрять» кода не получает — оно записано отложенным в записи '
    printf 'решения выше.\n'
}

# ------------------------------------------------------------------
# Подкоманда check: механическая сверка политики с деревом.
# ------------------------------------------------------------------
VIOLATIONS=0

report() {
    # Формат GitHub Actions: сообщение попадает в аннотации к файлу.
    printf '::error file=%s::%s\n' "$1" "$2"
    VIOLATIONS=$((VIOLATIONS + 1))
}

note() {
    printf '  %s\n' "$1"
}

route_of() {
    local lvl="$1" i out=''
    for ((i = 0; i < POS_COUNT; i++)); do
        out+="${POS_ID[$i]}$FS$(level_value "$i" "$lvl")"$'\n'
    done
    printf '%s' "$out"
}

word_count() {
    printf '%s' "$1" | tr -s '[:space:]' '\n' | grep -c .
}

# Текст файла в одну строку с одиночными пробелами: перенос значения по ширине
# и отступ списка сверку копий не обманывают.
normalized_file() {
    tr '\n' ' ' < "$1" | tr -s '[:space:]' ' '
}

normalized_value() {
    printf '%s' "$1" | tr -s '[:space:]' ' '
}

CHECK_TMP=''

run_check() {
    local i lvl a b pair consumer path matched short_list='' reduced_low=0
    local -A value_owner=()
    local -a long_values=()
    local value owner tmp

    printf 'Политика: %s\n' "$CONFIG"
    printf 'Применяет: %s\n' "$APPLIED_BY"
    printf 'Дерево: %s\n' "$REPO"
    printf 'Позиций: %s, пунктов «не сокращается никогда»: %s, потребителей: %s\n' \
        "$POS_COUNT" "${#NEVER[@]}" "${#CONSUMERS[@]}"

    # --------------------------------------------------------------
    # 1. Инварианты политики, которых не видит проверка формы.
    # --------------------------------------------------------------
    if [ "${#NEVER[@]}" -eq 0 ]; then
        report "$CONFIG" 'список never_reduced пуст: маршрут, у которого нечего защищать, — не политика'
        note 'Уровень сокращает число кругов, а не состав того, что делает человек.'
    fi

    for ((i = 0; i < POS_COUNT; i++)); do
        [ "$(level_reduced "$i" low)" = 'true' ] && reduced_low=$((reduced_low + 1))
    done
    if [ "$reduced_low" -eq 0 ]; then
        report "$CONFIG" 'на низком уровне не сокращается ни одна позиция: маршруты уровней различаются только словами'
        note 'Политика без единого сокращения не отвечает на вопрос, ради которого написана.'
    fi
    printf 'Сокращено на низком уровне позиций: %s\n' "$reduced_low"

    # --------------------------------------------------------------
    # 2. Три уровня — три разных маршрута. Сравниваются значения позиций, а не
    #    вывод целиком: строка «Уровень: …» различала бы любые два маршрута,
    #    включая дословно одинаковые.
    # --------------------------------------------------------------
    for pair in 'low medium' 'low high' 'medium high'; do
        a="${pair%% *}"
        b="${pair##* }"
        if [ "$(route_of "$a")" = "$(route_of "$b")" ]; then
            report "$CONFIG" "маршруты уровней $a и $b не различаются ни одной позицией"
            note 'Уровень, не меняющий маршрут, — это счёт без потребителя.'
        else
            printf 'Маршруты уровней %s и %s различаются\n' "$a" "$b"
        fi
    done

    # --------------------------------------------------------------
    # 3. Запись решения из политики лежит в дереве.
    # --------------------------------------------------------------
    if [ -f "$REPO/$DECISION" ]; then
        printf 'Запись решения на месте: %s\n' "$DECISION"
    else
        report "$CONFIG" "запись решения из поля decision не найдена в дереве: $DECISION"
        note 'Отклонение от ТЗ без записи через месяц неотличимо от недосмотра.'
    fi

    # --------------------------------------------------------------
    # 4. Значения позиций: длинные идут в сверку копий, короткие — в список.
    # --------------------------------------------------------------
    for ((i = 0; i < POS_COUNT; i++)); do
        for lvl in low medium high; do
            value="$(normalized_value "$(level_value "$i" "$lvl")")"
            if [ "$(word_count "$value")" -lt "$COPY_MIN_WORDS" ]; then
                short_list+="  - ${POS_ID[$i]} ($lvl): «$value»"$'\n'
                continue
            fi
            owner="${POS_ID[$i]} ($lvl)"
            if [ -n "${value_owner["$value"]+есть}" ]; then
                value_owner["$value"]="${value_owner["$value"]}, $owner"
            else
                value_owner["$value"]="$owner"
                long_values+=("$value")
            fi
        done
    done

    if [ -n "$short_list" ]; then
        printf 'В сверку копий не попали значения короче %s слов:\n' "$COPY_MIN_WORDS"
        printf '%s' "$short_list"
    else
        printf 'Значений короче %s слов в политике нет: в сверку копий попали все.\n' \
            "$COPY_MIN_WORDS"
    fi

    # Каталог держится в глобальной переменной, а не в local: trap срабатывает
    # после выхода из функции, и local к этому моменту уже не существует —
    # уборка выродилась бы в «rm -rf ""», а каталог остался бы в системе.
    tmp="$(mktemp -d)" || die 'Не удалось создать временный каталог — сверка не состоялась.'
    CHECK_TMP="$tmp"
    trap 'rm -rf "$CHECK_TMP"' EXIT

    if [ "${#long_values[@]}" -gt 0 ]; then
        printf '%s\n' "${long_values[@]}" > "$tmp/values"
    else
        : > "$tmp/values"
    fi

    # --------------------------------------------------------------
    # 5. Потребители: файл на месте, ссылка есть, дословной копии значения нет.
    # --------------------------------------------------------------
    for consumer in "${CONSUMERS[@]:-}"; do
        [ -z "$consumer" ] && continue
        path="$REPO/$consumer"

        if [ ! -f "$path" ]; then
            report "$CONFIG" "потребителя из политики нет в дереве: $consumer"
            note 'Опечатка в пути потребителя иначе даёт молчаливый зелёный: сверять оказалось нечего.'
            continue
        fi

        normalized_file "$path" > "$tmp/consumer"

        if ! grep -qF -- "$CONFIG_REL" "$tmp/consumer"; then
            report "$consumer" "нет ссылки на политику маршрута ($CONFIG_REL): $consumer"
            note 'Правило, не доехавшее до потребителя, — не источник, а надежда на него.'
            continue
        fi

        matched=''
        if [ -s "$tmp/values" ]; then
            matched="$(grep -oFf "$tmp/values" "$tmp/consumer" | sort -u)"
        fi

        if [ -n "$matched" ]; then
            while IFS= read -r value; do
                [ -z "$value" ] && continue
                report "$consumer" "дословное значение позиции ${value_owner["$value"]} у потребителя $consumer: «$value»"
                note 'Лечится заменой копии на отсылку к политике, а не правкой обеих сторон.'
            done <<< "$matched"
            continue
        fi

        printf 'Потребитель сходится: %s — ссылка есть, дословных значений нет\n' "$consumer"
    done

    printf '\n'
    if [ "$VIOLATIONS" -gt 0 ]; then
        printf 'Расхождений: %d. Маршрут и его потребители разъехались.\n' "$VIOLATIONS"
        return 1
    fi

    printf 'Маршрут сходится: политика, потребители и запись решения на месте.\n'
    return 0
}

# ------------------------------------------------------------------
# Режимы
# ------------------------------------------------------------------
case "$MODE" in
    level)
        [ "${#POSITIONAL[@]}" -ge 1 ] || {
            usage >&2
            die 'Подкоманде level нужен уровень: low, medium или high.'
        }
        level_known "${POSITIONAL[0]}" || {
            usage >&2
            die "Незнакомый уровень: ${POSITIONAL[0]} — маршрута по умолчанию нет."
        }
        print_level "${POSITIONAL[0]}"
        exit 0
        ;;

    check)
        [ -d "$REPO" ] || die "Не найден каталог дерева: $REPO"
        run_check
        exit $?
        ;;

    *)
        usage >&2
        die "Незнакомая подкоманда: $MODE"
        ;;
esac
