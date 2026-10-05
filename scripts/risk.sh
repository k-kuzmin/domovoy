#!/usr/bin/env bash
#
# Домовой — уровень риска задачи: low, medium или high, и причины.
#
# Сигналы — пути и слова. Путей, слов и порога здесь нет: всё в
# scripts/risk.json. Скрипт ничего не блокирует: уровень решает маршрут
# (docs/rules/README.md), а не код возврата.
#
# КОНФИГ
#
# Читается из git show ${RISK_CONFIG_REF:-origin/main}:scripts/risk.json, а не
# из дерева: дифф не ослабляет правило, по которому его оценивают. Файла на
# этом ref нет — берётся из дерева, и это печатается причиной. Ref для
# сценариев подменяется переменной RISK_CONFIG_REF.
#
# РЕЖИМЫ
#
#   plan <план.json>    — пути из files[].path; удаление — action: delete.
#                         Строк ещё нет: слова и размер по строкам не
#                         считаются, порог размера — только по числу файлов.
#   diff <base> <head>  — дифф base...head (от точки ветвления): пути,
#                         добавленные и удалённые строки, размер. Переименование
#                         разбирается как удаление и добавление (--no-renames):
#                         иначе старый путь не виден и вынос файла из-под
#                         шаблона уровень не поднимал бы.
#
# Пути из git читаются при core.quotePath=false: иначе кириллица приходит
# восьмеричными escape-последовательностями и обходит шаблоны.
#
# Репозиторий — тот, в котором запущен скрипт (текущий каталог), а не тот, где
# лежит сам скрипт: так работают сценарии scripts/risk.test.sh.
#
# Вывод: строка level=<low|medium|high>, затем строки «reason: …».
# Код возврата: 0 — посчитано, 2 — запуск не состоялся.
#
set -euo pipefail

die() { printf 'risk.sh: %s\n' "$*" >&2; exit 2; }

MODE="${1:-}"
case "$MODE" in
    plan) [ $# -eq 2 ] || die 'использование: risk.sh plan <план.json>' ;;
    diff) [ $# -eq 3 ] || die 'использование: risk.sh diff <base> <head>' ;;
    *)    die 'использование: risk.sh plan <план.json> | risk.sh diff <base> <head>' ;;
esac
command -v jq >/dev/null 2>&1 || die 'не найден jq'
TOP="$(git rev-parse --show-toplevel 2>/dev/null)" || die 'запуск вне git-репозитория'
GIT=(git -C "$TOP" -c core.quotePath=false)

# ------------------------------------------------------------------ конфиг
REF="${RISK_CONFIG_REF:-origin/main}"
META=()
if ! CONFIG="$("${GIT[@]}" show "$REF:scripts/risk.json" 2>/dev/null)"; then
    [ -f "$TOP/scripts/risk.json" ] || die "конфиг scripts/risk.json не найден ни на $REF, ни в дереве"
    CONFIG="$(cat "$TOP/scripts/risk.json")"
    META+=("конфиг взят из дерева: на $REF файла scripts/risk.json нет")
fi
printf '%s' "$CONFIG" | jq -e '
    (.size.files | type) == "number" and (.size.lines | type) == "number"
    and ([.high.paths, .high.deleted_paths, .high.words, .high.prefixes,
          .high.words_skip_paths, .high.removed_lines.paths,
          .high.removed_lines.words, .medium.paths]
         | all(type == "array" and all(type == "string")))
    and ([.high.words[], .high.prefixes[], .high.removed_lines.words[]]
         | all(test("^[A-Za-z0-9_:-]+$")))' >/dev/null 2>&1 \
    || die "конфиг scripts/risk.json ($REF или дерево) не разбирается или неполон"
cfg() { printf '%s' "$CONFIG" | jq -r "$1" | tr -d '\r'; }
# shellcheck disable=SC2034  # массивы читаются по имени через nameref в matches
{
    mapfile -t HIGH_PATHS < <(cfg '.high.paths[]')
    mapfile -t DELETED_PATHS < <(cfg '.high.deleted_paths[]')
    mapfile -t SKIP_PATHS < <(cfg '.high.words_skip_paths[]')
    mapfile -t RL_PATHS < <(cfg '.high.removed_lines.paths[]')
    mapfile -t MEDIUM_PATHS < <(cfg '.medium.paths[]')
}
WORDS="$(cfg '.high.words | join(" ")')"
PREFIXES="$(cfg '.high.prefixes | join(" ")')"
RL_WORDS="$(cfg '.high.removed_lines.words | join(" ")')"
MAX_FILES="$(cfg '.size.files')"
MAX_LINES="$(cfg '.size.lines')"

# ------------------------------------------------------------------ счёт
# Причины сворачиваются по ключу: один шаблон или слово — одна строка с первым
# файлом и числом остальных, а не строка на каждый файл.
LEVEL=0
declare -A FIRST=() COUNT=()
KEYS=()
hit() {  # hit <0|1|2> <ключ> <файл>
    local key="$2"
    [ "$1" -gt "$LEVEL" ] && LEVEL="$1"
    if [ -z "${COUNT[$key]+x}" ]; then
        KEYS+=("$key"); FIRST[$key]="$3"; COUNT[$key]=1
    else
        COUNT[$key]=$(( COUNT[$key] + 1 ))
    fi
}
matches() {  # matches <путь> <имя массива шаблонов> → печатает шаблон
    local -n pats="$2"
    local g
    for g in "${pats[@]}"; do
        # shellcheck disable=SC2053  # шаблон намеренно без кавычек
        if [[ $1 == $g ]]; then printf '%s' "$g"; return 0; fi
    done
    return 1
}
classify_path() {  # classify_path <путь> <статус A|M|D>
    local g
    if g="$(matches "$1" HIGH_PATHS)"; then
        hit 2 "high: путь «$g»" "$1"
    elif g="$(matches "$1" MEDIUM_PATHS)"; then
        hit 1 "medium: путь «$g»" "$1"
    fi
    if [ "$2" = D ] && g="$(matches "$1" DELETED_PATHS)"; then
        hit 2 "high: удалён «$g»" "$1"
    fi
    return 0
}

