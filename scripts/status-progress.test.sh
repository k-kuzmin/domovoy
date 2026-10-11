#!/usr/bin/env bash
#
# Домовой — проверочные сценарии картинки прогресса этапов (#140).
#
# ЗАЧЕМ
#
# `scripts/status-progress.sh` рисует прогресс этапов из майлстоунов и задач
# и публикует картинки в ветку status, минуя main. Обе половины работают в
# workflow, который до мерджа по событиям issues не запускается вовсе, —
# поэтому то, что можно проверить без GitHub, проверяется здесь.
#
# В СЕТЬ ЭТИ СЦЕНАРИИ НЕ ХОДЯТ
#
# Отрисовка читает рукописные фикстуры в форме ответа `gh api --paginate`.
# Публикация идёт в bare-репозиторий песочницы; перед каждым вызовом
# `publish` проверяется, что origin клона — именно он, иначе прогон
# прерывается с кодом 2: ошибка в каталоге здесь означала бы запись в
# настоящую ветку status публичного репозитория. Git запускается с
# `GIT_CONFIG_GLOBAL=/dev/null`, `GIT_CONFIG_NOSYSTEM=1` и пустым HOME —
# как на чистом runner, где identity коммита никто не задал.
#
# Форма workflow и README читается из дерева репозитория (от каталога
# сценария, а не от текущего каталога).
#
# ЧЕГО ЭТИ СЦЕНАРИИ НЕ ЛОВЯТ
#
# Права GITHUB_TOKEN, версию git на runner, учётные данные checkout в linked
# worktree и сам факт записи в status на GitHub — их показывает проверочный
# прогон workflow на PR (`publish --dry-run`) и первый прогон после мерджа.
# Внешний вид картинки в темах GitHub — только наблюдением.
#
# КАК ЗАПУСКАТЬ
#
#   bash scripts/status-progress.test.sh
#
# Код возврата: 0 — все сценарии прошли, 1 — есть провалившиеся,
# 2 — запустить нечем.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET="$SCRIPT_DIR/status-progress.sh"
WORKFLOW="$ROOT/.github/workflows/status-progress.yml"
README="$ROOT/README.md"

if [ ! -f "$TARGET" ]; then
    printf 'Не найден %s\n' "$TARGET" >&2
    exit 2
fi
for tool in jq git python3; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        printf 'Для сценариев нужен %s.\n' "$tool" >&2
        exit 2
    fi
done

# Прогон может идти изнутри хука или чужого git-окружения: переменные,
# привязывающие git к конкретному репозиторию, песочнице не нужны.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

PASSED=0
FAILED=0
FAILED_NAMES=()

CASE_NAME=''
CASE_OK=1
OUT=''
ERR=''
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
        printf '        stdout:\n%s\n' "$(printf '%s\n' "$OUT" | head -40)" | sed 's/^/        /'
        printf '        stderr:\n%s\n' "$ERR" | sed 's/^/        /'
    fi
}

expect_status() {
    if [ "$STATUS" -ne "$1" ]; then
        fail_case "код возврата $STATUS, ожидался $1"
    fi
}

expect_status_not_zero() {
    if [ "$STATUS" -eq 0 ]; then
        fail_case 'код возврата 0, ожидался отказ'
    fi
}

expect_out() {
    if ! printf '%s\n' "$OUT" | grep -qF -- "$1"; then
        fail_case "в stdout нет: $1"
    fi
}

expect_out_empty() {
    if [ -n "$OUT" ]; then
        fail_case 'stdout не пуст'
    fi
}

expect_err_not_empty() {
    if [ -z "$ERR" ]; then
        fail_case 'stderr пуст: отказ без объяснения'
    fi
}

# jq на Windows печатает CRLF; в CI его нет, но сравнения строк не должны
# зависеть от машины, на которой идёт прогон.
J() { jq "$@" | tr -d '\r'; }

# ------------------------------------------------------------------
# Отрисовка
# ------------------------------------------------------------------
render() {
    "$BASH" "$TARGET" render "$@" > "$SANDBOX/out.txt" 2> "$SANDBOX/err.txt"
    STATUS=$?
    OUT="$(tr -d '\r' < "$SANDBOX/out.txt")"
    ERR="$(< "$SANDBOX/err.txt")"
}

# Строки этапов: картинка пишет каждый этап одной строкой `<g class="stage">`.
stage_lines() { printf '%s\n' "$OUT" | grep -F '<g class="stage">' || true; }
labels() { stage_lines | sed -n 's/.*<text class="label"[^>]*>\([^<]*\)<\/text>.*/\1/p'; }
percents() { stage_lines | sed -n 's/.*<text class="pct"[^>]*>\([^<]*\)<\/text>.*/\1/p'; }

