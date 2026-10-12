#!/usr/bin/env bash
# Бэкап Домового: база Backend и том конфигурации Home Assistant.
#
#   bash ops/backup/backup.sh <каталог-назначения> [--keep N]
#
# Каталог назначения — корень на внешнем носителе, например
# <внешний-диск>/domovoy-backups. Он должен существовать: неподключённый
# диск — отказ, а не запись на системный диск. Каталог внутри клона
# репозитория — тоже отказ: бэкап содержит токены HA и приватную разметку
# дома.
#
# Что делает:
#   1. pg_dump -Fc изнутри контейнера postgres — db.dump;
#   2. архив тома /config изнутри работающего homeassistant — ha-config.tar.gz;
#      базы sqlite (рекордер, zigbee.db) кладутся онлайн-копией, HA не
#      останавливается (AR-6);
#   3. manifest.txt — число строк по таблицам и число не отключённых
#      записей реестра сущностей HA, только числа;
#   4. проверка целостности дампа и архива;
#   5. каталог .partial переименовывается в domovoy-backup-<UTC-метка>;
#   6. ротация: остаются N последних полных бэкапов (по умолчанию 14).
#
# Проект compose — тот, что задан в .env клона (COMPOSE_PROJECT_NAME),
# или переменная окружения COMPOSE_PROJECT_NAME. Лог — <назначение>/backup.log.
# Токены и пароли в вывод и лог не пишутся: учётные данные базы берутся
# из окружения самого контейнера postgres.

set -euo pipefail

# Git Bash переписывает аргументы вида /config в пути Windows; docker
# получает их как есть только с этой переменной. На Linux она ни на что
# не влияет.
export MSYS_NO_PATHCONV=1

usage() {
  echo "использование: bash ops/backup/backup.sh <каталог-назначения> [--keep N]" >&2
  exit 2
}

dest_arg=''
keep=14
while [ $# -gt 0 ]; do
  case "$1" in
    --keep)
      [ $# -ge 2 ] || usage
      keep="$2"
      shift 2
      ;;
    -h | --help) usage ;;
    -*) usage ;;
    *)
      [ -z "$dest_arg" ] || usage
      dest_arg="$1"
      shift
      ;;
  esac
done
[ -n "$dest_arg" ] || usage
[[ "$keep" =~ ^[1-9][0-9]*$ ]] || { echo "backup: --keep — целое число не меньше 1" >&2; exit 2; }

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "$root"

# Канонический путь существующего каталога: запись Windows (D:\…)
# приводится к POSIX, если есть cygpath; cd … && pwd -P снимает «..» и
# симлинки. Каталога нет — пустая строка.
canonical_dir() {
  local path="$1"
  if command -v cygpath >/dev/null 2>&1; then
    path="$(cygpath -u -- "$path")"
  fi
  (cd -- "$path" 2>/dev/null && pwd -P) || true
}

# На Windows регистр в путях не различается, а pwd -P его не выравнивает.
fold_case() {
  case "$(uname -s)" in
    MINGW* | MSYS* | CYGWIN*) printf '%s' "$1" | tr '[:upper:]' '[:lower:]' ;;
    *) printf '%s' "$1" ;;
  esac
}

dest="$(canonical_dir "$dest_arg")"
if [ -z "$dest" ]; then
  echo "backup: каталога назначения нет — носитель не подключён? Каталог не создаётся." >&2
  exit 1
fi

repo="$(git -C "$root" rev-parse --show-toplevel 2>/dev/null || echo "$root")"
repo="$(canonical_dir "$repo")"
dest_cmp="$(fold_case "$dest")"
repo_cmp="$(fold_case "$repo")"
if [ "$dest_cmp" = "$repo_cmp" ] || [ "${dest_cmp#"$repo_cmp"/}" != "$dest_cmp" ]; then
  echo "backup: каталог назначения внутри репозитория — бэкап содержит секреты, в клоне ему не место." >&2
  exit 1
fi

logfile="$dest/backup.log"
log() {
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$logfile"
  echo "$*"
}

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
name="domovoy-backup-$stamp"
partial="$dest/$name.partial"
final="$dest/$name"
done_ok=0

on_exit() {
  local code=$?
  if [ "$done_ok" -ne 1 ]; then
    [ -n "${partial:-}" ] && [ -d "$partial" ] && [ "${created_partial:-0}" -eq 1 ] && rm -rf -- "$partial"
    log "ошибка: бэкап $name не создан (код $code)" >/dev/null || true
    echo "backup: бэкап не создан, подробности выше и в $logfile" >&2
  fi
}
trap on_exit EXIT

