#!/usr/bin/env bash
#
# Домовой — статус карточки задачи на доске GitHub Projects v2.
#
# ЗАЧЕМ
#
# Статус на доске двигает оркестратор в трёх точках процесса: новая ветка,
# PR открыт, PR смерджен (`.claude/CLAUDE.md`, «Первые ходы» и
# «Рекомендованный порядок», п. 10–11; решение — docs/decisions/0032).
# Workflow и токена в секретах CI для этого нет: сценарий идёт локально под
# авторизацией `gh` в сессии, которой нужен scope `project`.
#
# Id доски, поля Status и его опций нигде не записаны: сценарий находит их по
# имени на самой доске при каждом вызове. Опция, переименованная на доске,
# не разъезжается со списком в тексте — списка в тексте нет.
#
# КАК ЗАПУСКАТЬ
#
#   bash scripts/board.sh <номер issue> <статус>
#
# Статус с пробелом — в кавычках: `bash scripts/board.sh 159 'In progress'`.
# Регистр имени не важен. Принимается любая опция поля Status доски.
#
# Доска — `BOARD_OWNER` (по умолчанию k-kuzmin) и `BOARD_NUMBER` (по
# умолчанию 2). Переопределять их нужно только сценариям проверки.
#
# ЧТО ДЕЛАЕТ
#
#   1. Запрос доски: id доски, id поля Status, опции (id и имя).
#   2. Опция ищется по имени. Нет такой — отказ, карточка не трогается.
#   3. `gh issue view` — node id issue текущего репозитория. Номер, который
#      ведёт на PR, а не на issue, — отказ, карточка не трогается.
#   4. `addProjectV2ItemById` — всегда: мутация идемпотентна и для карточки,
#      которая уже на доске, возвращает её же id. Так карточка добавляется,
#      если её нет.
#   5. `updateProjectV2ItemFieldValue` — ставит опцию.
#   6. Одно чтение статуса карточки сразу после установки. Ожидания и
#      повторной установки нет: перезапись встроенной автоматизацией позже
#      этого чтения сценарий не видит (предел записан в 0032).
#
# Код возврата и вывод:
#   0 — статус поставлен и подтверждён чтением; в stdout одна строка с
#       номером issue и именем статуса так, как оно записано на доске;
#   1 — сбой `gh` (в stderr имя вызова и его код), не найдены доска, поле
#       Status или issue, пустой id карточки, прочитанный после установки
#       статус не совпал с ожидаемым (в stderr фактический и ожидаемый);
#   2 — негодный вызов: аргументы или BOARD_NUMBER (тогда `gh` не
#       вызывается) или статуса нет среди опций доски (в stderr перечень
#       имеющихся; карточка не добавляется и не меняется), или номер ведёт
#       на PR, а не на issue (в stderr номер и url; карточка не
#       добавляется и не меняется).
#
# Зависимости — только bash и gh: ответы разбирает сам `gh --jq`.
#
set -uo pipefail

if [ "$#" -ne 2 ]; then
    printf 'Использование: bash scripts/board.sh <номер issue> <статус>\n' >&2
    printf "Статус с пробелом — в кавычках: bash scripts/board.sh 159 'In progress'\n" >&2
    exit 2
fi

ISSUE="$1"
STATUS="$2"

case "$ISSUE" in
    ''|*[!0-9]*)
        printf 'Номер issue — только цифры, получено: «%s»\n' "$ISSUE" >&2
        exit 2
        ;;
esac

if [ -z "$STATUS" ]; then
    printf 'Статус пуст.\n' >&2
    exit 2
fi

OWNER="${BOARD_OWNER:-k-kuzmin}"
NUMBER="${BOARD_NUMBER:-2}"
case "$NUMBER" in
    ''|*[!0-9]*)
        printf 'BOARD_NUMBER — только цифры, получено: «%s»\n' "$NUMBER" >&2
        exit 2
        ;;
esac

# Срезает хвостовой \r у каждой строки: gh в Git Bash на Windows может
# отдавать CRLF, и \r в id ломает следующий вызов, а в имени — сравнение.
strip_cr() {
    printf '%s' "$1" | tr -d '\r'
}

