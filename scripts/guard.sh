#!/usr/bin/env bash
#
# Домовой — гейт целостности (фаза 4 внедрения агентского пайплайна).
#
# ЗАЧЕМ
#
# Скрипт ловит не баги — для этого есть сборка, тесты и gitleaks. Он ловит
# попытки обойти проверки. Агент, застрявший на красном CI, склонен делать
# его зелёным неправильным способом: подавить предупреждение, пометить тест
# как пропущенный, удалить неудобный тест, ослабить конфигурацию качества.
# Гейт — единственное, что стоит между таким «исправлением» и зелёной
# сборкой. Поэтому он смотрит на дифф PR, а не на состояние кода.
#
# КАК ЗАПУСКАТЬ
#
#   bash scripts/guard.sh                       # сравнить HEAD с origin/main
#   bash scripts/guard.sh origin/main           # то же явно
#   bash scripts/guard.sh <база> <вершина>      # произвольный диапазон
#
# Первый аргумент — базовая ветка или коммит (по умолчанию origin/main).
# Второй, необязательный, — вершина сравнения (по умолчанию HEAD). Второй
# аргумент нужен, чтобы прогонять гейт по истории (коммит против родителя)
# без переключения рабочего каталога: скрипт читает только git, рабочее
# дерево не трогает вообще.
#
# Код возврата: 0 — нарушений нет, 1 — есть нарушения, 2 — ошибка запуска.
# Гейт всегда доходит до конца и печатает ВСЕ нарушения за один прогон:
# `set -e` здесь намеренно не включён.
#
# ПЕРЕМЕННЫЕ ОКРУЖЕНИЯ (в CI их проставляет workflow по меткам PR)
#
#   GUARD_ALLOW_PROTECTED              метка agent/allow-protected
#                                      разрешает изменение защищённых путей
#   GUARD_ALLOW_CONTRACT               метка agent/allow-contract
#                                      разрешает изменение contracts/openapi.json
#   GUARD_ALLOW_DESTRUCTIVE_MIGRATION  метка agent/allow-destructive-migration
#                                      разрешает деструктивную миграцию
#   GUARD_GITLEAKS                     путь к бинарю gitleaks, если он не в PATH
#
# Значения «включено»: 1, true, yes, on (регистр не важен). Всё остальное,
# включая пустую строку, — выключено.
#
# ЧТО ПРОВЕРЯЕТСЯ
#
#   1. Изменение защищённых путей (список синхронизирован с .github/CODEOWNERS
#      и разделом «Файлы, которые агент не трогает» в .claude/CLAUDE.md —
#      расхождение между тремя местами считается дефектом).
#   2. Добавление подавления проверок.
#   3. Удаление тестов.
#   4. Деструктивная миграция.
#   5. Изменение контракта API.
#   6. Захардкоженные секреты — делегировано gitleaks (см. ниже).
#
set -uo pipefail

# ------------------------------------------------------------------
# Аргументы и окружение
# ------------------------------------------------------------------
BASE_REF="${1:-origin/main}"
HEAD_REF="${2:-HEAD}"

if ! git rev-parse --git-dir >/dev/null 2>&1; then
    printf '::error::guard.sh запущен вне git-репозитория.\n' >&2
    exit 2
fi

for ref in "$BASE_REF" "$HEAD_REF"; do
    if ! git rev-parse --verify --quiet "$ref^{commit}" >/dev/null; then
        printf '::error::Неизвестная ревизия: %s. Проверьте аргументы: guard.sh <база> [<вершина>].\n' "$ref" >&2
        exit 2
    fi
done

BASE_SHA="$(git merge-base "$BASE_REF" "$HEAD_REF" 2>/dev/null)"
if [ -z "$BASE_SHA" ]; then
    # Нет общего предка — сравниваем напрямую, лучше так, чем молча ничего
    # не проверить.
    BASE_SHA="$(git rev-parse "$BASE_REF")"