# Подпись этапа N: строка из labels(), начинающаяся с «Этап N.».
row_for() { stage_lines | grep -F "<text class=\"label\"" | grep -F ">Этап $1." || true; }
pct_of() { row_for "$1" | sed -n 's/.*<text class="pct"[^>]*>\([^<]*\)<\/text>.*/\1/p'; }
rect_width() {
    # $1 — строка этапа, $2 — класс прямоугольника.
    printf '%s\n' "$1" | sed -n "s/.*<rect class=\"$2\"[^>]* width=\"\\([0-9]*\\)\".*/\\1/p"
}

# Майлстоуны: номер майлстоуна и номер этапа намеренно не совпадают по
# порядку, «Этап 0» закрыт, «Бэклог» и «Этапы позже» — посторонние.
# Счётчики open_issues/closed_issues намеренно врут: картинка обязана
# следовать состоянию задач, а не кешу майлстоуна.
STAGE6_TITLE='Этап 6. Память, профиль дома, подтверждения, локальная LLM'
FX_MS="$SANDBOX/milestones.json"
cat > "$FX_MS" <<JSON
[
  { "number": 3, "title": "$STAGE6_TITLE", "state": "open", "open_issues": 0, "closed_issues": 0 },
  { "number": 9, "title": "Бэклог", "state": "open", "open_issues": 5, "closed_issues": 5 },
  { "number": 1, "title": "Этап 3. Голос", "state": "open", "open_issues": 4, "closed_issues": 4 },
  { "number": 5, "title": "Этап 0. Инфраструктура", "state": "closed", "open_issues": 7, "closed_issues": 0 },
  { "number": 7, "title": "Этап 2. Home Assistant", "state": "open", "open_issues": 0, "closed_issues": 0 },
  { "number": 2, "title": "Этап 1. Ядро агента", "state": "open", "open_issues": 0, "closed_issues": 10 },
  { "number": 8, "title": "Этапы позже", "state": "open", "open_issues": 1, "closed_issues": 0 },
  { "number": 6, "title": "Этап 5. Мобильное приложение", "state": "open", "open_issues": 0, "closed_issues": 0 },
  { "number": 4, "title": "Этап 4. Уведомления", "state": "open", "open_issues": 0, "closed_issues": 0 }
]
JSON

# Задачи: этап 0 — 3/3 (100), этап 1 — 4/10 и закрытый PR (40), этап 2 —
# 2/3 (66), этап 3 — ни одной (0), этап 4 — 0/1 (0), этап 5 — 1/4 (25),
# этап 6 — 199/200 (99: округление вниз, а не к ближайшему). Плюс задачи
# постороннего майлстоуна и без майлстоуна.
issues_json() {
    J -n '
      def iss($m; $s): { state: $s, milestone: (if $m == null then null else { number: $m } end) };
      [ range(3) | iss(5; "closed") ]
      + [ range(4) | iss(2; "closed") ] + [ range(6) | iss(2; "open") ]
      + [ { state: "closed", milestone: { number: 2 }, pull_request: { url: "x" } } ]
      + [ range(2) | iss(7; "closed") ] + [ iss(7; "open") ]
      + [ iss(4; "open") ]
      + [ iss(6; "closed") ] + [ range(3) | iss(6; "open") ]
      + [ range(199) | iss(3; "closed") ] + [ iss(3; "open") ]
      + [ range(5) | iss(9; "closed") ] + [ iss(null; "closed") ]'
}
FX_IS="$SANDBOX/issues.json"
issues_json > "$FX_IS"

EXPECTED_LABELS="Этап 0. Инфраструктура
Этап 1. Ядро агента
Этап 2. Home Assistant
Этап 3. Голос
Этап 4. Уведомления
Этап 5. Мобильное приложение
$STAGE6_TITLE"
EXPECTED_PCTS='100 %
40 %
66 %
0 %
0 %
25 %
99 %'

# ==================================================================
# Семь этапов по порядку номера, в обеих темах одинаково.
# ==================================================================
for theme in light dark; do
    begin_case "семь этапов по порядку номера ($theme)"
    render "$theme" "$FX_MS" "$FX_IS"
    expect_status 0
    n="$(stage_lines | grep -c '')"
    [ "$n" -eq 7 ] || fail_case "строк-этапов $n, ожидалось 7"
    [ "$(labels)" = "$EXPECTED_LABELS" ] ||
        fail_case "подписи не те или не в том порядке: $(labels | tr '\n' '|')"
    printf '%s\n' "$OUT" | grep -qF 'Бэклог' && fail_case 'посторонний майлстоун «Бэклог» на картинке'
    printf '%s\n' "$OUT" | grep -qF 'Этапы позже' && fail_case 'посторонний майлстоун «Этапы позже» на картинке'
    end_case
