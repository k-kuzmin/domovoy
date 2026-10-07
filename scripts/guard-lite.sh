#!/usr/bin/env bash
#
# Домовой — гейт целостности, облегчённый (#131, вместо guard.sh).
#
# Ловит не баги, а известные способы «починить» красную проверку обходом:
# подавление, удалённый тест, разрушительную миграцию; плюс подписи и мусор
# прогона в диффе. Меток-обходов нет: сработавшее правило снимается правкой
# диффа или решением человека не мержить через гейт. Предел (запись 0026):
# скрипт правится тем же диффом, который проверяет (#87).
#
#   bash scripts/guard-lite.sh [база] [вершина]   # по умолчанию origin/main HEAD
#
# Код: 0 — чисто, 1 — нарушения (строкой «файл:строка: что»), 2 — ошибка
# запуска. Читает только git, рабочее дерево не трогает.
#
# ГДЕ ИЩЕТСЯ. Подавления, тестовые методы и миграции — только в файлах кода и
# конфигурации сборки (is_code_file) вне scripts/fixtures/: иначе гейт краснел
# бы на правилах, документации и на собственных сценариях. Мусор и подписи —
# по любому пути. Смотрятся добавленные строки; удалённые — только у тестовых
# методов. Удалённый файл с подавлением поэтому не нарушение, а починка.
# Дифф берётся с --no-renames: переименование — удаление плюс добавление, и
# тест, унесённый в файл не того типа, считается удалённым. Пути — из -z,
# поэтому кавычек git в них нет.
#
# МИГРАЦИИ. Разрушительный вызов API EF и сырой SQL смотрятся во всём файле
# миграции, кроме тела Down() (граница из #125): откат законно снимает то,
# что создал Up(). Тело Down() размечается по вершине счётом фигурных скобок
# от заголовка «void Down(»; скобка внутри строкового литерала счёт сбивает.
# SQL не разбирается — ищется текст в строке: оператор, разнесённый по
# строкам, не ловится; IF [NOT] EXISTS снимает срабатывание только с
# оператора, за ключевым словом которого стоит (перенос из guard.sh, 9).
#
# SKIP =. Шаблон широкий намеренно: любое присваивание «Skip =» в файле кода,
# а не только Skip = "…" внутри [Fact(…)]/[Theory(…)]. Проверка построчная, и
# атрибут, разнесённый по строкам, или причина константой (Skip = Reasons.X)
# узким шаблоном не ловились бы. Предел: ложное срабатывание на продуктовом
# коде вида new Page { Skip = offset } или bool Skip = false; — снимается
# переименованием или решением человека, обхода у гейта нет.
#
# ПОНИЖЕНИЕ AnalysisLevel — любое добавленное значение AnalysisLevel или
# свойства по категории (AnalysisLevelSecurity, AnalysisLevelStyle, …), кроме
# latest/preview с режимом default, recommended или all; регистр не важен, как
# и в MSBuild. Значение берётся только после имени свойства: «>» тега (с
# атрибутами или без), «=» в -p:…=… или «:» в env workflow; ссылка
# $(AnalysisLevel) и закрывающий тег не сверяются. Номер версии считается
# понижением: сравнения с прежним значением нет.
#
set -uo pipefail

BASE_REF="${1:-origin/main}"
HEAD_REF="${2:-HEAD}"

git rev-parse --git-dir >/dev/null 2>&1 || { echo 'guard-lite: вне git-репозитория' >&2; exit 2; }
for ref in "$BASE_REF" "$HEAD_REF"; do
    git rev-parse --verify --quiet "$ref^{commit}" >/dev/null ||
        { printf 'guard-lite: неизвестная ревизия: %s\n' "$ref" >&2; exit 2; }
done
BASE="$(git merge-base "$BASE_REF" "$HEAD_REF" 2>/dev/null || git rev-parse "$BASE_REF")"
HEAD="$(git rev-parse "$HEAD_REF")"

VIOLATIONS=0
report() { printf '%s:%s: %s\n' "$1" "$2" "${3//$'\r'/}"; VIOLATIONS=$((VIOLATIONS + 1)); }

is_code_file() {
    case "$1" in scripts/fixtures/*) return 1 ;; esac
    case "${1##*/}" in
        .editorconfig | .globalconfig | *.cs | *.csproj | *.props | *.targets | *.yml | *.ruleset) return 0 ;;
    esac
    return 1
}
is_migration() { [[ "$1" =~ (^|/)Migrations/[^/]+\.cs$ ]]; }

# Добавленные строки: «+<TAB>номер<TAB>текст» по новой стороне, удалённые —
# «-<TAB>номер<TAB>текст» по базовой. Заголовки файла пропускаются до «@@»:
# в -U0 строка «++ …» иначе читалась бы как «+++ …».
file_lines() {
    git -c core.quotePath=false diff --no-color --no-ext-diff --no-renames -U0 \
        "$BASE" "$HEAD" -- ":(literal)$1" |
        awk '
            /^diff --git / { hdr = 1; next }
            substr($0, 1, 2) == "@@" {
                hdr = 0; split(substr($2, 2), o, ","); split(substr($3, 2), n, ",")
                ol = o[1] + 0; nl = n[1] + 0; next
            }
            hdr { next }
            /^\+/ { t = substr($0, 2); sub(/\r$/, "", t); print "+\t" nl++ "\t" t; next }
            /^-/  { t = substr($0, 2); sub(/\r$/, "", t); print "-\t" ol++ "\t" t; next }'
}