fail() {
  log "ошибка: $*" >&2
  exit 1
}

dc() { docker compose --profile ha "$@"; }

log "старт: $name"

docker info >/dev/null 2>&1 || fail "docker недоступен — Docker Desktop не запущен?"
running="$(dc ps --status running --services </dev/null)" || fail "docker compose ps не выполнился"
for service in postgres homeassistant; do
  grep -qx "$service" <<<"$running" || fail "сервис $service не запущен"
done

[ ! -e "$final" ] && [ ! -e "$partial" ] || fail "каталог $name уже есть"
mkdir -- "$partial"
created_partial=1

# 1. База.
dc exec -T postgres sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc' \
  </dev/null >"$partial/db.dump" || fail "pg_dump не выполнился"

table_counts="$(dc exec -T postgres sh -c \
  'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -X -q -At -F " " -v ON_ERROR_STOP=1' \
  <ops/backup/table-counts.sql | tr -d '\r')" || fail "подсчёт строк в таблицах не выполнился"

# 2. Том HA. Сценарий модуля передаётся python3 через stdin: в контейнер
# ничего не копируется.
dc exec -T homeassistant python3 - archive /config \
  <ops/backup/ha_registry_check.py >"$partial/ha-config.tar.gz" || fail "архив тома HA не снят"

# Реестр сущностей обязателен: без него восстановленный HA не знает
# устройств, а манифест с нулём сделал бы проверку восстановления пустой.
ha_enabled="$(dc exec -T homeassistant python3 - count /config/.storage/core.entity_registry \
  <ops/backup/ha_registry_check.py | tr -d '\r')" || fail "реестр сущностей HA не прочитан"
[[ "$ha_enabled" =~ ^[0-9]+$ ]] || fail "реестр сущностей HA: ожидалось число"

# 3. Целостность до переименования. Дамп читается целиком, а не только
# оглавление: --file=/dev/null проходит по каждому блоку данных.
dc exec -T postgres pg_restore --list <"$partial/db.dump" >/dev/null \
  || fail "оглавление дампа не читается"
dc exec -T postgres pg_restore --file=/dev/null <"$partial/db.dump" >/dev/null \
  || fail "дамп не читается целиком"
gzip -t "$partial/ha-config.tar.gz" || fail "архив тома HA повреждён (gzip -t)"
listing="$(tar -tzf "$partial/ha-config.tar.gz")" || fail "архив тома HA не читается tar"
for member in .storage/core.entity_registry home-assistant_v2.db; do
  grep -qxF "$member" <<<"$listing" || fail "в архиве тома HA нет $member"
done
if grep -qE '(-wal|-shm)$' <<<"$listing"; then
  fail "в архиве тома HA есть -wal/-shm живой базы"
fi

# 4. Манифест: только числа и имена таблиц.
{
  echo "# Манифест бэкапа Домового. Числа для проверки восстановления: restore.sh"
  echo "format 1"
  echo "created_utc $stamp"
  while read -r table count; do
    [ -n "$table" ] || continue
    [[ "$count" =~ ^[0-9]+$ ]] || fail "подсчёт строк: непонятный ответ для $table"
    echo "db_table $table $count"
  done <<<"$table_counts"
  echo "ha_registry_enabled $ha_enabled"
} >"$partial/manifest.txt"

mv -- "$partial" "$final"
done_ok=1
tables="$(grep -c '^db_table ' "$final/manifest.txt" || true)"
log "успех: $name — таблиц БД: $tables, не отключённых сущностей HA: $ha_enabled"

# 5. Ротация — только после успеха и только полные бэкапы с точным
# именем: .partial и посторонние каталоги не трогаются.
backups=()
for entry in "$dest"/domovoy-backup-*; do
  base="${entry##*/}"
  if [ -d "$entry" ] && [[ "$base" =~ ^domovoy-backup-[0-9]{8}T[0-9]{6}Z$ ]]; then
    backups+=("$base")
  fi
done
if [ "${#backups[@]}" -gt "$keep" ]; then
  mapfile -t sorted < <(printf '%s\n' "${backups[@]}" | sort)
  excess=$((${#sorted[@]} - keep))
  for ((i = 0; i < excess; i++)); do
    rm -rf -- "${dest:?}/${sorted[i]}"
    log "ротация: удалён ${sorted[i]}"
  done
fi
