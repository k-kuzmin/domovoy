#!/usr/bin/env bash
#
# Домовой — картинка прогресса этапов для раздела «Статус» README (#140).
#
# ЗАЧЕМ
#
# Ручной абзац «Этап N из 6» устаревает в тот же день, когда закрывается
# задача, а бейджи shields.io по одному на этап показывают только число и
# через camo грузятся через раз (#139). Здесь картинка рисуется из самих
# майлстоунов и задач и публикуется в отдельную ветку status — без коммита в
# main. Зовёт сценарий workflow `.github/workflows/status-progress.yml`.
#
# ПОДКОМАНДЫ
#
#   bash scripts/status-progress.sh render <light|dark> <майлстоуны.json> <задачи.json>
#
#     Печатает в stdout SVG выбранной темы. Файлы данных — в том виде, как их
#     печатает `gh api --paginate`: один или несколько JSON-массивов подряд.
#     Этап — майлстоун с заголовком «Этап N. …», в любом состоянии: закрытый
#     этап остаётся на картинке со своим процентом. Процент — по состоянию
#     самих задач, а не по счётчикам майлстоуна (те — кеш и могут отставать от
#     события `issues: closed`); элементы с полем `pull_request` не считаются.
#     Номера этапов обязаны идти подряд от 0 без повторов, а заголовок,
#     начатый как этап («Этап 3 — …»), — быть в форме «Этап N.»; иначе
#     отказ: пропавший этап виден красным прогоном, а не картинкой без строки.
#     Пропажу последнего этапа целиком эта проверка не видит.
#     Округление вниз: 100 % — только когда закрыто всё, 0 задач — 0 %.
#     Из задач читаются только `state`, `milestone.number` и наличие
#     `pull_request`: заголовки и тела задач пишет кто угодно, на картинку они
#     не попадают. Заголовки майлстоунов экранируются под XML.
#
#   bash scripts/status-progress.sh publish <файл>... [--dry-run]
#
#     Кладёт файлы (по имени, без каталога) в ветку status репозитория
#     origin текущего каталога одним коммитом. Ветки нет — создаётся orphan
#     из одних этих файлов, дерево main туда не попадает. Не изменился ни
#     один файл — «картинка не изменилась», без коммита. Пуш без force:
#     история status сохраняется, отбитый пуш — красный прогон, а не
#     перезапись. Identity коммита задаётся здесь, глобальный конфиг не
#     нужен. С `--dry-run` всё то же, но пуш — `git push --dry-run`:
#     проверяет авторизацию и fast-forward, ничего не пишет.
#
#     При GITHUB_EVENT_NAME=pull_request без `--dry-run` — отказ до любого
#     вызова git: проверочный прогон PR получает токен с `contents: write`,
#     и эта проверка — вторая защита от случайной записи из него, рядом с
#     условием шага в workflow. Границей против изменённого кода PR она не
#     служит: сценарий и workflow берутся из той же ветки PR.
#
# Код возврата: 0 — готово, 1 — отказ по данным или git (причина в stderr),
# 2 — негодные аргументы. При отказе stdout `render` пуст: пустая или
# частичная картинка не публикуется.
#
set -uo pipefail

die() { printf 'status-progress.sh: %s\n' "$1" >&2; exit "${2:-1}"; }

usage() {
    printf 'Использование:\n' >&2
    printf '  bash scripts/status-progress.sh render <light|dark> <майлстоуны.json> <задачи.json>\n' >&2
    printf '  bash scripts/status-progress.sh publish <файл>... [--dry-run]\n' >&2
    exit 2
}

# jq на Windows печатает CRLF; на runner это пустая операция.
J() { jq "$@" | tr -d '\r'; }

# ------------------------------------------------------------------
# render
# ------------------------------------------------------------------

# Данные читаются `--slurpfile`, а не через аргумент: ответ задач с телами —
# сотни килобайт, больше предела длины одного аргумента.
#
# Вёрстка общая для обеих тем, различается только палитра. Ширина
# фиксирована: колонка подписи под 60 символов, полоса, процент.
# Контраст палитр посчитан в плане задачи (docs/tasks/140.plan.json).
# shellcheck disable=SC2016 # программа jq: $-переменные — её, а не оболочки
SVG_PROGRAM='
# Склейка страниц `gh api --paginate`: каждое JSON-значение верхнего уровня
# обязано быть массивом. Ноль значений — не пустой ответ, а отсутствие ответа:
# честная пустая страница от GitHub — это `[]`.
def pages($what):
  if length == 0 then error("\($what): пустой вход, ни одного JSON-значения")
  elif all(.[]; type == "array") then add
  else error("\($what): не массив, ожидались страницы gh api --paginate") end;