fi
HEAD_SHA="$(git rev-parse "$HEAD_REF")"

is_on() {
    case "${1:-}" in
        1 | [tT][rR][uU][eE] | [yY][eE][sS] | [oO][nN]) return 0 ;;
        *) return 1 ;;
    esac
}

ALLOW_PROTECTED=0
ALLOW_CONTRACT=0
ALLOW_DESTRUCTIVE=0
is_on "${GUARD_ALLOW_PROTECTED:-}" && ALLOW_PROTECTED=1
is_on "${GUARD_ALLOW_CONTRACT:-}" && ALLOW_CONTRACT=1
is_on "${GUARD_ALLOW_DESTRUCTIVE_MIGRATION:-}" && ALLOW_DESTRUCTIVE=1

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

VIOLATIONS=0

# ------------------------------------------------------------------
# Вывод
#
# Формат ::error:: понимает GitHub Actions (аннотация на строке файла).
# Он же читаем и в терминале, поэтому второй, «локальный» формат не нужен:
# два формата разъезжаются, один — нет.
# ------------------------------------------------------------------
annotate() {
    local file="$1" line="$2" message="$3"
    message="${message//$'\r'/}"
    message="${message//$'\n'/ }"
    printf '::error file=%s,line=%s::%s\n' "$file" "$line" "$message"
    VIOLATIONS=$((VIOLATIONS + 1))
}

# Строка исходника под аннотацией: без неё непонятно, на что сработал гейт.
quote_line() {
    local file="$1" line="$2" text="$3"
    text="${text//$'\r'/}"
    printf '    %s:%s: %s\n' "$file" "$line" "$text"
}

section() { printf '\n--- %s\n' "$1"; }

# ------------------------------------------------------------------
# Разбор диффа
#
# git diff -U0 | grep -n печатает номера строк ПОТОКА диффа, а не файла:
# такие номера бесполезны, по ним нельзя открыть файл. Поэтому дифф
# разбирается по заголовкам ханков @@ -a,b +c,d @@, и номера строк
# считаются настоящие: для добавленных — в новой версии файла, для
# удалённых — в базовой.
#
# Формат промежуточного файла: TAG \t FILE \t LINE \t TEXT
# TAG: "+" добавленная строка, "-" удалённая.
# ------------------------------------------------------------------
DIFF_LINES="$WORK/diff-lines.tsv"