# ------------------------------------------------------------------
# 1. Доска, поле Status, опции.
#
# Один запрос и для пользователя, и для организации: оба реализуют
# ProjectV2Owner. Поле берётся по имени, `options` — список, а не connection,
# поэтому пагинации нет. Ответ — строки: id доски, id поля, затем по строке
# «id<TAB>имя» на опцию. Пустое значение — пустая строка, а не сдвиг полей.
# ------------------------------------------------------------------
read -r -d '' BOARD_QUERY <<'GRAPHQL' || true
query($owner: String!, $number: Int!) {
  repositoryOwner(login: $owner) {
    ... on ProjectV2Owner {
      projectV2(number: $number) {
        id
        field(name: "Status") {
          ... on ProjectV2SingleSelectField {
            id
            options { id name }
          }
        }
      }
    }
  }
}
GRAPHQL

# shellcheck disable=SC2016  # $p — переменная jq, а не оболочки.
BOARD_ROWS="$(gh api graphql \
    -f query="$BOARD_QUERY" \
    -f owner="$OWNER" \
    -F number="$NUMBER" \
    --jq '.data.repositoryOwner.projectV2 as $p
          | ($p.id // ""),
            ($p.field.id // ""),
            (($p.field.options // [])[] | .id + "\t" + .name)')"
RC=$?
if [ "$RC" -ne 0 ]; then
    printf 'запрос доски: код %s\n' "$RC" >&2
    exit 1
fi
BOARD_ROWS="$(strip_cr "$BOARD_ROWS")"

PROJECT_ID=''
FIELD_ID=''
OPTION_ID=''
OPTION_NAME=''
OPTION_NAMES=''
STATUS_LOWER="${STATUS,,}"
ROW=0
while IFS= read -r line; do
    ROW=$((ROW + 1))
    case "$ROW" in
        1) PROJECT_ID="$line" ;;
        2) FIELD_ID="$line" ;;
        *)
            [ -n "$line" ] || continue
            opt_id="${line%%$'\t'*}"
            opt_name="${line#*$'\t'}"
            OPTION_NAMES="${OPTION_NAMES:+$OPTION_NAMES, }$opt_name"
            # Опция сопоставляется по имени с доски, без учёта регистра.
            if [ -z "$OPTION_ID" ] && [ "${opt_name,,}" = "$STATUS_LOWER" ]; then
                OPTION_ID="$opt_id"
                OPTION_NAME="$opt_name"
            fi
            ;;
    esac
done <<< "$BOARD_ROWS"

if [ -z "$PROJECT_ID" ]; then
    printf 'Доска №%s владельца «%s» не найдена (или у gh нет scope project).\n' "$NUMBER" "$OWNER" >&2
    exit 1
fi

if [ -z "$FIELD_ID" ]; then
    printf 'На доске №%s нет поля Status с выбором из списка.\n' "$NUMBER" >&2
    exit 1
fi

if [ -z "$OPTION_ID" ]; then
    printf 'На доске №%s нет статуса «%s».\n' "$NUMBER" "$STATUS" >&2
    printf 'Имеющиеся: %s\n' "${OPTION_NAMES:-ни одного}" >&2
    exit 2
fi

# ------------------------------------------------------------------
# 2. Node id issue текущего репозитория.
#
# `gh issue view` на номер PR отвечает кодом 0 и отдаёт node id PR: номера
# issue и PR в репозитории общие. Поэтому вместе с id читается url, и номер,
# который ведёт не на `/issues/`, отказывается до добавления карточки —
# иначе на доске появилась бы отдельная карточка PR.
# ------------------------------------------------------------------
ISSUE_ROW="$(gh issue view "$ISSUE" --json id,url --jq '.id + "\t" + .url')"
RC=$?
if [ "$RC" -ne 0 ]; then
    printf 'gh issue view: код %s\n' "$RC" >&2
    exit 1
fi
ISSUE_ROW="$(strip_cr "$ISSUE_ROW")"
ISSUE_ID="${ISSUE_ROW%%$'\t'*}"
ISSUE_URL=''
case "$ISSUE_ROW" in
    *$'\t'*) ISSUE_URL="${ISSUE_ROW#*$'\t'}" ;;