def stage_no: capture("^Этап (?<n>[0-9]+)\\.").n | tonumber;
def caption: if length > 60 then .[0:59] + "…" else . end;

($ms_pages | pages("майлстоуны")) as $ms
| ($is_pages | pages("задачи")) as $is
| ($ms
  | map(select(type == "object" and (.title | type) == "string"
               and (.title | test("^Этап [0-9]+\\."))))
  | map({ number, title, n: (.title | stage_no) })
  | sort_by(.n, .number)) as $stages
| if ($stages | length) == 0 then error("нет ни одного майлстоуна «Этап N.»") else . end
# Набор этапов — ровно 0..N без дыр и повторов: майлстоун, переименованный
# мимо формы «Этап N.», или дубль номера дают отказ, а не картинку на строку
# меньше или больше.
| ($ms
  | map(select(type == "object" and (.title | type) == "string") | .title
        | select(test("^Этап\\s*[0-9]") and (test("^Этап [0-9]+\\.") | not)))) as $malformed
| if ($malformed | length) > 0
  then error("заголовок начат как этап, но не в форме «Этап N.»: \($malformed | join("; "))") else . end
| ($stages | map(.n)) as $ns
| ($ns | group_by(.) | map(select(length > 1) | .[0] | tostring)) as $dups
| if ($dups | length) > 0 then error("этап \($dups | join(", ")) повторяется") else . end
| ([range(0; ($ns | max) + 1)] - $ns | map(tostring)) as $missing
| if ($missing | length) > 0
  then error("нет этапа \($missing | join(", ")): номера этапов идут подряд от 0") else . end
| ($is
  | map(select(type == "object" and .pull_request == null
               and (.milestone | type) == "object"))) as $issues
| ($stages | length) as $rows
| 26 as $row_h | 13 as $font
| 470 as $bar_x | 200 as $bar_w | 10 as $bar_h | 740 as $width
| ($rows * $row_h + 4) as $height
| [
    "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\($width)\" height=\"\($height)\" viewBox=\"0 0 \($width) \($height)\" role=\"img\" aria-label=\"Прогресс этапов\" font-family=\"-apple-system,BlinkMacSystemFont,Segoe UI,Noto Sans,Helvetica,Arial,sans-serif\" font-size=\"\($font)\">",
    "<title>Прогресс этапов</title>",
    ($stages | to_entries[] | .key as $i | .value as $s
      | [ $issues[] | select(.milestone.number == $s.number) ] as $own
      | ($own | length) as $total
      | ([ $own[] | select(.state == "closed") ] | length) as $closed
      | (if $total == 0 then 0 else ($closed * 100 / $total | floor) end) as $pct
      | ($i * $row_h + 4) as $top
      | ($top + 17) as $base
      | "<g class=\"stage\">"
        + "<text class=\"label\" fill=\"\($pal.label)\" x=\"0\" y=\"\($base)\">\($s.title | caption | @html)</text>"
        + "<rect class=\"track\" fill=\"\($pal.track)\" x=\"\($bar_x)\" y=\"\($top + 8)\" width=\"\($bar_w)\" height=\"\($bar_h)\" rx=\"5\"/>"
        + "<rect class=\"fill\" fill=\"\($pal.fill)\" x=\"\($bar_x)\" y=\"\($top + 8)\" width=\"\($bar_w * $pct / 100 | floor)\" height=\"\($bar_h)\" rx=\"5\"/>"
        + "<text class=\"pct\" fill=\"\($pal.pct)\" x=\"\($width)\" y=\"\($base)\" text-anchor=\"end\">\($pct) %</text>"
        + "</g>"),
    "</svg>"
  ]
| .[]
'

cmd_render() {
    [ "$#" -eq 3 ] || usage
    local theme="$1" ms_file="$2" is_file="$3" palette
    case "$theme" in
        light) palette='{"label":"#1f2328","pct":"#59636e","fill":"#1f883d","track":"#d1d9e0"}' ;;
        dark) palette='{"label":"#f0f6fc","pct":"#9198a1","fill":"#3fb950","track":"#3d444d"}' ;;
        *) printf 'status-progress.sh: неизвестная тема «%s», ожидалась light или dark\n' "$theme" >&2; usage ;;
    esac
    command -v jq >/dev/null 2>&1 || die 'не найден jq'
    [ -f "$ms_file" ] || die "нет файла майлстоунов: $ms_file"
    [ -f "$is_file" ] || die "нет файла задач: $is_file"

    local svg
    # Картинка собирается целиком и печатается только при успехе: отказ
    # посередине не оставляет в stdout половину SVG. Причину печатает jq.
    svg="$(J -nr --slurpfile ms_pages "$ms_file" --slurpfile is_pages "$is_file" \
        --argjson pal "$palette" "$SVG_PROGRAM")" ||
        die 'картинка не нарисована: набор этапов или данные негодны'
    printf '%s\n' "$svg"
}