done

begin_case 'обе темы: одинаковые строки, разные цвета'
render light "$FX_MS" "$FX_IS"
LIGHT_OUT="$OUT"
ROWS_LIGHT="$(labels)"
render dark "$FX_MS" "$FX_IS"
DARK_OUT="$OUT"
ROWS_DARK="$(labels)"
[ -n "$ROWS_LIGHT" ] && [ "$ROWS_LIGHT" = "$ROWS_DARK" ] || fail_case 'набор или порядок этапов в темах разный'
[ "$LIGHT_OUT" != "$DARK_OUT" ] || fail_case 'темы дали одинаковую картинку'
strip_colors() { printf '%s\n' "$1" | sed 's/#[0-9a-fA-F]\{6\}/#COLOR/g'; }
[ "$(strip_colors "$LIGHT_OUT")" = "$(strip_colors "$DARK_OUT")" ] ||
    fail_case 'темы различаются не только цветами'
end_case

# ==================================================================
# Процент: по задачам, вниз, без деления на ноль; полоса пропорциональна.
# ==================================================================
begin_case 'процент по задачам округляется вниз, ноль задач — 0 %'
render light "$FX_MS" "$FX_IS"
expect_status 0
[ "$(percents)" = "$EXPECTED_PCTS" ] ||
    fail_case "проценты: $(percents | tr '\n' '|'), ожидалось: $(printf '%s' "$EXPECTED_PCTS" | tr '\n' '|')"
# Этап 0 — закрытый майлстоун: присутствует, и со 100 %.
[ "$(pct_of 0)" = '100 %' ] || fail_case "закрытый этап 0: «$(pct_of 0)», ожидалось 100 %"
# Этап 3 — без единой задачи: присутствует с 0 %.
[ "$(pct_of 3)" = '0 %' ] || fail_case "этап без задач: «$(pct_of 3)», ожидалось 0 %"
end_case

begin_case 'полоса заполнена пропорционально проценту'
render light "$FX_MS" "$FX_IS"
for n in 0 1 2 3 4 5 6; do
    row="$(row_for "$n")"
    track="$(rect_width "$row" track)"
    fill="$(rect_width "$row" fill)"
    pct="$(pct_of "$n")"
    pct="${pct% %}"
    if [ -z "$track" ] || [ -z "$fill" ] || [ -z "$pct" ]; then
        fail_case "этап $n: нет полосы или процента"
        continue
    fi
    [ "$fill" -eq $((track * pct / 100)) ] ||
        fail_case "этап $n: заполнено $fill из $track при $pct %"
done
end_case

begin_case 'PR в майлстоуне не меняет процент'
J '[.[] | select(.pull_request == null)]' "$FX_IS" > "$SANDBOX/issues-no-pr.json"
render light "$FX_MS" "$SANDBOX/issues-no-pr.json"
WITHOUT_PR="$OUT"
render light "$FX_MS" "$FX_IS"
[ "$OUT" = "$WITHOUT_PR" ] || fail_case 'закрытый PR в майлстоуне изменил картинку'
[ "$(pct_of 1)" = '40 %' ] || fail_case "этап 1: «$(pct_of 1)», ожидалось 40 %"
end_case

# ==================================================================
# Экранирование и обрезка заголовка.
# ==================================================================
FX_MS_ESC="$SANDBOX/milestones-escape.json"
J -n '[{ number: 1, title: "Этап 2. A & B <c> \"d\" '"'"'e'"'"'", state: "open" }]' > "$FX_MS_ESC"
printf '[]\n' > "$SANDBOX/issues-empty-array.json"

for theme in light dark; do
    begin_case "заголовок экранируется под XML ($theme)"
    render "$theme" "$FX_MS_ESC" "$SANDBOX/issues-empty-array.json"
    expect_status 0
    expect_out 'A &amp; B &lt;c&gt; &quot;d&quot;'
    if ! printf '%s' "$OUT" | python3 -c 'import sys, xml.dom.minidom; xml.dom.minidom.parse(sys.stdin.buffer)' 2> "$SANDBOX/xml-err.txt"; then
        fail_case "SVG не разбирается как XML: $(tr -d '\r' < "$SANDBOX/xml-err.txt" | tail -1)"
    fi
    end_case
done