esac
if [ -z "$ISSUE_ID" ]; then
    printf 'Issue #%s не найдена: gh issue view вернул пустой id.\n' "$ISSUE" >&2
    exit 1
fi
case "$ISSUE_URL" in
    */issues/*) ;;
    *)
        printf 'Номер #%s принадлежит не issue, а PR (или иному объекту): %s\n' \
            "$ISSUE" "${ISSUE_URL:-url пуст}" >&2
        printf 'Сценарию нужен номер issue задачи, а не номер PR.\n' >&2
        exit 2
        ;;
esac

# ------------------------------------------------------------------
# 3. Карточка: добавить, если её нет. Мутация идемпотентна.
# ------------------------------------------------------------------
read -r -d '' ADD_MUTATION <<'GRAPHQL' || true
mutation($project: ID!, $content: ID!) {
  addProjectV2ItemById(input: { projectId: $project, contentId: $content }) {
    item { id }
  }
}
GRAPHQL

ITEM_ID="$(gh api graphql \
    -f query="$ADD_MUTATION" \
    -f project="$PROJECT_ID" \
    -f content="$ISSUE_ID" \
    --jq '.data.addProjectV2ItemById.item.id // ""')"
RC=$?
if [ "$RC" -ne 0 ]; then
    printf 'addProjectV2ItemById: код %s\n' "$RC" >&2
    exit 1
fi
ITEM_ID="$(strip_cr "$ITEM_ID")"
if [ -z "$ITEM_ID" ]; then
    printf 'Пустой id карточки issue #%s после addProjectV2ItemById.\n' "$ISSUE" >&2
    exit 1
fi

# ------------------------------------------------------------------
# 4. Установка статуса.
# ------------------------------------------------------------------
read -r -d '' UPDATE_MUTATION <<'GRAPHQL' || true
mutation($project: ID!, $item: ID!, $field: ID!, $option: String!) {
  updateProjectV2ItemFieldValue(
    input: {
      projectId: $project
      itemId: $item
      fieldId: $field
      value: { singleSelectOptionId: $option }
    }
  ) {
    projectV2Item { id }
  }
}
GRAPHQL

gh api graphql \
    -f query="$UPDATE_MUTATION" \
    -f project="$PROJECT_ID" \
    -f item="$ITEM_ID" \
    -f field="$FIELD_ID" \
    -f option="$OPTION_ID" \
    --jq '.data.updateProjectV2ItemFieldValue.projectV2Item.id' > /dev/null
RC=$?
if [ "$RC" -ne 0 ]; then
    printf 'updateProjectV2ItemFieldValue: код %s\n' "$RC" >&2
    exit 1
fi

# ------------------------------------------------------------------
# 5. Одно чтение обратно: код 0 значит то, что видно на доске сейчас.
# ------------------------------------------------------------------
read -r -d '' READ_QUERY <<'GRAPHQL' || true
query($item: ID!) {
  node(id: $item) {
    ... on ProjectV2Item {
      fieldValueByName(name: "Status") {
        ... on ProjectV2ItemFieldSingleSelectValue {
          optionId
          name
        }
      }
    }
  }
}
GRAPHQL

READ_ROW="$(gh api graphql \
    -f query="$READ_QUERY" \
    -f item="$ITEM_ID" \
    --jq '.data.node.fieldValueByName as $v
          | ($v.optionId // "") + "\t" + ($v.name // "")')"
RC=$?
if [ "$RC" -ne 0 ]; then
    printf 'чтение статуса: код %s\n' "$RC" >&2
    exit 1
fi
READ_ROW="$(strip_cr "$READ_ROW")"
ACTUAL_ID="${READ_ROW%%$'\t'*}"
ACTUAL_NAME=''
case "$READ_ROW" in
    *$'\t'*) ACTUAL_NAME="${READ_ROW#*$'\t'}" ;;
esac

if [ "$ACTUAL_ID" != "$OPTION_ID" ]; then
    printf 'Issue #%s: после установки на доске «%s», ожидался «%s».\n' \
        "$ISSUE" "${ACTUAL_NAME:-статус не задан}" "$OPTION_NAME" >&2
    exit 1
fi

printf 'Issue #%s: статус «%s».\n' "$ISSUE" "$OPTION_NAME"
exit 0