git -c core.quotepath=false diff --no-color --no-ext-diff -U0 -M \
    "$BASE_SHA" "$HEAD_SHA" |
    awk '
        function strip(p) {
            if (p == "/dev/null") return ""
            if (p ~ /^[ab]\//) return substr(p, 3)
            return p
        }
        /^diff --git / { oldf = ""; newf = ""; next }
        substr($0, 1, 4) == "--- " { oldf = strip(substr($0, 5)); next }
        substr($0, 1, 4) == "+++ " { newf = strip(substr($0, 5)); next }
        substr($0, 1, 2) == "@@" {
            # $2 = -a[,b]   $3 = +c[,d]
            split(substr($2, 2), o, ",")
            split(substr($3, 2), n, ",")
            oldln = o[1] + 0
            newln = n[1] + 0
            next
        }
        substr($0, 1, 1) == "+" {
            text = substr($0, 2); sub(/\r$/, "", text)
            if (newf != "") print "+\t" newf "\t" newln "\t" text
            newln++
            next
        }
        substr($0, 1, 1) == "-" {
            text = substr($0, 2); sub(/\r$/, "", text)
            if (oldf != "") print "-\t" oldf "\t" oldln "\t" text
            oldln++
            next
        }
        substr($0, 1, 1) == " " { newln++; oldln++; next }
    ' > "$DIFF_LINES"

# Гейт не имеет права молча пропустить PR из-за сломанного git: пустой дифф
# и отсутствие диффа — разные вещи, и вторая должна быть ошибкой запуска,
# а не зелёным результатом.
#
# PIPESTATUS живёт ровно до следующей команды, поэтому копируется сразу:
# первая же проверка [ ... ] его перезапишет.
DIFF_STATUS=("${PIPESTATUS[@]}")
if [ "${DIFF_STATUS[0]:-0}" -ne 0 ] || [ "${DIFF_STATUS[1]:-0}" -ne 0 ]; then
    printf '::error::Не удалось получить дифф %s..%s.\n' "$BASE_SHA" "$HEAD_SHA" >&2
    exit 2
fi

# Список изменённых файлов (с учётом удалений и переименований).
CHANGED_FILES="$WORK/changed.txt"
if ! git -c core.quotepath=false diff --name-only -M \
    "$BASE_SHA" "$HEAD_SHA" > "$CHANGED_FILES"; then
    printf '::error::Не удалось получить список изменённых файлов %s..%s.\n' \
        "$BASE_SHA" "$HEAD_SHA" >&2
    exit 2
fi

# Первая изменённая строка файла — чтобы аннотация вела в осмысленное место,
# а не всегда в начало файла.
first_changed_line() {
    local file="$1" line
    line="$(awk -F'\t' -v f="$file" '$2 == f { print $3; exit }' "$DIFF_LINES")"
    printf '%s' "${line:-1}"
}

# Отбор строк из DIFF_LINES: тег, регулярное выражение, необязательный
# фильтр по имени файла. Печатает FILE \t LINE \t TEXT.
#
# Регулярные выражения передаются через окружение, а не через awk -v:
# awk -v обрабатывает escape-последовательности в значении и портит
# шаблоны вида \[Fact, попутно печатая предупреждения в stderr.
select_lines() {
    local tag="$1"
    export GUARD_SELECT_TAG="$tag"
    export GUARD_SELECT_PAT="$2"
    export GUARD_SELECT_FPAT="${3:-}"
    awk -F'\t' '
        BEGIN {
            tag  = ENVIRON["GUARD_SELECT_TAG"]
            pat  = ENVIRON["GUARD_SELECT_PAT"]
            fpat = ENVIRON["GUARD_SELECT_FPAT"]
        }
        $1 != tag { next }
        fpat != "" && $2 !~ fpat { next }
        {
            text = $0
            sub(/^[^\t]*\t[^\t]*\t[^\t]*\t/, "", text)
            if (text ~ pat) print $2 "\t" $3 "\t" text
        }
    ' "$DIFF_LINES"
}

# ------------------------------------------------------------------
# Проверка 1. Защищённые пути
#
# Список синхронизирован с .github/CODEOWNERS — он источник истины.
# Порядок и группировка повторяют CODEOWNERS, чтобы расхождение было видно
# глазами при сравнении двух файлов.
# ------------------------------------------------------------------
PROTECTED_PATTERNS=(
    # --- Конфигурация качества и сборки ---
    'Directory\.Build\.props'
    'Directory\.Packages\.props'
    '\.editorconfig'
    'global\.json'
    '(.+/)?[^/]+\.ruleset'
    # --- Сам пайплайн ---
    '\.github/.+'
    '\.githooks/.+'
    'scripts/.+'
    # --- Правила проекта и принятые решения ---
    '\.claude/CLAUDE\.md'
    'docs/rules/.+'
    'docs/decisions/.+'
    # --- Поиск секретов ---
    '\.gitleaks\.toml'
    # --- Данные ---
    'src/Domovoy\.Data/Migrations/.+'
    # --- Контракт API и генерация клиента ---
    'contracts/.+'
    'src/Domovoy\.Mobile\.Core/Generated/.+'
    # --- Платформенное и подписи ---
    'src/Domovoy\.Mobile\.App/Platforms/.+'
    'src/Domovoy\.Mobile\.App/Resources/.+'
    '(.+/)?[^/]+\.keystore'
    '(.+/)?[^/]+\.mobileprovision'
    '(.+/)?[^/]+\.p12'
    '(.+/)?google-services\.json'
    '(.+/)?GoogleService-Info\.plist'
    '(.+/)?AndroidManifest\.xml'
    '(.+/)?Info\.plist'
)

PROTECTED_RE="$(
    IFS='|'
    printf '^(%s)$' "${PROTECTED_PATTERNS[*]}"
)"