begin_case 'SVG основного набора разбирается как XML'
render light "$FX_MS" "$FX_IS"
if ! printf '%s' "$OUT" | python3 -c 'import sys, xml.dom.minidom; xml.dom.minidom.parse(sys.stdin.buffer)' 2>/dev/null; then
    fail_case 'SVG не разбирается как XML'
fi
end_case

LONG_TITLE='Этап 3. Очень длинное название этапа, которое никак не помещается в колонку подписи'
FX_MS_LONG="$SANDBOX/milestones-long.json"
J -n --arg t "$LONG_TITLE" --arg s6 "$STAGE6_TITLE" \
    '[{ number: 1, title: $t, state: "open" }, { number: 2, title: $s6, state: "open" }]' > "$FX_MS_LONG"

begin_case 'длинный заголовок обрезается многоточием, 58 символов — целиком'
render light "$FX_MS_LONG" "$SANDBOX/issues-empty-array.json"
expect_status 0
long_label="$(labels | grep -F 'Этап 3.' || true)"
expected_long="$(J -rn --arg t "$LONG_TITLE" '$t[0:59] + "…"')"
[ "$long_label" = "$expected_long" ] || fail_case "обрезка: «$long_label», ожидалось «$expected_long»"
len="$(printf '%s' "$long_label" | J -Rr 'length')"
[ "$len" = 60 ] || fail_case "длина подписи $len, ожидалось 60"
len6="$(printf '%s' "$STAGE6_TITLE" | J -Rr 'length')"
[ "$len6" = 58 ] || fail_case "в фикстуре заголовок этапа 6 длиной $len6, а не 58"
expect_out "$STAGE6_TITLE</text>"
end_case

# ==================================================================
# Страницы `gh api --paginate`: несколько массивов подряд.
# ==================================================================
begin_case 'страницы gh api склеиваются в обоих файлах'
J -c '[.[] | select(.title | test("^Этап [0-3]\\."))]' "$FX_MS" > "$SANDBOX/ms-pages.json"
J -c '[.[] | select(.title | test("^Этап [0-3]\\.") | not)]' "$FX_MS" >> "$SANDBOX/ms-pages.json"
# Задачи этапа 6 (майлстоун 3) разнесены по двум страницам.
J -c '.[0:250]' "$FX_IS" > "$SANDBOX/is-pages.json"
J -c '.[250:]' "$FX_IS" >> "$SANDBOX/is-pages.json"
pages="$(grep -c '' "$SANDBOX/ms-pages.json")"
[ "$pages" -eq 2 ] || fail_case "фикстура майлстоунов из $pages страниц, а не из 2"
render light "$SANDBOX/ms-pages.json" "$SANDBOX/is-pages.json"
expect_status 0
[ "$(labels)" = "$EXPECTED_LABELS" ] || fail_case "подписи: $(labels | tr '\n' '|')"
[ "$(percents)" = "$EXPECTED_PCTS" ] || fail_case "проценты: $(percents | tr '\n' '|')"
end_case

# ==================================================================
# Отказы: без этапов, негодный вход, неизвестная тема.
# ==================================================================
begin_case 'майлстоунов нет — код 1, пустой stdout, причина в stderr'
render light "$SANDBOX/issues-empty-array.json" "$FX_IS"
expect_status 1
expect_out_empty
expect_err_not_empty
end_case

begin_case 'майлстоуны без «Этап N.» — код 1, пустой stdout, причина в stderr'
J -n '[{ number: 1, title: "Бэклог", state: "open" }, { number: 2, title: "Этапы позже", state: "open" }]' \
    > "$SANDBOX/ms-no-stages.json"
render light "$SANDBOX/ms-no-stages.json" "$FX_IS"
expect_status 1
expect_out_empty
expect_err_not_empty
end_case

printf '[{ "number": 1, "title": "Этап 0. x"' > "$SANDBOX/broken.json"
: > "$SANDBOX/nothing.json"
printf '{ "message": "Not Found" }\n' > "$SANDBOX/not-array.json"

for bad in broken nothing not-array; do
    begin_case "негодные майлстоуны ($bad) — отказ"
    render light "$SANDBOX/$bad.json" "$FX_IS"
    expect_status_not_zero
    expect_out_empty
    end_case

    begin_case "негодные задачи ($bad) — отказ"
    render light "$FX_MS" "$SANDBOX/$bad.json"
    expect_status_not_zero
    expect_out_empty
    end_case
done

begin_case 'файла данных нет — отказ'
render light "$SANDBOX/нет-такого.json" "$FX_IS"
expect_status_not_zero
expect_out_empty
end_case

