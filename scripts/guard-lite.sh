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
# тест, унесённый в файл не того типа, считается удалённым. Отдельный проход
# с -M ловит удалённый или вынесенный из tests/ файл *.cs (п.6 #133). Пути —
# из -z, поэтому кавычек git в них нет.
#
# МИГРАЦИИ. Миграция — *.cs или *.sql на любой глубине под Migrations/.
# SQL-файл проверяется целиком и только правилами миграций. Разрушительный
# вызов API EF и сырой SQL смотрятся во всём файле *.cs миграции, кроме тела
# Down() (граница из #125): откат законно снимает то, что создал Up(). Тело
# Down() размечается по вершине (down_lines): комментарии и литералы, которые
# разметка разбирает, скобки не сдвигают. Граница не определена — нарушение
# с причиной, и файл проверяется целиком: два объявления Down(), Down() не
# закрыт, глубина скобок ушла в минус, внутри Down() объявлен Up(), а также
# интерполированная строка, raw string, обычный литерал без закрытия в строке
# или verbatim, не закрытый до конца файла, в файле с объявлением Down().
# Рукописный migrationBuilder.Sql(@"…") в несколько строк разбирается: его
# строки — литерал, скобки в них границу не сдвигают. SQL не разбирается —
# ищется текст в строке: оператор, разнесённый по строкам, не ловится;
# IF [NOT] EXISTS снимает срабатывание только с оператора, за ключевым словом
# которого стоит (перенос из guard.sh, 9).
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
        .editorconfig | .globalconfig | *.cs | *.csproj | *.props | *.targets | *.yml | *.yaml | \
            *.rsp | *.runsettings | *.ruleset) return 0 ;;
        *.sql) is_migration "$1" && return 0 ;;
    esac
    return 1
}
# Миграция — *.cs или *.sql на любой глубине под каталогом Migrations/.
is_migration() { [[ "$1" =~ (^|/)Migrations/(.+/)?[^/]+\.(cs|sql)$ ]]; }

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