# ------------------------------------------------------------------
# publish
# ------------------------------------------------------------------
BOT_NAME='github-actions[bot]'
BOT_EMAIL='41898282+github-actions[bot]@users.noreply.github.com'

WT=''
WT_PARENT=''
TMP_BRANCH=''
cleanup() {
    if [ -n "$WT" ]; then
        git worktree remove --force "$WT" >/dev/null 2>&1 || rm -rf "$WT"
        git worktree prune >/dev/null 2>&1
    fi
    if [ -n "$TMP_BRANCH" ]; then
        git branch -D "$TMP_BRANCH" >/dev/null 2>&1
    fi
    if [ -n "${WT_PARENT:-}" ]; then
        rm -rf "$WT_PARENT"
    fi
}

cmd_publish() {
    local dry_run=0 files=() a
    for a in "$@"; do
        case "$a" in
            --dry-run) dry_run=1 ;;
            -*) printf 'status-progress.sh: неизвестный ключ %s\n' "$a" >&2; usage ;;
            *) files+=("$a") ;;
        esac
    done
    [ "${#files[@]}" -gt 0 ] || usage

    # Отказ записи из PR — до любого вызова git.
    if [ "${GITHUB_EVENT_NAME:-}" = pull_request ] && [ "$dry_run" -eq 0 ]; then
        die 'на событии pull_request публикация только с --dry-run: запись в status из непросмерженного кода закрыта'
    fi

    local f name names=()
    for f in "${files[@]}"; do
        [ -f "$f" ] || die "нет файла: $f"
        name="$(basename -- "$f")"
        names+=("$name")
    done

    git --version || die 'не найден git'
    git rev-parse --git-dir >/dev/null 2>&1 || die 'текущий каталог — не репозиторий git'

    WT_PARENT="$(mktemp -d)" || die 'не создан временный каталог'
    WT="$WT_PARENT/status"
    trap cleanup EXIT

    local rc
    git ls-remote --exit-code origin refs/heads/status >/dev/null
    rc=$?
    if [ "$rc" -eq 0 ]; then
        git fetch -q --depth=1 origin refs/heads/status || die 'ветка status не получена'
        git worktree add -q --detach "$WT" FETCH_HEAD || die 'не создан worktree ветки status'
    elif [ "$rc" -eq 2 ]; then
        # Временная ветка вместо `status`: локальная ветка с таким именем
        # может уже быть в клоне. Пушится всё равно в refs/heads/status.
        TMP_BRANCH="status-progress-tmp-$$"
        git worktree add -q --orphan -b "$TMP_BRANCH" "$WT" || die 'не создан orphan-worktree ветки status'
        printf 'ветки status нет — будет создана\n'
    else
        die "origin недоступен: git ls-remote вернул $rc"
    fi

    local i
    for i in "${!files[@]}"; do
        cp -- "${files[$i]}" "$WT/${names[$i]}" || die "не скопирован ${files[$i]}"
    done
    git -C "$WT" add -- "${names[@]}" || die 'git add не прошёл'

    local push_args=(push origin HEAD:refs/heads/status)
    [ "$dry_run" -eq 1 ] && push_args=(push --dry-run origin HEAD:refs/heads/status)

    if git -C "$WT" diff --cached --quiet; then
        printf 'картинка не изменилась — коммита нет\n'
        if [ "$dry_run" -eq 1 ]; then
            # Проверочный прогон всё равно проверяет авторизацию пуша.
            git -C "$WT" "${push_args[@]}" || die 'git push --dry-run не прошёл'
        fi
        return 0
    fi

    git -C "$WT" -c user.name="$BOT_NAME" -c user.email="$BOT_EMAIL" \
        commit -q -m 'chore: картинка прогресса этапов' || die 'коммит не создан'
    git -C "$WT" "${push_args[@]}" || die 'пуш в status не прошёл'
    if [ "$dry_run" -eq 1 ]; then
        printf 'dry-run: пуш в status проверен, ничего не записано\n'
    else
        printf 'опубликовано в status: %s\n' "$(git -C "$WT" rev-parse --short HEAD)"
    fi
}

case "${1:-}" in
    render) shift; cmd_render "$@" ;;
    publish) shift; cmd_publish "$@" ;;
    *) usage ;;
esac