for args in 'sepia' '' 'LIGHT'; do
    begin_case "неизвестная тема «$args» — код 2, пустой stdout"
    render "$args" "$FX_MS" "$FX_IS"
    expect_status 2
    expect_out_empty
    end_case
done

begin_case 'render без файлов данных — код 2'
render light
expect_status 2
expect_out_empty
end_case

begin_case 'неизвестная подкоманда — код 2'
"$BASH" "$TARGET" draw > "$SANDBOX/out.txt" 2> "$SANDBOX/err.txt"
STATUS=$?
OUT="$(< "$SANDBOX/out.txt")"
ERR="$(< "$SANDBOX/err.txt")"
expect_status 2
end_case

# ==================================================================
# Фон прозрачный, палитры у тем свои.
# ==================================================================
for theme in light dark; do
    begin_case "фон прозрачный, цвет подписи темы ($theme)"
    render "$theme" "$FX_MS" "$FX_IS"
    root="$(printf '%s\n' "$OUT" | grep -m1 -F '<svg' || true)"
    [ -n "$root" ] || fail_case 'нет корневого <svg>'
    case "$root" in
        *background* | *' fill='* | *'style='*) fail_case "у корневого svg задан фон: $root" ;;
    esac
    svg_w="$(printf '%s\n' "$root" | sed -n 's/.* width="\([0-9]*\)".*/\1/p')"
    [ -n "$svg_w" ] || fail_case 'у корневого svg нет ширины'
    if printf '%s\n' "$OUT" | grep -oE '<rect [^>]*>' | grep -qE "width=\"(100%|$svg_w)\""; then
        fail_case 'есть прямоугольник на всю ширину картинки — фон-карточка'
    fi
    case "$theme" in
        light) expected='#1f2328' ;;
        dark) expected='#f0f6fc' ;;
    esac
    n_labels="$(stage_lines | grep -c '')"
    n_colored="$(stage_lines | grep -cF "<text class=\"label\" fill=\"$expected\"" || true)"
    [ "$n_labels" -gt 0 ] && [ "$n_labels" = "$n_colored" ] ||
        fail_case "подписей $n_labels, цвета $expected — $n_colored"
    end_case
done

# ==================================================================
# Публикация: bare-репозиторий песочницы вместо origin.
# ==================================================================
GIT_HOME="$SANDBOX/home"
mkdir -p "$GIT_HOME"
ORIGIN="$SANDBOX/origin.git"
SEED="$SANDBOX/seed"
CLONE="$SANDBOX/clone"

# Git как на чистом runner: ни глобального, ни системного конфига, пустой
# HOME. GITHUB_EVENT_NAME снимается: в CI сценарии идут на событии
# pull_request, и сценарий публикации отказал бы во всех вызовах.
g() {
    env -u GITHUB_EVENT_NAME GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
        HOME="$GIT_HOME" git "$@"
}

g init -q --bare -b main "$ORIGIN"
g init -q -b main "$SEED"
printf 'дерево main\n' > "$SEED/main-only.txt"
g -C "$SEED" add main-only.txt
g -C "$SEED" -c user.name=seed -c user.email=seed@example.invalid commit -q -m 'chore: начало'
g -C "$SEED" push -q "$ORIGIN" HEAD:refs/heads/main
g clone -q "$ORIGIN" "$CLONE" 2>/dev/null
MAIN_TIP="$(g -C "$ORIGIN" rev-parse refs/heads/main)"

# Предохранитель: origin клона обязан быть bare-репозиторием песочницы.
# Зовётся перед каждым вызовом publish.
SANDBOX_ORIGIN_REAL="$(cd "$ORIGIN" && pwd -P)"
assert_sandbox_origin() {
    local url real
    url="$(g -C "$CLONE" remote get-url origin 2>/dev/null || true)"
    real="$(cd "$url" 2>/dev/null && pwd -P || true)"
    if [ -z "$real" ] || [ "$real" != "$SANDBOX_ORIGIN_REAL" ]; then
        printf 'origin клона песочницы — «%s», а не %s: публикация не запускается.\n' \
            "$url" "$ORIGIN" >&2
        exit 2
    fi
}

LIGHT="$SANDBOX/files/progress-light.svg"
DARK="$SANDBOX/files/progress-dark.svg"
mkdir -p "$SANDBOX/files"
printf '<svg>светлая 1</svg>\n' > "$LIGHT"
printf '<svg>тёмная 1</svg>\n' > "$DARK"