# Номера строк тела Down() в версии вершины, по одной в строке.
down_lines() {
    git show "$HEAD:$1" 2>/dev/null | awk '
        !inm && /void[[:space:]]+Down[[:space:]]*\(/ { inm = 1; opened = 0; depth = 0 }
        inm {
            print NR; line = $0
            o = gsub(/\{/, "", line); c = gsub(/\}/, "", line); depth += o - c
            if (o > 0) opened = 1
            if ((opened && depth <= 0) || (!opened && $0 ~ /;[[:space:]]*$/)) inm = 0
        }'
}

# Директиву ставит генератор EF (Designer, ModelSnapshot, seed из нескольких
# строк — CA1814), поэтому в каталоге миграций проекта данных она не
# нарушение. Исключение — только это правило и только этот путь: каталог в
# risk.json — former_protected (high), остальные подавления в нём краснеют.
PRAGMA='#pragma[[:space:]]+warning[[:space:]]+disable'
EF_GENERATED='src/Domovoy.Data/Migrations/'
SUPPRESSION=(
    '(^|[^A-Za-z0-9_])Skip[[:space:]]*=([^=>]|$)'        'Skip = — тест выключен'
    '\[Ignore(\]|\()'                                     '[Ignore] — тест выключен'
    '\[ExcludeFromCodeCoverage'                           '[ExcludeFromCodeCoverage]'
    'SuppressMessage'                                     '[SuppressMessage]'
    '[Nn]o[Ww]arn'                                        'NoWarn'
    'WarningsNotAsErrors'                                 'WarningsNotAsErrors'
    'TreatWarningsAsErrors[^A-Za-z]*[Ff]alse'             'TreatWarningsAsErrors=false'
    'EnforceCodeStyleInBuild[^A-Za-z]*[Ff]alse'           'EnforceCodeStyleInBuild=false'
    'continue-on-error[[:space:]]*:[[:space:]]*([^[:space:]f#]|f[^a])' 'continue-on-error'
    '--filter.*(!=|!~)'                                   '--filter с отрицанием'
)
# Имя свойства (группа 2) и значение (группа 4): после тега с атрибутами,
# после «=» (-p:…=…) или «:» (env в workflow). Перед именем не «/», «(» и
# не буква — это не закрывающий тег и не $(AnalysisLevel).
ANALYSIS_LEVEL='(^|[^/(A-Za-z0-9_])([Aa][Nn][Aa][Ll][Yy][Ss][Ii][Ss][Ll][Ee][Vv][Ee][Ll][A-Za-z]*)([[:space:]][^>]*>|>|[[:space:]]*[=:][[:space:]]*["'"'"']?)([A-Za-z0-9.-]*)'
EF_DESTRUCTIVE='(DropColumn|DropTable|RenameColumn|RenameTable|AlterColumn|DropIndex|DropForeignKey|DropPrimaryKey|DropUniqueConstraint|AddPrimaryKey)'
L='(^|[^a-z0-9_])'; T='([^a-z0-9_]|$)'
# Тройки: шаблон в нижнем регистре, идемпотентная форма (вырезается до
# сверки), имя правила.
SQL_RULES=(
    "${L}delete[[:space:]]+from${T}|${L}truncate${T}"  ''  'DELETE или TRUNCATE'
    "${L}drop[[:space:]]+(table|column|index|constraint)${T}" \
        'drop[[:space:]]+(table|column|index|constraint)[[:space:]]+(concurrently[[:space:]]+)?if[[:space:]]+exists' \
        'DROP без IF EXISTS'
    "${L}access[[:space:]]+exclusive${T}"  ''  'ACCESS EXCLUSIVE'
    "${L}add[[:space:]]+constraint[[:space:]].*primary[[:space:]]+key${T}"  ''  'ADD CONSTRAINT … PRIMARY KEY'
    "${L}(create[[:space:]]+table|add[[:space:]]+column)${T}" \
        '(create[[:space:]]+table|add[[:space:]]+column)[[:space:]]+if[[:space:]]+not[[:space:]]+exists' \
        'CREATE TABLE или ADD COLUMN без IF NOT EXISTS'
)

check_added() {
    local file="$1" line="$2" text="$3" i lower rest
    [[ "$text" =~ $PRAGMA && "$file" != "$EF_GENERATED"* ]] &&
        report "$file" "$line" 'подавление: #pragma warning disable'
    for ((i = 0; i < ${#SUPPRESSION[@]}; i += 2)); do
        [[ "$text" =~ ${SUPPRESSION[i]} ]] && report "$file" "$line" "подавление: ${SUPPRESSION[i + 1]}"
    done
    case "${file##*/}" in .editorconfig | .globalconfig)
        [[ "$text" =~ severity[[:space:]]*=[[:space:]]*(none|silent)([[:space:]]|$) ]] &&
            report "$file" "$line" "подавление: severity = ${BASH_REMATCH[1]}" ;;
    esac
    if [[ "$text" =~ $ANALYSIS_LEVEL ]]; then
        local prop="${BASH_REMATCH[2]}" level="${BASH_REMATCH[4]}"
        [[ "${level,,}" =~ ^(latest|preview)(-(default|recommended|all))?$ ]] ||
            report "$file" "$line" "подавление: понижение $prop до «$level»"
    fi
    is_migration "$file" || return 0
    [ -n "${DOWN[$line]:-}" ] && return 0
    [[ "$text" =~ $EF_DESTRUCTIVE ]] && report "$file" "$line" "разрушительная миграция: ${BASH_REMATCH[1]}"
    lower="${text,,}"
    for ((i = 0; i < ${#SQL_RULES[@]}; i += 3)); do
        rest="$lower"
        if [ -n "${SQL_RULES[i + 1]}" ]; then
            while [[ "$rest" =~ ${SQL_RULES[i + 1]} ]]; do rest="${rest/"${BASH_REMATCH[0]}"/ }"; done
        fi
        [[ "$rest" =~ ${SQL_RULES[i]} ]] && report "$file" "$line" "сырой SQL в миграции: ${SQL_RULES[i + 2]}"
    done
    return 0
}

NAME_STATUS="$(mktemp)"; LINES="$(mktemp)"; REMOVED_TESTS="$(mktemp)"
trap 'rm -f "$NAME_STATUS" "$LINES" "$REMOVED_TESTS"' EXIT
git -c core.quotePath=false diff --name-status -z --no-renames "$BASE" "$HEAD" > "$NAME_STATUS" ||
    { echo 'guard-lite: не удалось получить список файлов' >&2; exit 2; }

TESTS_ADDED=0
TEST_ATTR='\[(Fact|Theory)(\]|\()'
while IFS= read -r -d '' status && IFS= read -r -d '' file; do
    base="${file##*/}"; lbase="${base,,}"
    if [ "$status" != D ]; then
        # Отчёты покрытия — по расширению и по каталогу отчётов: голое
        # coverage* ловило бы и код, например CoverageGateTests.cs. Каталог
        # coverage/ или CoverageReport/ — мусор целиком, как TestResults/.
        lpath="${file,,}"
        [[ "$lbase" == *.trx || "$lbase" == *.cobertura.xml || "$file" =~ (^|/)[Tt]est[Rr]esults?/ ||
           "$lbase" =~ ^coverage.*\.(xml|json|info)$ || "$lbase" == *.coverage || "$lbase" == *.coveragexml ||
           "$lpath" =~ (^|/)(coverage|coveragereport)/ ]] &&
            report "$file" 1 'мусор прогона в диффе (*.trx, TestResults/, отчёт покрытия)'
        [[ "$lbase" == *.keystore || "$lbase" == *.p12 || "$lbase" == *.mobileprovision || "$base" == google-services.json ]] &&
            report "$file" 1 'подпись или ключ платформы в диффе'
    fi
    is_code_file "$file" || continue
    [[ "$base" == *.ruleset ]] && { report "$file" 1 'подавление: правка *.ruleset'; continue; }
    declare -A DOWN=()
    if is_migration "$file" && [ "$status" != D ]; then
        while IFS= read -r n; do DOWN[$n]=1; done < <(down_lines "$file")
    fi
    file_lines "$file" > "$LINES" ||
        { printf 'guard-lite: не удалось получить дифф %s\n' "$file" >&2; exit 2; }
    while IFS=$'\t' read -r tag line text; do
        if [ "$tag" = + ]; then
            check_added "$file" "$line" "$text"
            [[ "$base" == *.cs && "$text" =~ $TEST_ATTR ]] && TESTS_ADDED=$((TESTS_ADDED + 1))
        elif [[ "$base" == *.cs && "$text" =~ $TEST_ATTR ]]; then
            printf '%s\t%s\t%s\n' "$file" "$line" "$text" >> "$REMOVED_TESTS"
        fi
    done < "$LINES"
    unset DOWN
done < "$NAME_STATUS"

TESTS_REMOVED="$(wc -l < "$REMOVED_TESTS" | tr -d ' ')"
if [ "$TESTS_REMOVED" -gt "$TESTS_ADDED" ]; then
    while IFS=$'\t' read -r file line text; do
        report "$file" "$line" "удалён тестовый метод (удалено $TESTS_REMOVED, добавлено $TESTS_ADDED): ${text#"${text%%[![:space:]]*}"}"
    done < "$REMOVED_TESTS"
fi

if [ "$VIOLATIONS" -eq 0 ]; then
    printf 'guard-lite: нарушений нет (%s..%s)\n' "${BASE:0:7}" "${HEAD:0:7}"
    exit 0
fi
printf 'guard-lite: нарушений — %s (%s..%s). Обход проверки не чинит её: уберите причину.\n' \
    "$VIOLATIONS" "${BASE:0:7}" "${HEAD:0:7}"
exit 1