PROTECTED_HIT="$WORK/protected.txt"
: > "$PROTECTED_HIT"
while IFS= read -r file; do
    [ -n "$file" ] || continue
    if [[ "$file" =~ $PROTECTED_RE ]]; then
        printf '%s\n' "$file" >> "$PROTECTED_HIT"
    fi
done < "$CHANGED_FILES"

if [ -s "$PROTECTED_HIT" ] && [ "$ALLOW_PROTECTED" -eq 0 ]; then
    section 'Проверка 1: изменены защищённые пути'
    while IFS= read -r file; do
        annotate "$file" "$(first_changed_line "$file")" \
            "Защищённый путь изменён: $file. Это конфигурация качества, пайплайн, правила проекта, миграции, контракт или подписи — цена ошибки здесь выше, чем в обычном коде. Изменение допустимо только с меткой agent/allow-protected на PR: её ставит человек, посмотрев дифф. Если метки нет — вынесите правку из этого PR."
    done < "$PROTECTED_HIT"
elif [ -s "$PROTECTED_HIT" ]; then
    section 'Проверка 1: защищённые пути изменены, но есть метка agent/allow-protected'
    while IFS= read -r file; do
        printf '    разрешено: %s\n' "$file"
    done < "$PROTECTED_HIT"
fi

# ------------------------------------------------------------------
# Проверка 2. Подавление проверок
#
# Защищённые пути из проверки 1 исключены безусловно, независимо от метки.
# Причина: Directory.Build.props законно содержит <NoWarn>$(NoWarn);CS1591</NoWarn>,
# .github/** законно содержит настройки работ, и срабатывание проверки 2 на
# этих файлах было бы вторым сообщением о том же самом изменении. Такой файл
# попадает в PR только после того, как человек поставил agent/allow-protected,
# то есть посмотрел дифф целиком — подавление внутри него это его решение,
# а не решение гейта.
#
# Следствие, принятое сознательно: continue-on-error: true внутри .github/**
# проверкой 2 не ловится — его ловит проверка 1. Шаблон остаётся в списке
# ради workflow-файлов вне .github/. Исключение из исключения вернуло бы
# ровно то двойное срабатывание, которого мы избегаем.
# ------------------------------------------------------------------
SUPPRESSION_PATTERNS=(
    '\[Ignore(\]|\()'
    'Skip[[:space:]]*=[[:space:]]*"'
    '#pragma[[:space:]]+warning[[:space:]]+disable'
    '<NoWarn[>[:space:]]'
    '\[ExcludeFromCodeCoverage'
    '<TreatWarningsAsErrors>[[:space:]]*false'
    'continue-on-error:[[:space:]]*true'
    '--filter.*(!~|!=)'
)

# Порядок совпадает с SUPPRESSION_PATTERNS: массивы читаются параллельно.
SUPPRESSION_LABELS=(
    '[Ignore] — тест исключён из прогона'
    'Skip = "…" — тест исключён из прогона'
    '#pragma warning disable — предупреждение подавлено точечно'
    '<NoWarn> — предупреждение подавлено на весь проект'
    '[ExcludeFromCodeCoverage] — код исключён из покрытия'
    '<TreatWarningsAsErrors>false — предупреждения перестали быть ошибками'
    'continue-on-error: true — падение шага перестало ронять работу'
    '--filter с отрицанием — часть тестов исключена из прогона'
)

