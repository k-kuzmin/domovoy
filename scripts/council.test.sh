#!/usr/bin/env bash
#
# Домовой — сценарии сводки совета scripts/council.sh.
#
# Сводка ценна фильтром: замечание без места в артефакте или со ссылкой на
# норму, которой нет, должно отбрасываться с причиной, а отброс блокера —
# всплывать кодом. Сценарии строят одноразовый git-репозиторий (mktemp) со
# своими .claude/CLAUDE.md и docs/rules/ — сверка norm не должна зеленеть на
# файлах проекта, — делают в нём два коммита для диффа и кладут туда же
# подставные вердикты.
#
#   bash scripts/council.test.sh
#
# Код возврата: 0 — все сценарии прошли, 1 — есть провалившиеся.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECK="$SCRIPT_DIR/council.sh"

[ -f "$CHECK" ] || { printf 'Не найден %s\n' "$CHECK" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { printf 'Не найден jq\n' >&2; exit 2; }

SANDBOX="$(mktemp -d)" || exit 2
[ -n "$SANDBOX" ] && [ -d "$SANDBOX" ] || exit 2
trap 'rm -rf "$SANDBOX"' EXIT
REPO="$SANDBOX/repo"
mkdir -p "$REPO" || exit 2

# Каждый вызов git — с -C: упавший cd не должен коммитить в настоящую ветку.
g() { git -C "$REPO" -c core.hooksPath=/dev/null -c commit.gpgsign=false "$@"; }

g init -q
g config user.name 'Сценарий'
g config user.email 'scenario@example.invalid'
mkdir -p "$REPO/.claude" "$REPO/docs/rules" "$REPO/docs/decisions" "$REPO/src"
printf '# Правила\n\n- Токены не логируются никогда.\n' > "$REPO/.claude/CLAUDE.md"
printf '# План\n\nКонтракт приёмки без пустых ячеек.\n' > "$REPO/docs/rules/plan.md"
printf '# 0001\n\nРешение принято.\n' > "$REPO/docs/decisions/0001-x.md"
for i in 1 2 3 4 5 6 7 8 9 10; do printf 'строка %d\n' "$i"; done > "$REPO/src/App.cs"
printf 'другое\n' > "$REPO/src/Other.cs"
g add -A && g commit -q -m 'chore: база' && g tag base
# Изменены строки 3–4 в App.cs, добавлен New.cs из пяти строк.
sed -i -e 's/^строка 3$/правка 3/' -e 's/^строка 4$/правка 4/' "$REPO/src/App.cs"
for i in 1 2 3 4 5; do printf 'новое %d\n' "$i"; done > "$REPO/src/New.cs"
g add -A && g commit -q -m 'feat: правка'
# Не под git: norm.file отсюда должен отбрасываться, хотя цитата в нём есть.
printf 'Решение принято.\n' > "$REPO/docs/rules/untracked.md"
printf '{"files":[{"path":"src/App.cs"},{"path":"src/New.cs"}],"acceptance":["первый","второй"]}\n' > "$REPO/plan.json"
RANGE='base...HEAD'
EMPTY_HASH=$(printf '' | sha256sum | cut -d' ' -f1)

PASSED=0 FAILED=0 FAILED_NAMES=() CASE_NAME='' CASE_OK=1 OUTPUT='' STATUS=0 K=0 VD=''

begin_case() {
    CASE_NAME="$1" CASE_OK=1 OUTPUT='' STATUS=0
    K=$((K + 1)); VD="$SANDBOX/v$K"; mkdir -p "$VD"
    printf '\n[ ... ] %s\n' "$CASE_NAME"
}
fail_case() { CASE_OK=0; printf '        ! %s\n' "$1"; }
end_case() {
    if [ "$CASE_OK" -eq 1 ]; then
        PASSED=$((PASSED + 1)); printf '[ ok  ] %s\n' "$CASE_NAME"
    else
        FAILED=$((FAILED + 1)); FAILED_NAMES+=("$CASE_NAME")
        printf '[ FAIL] %s\n' "$CASE_NAME"
        printf '        вывод:\n%s\n' "$OUTPUT" | sed 's/^/        /'
    fi
}
run_council() { OUTPUT="$(cd "$REPO" && bash "$CHECK" "$@" 2>&1)"; STATUS=$?; }
run_diff() { run_council diff "$RANGE" "$VD" "$@"; }
run_plan() { run_council plan "$REPO/plan.json" "$VD" "$@"; }
expect_status() { [ "$STATUS" -eq "$1" ] || fail_case "код возврата $STATUS, ожидался $1"; }
expect_output() { printf '%s' "$OUTPUT" | grep -qF -- "$1" || fail_case "в выводе нет: $1"; }
expect_no_output() { ! printf '%s' "$OUTPUT" | grep -qF -- "$1" || fail_case "в выводе не должно быть: $1"; }
hash_of() { printf '%s' "$OUTPUT" | sed -n 's/^hash=//p'; }

# Вердикт: роль, verdict, findings (JSON), read (JSON), unable_to_verify (JSON).
put() {
    printf '{"role":"%s","verdict":"%s","findings":%s,"read":%s,"unable_to_verify":%s}\n' \
        "$1" "$2" "${3:-[]}" "${4:-[\"docs/rules/plan.md\"]}" "${5:-[]}" > "$VD/$1.json"
}
# Замечание на диффе: severity, claim, file, line.
fd() { printf '{"severity":"%s","claim":"%s","evidence":{"file":"%s","line":%s}}' "$1" "$2" "$3" "$4"; }
# Блокер стража с norm: claim, norm.file, quote (JSON-строка без кавычек).
fn() { printf '{"severity":"blocker","claim":"%s","evidence":{"file":"src/App.cs","line":3},"norm":{"file":"%s","quote":"%s"}}' "$1" "$2" "$3"; }
quiet() { put skeptic no_objections; put engineer no_objections; put constitution no_objections; }

# ------------------------------------------------------------------
begin_case 'Чистый набор — код 0, пометки нет, хеш пустого набора'
quiet
run_diff
expect_status 0
expect_output 'Итог: код 0 — блокеров нет'
expect_output "hash=$EMPTY_HASH"
expect_no_output 'отброшен блокер'
end_case

begin_case 'nit без evidence отброшен с причиной, код 0 и без пометки'
quiet; put skeptic another_round '[{"severity":"nit","claim":"мелочь"}]'
run_diff
expect_status 0
expect_output 'мелочь — причина: нет evidence'
expect_no_output 'отброшен блокер'
end_case

begin_case 'blocker без evidence — отброшен, код 1 и пометка «отброшен блокер»'
quiet; put skeptic another_round '[{"severity":"blocker","claim":"дыра"}]'
run_diff
expect_status 1
expect_output 'дыра — причина: нет evidence'
expect_output 'отброшен блокер'
end_case

begin_case 'major с evidence на несуществующий файл — отброшен, код 1'
quiet; put engineer another_round "[$(fd major призрак src/Ghost.cs 1)]"
run_diff
expect_status 1
expect_output 'evidence.file вне артефакта: src/Ghost.cs (файла нет)'
expect_output 'отброшен блокер'
end_case

begin_case 'major с evidence на файл вне диффа — отброшен, код 1'
quiet; put engineer another_round "[$(fd major чужой src/Other.cs 1)]"
run_diff
expect_status 1
expect_output 'evidence.file вне артефакта: src/Other.cs'
expect_no_output 'src/Other.cs (файла нет)'
expect_output 'отброшен блокер'
end_case

begin_case 'Строка вне изменённого участка диффа — отброшена, код 1'
quiet; put engineer another_round "[$(fd major мимо src/App.cs 8),$(fd nit заграница src/New.cs 6)]"
run_diff
expect_status 1
expect_output 'строка src/App.cs:8 вне изменённого участка диффа'
expect_output 'строка src/New.cs:6 вне изменённого участка диффа'
end_case

begin_case 'Принятый blocker в изменённом участке — код 1 без пометки'
quiet; put engineer another_round "[$(fd blocker поломка src/App.cs 4)]"
run_diff
expect_status 1
expect_output 'Принятые замечания: 1'
expect_output '[blocker] engineer: поломка — src/App.cs:4'
expect_output 'принят blocker'
expect_no_output 'отброшен блокер'
end_case

begin_case 'Принятый major на границе хунка нового файла — код 0'
quiet; put engineer another_round "[$(fd major граница src/New.cs 5)]"
run_diff
expect_status 0
expect_output '[major] engineer: граница — src/New.cs:5'
end_case

begin_case 'Добавленная строка «++ …» не сбивает файл следующего хунка'
# В -U0 строка «++ x» в диффе выглядит как «+++ x» — заголовок файла. Ветка
# trap от HEAD: хунки App.cs на строках 1 и 8, первый добавляет «++ x».
g branch -q trap HEAD
g checkout -q trap
sed -i -e 's/^строка 1$/++ x/' -e 's/^строка 8$/правка 8/' "$REPO/src/App.cs"
g commit -q -am 'feat: ловушка заголовка'
g checkout -q -
quiet; put engineer another_round "[$(fd major второйхунк src/App.cs 8)]"
run_council diff 'HEAD...trap' "$VD"
expect_status 0
expect_output '[major] engineer: второйхунк — src/App.cs:8'
end_case

begin_case 'quote стража, которой нет в norm.file, — отброшена'
quiet; put constitution another_round "[$(fn нарушение .claude/CLAUDE.md 'такой фразы нет')]"
run_diff
expect_status 1
expect_output 'norm.quote не найдена в .claude/CLAUDE.md'
expect_output 'отброшен блокер'
end_case

begin_case 'norm.file вне git ls-files — отброшен, хотя цитата в нём есть'
quiet; put constitution another_round "[$(fn неучтённый docs/rules/untracked.md 'Решение принято.')]"
run_diff
expect_status 1
expect_output 'norm.file вне git ls-files: docs/rules/untracked.md'
end_case

begin_case 'norm.file вне .claude/CLAUDE.md, docs/decisions/**, docs/rules/** — отброшен'
quiet; put constitution another_round "[$(fn непризнанный src/App.cs 'правка 3')]"
run_diff
expect_status 1
expect_output 'norm.file вне .claude/CLAUDE.md, docs/decisions/**, docs/rules/**: src/App.cs'
end_case

begin_case 'quote, начинающаяся с «-» и стоящая в norm.file, — принята'
quiet; put constitution another_round "[$(fn 'токен в логе' .claude/CLAUDE.md '- Токены не логируются никогда.')]"
run_diff
expect_status 1
expect_output 'Принятые замечания: 1'
expect_output '[blocker] constitution: токен в логе — src/App.cs:3'
expect_no_output 'отброшен блокер'
end_case

begin_case 'Цитата из docs/decisions/ принята, многострочная — отброшена'
quiet; put constitution another_round "[$(fn решение docs/decisions/0001-x.md 'Решение принято.'),$(fn склейка docs/decisions/0001-x.md '# 0001\nРешение')]"
run_diff
expect_output '[blocker] constitution: решение — src/App.cs:3'
expect_output 'склейка — причина: norm.quote в несколько строк'
end_case

begin_case 'blocker стража без norm — отброшен с причиной'
quiet; put constitution another_round "[$(fd blocker безнормы src/App.cs 3)]"
run_diff
expect_status 1
expect_output 'у blocker стража нет norm'
expect_output 'отброшен блокер'
end_case

begin_case 'escalate — код 2'
quiet; put skeptic escalate
run_diff
expect_status 2
expect_output 'escalate'
end_case

begin_case 'escalate при принятом блокере — код 2, а не 1'
quiet; put skeptic escalate; put engineer another_round "[$(fd blocker поломка src/App.cs 3)]"
run_diff
expect_status 2
end_case

begin_case 'no_objections при непустом unable_to_verify — код 2'
quiet; put engineer no_objections '[]' '[]' '["нет доступа к логам"]'
run_diff
expect_status 2
expect_output 'no_objections при непустом unable_to_verify'
end_case

begin_case 'Повтор набора прошлого хеша — код 2, другой хеш — код 1'
quiet; put engineer another_round "[$(fd blocker поломка src/App.cs 3)]"
run_diff
expect_status 1
H=$(hash_of)
run_diff "$H"
expect_status 2
expect_output 'набор совпал с прошлым хешем'
run_diff "$EMPTY_HASH"
expect_status 1
end_case

begin_case 'Пустой принятый набор с хешем пустоты — не повтор, код 0'
quiet
run_diff "$EMPTY_HASH"
expect_status 0
end_case

begin_case 'Хеш не зависит от порядка замечаний и файлов вердиктов'
quiet; put engineer another_round "[$(fd nit альфа src/App.cs 3),$(fd nit бета src/New.cs 1)]"
run_diff
H1=$(hash_of)
quiet; put skeptic another_round "[$(fd nit бета src/New.cs 1)]"; put engineer another_round "[$(fd nit альфа src/App.cs 3)]"
run_diff
H2=$(hash_of)
[ -n "$H1" ] && [ "$H1" = "$H2" ] || fail_case "хеши разные: $H1 / $H2"
[ "$H1" != "$EMPTY_HASH" ] || fail_case 'хеш непустого набора равен хешу пустоты'
end_case

begin_case 'Брак стража: no_objections без read — код 3'
quiet; put constitution no_objections '[]' '[]'
run_diff
expect_status 3
expect_output 'брак: перезапустить стража'
end_case

begin_case 'План: pointer резолвится — принят, не резолвится — отброшен'
quiet; put engineer another_round '[{"severity":"major","claim":"второй файл","evidence":{"pointer":"/files/1"}},{"severity":"major","claim":"критерий","evidence":{"pointer":"/acceptance/0"}},{"severity":"major","claim":"нет пункта","evidence":{"pointer":"/acceptance/5"}},{"severity":"nit","claim":"нет поля","evidence":{"pointer":"/nope"}}]'
run_plan
expect_status 1
expect_output '[major] engineer: второй файл — /files/1'
expect_output '[major] engineer: критерий — /acceptance/0'
expect_output 'evidence.pointer не резолвится в плане: /acceptance/5'
expect_output 'evidence.pointer не резолвится в плане: /nope'
expect_output 'отброшен блокер'
end_case

begin_case 'План: file из files[].path принят, файл не из плана — отброшен'
quiet; put engineer another_round '[{"severity":"major","claim":"новый","evidence":{"file":"src/New.cs"}},{"severity":"major","claim":"чужой","evidence":{"file":"src/Other.cs"}},{"severity":"nit","claim":"пустое","evidence":{}}]'
run_plan
expect_status 1
expect_output '[major] engineer: новый — src/New.cs'
expect_output 'evidence.file не из files[].path плана: src/Other.cs'
expect_output 'нет evidence.pointer и evidence.file'
end_case

begin_case 'План: только принятые major — код 0'
quiet; put engineer another_round '[{"severity":"major","claim":"новый","evidence":{"file":"src/New.cs"}}]'
run_plan
expect_status 0
end_case

begin_case 'Ошибки запуска — код 3'
run_diff
expect_status 3
quiet
run_council review "$RANGE" "$VD"
expect_status 3
run_council diff 'нет-такой...HEAD' "$VD"
expect_status 3
printf '{"role":"judge","verdict":"no_objections","findings":[]}\n' > "$VD/judge.json"
run_diff
expect_status 3
end_case

# ------------------------------------------------------------------
printf '\n'
if [ "$FAILED" -gt 0 ]; then
    printf 'Провалившиеся сценарии:\n'
    for name in "${FAILED_NAMES[@]}"; do printf '  - %s\n' "$name"; done
    printf '\n'
fi
printf 'Пройдено: %d, провалено: %d, пропущено: 0\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ] || exit 1
exit 0
