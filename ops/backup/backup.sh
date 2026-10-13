#!/usr/bin/env bash
# Бэкап Домового: база Backend и том конфигурации Home Assistant.
#
#   bash ops/backup/backup.sh [<каталог-назначения>] [--keep N] [--max-size ГБ]
#
# Каталог назначения — корень на внешнем носителе, например
# <внешний-диск>/domovoy-backups. Без аргумента берётся BACKUP_DIR, без
# --max-size — BACKUP_MAX_SIZE_GB: из переменной окружения, если она
# задана, иначе из .env клона (ops/backup/dotenv.sh; .env не исполняется).
# Так запускает задача Планировщика (ops/backup/install-schedule.ps1):
# правка .env действует со следующего прогона. Каталог не задан нигде —
# код 2.
#
# Каталог должен существовать: неподключённый диск — отказ, а не запись
# на системный диск. Каталог внутри клона репозитория — тоже отказ: бэкап
# содержит токены HA и приватную разметку дома.
#
# Что делает:
#   1. pg_dump -Fc изнутри контейнера postgres — db.dump;
#   2. архив тома /config изнутри работающего homeassistant — ha-config.tar.gz;
#      базы sqlite (рекордер, zigbee.db) кладутся онлайн-копией, HA не
#      останавливается (AR-6);
#   3. manifest.txt — число строк по таблицам и число не отключённых
#      записей реестра сущностей HA, только числа; строки считаются по
#      дампу, восстановленному во временную базу, реестр — по его копии в
#      архиве, а не по живым данным;
#   4. проверка целостности дампа и архива;
#   5. каталог .partial переименовывается в domovoy-backup-<UTC-метка>;
#   6. ротация: остаются N последних полных бэкапов (по умолчанию 14).
#
# --max-size ГБ — лимит на суммарный объём полных бэкапов на носителе
# (ГБ = 1024^3 байт). До записи нового его размер оценивается по последнему
# успешному; если с ним сумма выходит за лимит, самые старые полные бэкапы
# удаляются по одному, пока не влезет. Последний успешный не удаляется
# никогда: не влезает и без остальных, или свободного места на носителе
# меньше оценки — отказ. Без лимита (ни --max-size, ни BACKUP_MAX_SIZE_GB)
# до записи ничего не удаляется.
#
# Проект compose — тот, что задан в .env клона (COMPOSE_PROJECT_NAME),
# или переменная окружения COMPOSE_PROJECT_NAME. Лог — <назначение>/backup.log.
# Токены и пароли в вывод и лог не пишутся: учётные данные базы берутся
# из окружения самого контейнера postgres.

set -euo pipefail
# Дамп, архив тома и лог содержат токены HA и приватную разметку дома:
# на носителе они доступны только владельцу.
umask 077

# Git Bash переписывает аргументы вида /config в пути Windows; docker
# получает их как есть только с этой переменной. На Linux она ни на что
# не влияет.
export MSYS_NO_PATHCONV=1

usage() {
  echo "использование: bash ops/backup/backup.sh [<каталог-назначения>] [--keep N] [--max-size ГБ]" >&2
  exit 2
}

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
# shellcheck source=ops/backup/dotenv.sh
. "$root/ops/backup/dotenv.sh"

