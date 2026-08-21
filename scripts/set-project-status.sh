#!/usr/bin/env bash
#
# Ставит поле Status у карточки задачи на доске GitHub Projects v2.
#
# Projects v2 живёт только в GraphQL, и GITHUB_TOKEN в него писать не умеет —
# нужен персональный токен со scope `project`. Отсюда отдельный скрипт, а не
# пара строк в workflow: тем же скриптом чинится доска руками, когда
# синхронизация пропустила событие.
#
# Переменные окружения:
#   GH_TOKEN        персональный токен со scope `project`
#                   (и `repo`, если репозиторий приватный);
#   PROJECT_OWNER   владелец доски — логин пользователя или организации;
#   PROJECT_NUMBER  номер доски, он же последний сегмент её URL;
#   ISSUE_NODE_ID   node_id issue или PR, карточку которого двигаем;
#   STATUS          имя статуса, например «In progress».
#
# Скрипт идемпотентен: карточки на доске ещё нет — она создаётся, статус уже
# стоит — мутация просто повторяется. Запрошенного статуса на доске нет —
# предупреждение и выход с нулём: набор статусов задаёт человек, и скрипт не
# вправе ронять из-за этого весь workflow.

set -euo pipefail

require_env() {
  local name="$1"
  if [ -z "${!name:-}" ]; then
    echo "Не задана переменная окружения $name." >&2
    exit 2
  fi
}

require_env GH_TOKEN
require_env PROJECT_OWNER
require_env PROJECT_NUMBER
require_env ISSUE_NODE_ID
require_env STATUS

if ! command -v gh >/dev/null 2>&1; then
  echo 'Нужен gh CLI: https://cli.github.com' >&2
  exit 2
fi

# Один запрос вместо ветвления «сначала пользователь, потом организация»:
# и User, и Organization реализуют интерфейс ProjectV2Owner. Ветвление здесь
# было бы ещё и нерабочим — gh выходит с ненулевым кодом на ошибке GraphQL,
# и под `set -e` до второй попытки дело бы не дошло.
read -r -d '' PROJECT_QUERY <<'GRAPHQL' || true
query($owner: String!, $number: Int!) {
  repositoryOwner(login: $owner) {
    ... on ProjectV2Owner {
      projectV2(number: $number) {
        id
        title
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

# Ответ разбирается на TSV средствами самого gh, без зависимости от внешнего
# jq. Первая строка — данные доски, дальше по строке на статус.
#
# Само сопоставление имени статуса вынесено ниже, в оболочку, а не сделано
# внутри выражения. Иначе выражению понадобился бы доступ к переменной
# окружения STATUS, и если бы этот доступ не сработал, скрипт не упал бы, а
# на каждом запуске сообщал «такого статуса нет» — то есть тихо перестал бы
# работать. Молчаливый отказ здесь хуже лишних пяти строк.
# shellcheck disable=SC2016  # $p — переменная jq, а не оболочки.
project_rows="$(
  gh api graphql \
    -f query="$PROJECT_QUERY" \
    -f owner="$PROJECT_OWNER" \
    -F number="$PROJECT_NUMBER" \
    --jq '
      .data.repositoryOwner.projectV2 as $p
      | ([($p.id // ""), ($p.title // ""), ($p.field.id // "")] | @tsv),
        (($p.field.options // [])[] | [.id, .name] | @tsv)'
)"

IFS=$'\t' read -r project_id project_title field_id <<<"$(printf '%s\n' "$project_rows" | head -n 1)"

if [ -z "$project_id" ]; then
  echo "Доска №$PROJECT_NUMBER у владельца «$PROJECT_OWNER» не найдена." >&2
  echo 'Проверьте номер доски и то, что у токена есть scope project.' >&2
  exit 1
fi

if [ -z "$field_id" ]; then
  echo "::warning::У доски «$project_title» нет поля Status — двигать нечего." >&2
  exit 0
fi

# Регистр не учитывается: «In progress» и «In Progress» на доске неразличимы
# для человека, и скрипт не должен делать вид, что различимы.
status_lower="$(printf '%s' "$STATUS" | tr '[:upper:]' '[:lower:]')"
option_id=''
option_names=''

while IFS=$'\t' read -r current_id current_name; do
  [ -n "$current_name" ] || continue
  option_names="${option_names:+$option_names, }$current_name"
  if [ -z "$option_id" ] &&
    [ "$(printf '%s' "$current_name" | tr '[:upper:]' '[:lower:]')" = "$status_lower" ]; then
    option_id="$current_id"
  fi
done <<<"$(printf '%s\n' "$project_rows" | tail -n +2)"

if [ -z "$option_id" ]; then
  echo "::warning::На доске «$project_title» нет статуса «$STATUS»." >&2
  echo "Заведены такие: ${option_names:-ни одного}" >&2
  echo 'Добавьте недостающий статус или поправьте имена в .github/workflows/status-sync.yml.' >&2
  exit 0
fi

# Мутация идемпотентна: если карточка уже на доске, вернётся её же id.
read -r -d '' ADD_MUTATION <<'GRAPHQL' || true
mutation($project: ID!, $content: ID!) {
  addProjectV2ItemById(input: { projectId: $project, contentId: $content }) {
    item { id }
  }
}
GRAPHQL

item_id="$(
  gh api graphql \
    -f query="$ADD_MUTATION" \
    -f project="$project_id" \
    -f content="$ISSUE_NODE_ID" \
    --jq '.data.addProjectV2ItemById.item.id'
)"

if [ -z "$item_id" ]; then
  echo "Не удалось получить карточку для $ISSUE_NODE_ID на доске «$project_title»." >&2
  exit 1
fi

read -r -d '' SET_MUTATION <<'GRAPHQL' || true
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
  -f query="$SET_MUTATION" \
  -f project="$project_id" \
  -f item="$item_id" \
  -f field="$field_id" \
  -f option="$option_id" \
  --jq '.data.updateProjectV2ItemFieldValue.projectV2Item.id' >/dev/null

echo "Доска «$project_title»: карточка $ISSUE_NODE_ID переведена в «$STATUS»."