# $1 — значение GITHUB_EVENT_NAME или пусто, дальше — аргументы publish.
publish_as() {
    local event="$1"
    shift
    assert_sandbox_origin
    (
        cd "$CLONE" || exit 99
        if [ -n "$event" ]; then
            env GITHUB_EVENT_NAME="$event" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
                HOME="$GIT_HOME" "$BASH" "$TARGET" publish "$@"
        else
            env -u GITHUB_EVENT_NAME GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
                HOME="$GIT_HOME" "$BASH" "$TARGET" publish "$@"
        fi
    ) > "$SANDBOX/out.txt" 2> "$SANDBOX/err.txt"
    STATUS=$?
    OUT="$(tr -d '\r' < "$SANDBOX/out.txt")"
    ERR="$(< "$SANDBOX/err.txt")"
}
publish() { publish_as '' "$@"; }

refs_snapshot() { g -C "$ORIGIN" for-each-ref --format='%(refname) %(objectname)'; }
status_tip() { g -C "$ORIGIN" rev-parse --verify --quiet refs/heads/status || true; }
status_count() { g -C "$ORIGIN" rev-list --count refs/heads/status 2>/dev/null || echo 0; }

expect_refs_unchanged() {
    if [ "$(refs_snapshot)" != "$1" ]; then
        fail_case "refs bare-репозитория изменились: $(refs_snapshot | tr '\n' '|')"
    fi
}

expect_main_unchanged() {
    [ "$(g -C "$ORIGIN" rev-parse refs/heads/main)" = "$MAIN_TIP" ] || fail_case 'ref main изменился'
}

expect_bot_author() {
    local who
    who="$(g -C "$ORIGIN" log -1 --format='%an <%ae>|%cn <%ce>' refs/heads/status)"
    [ "$who" = 'github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>|github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>' ] ||
        fail_case "автор и коммиттер: $who"
}

expect_status_file() {
    # $1 — имя в ветке status, $2 — файл, с которым содержимое совпадает.
    g -C "$ORIGIN" show "refs/heads/status:$1" > "$SANDBOX/shown" 2>/dev/null ||
        { fail_case "в status нет $1"; return; }
    cmp -s "$SANDBOX/shown" "$2" || fail_case "$1 в status не совпадает с $2"
}

expect_first_line_git_version() {
    case "$(printf '%s\n' "$OUT" | head -1)" in
        'git version '*) ;;
        *) fail_case "первая строка вывода не «git version …»: $(printf '%s\n' "$OUT" | head -1)" ;;
    esac
}

begin_case 'publish --dry-run без ветки status ничего не пишет'
before="$(refs_snapshot)"
publish "$LIGHT" "$DARK" --dry-run
expect_status 0
expect_first_line_git_version
expect_refs_unchanged "$before"
[ -z "$(status_tip)" ] || fail_case 'ветка status появилась'
end_case

begin_case 'publish на pull_request без --dry-run отказывает (ветки нет)'
before="$(refs_snapshot)"
publish_as pull_request "$LIGHT" "$DARK"
expect_status 1
expect_err_not_empty
expect_out_empty
expect_refs_unchanged "$before"
end_case

begin_case 'publish создаёт ветку status из двух файлов'
publish "$LIGHT" "$DARK"
expect_status 0
expect_first_line_git_version
files="$(g -C "$ORIGIN" ls-tree -r --name-only refs/heads/status 2>/dev/null | tr '\n' ' ')"
[ "$files" = 'progress-dark.svg progress-light.svg ' ] || fail_case "файлы в status: «$files»"
parents="$(g -C "$ORIGIN" rev-list --parents -n1 refs/heads/status 2>/dev/null | wc -w)"
[ "$parents" -eq 1 ] || fail_case 'у первого коммита status есть родитель — не orphan'
[ "$(status_count)" = 1 ] || fail_case "коммитов в status $(status_count), ожидался 1"
expect_status_file progress-light.svg "$LIGHT"
expect_status_file progress-dark.svg "$DARK"
expect_main_unchanged
expect_bot_author
# Временный worktree и временная ветка за собой не оставлены.
[ "$(g -C "$CLONE" worktree list | grep -c '')" -eq 1 ] || fail_case 'в клоне остался worktree'
[ "$(g -C "$CLONE" branch --list | grep -c '')" -eq 1 ] || fail_case "в клоне остались ветки: $(g -C "$CLONE" branch --list | tr '\n' ' ')"
end_case
FIRST_TIP="$(status_tip)"

begin_case 'publish --dry-run при существующей status ничего не пишет'
printf '<svg>светлая 2</svg>\n' > "$LIGHT"
before="$(refs_snapshot)"
publish "$LIGHT" "$DARK" --dry-run
expect_status 0
expect_first_line_git_version
expect_refs_unchanged "$before"
end_case

