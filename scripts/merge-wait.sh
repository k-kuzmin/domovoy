#!/usr/bin/env bash
#
# Домовой — ожидание мерджа PR.
#
# ЗАЧЕМ
#
# Мердж делает человек, и происходит он не тогда, когда оркестратор отдал PR,
# а через минуты или дни. Оркестратор ставит этот сценарий в фон в том же
# сообщении, где зелёный PR отдаётся человеку (`.claude/CLAUDE.md`,
# «Рекомендованный порядок», п. 11), и по его выводу решает, что дальше:
# `MERGED` — закрыть задачу и убрать ветку и worktree, `CLOSED` — вопрос
# человеку, ничего не удаляется.
#
# Сценарий, а не однострочный цикл: в сессии, изолированной в worktree, Bash
# отказывается выполнять цикл в одной команде как слишком сложный для
# проверки, а вызов файла проходит.
#
# КАК ЗАПУСКАТЬ
#
#   bash scripts/merge-wait.sh <номер PR>
#
# Пауза между опросами — `MERGE_WAIT_INTERVAL` секунд, по умолчанию 60.
#
# Код возврата и вывод:
#   0 — PR смерджен или закрыт; состояние (`MERGED` или `CLOSED`) в stdout;
#   1 — сбой `gh` (`gh pr view: код <rc>` в stderr) или незнакомое состояние;
#       сбой завершает ожидание, а не крутит цикл на пустом значении;
#   2 — негодный аргумент; `gh` не зовётся.
#
# Зависимости — только bash и gh.
#
set -uo pipefail

if [ "$#" -ne 1 ]; then
    printf 'Использование: bash scripts/merge-wait.sh <номер PR>\n' >&2
    exit 2
fi

PR="$1"
case "$PR" in
    ''|*[!0-9]*)
        printf 'Номер PR — только цифры, получено: «%s»\n' "$PR" >&2
        exit 2
        ;;
esac

INTERVAL="${MERGE_WAIT_INTERVAL:-60}"

while :; do
    STATE="$(gh pr view "$PR" --json state --jq .state)"
    RC=$?
    if [ "$RC" -ne 0 ]; then
        printf 'gh pr view: код %s\n' "$RC" >&2
        exit 1
    fi
    case "$STATE" in
        OPEN)
            sleep "$INTERVAL"
            ;;
        MERGED|CLOSED)
            printf '%s\n' "$STATE"
            exit 0
            ;;
        *)
            printf 'gh pr view: незнакомое состояние PR #%s: «%s»\n' "$PR" "$STATE" >&2
            exit 1
            ;;
    esac
done