SUPPRESSION_HIT="$WORK/suppression.txt"
: > "$SUPPRESSION_HIT"
for index in "${!SUPPRESSION_PATTERNS[@]}"; do
    pattern="${SUPPRESSION_PATTERNS[$index]}"
    label="${SUPPRESSION_LABELS[$index]}"
    while IFS=$'\t' read -r file line text; do
        [ -n "$file" ] || continue
        if [[ "$file" =~ $PROTECTED_RE ]]; then
            continue
        fi
        printf '%s\t%s\t%s\t%s\n' "$file" "$line" "$label" "$text" >> "$SUPPRESSION_HIT"
    done < <(select_lines '+' "$pattern")
done

if [ -s "$SUPPRESSION_HIT" ]; then
    section 'Проверка 2: добавлено подавление проверок'
    while IFS=$'\t' read -r file line label text; do
        annotate "$file" "$line" \
            "Подавление проверки: $label. Подавление делает сборку зелёной, не решая причину. Уберите причину предупреждения или падения. Если подавление действительно необходимо — оно оформляется комментарием // HACK: со ссылкой на заведённую issue и обсуждается в PR, а не проносится в диффе."
        quote_line "$file" "$line" "$text"
    done < "$SUPPRESSION_HIT"
fi

# ------------------------------------------------------------------
# Проверка 3. Удаление тестов
#
# Внимание: в этом репозитории все атрибуты записаны в форме
# [Fact(DisplayName = "…")] и [Theory(DisplayName = "…")], голого [Fact]
# нет ни одного. Регулярка \[(Fact|Theory)\] дала бы ноль совпадений всегда
# и сделала бы проверку мёртвой, поэтому за именем атрибута допускается
# как ']', так и '('.
#
# Подсчёт ограничен каталогом tests/. Строка, похожая на атрибут, в
# документации, в примере или в фикстуре проверочного сценария — не тест,
# и её правка не должна выглядеть как удаление теста.
# ------------------------------------------------------------------
TEST_ATTR_RE='\[(Fact|Theory)(\]|\()'
TEST_FILE_RE='^tests/'

DELETED_TESTS="$WORK/deleted-tests.txt"
git -c core.quotepath=false diff --name-only --diff-filter=D -M \
    "$BASE_SHA" "$HEAD_SHA" -- 'tests/' > "$DELETED_TESTS"

ADDED_ATTRS="$WORK/added-attrs.tsv"
REMOVED_ATTRS="$WORK/removed-attrs.tsv"
select_lines '+' "$TEST_ATTR_RE" "$TEST_FILE_RE" > "$ADDED_ATTRS"
select_lines '-' "$TEST_ATTR_RE" "$TEST_FILE_RE" > "$REMOVED_ATTRS"

ADDED_ATTR_COUNT="$(wc -l < "$ADDED_ATTRS" | tr -d ' ')"
REMOVED_ATTR_COUNT="$(wc -l < "$REMOVED_ATTRS" | tr -d ' ')"

if [ -s "$DELETED_TESTS" ] || [ "$REMOVED_ATTR_COUNT" -gt "$ADDED_ATTR_COUNT" ]; then
    section 'Проверка 3: удалены тесты'

    while IFS= read -r file; do
        [ -n "$file" ] || continue
        annotate "$file" '1' \
            "Файл с тестами удалён: $file. Удаление теста — не способ сделать сборку зелёной. Если тест устарел вместе с поведением, которое он проверял, — объясните это в описании PR и в сообщении коммита; если он мешает — почините код, а не тест."
    done < "$DELETED_TESTS"

    if [ "$REMOVED_ATTR_COUNT" -gt "$ADDED_ATTR_COUNT" ]; then
        printf '    удалено [Fact]/[Theory]: %s, добавлено: %s\n' \
            "$REMOVED_ATTR_COUNT" "$ADDED_ATTR_COUNT"
        while IFS=$'\t' read -r file line text; do
            [ -n "$file" ] || continue
            annotate "$file" "$line" \
                "Тест удалён: [Fact]/[Theory] пропал из $file (строка $line базовой версии). Удалённых тестов в этом PR больше, чем добавленных ($REMOVED_ATTR_COUNT против $ADDED_ATTR_COUNT). Покрытие не должно уменьшаться молча."
            quote_line "$file" "$line" "$text"
        done < "$REMOVED_ATTRS"
    fi
