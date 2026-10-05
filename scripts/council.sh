#!/usr/bin/env bash
#
# Домовой — детерминированная сводка совета по вердиктам советников.
#
# Оркестратор читает эту сводку, а не составляет её: фильтр замечаний и код
# выхода не зависят от того, кто и как пересказывает вердикты. Схема вердикта
# и смысл ролей — определения .claude/agents/advisor-*.md; когда собирается
# совет и что получает на вход — docs/rules/README.md, раздел «Совет».
#
#   bash scripts/council.sh <plan|diff> <артефакт> <каталог-вердиктов> [прошлый-хеш]
#
# Артефакт: в режиме plan — путь к docs/tasks/<N>.plan.json, в режиме diff —
# диапазон git (origin/main...HEAD). Вердикты — *.json в каталоге, по одному
# на роль. Пути в evidence и norm считаются от корня репозитория.
#
# Отбрасывается замечание: без evidence (на любом уровне); с evidence вне
# артефакта — на диффе файл не из изменённых или строка не в новой стороне
# хунка, на плане pointer не резолвится или file не из files[].path; с norm,
# у которой file не в git ls-files или вне .claude/CLAUDE.md, docs/decisions/,
# docs/rules/, или quote не находится `grep -F --` (пустая и многострочная
# цитата — тоже отброс: grep -F читает перевод строки как несколько шаблонов);
# blocker стража без norm.
#
# Коды: 0 — блокеров нет; 1 — принят blocker или отброшен blocker/major
# (пометка «отброшен блокер»); 2 — escalate, no_objections при непустом
# unable_to_verify, или непустой принятый набор совпал с прошлым хешем;
# 3 — ошибка запуска, в том числе брак стража (no_objections без read).
# Приоритет 3 > 2 > 1 > 0. Хеш — sha256 по отсортированным строкам
# «claim<TAB>место» принятых замечаний. Принятые major и nit код не меняют.
#
set -Eeuo pipefail
trap 'exit 3' ERR

die() { printf 'council.sh: %s\n' "$1" >&2; exit 3; }
[ $# -ge 3 ] && [ $# -le 4 ] || die 'вызов: council.sh <plan|diff> <артефакт> <каталог-вердиктов> [прошлый-хеш]'
MODE=$1 ART=$2 DIR=$3 PREV=${4:-}
command -v jq >/dev/null 2>&1 || die 'не найден jq'
case $MODE in plan|diff) ;; *) die "неизвестный режим: $MODE" ;; esac
[ -d "$DIR" ] || die "нет каталога вердиктов: $DIR"
DIR=$(cd "$DIR" && pwd)
if [ "$MODE" = plan ]; then
    [ -f "$ART" ] || die "нет плана: $ART"
    ART="$(cd "$(dirname "$ART")" && pwd)/$(basename "$ART")"
    jq -e 'type == "object"' "$ART" >/dev/null 2>&1 || die "план не разбирается как JSON-объект: $ART"
fi
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || die 'не репозиторий git'
cd "$ROOT"
J() { jq "$@" | tr -d '\r'; }   # jq на Windows отдаёт CRLF
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
G() { git -c core.quotePath=false "$@"; }
G ls-files > "$T/ls"

if [ "$MODE" = diff ]; then
    G diff --no-color --no-ext-diff --no-renames --name-only "$ART" -- > "$T/files" 2>/dev/null || die "диапазон не разбирается: $ART"
    # Хунки новой стороны: путь<TAB>первая<TAB>последняя строка.
    G diff --no-color --no-ext-diff --no-renames --src-prefix=a/ --dst-prefix=b/ -U0 "$ART" -- | awk '
        /^\+\+\+ / { f = ($0 == "+++ /dev/null") ? "" : substr($0, 7); sub(/\t$/, "", f); next }
        /^@@ / && f != "" { s = substr($3, 2); n = split(s, p, ","); c = (n > 1) ? p[2] : 1
                            if (c > 0) printf "%s\t%d\t%d\n", f, p[1], p[1] + c - 1 }' > "$T/hunks"
