#!/usr/bin/env bash
# Восстановление Домового из бэкапа ops/backup/backup.sh.
#
#   bash ops/backup/restore.sh --from <каталог-бэкапа> --check [--ha-api-check required|skip] [--keep]
#   bash ops/backup/restore.sh --from <каталог-бэкапа> --project <имя> [--ha-api-check required|skip]
#
# --check — проверка восстановления без простоя рабочего стека: отдельный
#   проект compose (domovoy-restore-check, переопределяется переменной
#   RESTORE_CHECK_PROJECT) только из docker-compose.yml и
#   ops/backup/restore-check.compose.yml, сети internal, порты на хост не
#   публикуются. В конце проект удаляется вместе с томами при любом исходе;
#   --keep оставляет его для разбора (удалять вручную: docker compose -p <имя> down -v).
# --project <имя> — восстановление после потери данных в проект с этим
#   именем: обычные файлы compose (с docker-compose.override.yml, если он
#   есть), обычные сети и порты из .env. Проект не удаляется. Отказ, если на
#   хосте работает homeassistant другого проекта compose: восстановленный HA
#   управлял бы теми же устройствами параллельно. Рабочий стек сначала
#   останавливается: docker compose --profile ha down (без -v).
#
# В обоих режимах проект обязан быть пустым — ни контейнеров (даже
# остановленных), ни томов. Перезаписи данных нет.
#
# Проверки:
#   БД  — число строк по каждой таблице равно манифесту;
#   HA  — число не отключённых записей реестра равно манифесту, копии баз
#         sqlite проходят integrity_check, и каждая такая сущность есть в
#         /api/states восстановленного HA (запрос — изнутри контейнера api
#         с его токеном; --ha-api-check skip пропускает только этот запрос);
#   api — анонимный /health восстановленного api отвечает.
# Любое расхождение — ненулевой код.

set -euo pipefail
export MSYS_NO_PATHCONV=1

started=$SECONDS

usage() {
  sed -n '4,5p' "${BASH_SOURCE[0]}" | sed 's/^# *//' >&2
  exit 2
}

from_arg=''
mode=''
project=''
ha_api_check='required'
keep_project=0
while [ $# -gt 0 ]; do
  case "$1" in
    --from)
      [ $# -ge 2 ] || usage
      from_arg="$2"
      shift 2
      ;;
    --check)
      [ -z "$mode" ] || usage
      mode='check'
      shift
      ;;
    --project)
      [ -z "$mode" ] && [ $# -ge 2 ] || usage
      mode='project'
      project="$2"
      shift 2
      ;;
    --ha-api-check)
      [ $# -ge 2 ] || usage
      ha_api_check="$2"
      shift 2
      ;;
    --keep)
      keep_project=1
      shift
      ;;
    *) usage ;;
  esac
done
[ -n "$from_arg" ] && [ -n "$mode" ] || usage
case "$ha_api_check" in required | skip) ;; *) usage ;; esac
if [ "$keep_project" -eq 1 ] && [ "$mode" != 'check' ]; then usage; fi

if [ "$mode" = 'check' ]; then
  project="${RESTORE_CHECK_PROJECT:-domovoy-restore-check}"