fi

# ------------------------------------------------------------------
# Проверка 4. Деструктивная миграция
#
# Каталога миграций может не существовать (первая миграция появится позже) —
# проверка работает по диффу, поэтому его отсутствие не ошибка, а пустой
# результат.
# ------------------------------------------------------------------
MIGRATION_FILE_RE='^src/Domovoy\.Data/Migrations/'
DESTRUCTIVE_RE='(DropColumn|DropTable|RenameColumn|RenameTable|AlterColumn)'

DESTRUCTIVE_HIT="$WORK/destructive.tsv"
select_lines '+' "$DESTRUCTIVE_RE" "$MIGRATION_FILE_RE" > "$DESTRUCTIVE_HIT"

if [ -s "$DESTRUCTIVE_HIT" ] && [ "$ALLOW_DESTRUCTIVE" -eq 0 ]; then
    section 'Проверка 4: деструктивная миграция'
    while IFS=$'\t' read -r file line text; do
        [ -n "$file" ] || continue
        annotate "$file" "$line" \
            "Деструктивная операция в миграции: $file. Удаление и переименование столбцов и таблиц необратимо теряет данные и ломает работающий экземпляр при откате. Нужна метка agent/allow-destructive-migration на PR — её ставит человек, убедившись, что данные не нужны или есть план переноса."
        quote_line "$file" "$line" "$text"
    done < "$DESTRUCTIVE_HIT"
elif [ -s "$DESTRUCTIVE_HIT" ]; then
    section 'Проверка 4: деструктивная миграция разрешена меткой agent/allow-destructive-migration'
    cut -f1,2 "$DESTRUCTIVE_HIT" | sed 's/^/    разрешено: /'
fi

# ------------------------------------------------------------------
# Проверка 5. Контракт API
#
# Каталога contracts/ может ещё не быть — та же оговорка, что и с миграциями.
# ------------------------------------------------------------------
CONTRACT_FILE='contracts/openapi.json'

if grep -Fxq "$CONTRACT_FILE" "$CHANGED_FILES"; then
    if [ "$ALLOW_CONTRACT" -eq 0 ]; then
        section 'Проверка 5: изменён контракт API'
        annotate "$CONTRACT_FILE" "$(first_changed_line "$CONTRACT_FILE")" \
            "Контракт API изменён: $CONTRACT_FILE. От него зависит сгенерированный клиент и уже установленные приложения — несогласованное изменение ломает их без предупреждения. Нужна метка agent/allow-contract на PR."
    else
        section 'Проверка 5: контракт API изменён, но есть метка agent/allow-contract'
        printf '    разрешено: %s\n' "$CONTRACT_FILE"
    fi
fi