dest_arg=''
keep=14
max_size_gb=''
while [ $# -gt 0 ]; do
  case "$1" in
    --keep)
      [ $# -ge 2 ] || usage
      keep="$2"
      shift 2
      ;;
    --max-size)
      [ $# -ge 2 ] || usage
      max_size_gb="$2"
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
if [ -z "$dest_arg" ]; then
  dest_arg="$(backup_setting BACKUP_DIR "$root")"
  if [ -z "$dest_arg" ]; then
    echo "backup: каталог назначения не задан — задайте BACKUP_DIR в .env клона или передайте каталог аргументом" >&2
    usage
  fi
fi
max_size_source='--max-size'
if [ -z "$max_size_gb" ]; then
  max_size_gb="$(backup_setting BACKUP_MAX_SIZE_GB "$root")"
  max_size_source='BACKUP_MAX_SIZE_GB'
fi
[[ "$keep" =~ ^[1-9][0-9]*$ ]] || { echo "backup: --keep — целое число не меньше 1" >&2; exit 2; }
if [ -n "$max_size_gb" ] && ! [[ "$max_size_gb" =~ ^[1-9][0-9]{0,5}$ ]]; then
  echo "backup: $max_size_source — целое число гигабайт от 1" >&2
  exit 2
fi

cd "$root"

# Канонический путь существующего каталога: запись Windows (D:\…)
# приводится к POSIX (host_path: cygpath в Git Bash, wslpath в WSL);
# cd … && pwd -P снимает «..» и симлинки. Каталога нет — пустая строка.
canonical_dir() {
  local path
  path="$(host_path "$1")"
  (cd -- "$path" 2>/dev/null && pwd -P) || true
}

# На Windows регистр в путях не различается, а pwd -P его не выравнивает;
# так же — диски Windows внутри WSL (/mnt/<диск>/…).
fold_case() {
  case "$(uname -s)" in
    MINGW* | MSYS* | CYGWIN*) printf '%s' "$1" | tr '[:upper:]' '[:lower:]' ;;
    *)
      case "$1" in
        /mnt/[A-Za-z]/*) printf '%s' "$1" | tr '[:upper:]' '[:lower:]' ;;
        *) printf '%s' "$1" ;;
      esac
      ;;
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

created_verify_db=0
drop_verify_db() {
  # shellcheck disable=SC2016
  dc exec -T postgres sh -c 'dropdb -U "$POSTGRES_USER" --if-exists "$1"' sh "$verify_db" </dev/null \
    && created_verify_db=0
}

on_exit() {
  local code=$?
  if [ "${created_verify_db:-0}" -eq 1 ]; then
    drop_verify_db >/dev/null 2>&1 || log "временная база $verify_db не удалена: dropdb вручную" >&2 || true
  fi
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

docker info >/dev/null 2>&1 || fail "docker недоступен — демон docker не запущен?"
running="$(dc ps --status running --services </dev/null)" || fail "docker compose ps не выполнился"
for service in postgres homeassistant; do
  grep -qx "$service" <<<"$running" || fail "сервис $service не запущен"
done

# Остатки временных баз проверки дампа (шаг 3) от прогонов, убитых раньше,
# чем сработал trap: SIGKILL, выключение хоста. Удаляются только базы с
# точной формой имени шага 3. Базу, к которой подключён параллельный
# прогон, dropdb без --force не удаляет — это предупреждение, а не отказ
# бэкапа. Но подключена она не всё время: между createdb и pg_restore и
# между pg_restore и psql базу параллельного прогона dropdb удалит, и тот
# упадёт на шаге 3 громко; манифест он при этом не запишет, порчи нет.
verify_pattern='^domovoy_backup_verify_[0-9]{8}t[0-9]{6}z$'
# shellcheck disable=SC2016
leftovers="$(dc exec -T postgres sh -c \
  'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -X -q -At -v ON_ERROR_STOP=1 -c "$1"' sh \
  "SELECT datname FROM pg_database WHERE datname ~ '$verify_pattern' ORDER BY 1" \
  </dev/null | tr -d '\r')" || fail "список временных баз проверки не получен"
dropped=0
while read -r leftover; do
  [[ "$leftover" =~ $verify_pattern ]] || continue
  # shellcheck disable=SC2016
  if dc exec -T postgres sh -c 'dropdb -U "$POSTGRES_USER" "$1"' sh "$leftover" </dev/null >/dev/null; then
    dropped=$((dropped + 1))
  else
    log "предупреждение: временная база $leftover не удалена (занята?) — dropdb вручную" >&2
  fi
done <<<"$leftovers"
log "остатки временных баз проверки от прошлых прогонов: удалено $dropped"

# Место на носителе — до записи нового бэкапа (только с лимитом: --max-size
# или BACKUP_MAX_SIZE_GB).
# Оценка размера нового — размер последнего успешного. Удаляются только
# полные каталоги domovoy-backup-<метка>, от старых к новым, последний —
# никогда; .partial и посторонние каталоги не трогаются.
size_kb() {
  local out
  out="$(du -sk -- "$1")" || return 1
  out="${out%%[[:space:]]*}"
  [[ "$out" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$out"
}
mb() { echo "$((($1 + 1023) / 1024))"; }
if [ -n "$max_size_gb" ]; then
  existing=()
  for entry in "$dest"/domovoy-backup-*; do
    base="${entry##*/}"
    if [ -d "$entry" ] && [[ "$base" =~ ^domovoy-backup-[0-9]{8}T[0-9]{6}Z$ ]]; then
      existing+=("$base")
    fi
  done
  if [ "${#existing[@]}" -eq 0 ]; then
    log "место: первый бэкап — оценки размера нет, лимит $max_size_source и свободное место не проверяются"
  else
    mapfile -t existing < <(printf '%s\n' "${existing[@]}" | sort)
    newest="${existing[${#existing[@]} - 1]}"
    estimate_kb="$(size_kb "$dest/$newest")" || fail "размер последнего бэкапа $newest не определён (du)"
    limit_kb=$((max_size_gb * 1024 * 1024))
    if [ $((estimate_kb * 2)) -gt "$limit_kb" ]; then
      fail "лимит $max_size_source $max_size_gb ГБ мал: последний бэкап $newest занимает $(mb "$estimate_kb") МБ, и вместе с новым такого же размера в лимит не помещается. Последний успешный бэкап не удаляется — увеличьте $max_size_source."
    fi
    sizes=()
    total_kb=0
    for base in "${existing[@]}"; do
      size="$(size_kb "$dest/$base")" || fail "размер бэкапа $base не определён (du)"
      sizes+=("$size")
      total_kb=$((total_kb + size))
    done
    i=0
    while [ $((total_kb + estimate_kb)) -gt "$limit_kb" ] && [ "$i" -lt $((${#existing[@]} - 1)) ]; do
      rm -rf -- "${dest:?}/${existing[i]}"
      total_kb=$((total_kb - sizes[i]))
      log "лимит $max_size_source $max_size_gb ГБ: удалён ${existing[i]} ($(mb "${sizes[i]}") МБ)"
      i=$((i + 1))
    done
    free_kb="$(df -Pk -- "$dest" | awk 'NR == 2 { print $4 }')" || fail "свободное место на носителе не определено (df)"
    [[ "$free_kb" =~ ^[0-9]+$ ]] || fail "свободное место на носителе не определено (df)"
    if [ "$free_kb" -lt "$estimate_kb" ]; then
      fail "на носителе свободно $(mb "$free_kb") МБ, новому бэкапу нужно около $(mb "$estimate_kb") МБ (размер последнего). Освободите место на носителе или уменьшите $max_size_source, чтобы старые бэкапы удалялись раньше."
    fi
  fi
fi

[ ! -e "$final" ] && [ ! -e "$partial" ] || fail "каталог $name уже есть"
mkdir -- "$partial"
created_partial=1

# 1. База.
dc exec -T postgres sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc' \
  </dev/null >"$partial/db.dump" || fail "pg_dump не выполнился"

# 2. Том HA. Сценарий модуля передаётся python3 через stdin: в контейнер
# ничего не копируется. stdout — архив, stderr — число не отключённых
# записей реестра, посчитанное по тем же байтам, что легли в архив (HA
# переписывает реестр на ходу, второе чтение тома дало бы другую версию),
# и предупреждения модуля.
# Реестр сущностей обязателен: без него восстановленный HA не знает
# устройств, а манифест с нулём сделал бы проверку восстановления пустой.
archive_messages() { [ -z "$archive_err" ] || grep -v '^registry_enabled ' <<<"$archive_err" >&2 || true; }
archive_err="$(dc exec -T homeassistant python3 - archive /config \
  <ops/backup/ha_registry_check.py 2>&1 >"$partial/ha-config.tar.gz" | tr -d '\r')" \
  || { archive_messages; fail "архив тома HA не снят"; }
archive_messages
ha_enabled="$(sed -n 's/^registry_enabled //p' <<<"$archive_err")"
[[ "$ha_enabled" =~ ^[0-9]+$ ]] || fail "реестр сущностей HA: модуль архивации не вернул число"

# 3. Целостность до переименования. Дамп восстанавливается во временную
# базу того же postgres теми же флагами, что у restore.sh, и строки таблиц
# считаются по ней. Так числа манифеста описывают сам дамп: запрос к живой
# базе шёл бы в другой транзакции, и запись api между дампом и подсчётом
# развела бы манифест с дампом. Временная база удаляется и при отказе.
dc exec -T postgres pg_restore --list <"$partial/db.dump" >/dev/null \
  || fail "оглавление дампа не читается"
verify_db="domovoy_backup_verify_$(tr '[:upper:]' '[:lower:]' <<<"$stamp")"
# shellcheck disable=SC2016
dc exec -T postgres sh -c 'createdb -U "$POSTGRES_USER" -T template0 "$1"' sh "$verify_db" </dev/null \
  || fail "временная база для проверки дампа не создана"
created_verify_db=1
# shellcheck disable=SC2016
dc exec -T postgres sh -c 'pg_restore -U "$POSTGRES_USER" -d "$1" --no-owner --exit-on-error' sh "$verify_db" \
  <"$partial/db.dump" || fail "дамп не восстанавливается во временную базу"
# shellcheck disable=SC2016
table_counts="$(dc exec -T postgres sh -c \
  'psql -U "$POSTGRES_USER" -d "$1" -X -q -At -F " " -v ON_ERROR_STOP=1' sh "$verify_db" \
  <ops/backup/table-counts.sql | tr -d '\r')" || fail "подсчёт строк в таблицах дампа не выполнился"
drop_verify_db || fail "временная база $verify_db не удалена"
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
