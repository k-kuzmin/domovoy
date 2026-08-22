#!/usr/bin/env bash
#
# Заводит метки агентского цикла в репозитории.
#
# Только агентские метки. Существующая таксономия — stage/*, area/*, type/*,
# priority/* — заведена раньше и скриптом не трогается: пересоздавать её
# означало бы затирать цвета и описания, выставленные руками.
#
# Скрипт идемпотентен и рассчитан на повторный запуск: `gh label create
# --force` обновляет метку, если она уже есть, вместо того чтобы падать.
# Побочный эффект тот же, что и смысл: цвета и описания агентских меток
# приводятся к тому, что записано здесь, — этот файл и есть их источник.
#
# Использование:
#   scripts/bootstrap.sh                       # текущий репозиторий
#   scripts/bootstrap.sh --repo owner/name     # явно заданный
#   scripts/bootstrap.sh --dry-run             # показать, ничего не меняя
#
# Требуется gh CLI с правом записи в репозиторий.
#
# БЕЗ ОБВЯЗКИ: разовый ручной инструмент под токеном с правом записи в
# настройки репозитория, запускать его на каждом PR незачем и небезопасно.
# Маркер читает scripts/wiring.sh — он следит, чтобы остальные скрипты
# вызывались хотя бы одним workflow.

set -euo pipefail

repo=''
dry_run='false'

usage() {
  cat <<'HELP'
Заводит метки агентского цикла в репозитории. Существующие метки проекта
(stage/*, area/*, type/*, priority/*) не трогает.

  scripts/bootstrap.sh                    текущий репозиторий
  scripts/bootstrap.sh --repo owner/name  явно заданный
  scripts/bootstrap.sh --dry-run          показать, ничего не меняя
HELP
}

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)
      if [ $# -lt 2 ]; then
        echo 'Ключ --repo требует значения вида owner/name.' >&2
        exit 2
      fi
      repo="$2"
      shift 2
      ;;
    --dry-run)
      dry_run='true'
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "Неизвестный аргумент: $1" >&2
      exit 2
      ;;
  esac
done

if ! command -v gh >/dev/null 2>&1; then
  echo 'Нужен gh CLI: https://cli.github.com' >&2
  exit 2
fi

if [ "$dry_run" = 'false' ] && ! gh auth status >/dev/null 2>&1; then
  echo 'gh не авторизован. Выполните: gh auth login' >&2
  exit 2
fi

# Формат строки: имя|цвет|описание.
#
# Цвета сгруппированы по смыслу, чтобы доска читалась боковым зрением:
# фиолетовый — вход в цикл, синий и зелёный — движение, жёлтый и красный —
# остановка и разрешения на опасное.
labels=(
  'agent|5319e7|Задача, которую может взять агент'

  'agent/ready|0e8a16|Разобрана и готова к работе: агент берёт её в следующем проходе'
  'agent/needs-clarification|fbca04|Формулировка неоднозначна: нужен ответ владельца'
  'agent/in-progress|1d76db|Агент работает над задачей прямо сейчас'
  'agent/needs-human|d93f0b|Агент остановился: дальше без человека нельзя'
  'agent/flaky|e99695|Результат невоспроизводим: проверка или тест плавают'

  'agent/allow-protected|b60205|Разрешает агенту править защищённые пути'
  'agent/allow-contract|b60205|Разрешает агенту менять контракт API'
  'agent/allow-destructive-migration|b60205|Разрешает DropColumn, RenameColumn и смену типа в миграции'

  'plan/proposed|c5def5|План предложен и ждёт разбора владельцем'
  'plan/approved|006b75|План одобрен: можно приступать к коду'

  'fix/1|fef2c0|Первая итерация исправлений по CI или ревью'
  'fix/2|fbca04|Вторая итерация: причина не найдена с первого раза'
  'fix/3|d93f0b|Третья итерация — последняя, дальше задача уходит человеку'

  'review/1|c5def5|Первый круг ревью пройден'
  'review/2|fbca04|Второй круг — последний, дальше задача уходит человеку'
)

created=0

for entry in "${labels[@]}"; do
  IFS='|' read -r name color description <<<"$entry"

  if [ "$dry_run" = 'true' ]; then
    printf 'создать или обновить: %-28s #%s  %s\n' "$name" "$color" "$description"
    created=$((created + 1))
    continue
  fi

  args=(label create "$name" --color "$color" --description "$description" --force)
  [ -z "$repo" ] || args+=(--repo "$repo")

  gh "${args[@]}"
  created=$((created + 1))
done

if [ "$dry_run" = 'true' ]; then
  echo "Проверка без изменений: обработано бы меток — $created."
else
  echo "Готово: агентских меток заведено или обновлено — $created."
fi
