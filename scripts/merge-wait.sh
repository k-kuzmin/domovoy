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
# человеку, ничего не удаляется, `BEHIND` или `DIRTY` — ветка отстала от main
# (без конфликта или с ним), владелец смерджить PR не может: сверить ветку с
# origin/main и подтянуть её, как сказано в п. 10–11.
#
# Исходы BEHIND и DIRTY берутся из `mergeStateStatus` и зависят от ruleset
# main: BEHIND GitHub отдаёт, пока включено требование свежей ветки
# (`strict_required_status_checks_policy`). Остальные значения у открытого PR
# (`UNKNOWN`, `BLOCKED`, `CLEAN`, `UNSTABLE`, будущие) — продолжение ожидания;
# у смердженного и закрытого PR `mergeStateStatus` не смотрится.
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
# Ноль — только для сценариев с подставным `gh`: на настоящем PR он опрашивает
# API без паузы.
#
# Код возврата и вывод:
#   0 — PR смерджен или закрыт, или ветка отстала от main; исход (`MERGED`,
#       `CLOSED`, `BEHIND` или `DIRTY`) в stdout;
#   1 — сбой `gh` (`gh pr view: код <rc>` в stderr) или незнакомое состояние;
#       сбой завершает ожидание, а не крутит цикл на пустом значении;
#   2 — негодный аргумент или `MERGE_WAIT_INTERVAL`; `gh` не зовётся.
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
case "$INTERVAL" in
    *[!0-9]*)
        printf 'MERGE_WAIT_INTERVAL — только цифры (секунды), получено: «%s»\n' "$INTERVAL" >&2
        exit 2
        ;;
esac

while :; do
    ANSWER="$(gh pr view "$PR" --json state,mergeStateStatus --jq '.state + " " + .mergeStateStatus')"
    RC=$?
    if [ "$RC" -ne 0 ]; then
        printf 'gh pr view: код %s\n' "$RC" >&2
        exit 1
    fi
    # Второго слова может не быть: при null mergeStateStatus jq печатает
    # «OPEN » с хвостовым пробелом.
    STATE="${ANSWER%% *}"
    MERGE_STATE=''
    case "$ANSWER" in
        *' '*) MERGE_STATE="${ANSWER#* }" ;;
    esac
    case "$STATE" in
        OPEN)
            case "$MERGE_STATE" in
                BEHIND|DIRTY)
                    printf '%s\n' "$MERGE_STATE"
                    exit 0
                    ;;
            esac
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