else
    J -r 'if (.files | type) == "array" then .files[] | objects | .path | strings else empty end' "$ART" > "$T/files"
fi

ROLES='' ESC='' BRAK=0 N=0
: > "$T/f"
for f in "$DIR"/*.json; do
    [ -e "$f" ] || die "в каталоге нет вердиктов: $DIR"
    jq -e 'type == "object" and ((.findings // []) | type) == "array"' "$f" >/dev/null 2>&1 || die "вердикт не по схеме: $f"
    role=$(J -r '.role | strings' "$f") verdict=$(J -r '.verdict | strings' "$f")
    case $role in skeptic|engineer|constitution|pragmatist) ;; *) die "неизвестная роль «$role»: $f" ;; esac
    case $verdict in no_objections|another_round|escalate) ;; *) die "неизвестный verdict «$verdict»: $f" ;; esac
    N=$((N + 1)) ROLES="$ROLES $role=$verdict"
    [ "$verdict" = escalate ] && ESC="$ESC $role: escalate;"
    if [ "$verdict" = no_objections ]; then
        [ "$(J '[(.unable_to_verify // [])[] | strings | select(length > 0)] | length' "$f")" -gt 0 ] &&
            ESC="$ESC $role: no_objections при непустом unable_to_verify;"
        if [ "$role" = constitution ] && [ "$(J '[(.read // [])[] | strings | select(length > 0)] | length' "$f")" -eq 0 ]; then BRAK=1; fi
    fi
    J -r --arg role "$role" '
        def s: if type == "string" then . else "" end;
        def c: gsub("[\t\n\r\u001f]"; " ");
        def o: if type == "object" then . else {} end;
        .findings[] | o | (.evidence | o) as $e | (.norm | o) as $n | ($n.quote | s) as $q |
        [ $role, (.severity | s), (.claim | s | c),
          (if .evidence == null then "none" elif (.evidence | type) == "object" then "ok" else "bad" end),
          ($e.file | s | c),
          ($e.line | if . == null then "" elif type == "number" and . == floor and . >= 1 then tostring else "bad" end),
          ($e.pointer | s | c),
          (if .norm == null then "none" elif (.norm | type) == "object" then "ok" else "bad" end),
          ($n.file | s | c),
          (if $q == "" then "empty" elif ($q | test("[\n\r\t]")) then "multi" else "ok" end),
          ($q | c) ] | join("\u001f")' "$f" >> "$T/f"
done

printf 'Совет: режим %s, артефакт %s, вердиктов %d:%s\n' "$MODE" "$ART" "$N" "$ROLES"
[ "$BRAK" -eq 1 ] && { printf 'брак: перезапустить стража — no_objections без read\n'; exit 3; }

check() {
    case $sev in blocker|major|nit) ;; *) R="неизвестный severity «$sev»"; return 0 ;; esac
    [ -n "$claim" ] || { R='нет claim'; return 0; }
    case $ek in none) R='нет evidence'; return 0 ;; bad) R='evidence не объект'; return 0 ;; esac
    if [ "$MODE" = diff ]; then
        [ -n "$ef" ] || { R='нет evidence.file'; return 0; }
        if ! grep -qxF -- "$ef" "$T/files"; then
            R="evidence.file вне артефакта: $ef"; [ -e "$ef" ] || R="$R (файла нет)"; return 0
        fi
        case $el in '') R='нет evidence.line'; return 0 ;; bad) R='evidence.line не целое положительное'; return 0 ;; esac
        awk -F'\t' -v f="$ef" -v l="$el" '$1 == f && l >= $2 && l <= $3 { ok = 1 } END { exit !ok }' "$T/hunks" ||
            { R="строка $ef:$el вне изменённого участка диффа"; return 0; }
        P="$ef:$el"
    elif [ -n "$ep" ]; then
        # Указатель — файлом, а не --arg: Git Bash переписал бы «/files/1» в путь Windows.
        printf '%s' "$ep" > "$T/ptr"
        J -e --rawfile p "$T/ptr" 'def r($t): if ($t | length) == 0 then true
                elif type == "array" then ($t[0] | test("^(0|[1-9][0-9]*)$")) and (($t[0] | tonumber) < length) and (.[$t[0] | tonumber] | r($t[1:]))
                elif type == "object" then has($t[0]) and (.[$t[0]] | r($t[1:])) else false end;
            ($p | startswith("/")) and r($p | split("/")[1:] | map(gsub("~1"; "/") | gsub("~0"; "~")))' "$ART" >/dev/null ||
            { R="evidence.pointer не резолвится в плане: $ep"; return 0; }
        P=$ep
    elif [ -n "$ef" ]; then
        grep -qxF -- "$ef" "$T/files" || { R="evidence.file не из files[].path плана: $ef"; return 0; }
        P=$ef
    else R='нет evidence.pointer и evidence.file'; return 0; fi
    [ "$role" = constitution ] && [ "$sev" = blocker ] && [ "$nk" = none ] && { R='у blocker стража нет norm'; return 0; }
    case $nk in none) return 0 ;; bad) R='norm не объект'; return 0 ;; esac
    case $nf in .claude/CLAUDE.md|docs/decisions/?*|docs/rules/?*) ;;
        *) R="norm.file вне .claude/CLAUDE.md, docs/decisions/**, docs/rules/**: $nf"; return 0 ;; esac
    grep -qxF -- "$nf" "$T/ls" || { R="norm.file вне git ls-files: $nf"; return 0; }
    case $qk in empty) R='пустая norm.quote'; return 0 ;; multi) R='norm.quote в несколько строк или с табуляцией'; return 0 ;; esac
    grep -qF -- "$q" "$nf" || { R="norm.quote не найдена в $nf"; return 0; }
}

ACC=0 ACC_B=0 DROP_B=0
: > "$T/acc"; : > "$T/drop"; : > "$T/hash"
while IFS=$'\x1f' read -r role sev claim ek ef el ep nk nf qk q; do
    R='' P=''
    check
    if [ -z "$R" ]; then
        ACC=$((ACC + 1)); [ "$sev" = blocker ] && ACC_B=1
        printf '  - [%s] %s: %s — %s\n' "$sev" "$role" "$claim" "$P" >> "$T/acc"
        printf '%s\t%s\n' "$claim" "$P" >> "$T/hash"
    else
        mark=''; case $sev in nit) ;; *) DROP_B=1; mark=' — отброшен блокер' ;; esac
        printf '  - [%s] %s: %s — причина: %s%s\n' "$sev" "$role" "$claim" "$R" "$mark" >> "$T/drop"
    fi
done < "$T/f"

HASH=$(LC_ALL=C sort "$T/hash" | sha256sum | cut -d' ' -f1)
printf 'Принятые замечания: %d\n' "$ACC"; cat "$T/acc"
printf 'Отброшенные: %d\n' "$(($(wc -l < "$T/drop")))"; cat "$T/drop"
CODE=0 WHY=''
[ "$ACC_B" -eq 1 ] && CODE=1 WHY='принят blocker — исправление и ещё один круг'
[ "$DROP_B" -eq 1 ] && CODE=1 WHY="${WHY:+$WHY; }отброшен блокер — смотреть причину"
[ -n "$PREV" ] && [ "$ACC" -gt 0 ] && [ "$HASH" = "$PREV" ] && CODE=2 WHY="набор совпал с прошлым хешем — человек${WHY:+; $WHY}"
[ -n "$ESC" ] && CODE=2 WHY="escalate —${ESC%;} — человек${WHY:+; $WHY}"
printf 'Итог: код %d — %s\n' "$CODE" "${WHY:-блокеров нет}"
printf 'hash=%s\n' "$HASH"
exit "$CODE"