begin_case 'publish на pull_request без --dry-run отказывает (ветка есть)'
before="$(refs_snapshot)"
publish_as pull_request "$LIGHT" "$DARK"
expect_status 1
expect_err_not_empty
expect_out_empty
expect_refs_unchanged "$before"
end_case

begin_case 'publish коммитит изменённую картинку поверх истории'
publish "$LIGHT" "$DARK"
expect_status 0
[ "$(status_count)" = 2 ] || fail_case "коммитов в status $(status_count), ожидалось 2"
parent="$(g -C "$ORIGIN" rev-parse --verify --quiet 'refs/heads/status^1' || true)"
[ "$parent" = "$FIRST_TIP" ] || fail_case 'родитель нового коммита — не прежняя вершина status'
expect_status_file progress-light.svg "$LIGHT"
expect_status_file progress-dark.svg "$DARK"
changed="$(g -C "$ORIGIN" diff --name-only 'refs/heads/status^1' refs/heads/status | tr '\n' ' ')"
[ "$changed" = 'progress-light.svg ' ] || fail_case "изменены в коммите: «$changed»"
expect_main_unchanged
expect_bot_author
end_case
SECOND_TIP="$(status_tip)"

begin_case 'publish без изменений не коммитит'
publish "$LIGHT" "$DARK"
expect_status 0
expect_out 'картинка не изменилась'
[ "$(status_count)" = 2 ] || fail_case "коммитов в status $(status_count), ожидалось 2"
[ "$(status_tip)" = "$SECOND_TIP" ] || fail_case 'вершина status сдвинулась'
expect_main_unchanged
end_case

# Проверочный прогон PR, не меняющий картинку, всё равно проверяет пуш:
# иначе авторизация на PR проверялась бы только при изменившемся проценте.
begin_case 'publish --dry-run без изменений: код 0, пуш проверен, ничего не записано'
before="$(refs_snapshot)"
publish "$LIGHT" "$DARK" --dry-run
expect_status 0
expect_first_line_git_version
expect_out 'картинка не изменилась'
printf '%s\n' "$ERR" | grep -qiE 'up.to.date|Everything' ||
    fail_case 'в выводе нет ответа git push --dry-run'
expect_refs_unchanged "$before"
end_case

begin_case 'publish без файлов и с отсутствующим файлом — отказ без записи'
before="$(refs_snapshot)"
publish --dry-run
expect_status 2
publish "$SANDBOX/files/нет-такого.svg"
expect_status_not_zero
expect_refs_unchanged "$before"
end_case

# ==================================================================
# Форма workflow.
# ==================================================================
begin_case 'workflow: права, закрепление, без данных события'
if [ ! -f "$WORKFLOW" ]; then
    fail_case "нет $WORKFLOW"
else
    WF="$(tr -d '\r' < "$WORKFLOW")"
    # Ровно один блок permissions, и в нём ровно contents: write.
    n_perm="$(printf '%s\n' "$WF" | grep -cE '^[[:space:]]*permissions:' || true)"
    [ "$n_perm" = 1 ] || fail_case "блоков permissions: $n_perm, ожидался 1"
    perm_body="$(printf '%s\n' "$WF" | awk '
        /^permissions:/ { inside = 1; next }
        inside && /^[^[:space:]#]/ { inside = 0 }
        inside && /[^[:space:]]/ && !/^[[:space:]]*#/ { sub(/^[[:space:]]+/, ""); print }')"
    [ "$perm_body" = 'contents: write' ] || fail_case "в permissions: «$(printf '%s' "$perm_body" | tr '\n' '|')»"
    printf '%s\n' "$WF" | grep -qF 'secrets.' && fail_case 'в workflow есть secrets.'
    # github.event. — только в строках условий `if:`.
    bad_event="$(printf '%s\n' "$WF" | grep -F 'github.event.' | grep -vE '^[[:space:]]*if:' || true)"
    [ -z "$bad_event" ] || fail_case "github.event. вне if: $bad_event"
    # Каждый uses — actions/checkout@v7.
    uses="$(printf '%s\n' "$WF" | grep -E '^[[:space:]]*(-[[:space:]]+)?uses:' | sed -E 's/^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*//' | sort -u)"
    [ "$uses" = 'actions/checkout@v7' ] || fail_case "uses: «$(printf '%s' "$uses" | tr '\n' '|')»"
    for trig in pull_request schedule workflow_dispatch issues milestone push; do
        printf '%s\n' "$WF" | grep -qE "^  $trig:" || fail_case "нет триггера $trig"
    done
    printf '%s\n' "$WF" | grep -qE '^concurrency:' || fail_case 'нет concurrency'
    printf '%s\n' "$WF" | grep -qE '^  cancel-in-progress: false$' || fail_case 'cancel-in-progress не false'
    group="$(printf '%s\n' "$WF" | sed -n 's/^  group:[[:space:]]*//p')"
    case "$group" in
        *"pull_request"*) ;;
        *) fail_case "группа concurrency не различает pull_request: «$group»" ;;
    esac
    printf '%s\n' "$WF" | grep -qE 'milestones\?[^ ]*state=all' || fail_case 'запрос майлстоунов без state=all'
    printf '%s\n' "$WF" | grep -qE 'issues\?[^ ]*state=all' || fail_case 'запрос задач без state=all'
    printf '%s\n' "$WF" | grep -qF 'status-progress.sh render light' || fail_case 'нет render light'
    printf '%s\n' "$WF" | grep -qF 'status-progress.sh render dark' || fail_case 'нет render dark'
    # Шаги publish: какое условие у шага и есть ли --dry-run. Публикация без
    # --dry-run допустима только в шаге с условием «не pull_request», вызов
    # на pull_request — только с --dry-run.
    steps="$(printf '%s\n' "$WF" | awk '
        /^      - / { cond = "" }
        /^        if:/ { cond = $0 }
        /status-progress\.sh publish/ {
            mode = ($0 ~ /--dry-run/) ? "dry" : "write"
            files = ($0 ~ /progress-light\.svg/ && $0 ~ /progress-dark\.svg/) ? "both" : "partial"
            if (cond ~ /!= .pull_request./) c = "not-pr"
            else if (cond ~ /== .pull_request./) c = "pr"
            else c = "any"
            print c, mode, files
        }' | sort)"
    [ "$steps" = $'not-pr write both\npr dry both' ] ||
        fail_case "шаги publish (условие режим файлы): «$(printf '%s' "$steps" | tr '\n' '|')»"