# ------------------------------------------------------------------
# Проверка 6. Захардкоженные секреты — делегировано gitleaks
#
# Свой параллельный regexp здесь был бы вредной самодеятельностью. В
# репозитории уже работают два прохода gitleaks (хук pre-commit и работа
# gitleaks.yml в CI) по конфигу .gitleaks.toml, который знает приватные
# данные именно этого проекта: домены, entity_id, топик ntfy. Свой слабый
# дубль дал бы ложные срабатывания на легальных именах полей и пропустил
# бы ровно то, ради чего конфиг писался. Поэтому гейт не ищет секреты сам,
# а вызывает gitleaks на диапазоне коммитов.
#
# Отсутствие бинаря здесь не ошибка: гейт запускают и локально. Основной
# рубеж — хук pre-commit, который без gitleaks коммит не пропускает, и
# отдельная работа gitleaks.yml в CI. Дублировать их отказом означало бы
# сделать гейт неработающим там, где он и не должен быть единственным.
# ------------------------------------------------------------------
find_gitleaks() {
    if [ -n "${GUARD_GITLEAKS:-}" ]; then
        if [ -x "$GUARD_GITLEAKS" ] || command -v "$GUARD_GITLEAKS" >/dev/null 2>&1; then
            printf '%s\n' "$GUARD_GITLEAKS"
            return 0
        fi
        return 1
    fi

    if command -v gitleaks >/dev/null 2>&1; then
        command -v gitleaks
        return 0
    fi

    local candidate
    for candidate in \
        "${LOCALAPPDATA:-}/Microsoft/WinGet/Links/gitleaks.exe" \
        "${HOME:-}/AppData/Local/Microsoft/WinGet/Links/gitleaks.exe" \
        "${HOME:-}/.local/bin/gitleaks" \
        "${HOME:-}/go/bin/gitleaks" \
        "/usr/local/bin/gitleaks" \
        "/opt/homebrew/bin/gitleaks"; do
        if [ -x "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

REPO_ROOT="$(git rev-parse --show-toplevel)"
GITLEAKS_CONFIG="$REPO_ROOT/.gitleaks.toml"

if [ "$BASE_SHA" = "$HEAD_SHA" ]; then
    : # пустой диапазон, сканировать нечего
elif GITLEAKS_BIN="$(find_gitleaks)"; then
    gitleaks_args=(git --redact --no-banner --log-level warn
        --log-opts "$BASE_SHA..$HEAD_SHA")
    if [ -f "$GITLEAKS_CONFIG" ]; then
        gitleaks_args+=(-c "$GITLEAKS_CONFIG")
    fi
    gitleaks_args+=("$REPO_ROOT")

    GITLEAKS_OUT="$WORK/gitleaks.txt"
    if ! "$GITLEAKS_BIN" "${gitleaks_args[@]}" > "$GITLEAKS_OUT" 2>&1; then
        section 'Проверка 6: gitleaks нашёл секрет'
        sed 's/^/    /' "$GITLEAKS_OUT"
        annotate '.gitleaks.toml' '1' \
            "gitleaks нашёл секрет или приватные данные в коммитах $BASE_SHA..$HEAD_SHA (значения в выводе выше отредактированы). Секреты приходят только из IConfiguration: локально dotnet user-secrets, в продакшене переменные окружения. Значение, уже попавшее в историю, считается скомпрометированным и подлежит отзыву, а не удалению. Если это ложное срабатывание — правило добавляется в .gitleaks.toml отдельным PR."
    fi
else
    section 'Проверка 6: gitleaks не найден'
    printf '    Поиск секретов не выполнен здесь и выполняется отдельно:\n'
    printf '      хук .githooks/pre-commit — не пропускает коммит без gitleaks;\n'
    printf '      работа gitleaks.yml в CI — обязательная проверка PR.\n'
    printf '    Свой упрощённый поиск гейт намеренно не делает: он дал бы\n'
    printf '    ложные срабатывания и пропустил бы то, что ловит .gitleaks.toml.\n'
    printf '    Чтобы проверять локально: winget install --id Gitleaks.Gitleaks --exact\n'
    printf '    или укажите путь к бинарю в GUARD_GITLEAKS.\n'
fi

# ------------------------------------------------------------------
# Итог
# ------------------------------------------------------------------
printf '\n'
if [ "$VIOLATIONS" -eq 0 ]; then
    printf 'Гейт целостности: нарушений нет (%s..%s).\n' \
        "${BASE_SHA:0:7}" "${HEAD_SHA:0:7}"
    exit 0
fi

printf 'Гейт целостности: нарушений — %s (%s..%s).\n' \
    "$VIOLATIONS" "${BASE_SHA:0:7}" "${HEAD_SHA:0:7}"
printf 'Гейт ловит не баги, а обход проверок. Зелёная сборка, полученная\n'
printf 'подавлением или удалением теста, хуже красной: она врёт.\n'
printf 'Метки ставит человек, а не агент: agent/allow-protected,\n'
printf 'agent/allow-contract, agent/allow-destructive-migration.\n'
exit 1