fi
[[ "$project" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || { echo "restore: имя проекта — строчные буквы, цифры, - и _" >&2; exit 2; }

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "$root"

from="$from_arg"
if command -v cygpath >/dev/null 2>&1; then from="$(cygpath -u -- "$from")"; fi
from="$( (cd -- "$from" 2>/dev/null && pwd -P) || true)"
[ -n "$from" ] || { echo "restore: каталога бэкапа нет" >&2; exit 1; }
case "${from##*/}" in
  *.partial) echo "restore: каталог .partial — недописанный бэкап" >&2; exit 1 ;;
esac
for file in db.dump ha-config.tar.gz manifest.txt; do
  [ -f "$from/$file" ] || { echo "restore: в каталоге бэкапа нет $file" >&2; exit 1; }
done

# Манифест: «db_table <таблица> <число>» и «ha_registry_enabled <число>».
grep -qx 'format 1' "$from/manifest.txt" || { echo "restore: неизвестный формат манифеста" >&2; exit 1; }
expected_tables="$(grep '^db_table ' "$from/manifest.txt" | tr -d '\r' | cut -d' ' -f2- | sort || true)"
expected_ha="$(grep '^ha_registry_enabled ' "$from/manifest.txt" | tr -d '\r' | cut -d' ' -f2 || true)"
[[ "$expected_ha" =~ ^[0-9]+$ ]] || { echo "restore: в манифесте нет числа сущностей HA" >&2; exit 1; }

files=()
if [ "$mode" = 'check' ]; then
  files=(-f docker-compose.yml -f ops/backup/restore-check.compose.yml)
  # Восстановленный api ходит в восстановленный HA, а не по адресу из
  # .env — тот может указывать на рабочий HA в ЛВС.
  export HA_BASE_URL='http://homeassistant:8123'
fi

dc() { docker compose -p "$project" "${files[@]}" --profile ha "$@"; }

project_is_empty() {
  local label="label=com.docker.compose.project=$project"
  [ -z "$(docker ps -aq --filter "$label")" ] && [ -z "$(docker volume ls -q --filter "$label")" ]
}

docker info >/dev/null 2>&1 || { echo "restore: docker недоступен" >&2; exit 1; }
# --project поднимает HA с обычными сетями и override с USB-координатором:
# рядом с работающим HA другого проекта он управлял бы теми же
# устройствами параллельно. Безопасен рядом с работающим стеком только
# --check.
if [ "$mode" = 'project' ]; then
  running_ha="$(docker ps --filter 'label=com.docker.compose.service=homeassistant' \
    --format '{{.Label "com.docker.compose.project"}}' | tr -d '\r' | grep -vxF "$project" | sort -u || true)"
  if [ -n "$running_ha" ]; then
    while read -r other; do
      echo "restore: на хосте работает Home Assistant проекта ${other:-<без имени>} — восстановленный управлял бы теми же устройствами." >&2
      echo "restore: сначала остановите его, тома не трогая: docker compose -p ${other:-<проект>} --profile ha down (без -v)" >&2
    done <<<"$running_ha"
    exit 1
  fi
fi
if ! project_is_empty; then
  echo "restore: в проекте $project уже есть контейнеры или тома — восстановление идёт только в пустой проект." >&2
  echo "restore: если прошлое восстановление отменяется: docker compose -p $project down -v" >&2
  exit 1
fi

helper="$project-restore-helper"
cleanup() {
  local code=$?
  docker rm -f "$helper" >/dev/null 2>&1 || true
  if [ "$mode" = 'check' ]; then
    if [ "$keep_project" -eq 1 ]; then
      echo "проверочный проект $project оставлен (--keep): docker compose -p $project down -v"
    else
      dc down -v --remove-orphans </dev/null >/dev/null 2>&1 || true
      echo "проверочный проект $project удалён вместе с томами"
    fi
  fi
  if [ "$code" -ne 0 ]; then
    echo "restore: восстановление не прошло проверку (код $code)" >&2
  fi
}
trap cleanup EXIT

fail() {
  echo "restore: $*" >&2
  exit 1
}

echo "восстановление: проект $project, режим $mode"

# 1. База — в пустой том, до старта api.
dc up -d --wait --wait-timeout 180 postgres </dev/null || fail "postgres не поднялся"
dc exec -T postgres sh -c \
  'pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner --exit-on-error' \
  <"$from/db.dump" || fail "pg_restore не выполнился"
# База против манифеста — сразу после pg_restore, пока api не запущен и
# ничего в неё не записал.
actual_tables="$(dc exec -T postgres sh -c \
  'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -X -q -At -F " " -v ON_ERROR_STOP=1' \
  <ops/backup/table-counts.sql | tr -d '\r' | sort)" || fail "подсчёт строк в восстановленной базе не выполнился"
if [ "$actual_tables" != "$expected_tables" ]; then
  # Называется таблица и числа, содержимое строк не печатается.
  diff <(echo "$expected_tables") <(echo "$actual_tables") \
    | sed -n 's/^< /  в манифесте: /p; s/^> /  восстановлено: /p' >&2 || true
  fail "БД: восстановленные таблицы расходятся с манифестом"
fi
echo "БД: таблицы совпадают с манифестом ($(grep -c . <<<"$expected_tables" || true) таблиц)"

# 2. Том HA — до первого старта HA, во временном контейнере с тем же томом.
dc run -d --no-deps --name "$helper" --entrypoint sleep homeassistant 3600 </dev/null >/dev/null \
  || fail "временный контейнер для тома HA не создан"
docker cp ops/backup/ha_registry_check.py "$helper:/tmp/ha_registry_check.py" >/dev/null
docker exec -i "$helper" python3 /tmp/ha_registry_check.py extract /config \
  <"$from/ha-config.tar.gz" || fail "архив тома HA не распакован"
restored_ha="$(docker exec "$helper" python3 /tmp/ha_registry_check.py count /config/.storage/core.entity_registry | tr -d '\r')" \
  || fail "реестр сущностей в восстановленном томе HA не читается"
[ "$restored_ha" = "$expected_ha" ] \
  || fail "HA: в восстановленном реестре $restored_ha не отключённых записей, в манифесте $expected_ha"
# Каждая база sqlite тома (рекордер, zigbee.db и прочие, что archive
# положил онлайн-копией); рекордер обязателен.
sqlite_report="$(docker exec "$helper" python3 /tmp/ha_registry_check.py sqlite-check-all /config | tr -d '\r')" \
  || { [ -z "$sqlite_report" ] || sed '$d' <<<"$sqlite_report" >&2; fail "HA: копии баз sqlite не прошли integrity_check"; }
docker rm -f "$helper" >/dev/null
echo "HA: реестр восстановлен, $restored_ha не отключённых записей, как в манифесте; баз sqlite цело: $sqlite_report"

# 3. Стек целиком. --build: проверяется текущий код api, а не образ,
# оставшийся от прошлой проверки; при неизменном коде сборка берётся из кеша.
dc up -d --build </dev/null || fail "стек не поднялся"

# 4. HA API: состояния восстановленного HA против реестра бэкапа.
if [ "$ha_api_check" = 'skip' ]; then
  echo "HA: проверка HA API пропущена (--ha-api-check skip)"
else
  dc cp ops/backup/ha_registry_check.py homeassistant:/tmp/ha_registry_check.py >/dev/null 2>&1 \
    || fail "модуль проверки не скопирован в контейнер HA"
  # Сверка идёт с реестром из бэкапа, а не с /config восстановленного HA:
  # HA при старте реестр переписывает, и запись, удалённая им на старте,
  # исчезла бы из обеих сторон сравнения. Реестр берётся из архива
  # бэкапа — тех байтов, что легли в том до первого старта HA, — и трубой
  # уходит в контейнер, без файла на хосте.
  tar -xzOf "$from/ha-config.tar.gz" .storage/core.entity_registry \
    | dc exec -T homeassistant sh -c 'cat >/tmp/registry.backup.json' \
    || fail "реестр сущностей из бэкапа не передан в контейнер HA"
  # Токен берётся из окружения контейнера api и не выходит из него: заголовок
  # печатает встроенная printf оболочки контейнера (dash), а curl читает его
  # со stdin (-H @-). Поэтому токена нет ни в командной строке хоста, ни в
  # argv процессов контейнера, ни в выводе.
  # shellcheck disable=SC2016
  api_code_cmd='printf "Authorization: Bearer %s\n" "$Ha__Token" | curl -s -o /dev/null --max-time 10 -w "%{http_code}" -H @- http://homeassistant:8123/api/'
  # shellcheck disable=SC2016
  states_cmd='printf "Authorization: Bearer %s\n" "$Ha__Token" | curl -sS --fail --max-time 30 -H @- http://homeassistant:8123/api/states'
  deadline=$((SECONDS + 300))
  code='000'
  while :; do
    code="$(dc exec -T api sh -c "$api_code_cmd" </dev/null | tr -d '\r' || true)"
    [ "$code" = '000' ] || [ -z "$code" ] || break
    [ "$SECONDS" -lt "$deadline" ] || fail "HA не ответил за 300 с"
    sleep 5
  done
  case "$code" in
    200) ;;
    401 | 403) fail "HA: токен из окружения api не принят восстановленным HA (HTTP $code)" ;;
    *) fail "HA: /api/ ответил HTTP $code" ;;
  esac
  # Состояния сущностей реестра появляются, когда HA закончил старт:
  # сверка повторяется, пока не сойдётся или не выйдет время.
  result=''
  while :; do
    if result="$(dc exec -T api sh -c "$states_cmd" </dev/null \
      | dc exec -T homeassistant python3 /tmp/ha_registry_check.py compare \
        /tmp/registry.backup.json - --expect "$expected_ha" | tr -d '\r')"; then
      break
    fi
    [ "$SECONDS" -lt "$deadline" ] || fail "HA: $(head -n1 <<<"$result") сущностей реестра в состояниях; $(sed -n 2p <<<"$result")"
    sleep 5
  done
  dc exec -T homeassistant rm -f /tmp/registry.backup.json </dev/null || true
  echo "HA: $result сущностей реестра в состояниях"
fi

# 5. Анонимный /health. В режиме --check внешние компоненты (LLM, ntfy)
# в изолированной сети недоступны, поэтому статус печатается, а не
# требуется «healthy»: проверяется, что восстановленный api поднялся и
# отвечает.
health=''
deadline=$((SECONDS + 180))
while :; do
  health="$(dc exec -T api curl -s --max-time 10 http://localhost:8080/health </dev/null | tr -d '\r' || true)"
  grep -qE '"status":"(healthy|degraded|unhealthy)"' <<<"$health" && break
  [ "$SECONDS" -lt "$deadline" ] || fail "/health восстановленного api не ответил за 180 с"
  sleep 3
done
echo "/health отвечает: $(sed -E 's/.*"status":"([a-z]+)".*/\1/' <<<"$health")"

elapsed=$((SECONDS - started))
echo "восстановление и проверки: $((elapsed / 60)) мин $((elapsed % 60)) с"
echo "  в замере: загрузка недостающих образов (уже лежащие на хосте не загружаются) и сборка api (--build, из кеша при неизменном коде)"