NFILES=0
if [ "$MODE" = plan ]; then
    PLAN="$2"
    [ -f "$PLAN" ] || die "план не найден: $PLAN"
    jq -e '.files | type == "array"' "$PLAN" >/dev/null 2>&1 \
        || die "план $PLAN не разбирается или в нём нет files[]"
    while IFS=$'\t' read -r action path; do
        [ -n "$path" ] || continue
        NFILES=$(( NFILES + 1 ))
        if [ "$action" = delete ]; then classify_path "$path" D; else classify_path "$path" M; fi
    done < <(jq -r '.files[] | [(.action // ""), (.path // "")] | @tsv' "$PLAN" | tr -d '\r' | sort -u -t$'\t' -k2,2)
    META+=("режим plan: слова и размер по строкам не считаются, только пути и число файлов")
else
    for r in "$2" "$3"; do
        "${GIT[@]}" rev-parse --verify --quiet "$r^{commit}" >/dev/null || die "ref не разрешается: $r"
    done
    RANGE="$2...$3"
    DIFF=("${GIT[@]}" diff --no-renames --no-ext-diff --no-color --src-prefix=a/ --dst-prefix=b/ "$RANGE")
    while IFS= read -r -d '' status && IFS= read -r -d '' path; do
        NFILES=$(( NFILES + 1 ))
        classify_path "$path" "${status:0:1}"
    done < <("${DIFF[@]}" --name-status -z)
    NLINES="$("${DIFF[@]}" --numstat | awk -F'\t' '$1 != "-" { s += $1 + $2 } END { print s + 0 }')"
    if [ "$NLINES" -gt "$MAX_LINES" ]; then
        hit 1 "medium: размер выше порога: строк $NLINES > $MAX_LINES" ""
    fi
    [ "$NFILES" -eq 0 ] && META+=("дифф $RANGE пуст")
    # Слова: awk отдаёт «вид<TAB>сторона<TAB>файл<TAB>слово», фильтр путей — здесь.
    while IFS=$'\t' read -r kind side file word; do
        if [ "$kind" = rl ]; then
            [ "$side" = - ] && matches "$file" RL_PATHS >/dev/null \
                && hit 2 "high: слово «$word» в удалённой строке workflow" "$file"
        elif ! matches "$file" SKIP_PATHS >/dev/null; then
            if [ "$side" = + ]; then where='добавленной'; else where='удалённой'; fi
            hit 2 "high: слово «$word» в $where строке" "$file"
        fi
    done < <("${DIFF[@]}" --unified=0 | tr -d '\r' | awk -v W="$WORDS" -v P="$PREFIXES" -v R="$RL_WORDS" '
        BEGIN { nw = split(W, w, " "); np = split(P, p, " "); nr = split(R, r, " ")
                L = "(^|[^a-z0-9_])"; T = "([^a-z0-9_]|$)" }
        function path(s) { sub(/\t$/, "", s); return s == "/dev/null" ? "" : substr(s, 3) }
        function out(k, s, f, x) { key = k SUBSEP s SUBSEP f SUBSEP x
                if (!(key in seen)) { seen[key] = 1; print k "\t" s "\t" f "\t" x } }
        /^diff --git / { hdr = 1; old = ""; cur = ""; next }
        hdr && /^--- / { old = path(substr($0, 5)); next }
        hdr && /^\+\+\+ / { cur = path(substr($0, 5)); if (cur == "") cur = old; next }
        /^@@/ { hdr = 0; next }
        hdr || cur == "" { next }
        /^[+-]/ { side = substr($0, 1, 1); t = tolower(substr($0, 2))
            for (i = 1; i <= nw; i++) if (t ~ (L tolower(w[i]) T)) out("w", side, cur, w[i])
            for (i = 1; i <= np; i++) if (t ~ (L tolower(p[i])))   out("w", side, cur, p[i] "…")
            for (i = 1; i <= nr; i++) if (t ~ (L tolower(r[i]) T)) out("rl", side, cur, r[i]) }')
fi
if [ "$NFILES" -gt "$MAX_FILES" ]; then
    hit 1 "medium: размер выше порога: файлов $NFILES > $MAX_FILES" ""
fi

# ------------------------------------------------------------------ вывод
NAMES=(low medium high)
printf 'level=%s\n' "${NAMES[$LEVEL]}"
for m in "${META[@]+"${META[@]}"}"; do printf 'reason: %s\n' "$m"; done
for lvl in high medium; do
    for k in "${KEYS[@]+"${KEYS[@]}"}"; do
        [ "${k%%:*}" = "$lvl" ] || continue
        extra=''
        [ "${COUNT[$k]}" -gt 1 ] && extra=" (и ещё $(( COUNT[$k] - 1 )))"
        if [ -n "${FIRST[$k]}" ]; then
            printf 'reason: %s: %s%s\n' "$k" "${FIRST[$k]}" "$extra"
        else
            printf 'reason: %s\n' "$k"
        fi
    done
done
[ "${#KEYS[@]}" -eq 0 ] && printf 'reason: сигналов нет\n'
exit 0