# Разметка Down() в версии вершины: «D<TAB>номер» на каждую строку от
# заголовка до закрытия тела, «E<TAB>номер<TAB>причина» — граница не
# определена. Сначала строка очищается: комментарии вырезаются, литералы
# (обычная строка с экранированием «\», verbatim @"…" с «""», символьный
# '…') заменяются пустыми; потом по очищенному коду ищутся заголовки и
# считаются скобки. Verbatim без закрытия в строке продолжается на следующих
# (inverb): их текст до кавычки, не удвоенной, — литерал. Форма, которую
# разметка не разбирает, — интерполированная строка, raw string, обычный
# литерал без закрытия в строке, verbatim без закрытия до конца файла —
# останавливает разбор: в файле с объявлением Down() это «E», а не догадка.
# Только POSIX awk (в CI это mawk), байтово: синтаксис C# — ASCII.
down_lines() {
    git show "$HEAD:$1" 2>/dev/null | LC_ALL=C awk '
        function fail(why) { if (!stop) { stop = 1; eline = NR; ereason = why } }
        function isid(ch) { return ch ~ /[A-Za-z0-9_]/ }
        # Конец литерала, открытого перед позицией j: номер закрывающей
        # кавычки q или 0, если до конца строки он не закрыт.
        function close_at(s, j, q, verb,    ch) {
            while (j <= length(s)) {
                ch = substr(s, j, 1)
                if (verb && ch == q) { if (substr(s, j + 1, 1) == q) { j += 2; continue } return j }
                if (!verb && ch == "\\") { j += 2; continue }
                if (ch == q) return j
                j++
            }
            return 0
        }
        {
            raw = $0; sub(/\r$/, "", raw)
            if (raw ~ /void[ \t]+Down[ \t]*\(/) rawdown = 1
            if (stop) next
            mark = (mode != "")
            code = ""; n = length(raw); i = 1
            if (inverb) {
                # Продолжение verbatim со строки vline: до закрывающей
                # кавычки всё — содержимое литерала, а не код.
                j = close_at(raw, 1, "\"", 1)
                if (!j) { if (mark) print "D\t" NR; next }
                inverb = 0; code = "\"\""; i = j + 1
            } else if (!inblock && raw ~ /^[ \t]*#/) { if (mark) print "D\t" NR; next }
            while (i <= n) {
                c = substr(raw, i, 1); c2 = substr(raw, i, 2)
                if (inblock) { if (c2 == "*/") { inblock = 0; i += 2; code = code " " } else i++; continue }
                if (c2 == "//") break
                if (c2 == "/*") { inblock = 1; i += 2; continue }
                if (c2 == "$\"" || c2 == "$@" || c2 == "@$") { fail("интерполированная строка"); break }
                if (substr(raw, i, 3) == "\"\"\"") { fail("raw string"); break }
                if (c2 == "@\"" || c == "\"" || c == "'\''") {
                    verb = (c == "@"); q = verb ? "\"" : c
                    j = close_at(raw, i + (verb ? 2 : 1), q, verb)
                    if (!j && verb) { inverb = 1; vline = NR; code = code q q; break }
                    if (!j) { fail("незакрытый литерал"); break }
                    code = code q q; i = j + 1; continue
                }
                code = code c; i++
            }
            if (stop) next
            n = length(code)
            for (i = 1; i <= n; i++) {
                c = substr(code, i, 1)
                if (c == "v" && (i == 1 || !isid(substr(code, i - 1, 1)))) {
                    rest = substr(code, i)
                    if (rest ~ /^void[ \t]+Down[ \t]*\(/) {
                        if (++downs > 1) { fail("заголовков Down() больше одного"); break }
                        mode = "sig"; hline = NR; mark = 1; continue
                    }
                    if (mode != "" && rest ~ /^void[ \t]+Up[ \t]*\(/) { fail("заголовок Up() внутри Down()"); break }
                }
                if (c == "{") {
                    depth++
                    if (mode == "sig") { mode = "body"; ddepth = depth }
                } else if (c == "}") {
                    if (--depth < 0) { fail("глубина скобок ушла в минус"); break }
                    if (mode == "body" && depth < ddepth) mode = ""
                } else if (c == "=" && substr(code, i + 1, 1) == ">" && mode == "sig") {
                    mode = "expr"; edepth = depth
                } else if (c == ";" && (mode == "sig" || (mode == "expr" && depth == edepth))) {
                    mode = ""
                }
            }
            if (stop) next
            if (mark) print "D\t" NR
        }
        END {
            if (!stop && inverb) { stop = 1; eline = vline; ereason = "многострочный литерал не закрыт до конца файла" }
            if (stop) { if (rawdown || downs) printf "E\t%d\t%s\n", eline, ereason }
            else if (mode != "") printf "E\t%d\t%s\n", hline, "Down() не закрыт до конца файла"
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
    '<TestCaseFilter>.*(!=|!~)'                           'TestCaseFilter с отрицанием'
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
    local file="$1" line="$2" text="$3" i
    # SQL-файл миграции — не код сборки: только правила миграций.
    [[ "$file" == *.sql ]] && { check_migration "$file" "$line" "$text"; return 0; }
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
    is_migration "$file" && check_migration "$file" "$line" "$text"
    return 0
}

check_migration() {
    local file="$1" line="$2" text="$3" i lower rest
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
        [[ "$lbase" == *.keystore || "$lbase" == *.p12 || "$lbase" == *.mobileprovision || "$base" == google-services.json ||
           "$base" == GoogleService-Info.plist ]] &&
            report "$file" 1 'подпись или ключ платформы в диффе'
    fi
    is_code_file "$file" || continue
    [[ "$base" == *.ruleset ]] && { report "$file" 1 'подавление: правка *.ruleset'; continue; }
    declare -A DOWN=()
    if is_migration "$file" && [[ "$base" == *.cs && "$status" != D ]]; then
        undetermined=0
        while IFS=$'\t' read -r kind n why; do
            case "$kind" in
                D) DOWN[$n]=1 ;;
                E) report "$file" "$n" "граница Down() не определена: $why"; undetermined=1 ;;
            esac
        done < <(down_lines "$file")
        # Граница не определена — весь файл проверяется как Up().
        [ "$undetermined" -eq 0 ] || DOWN=()
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

# Файл тестового кода (*.cs под tests/), удалённый или вынесенный из него, —
# нарушение сам по себе: баланс атрибутов ниже его не видит, если столько же
# тестов добавлено в другом месте. Отдельный проход с -M (порог сходства git
# по умолчанию, 50 %): переименование в tests/…*.cs не нарушение; переименование
# с переписыванием ниже порога git читает как удаление — красный осознанно,
# переименование и переписывание идут разными PR. Не-код под tests/ не правило.
is_test_code() { [[ "$1" == tests/*.cs ]]; }
git -c core.quotePath=false diff --name-status -z -M "$BASE" "$HEAD" > "$NAME_STATUS" ||
    { echo 'guard-lite: не удалось получить список переименований' >&2; exit 2; }
while IFS= read -r -d '' status && IFS= read -r -d '' file; do
    case "$status" in
        R*) IFS= read -r -d '' dest
            is_test_code "$file" && ! is_test_code "$dest" &&
                report "$file" 1 "удалён или вынесен из tests/ файл тестов (перенесён в $dest)" ;;
        D) is_test_code "$file" && report "$file" 1 'удалён или вынесен из tests/ файл тестов (удалён)' ;;
    esac
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