fi
end_case

# ==================================================================
# README: picture со светлой и тёмной картинкой из ветки status.
# ==================================================================
RAW='https://raw.githubusercontent.com/k-kuzmin/domovoy/status'
begin_case 'README: picture со светлой и тёмной картинкой'
RM="$(tr -d '\r' < "$README")"
section="$(printf '%s\n' "$RM" | awk '/^## Статус$/ { inside = 1; next } inside && /^## / { exit } inside')"
[ -n "$section" ] || fail_case 'в README нет раздела «## Статус»'
n_link="$(printf '%s\n' "$section" | grep -cF '<a href="https://github.com/k-kuzmin/domovoy/milestones">' || true)"
[ "$n_link" = 1 ] || fail_case "ссылок на milestones обёрткой картинки: $n_link, ожидалась 1"
n_pic="$(printf '%s\n' "$section" | grep -cF '<picture>' || true)"
[ "$n_pic" = 1 ] || fail_case "элементов picture: $n_pic, ожидался 1"
# Имена файлов — те, что пишет workflow: светлая из render light, тёмная из render dark.
light_name="progress-light.svg"
dark_name="progress-dark.svg"
if [ -f "$WORKFLOW" ]; then
    WF="$(tr -d '\r' < "$WORKFLOW")"
    light_name="$(printf '%s\n' "$WF" | sed -n 's/.*render light .*[/"]\(progress-[a-z]*\.svg\)".*/\1/p' | head -1)"
    dark_name="$(printf '%s\n' "$WF" | sed -n 's/.*render dark .*[/"]\(progress-[a-z]*\.svg\)".*/\1/p' | head -1)"
    [ -n "$light_name" ] && [ -n "$dark_name" ] || fail_case 'в workflow не нашлись имена файлов render'
fi
printf '%s\n' "$section" | grep -qF "<source media=\"(prefers-color-scheme: dark)\" srcset=\"$RAW/$dark_name\">" ||
    fail_case "нет <source> тёмной темы с $RAW/$dark_name"
printf '%s\n' "$section" | grep -qE "<img [^>]*src=\"$RAW/$light_name\"" ||
    fail_case "нет <img> со светлой $RAW/$light_name"
in_section="$(printf '%s\n' "$section" | grep -cF 'status/progress-' || true)"
in_readme="$(printf '%s\n' "$RM" | grep -cF 'status/progress-' || true)"
[ "$in_section" = "$in_readme" ] || fail_case 'ссылки на картинки есть вне раздела «Статус»'
printf '%s\n' "$RM" | grep -qF 'Этап 0 из 6' && fail_case 'в README остался абзац «Этап 0 из 6»'
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

printf 'Картинка прогресса рисуется и публикуется как задумано.\n'
exit 0
