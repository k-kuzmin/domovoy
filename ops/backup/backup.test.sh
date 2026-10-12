#!/usr/bin/env bash
# Регрессионный сценарий бэкапа и восстановления.
#
#   bash ops/backup/backup.test.sh            # все тесты, нужен docker
#   bash ops/backup/backup.test.sh --static   # только тесты без docker
#
# Нужны .env и config/* из примеров в корне клона (как в работе CI
# «Бэкап и восстановление»). Стек поднимается отдельными проектами compose
# с собственными именами и портами — рабочий проект не затрагивается:
#   BACKUP_TEST_PROJECT   — исходный стек (domovoy-bt-src);
#   domovoy-bt-check      — проверочный проект restore.sh --check;
#   domovoy-bt-fresh      — проект восстановления restore.sh --project.
# Все три обязаны быть пустыми на старте; тест удаляет их вместе с томами
# в конце. Порты на хосте — BACKUP_TEST_API_PORT/BACKUP_TEST_HA_PORT и на
# 10000 больше для проекта восстановления.

set -uo pipefail
export MSYS_NO_PATHCONV=1

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
root="$(cd "$here/../.." && pwd -P)"
cd "$root" || exit 1

static_only=0
[ "${1:-}" = '--static' ] && static_only=1

src_project="${BACKUP_TEST_PROJECT:-domovoy-bt-src}"
check_project='domovoy-bt-check'
fresh_project='domovoy-bt-fresh'
api_port="${BACKUP_TEST_API_PORT:-28080}"
ha_port="${BACKUP_TEST_HA_PORT:-28123}"
fresh_api_port=$((api_port + 10000))
fresh_ha_port=$((ha_port + 10000))

for name in "$src_project" "$check_project" "$fresh_project"; do
  case "$name" in
    domovoy | domovoy-restore-check)
      echo "backup.test: проект $name — рабочий или проверочный проект владельца, тест его не трогает" >&2
      exit 2
      ;;
  esac
done

export COMPOSE_PROJECT_NAME="$src_project"
export API_HTTP_PORT="$api_port"
export HA_HTTP_PORT="$ha_port"
export RESTORE_CHECK_PROJECT="$check_project"

registry_fixture="$here/fixtures/core.entity_registry.json"
# Число не отключённых записей фикстуры известно заранее (python на хосте
# не обязателен). HA на старте добавляет к ним сущности встроенных
# интеграций, поэтому ожидаемое число в манифесте — expected_ha — берётся
# из живого реестра после засева, а не из фикстуры.
fixture_enabled=3
expected_ha=''
marker="example-marker-$$-$RANDOM"

work="$(mktemp -d)"
created_backups_dir=0
stack_started=0
artifacts=()

cleanup() {
  local path
  for path in "${artifacts[@]}"; do rm -rf -- "$root/$path"; done
  if [ "$created_backups_dir" -eq 1 ]; then rm -rf -- "$root/backups"; fi
  if [ "$stack_started" -eq 1 ]; then
    local project
    for project in "$src_project" "$check_project" "$fresh_project"; do
      docker compose -p "$project" -f docker-compose.yml --profile ha down -v --remove-orphans \
        </dev/null >/dev/null 2>&1 || true
    done
  fi
  rm -rf -- "$work"
}
trap cleanup EXIT

passed=0
failed=0
skipped=0
ok() { echo "ok   $1"; passed=$((passed + 1)); }
fail() { echo "FAIL $1: $2"; failed=$((failed + 1)); }
skip() { echo "skip $1: $2"; skipped=$((skipped + 1)); }

# Запуск сценария: вывод в $work/out, код — в $rc.
run() {
  "$@" >"$work/out" 2>&1 </dev/null
  rc=$?
}

show_out() { sed 's/^/    | /' "$work/out" | tail -n 15; }

dcs() { docker compose -p "$src_project" -f docker-compose.yml --profile ha "$@"; }

psql_in() {
  local project="$1"
  shift
  docker compose -p "$project" -f docker-compose.yml --profile ha exec -T postgres sh -c \
    'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -X -q -At -v ON_ERROR_STOP=1 "$@"' psql "$@" | tr -d '\r'
}

project_volumes() {
  docker volume ls -q --filter "label=com.docker.compose.project=$1"
}

# ------------------------------------------------------------------
# Без docker
# ------------------------------------------------------------------

test_backup_artifacts_are_ignored_in_tree() {
  local name=backup_artifacts_are_ignored_in_tree
  local samples=(db.dump ha-config.tar.gz backup.log domovoy-backup-20260101T000000Z)
  local path
  for path in "${samples[@]}"; do
    if [ -e "$root/$path" ]; then fail "$name" "$path уже лежит в корне клона"; return; fi
  done
  artifacts+=("${samples[@]}")
  : >"$root/db.dump"
  : >"$root/ha-config.tar.gz"
  : >"$root/backup.log"
  mkdir "$root/domovoy-backup-20260101T000000Z"
  : >"$root/domovoy-backup-20260101T000000Z/manifest.txt"

  local status
  status="$(git status --ignored --porcelain -- "${samples[@]}")"
  rm -rf -- "${samples[@]/#/$root/}"
  for path in db.dump ha-config.tar.gz backup.log domovoy-backup-20260101T000000Z/; do
    if ! grep -qxF "!! $path" <<<"$status"; then
      fail "$name" "$path не игнорируется: $(grep -F "$path" <<<"$status" || echo 'нет в выводе')"
      return
    fi
  done
  if grep -q '^??' <<<"$status"; then fail "$name" "есть неотслеживаемые: $status"; return; fi
  ok "$name"
}

# Поддельный docker первым в PATH: отказ обязан случиться до первого
# docker-вызова, и подделка это фиксирует.
fake_docker_path() {
  mkdir -p "$work/fakebin"
  cat >"$work/fakebin/docker" <<EOF
#!/usr/bin/env bash
echo called >>"$work/docker-called"
exit 1
EOF
  chmod +x "$work/fakebin/docker"
  echo "$work/fakebin:$PATH"
}

test_backup_refuses_destination_inside_repository() {
  local name=backup_refuses_destination_inside_repository
  if [ ! -e "$root/backups" ]; then
    mkdir "$root/backups"
    created_backups_dir=1
  fi
  local fake_path
  fake_path="$(fake_docker_path)"
  rm -f "$work/docker-called"

  local forms=("$root/backups" "/tmp/..$root/backups" "$root/backups/../backups" "$root")
  if ln -s "$root/backups" "$work/link-into-repo" 2>/dev/null && [ -L "$work/link-into-repo" ]; then
    forms+=("$work/link-into-repo")
  else
    rm -rf -- "$work/link-into-repo"
    skip "$name/symlink" "симлинки в этом окружении недоступны (Git Bash без winsymlinks)"
  fi
  if command -v cygpath >/dev/null 2>&1; then
    forms+=("$(cygpath -w "$root/backups")")
    # Регистр букв: на Windows путь в другом регистре — тот же каталог.
    forms+=("$(cygpath -w "$root/backups" | tr '[:lower:]' '[:upper:]')")
  else
    skip "$name/windows" "пропущен: нет cygpath"
  fi

  local before form
  before="$(ls -A "$root/backups")"
  for form in "${forms[@]}"; do
    PATH="$fake_path" run bash ops/backup/backup.sh "$form"
    if [ "$rc" -eq 0 ]; then fail "$name" "принят каталог «$form»"; return; fi
    if ! grep -q 'внутри репозитория' "$work/out"; then
      fail "$name" "«$form»: отказ не по той причине"; show_out; return
    fi
  done
  if [ -e "$work/docker-called" ]; then fail "$name" "docker вызывался до отказа"; return; fi
  if [ "$(ls -A "$root/backups")" != "$before" ]; then fail "$name" "в backups/ что-то создано"; return; fi
  ok "$name"
}

test_backup_refuses_missing_destination() {
  local name=backup_refuses_missing_destination
  local fake_path
  fake_path="$(fake_docker_path)"
  rm -f "$work/docker-called"
  mkdir "$work/usb"
  PATH="$fake_path" run bash ops/backup/backup.sh "$work/usb/not-connected"
  if [ "$rc" -eq 0 ]; then fail "$name" "код 0"; return; fi
  if [ -e "$work/usb/not-connected" ]; then fail "$name" "каталог назначения создан"; return; fi
  if [ -n "$(find "$work" -name '*.partial' -print -quit)" ]; then fail "$name" "появился .partial"; return; fi
  if [ -e "$work/docker-called" ]; then fail "$name" "docker вызывался"; return; fi
  ok "$name"
}

# Каталог бэкапа с правильной формой, но без данных: отказ обязан случиться
# раньше, чем что-то из него читается в контейнеры.
fake_backup_dir() {
  mkdir -p "$1"
  : >"$1/db.dump"
  : >"$1/ha-config.tar.gz"
  printf 'format 1\nha_registry_enabled 3\n' >"$1/manifest.txt"
}

test_restore_refuses_manifest_without_ha_count() {
  local name=restore_refuses_manifest_without_ha_count
  fake_backup_dir "$work/no-ha-count"
  printf 'format 1\ndb_table public.example 1\n' >"$work/no-ha-count/manifest.txt"
  run bash ops/backup/restore.sh --from "$work/no-ha-count" --check
  if [ "$rc" -eq 0 ]; then fail "$name" "код 0"; return; fi
  grep -q 'в манифесте нет числа сущностей HA' "$work/out" || { fail "$name" "отказ без названной причины"; show_out; return; }
  ok "$name"
}

test_restore_project_refuses_while_other_ha_runs_static() {
  local name=restore_project_refuses_while_other_ha_runs/static
  # Подделка docker: работает homeassistant проекта example-other, всё
  # остальное пусто; любой docker compose — отметка в журнале и отказ.
  mkdir -p "$work/fakebin-ha"
  cat >"$work/fakebin-ha/docker" <<EOF
#!/usr/bin/env bash
case "\$*" in
  info*) exit 0 ;;
  compose*) echo compose >>"$work/compose-called"; exit 1 ;;
  *com.docker.compose.service=homeassistant*) echo example-other ;;
esac
exit 0
EOF
  chmod +x "$work/fakebin-ha/docker"
  fake_backup_dir "$work/fake-backup"
  rm -f "$work/compose-called"
  PATH="$work/fakebin-ha:$PATH" run bash ops/backup/restore.sh --from "$work/fake-backup" --project example-fresh
  if [ "$rc" -eq 0 ]; then fail "$name" "код 0 при работающем HA другого проекта"; return; fi
  grep -q 'работает Home Assistant проекта example-other' "$work/out" || { fail "$name" "отказ не по работающему HA"; show_out; return; }
  grep -qF 'docker compose -p example-other --profile ha down (без -v)' "$work/out" || { fail "$name" "нет команды остановки без -v"; show_out; return; }
  if [ -e "$work/compose-called" ]; then fail "$name" "docker compose вызывался до отказа"; return; fi

  # --check рядом с работающим HA — штатный режим, этот отказ его не трогает.
  PATH="$work/fakebin-ha:$PATH" run bash ops/backup/restore.sh --from "$work/fake-backup" --check
  if grep -q 'работает Home Assistant проекта' "$work/out"; then fail "$name" "--check отказал по работающему HA"; return; fi
  ok "$name"
}

# ------------------------------------------------------------------
# С docker
# ------------------------------------------------------------------

start_source_stack() {
  local project
  for project in "$src_project" "$check_project" "$fresh_project"; do
    if [ -n "$(docker ps -aq --filter "label=com.docker.compose.project=$project")" ] \
      || [ -n "$(project_volumes "$project")" ]; then
      echo "backup.test: проект $project не пуст — тест его не трогает: docker compose -p $project down -v" >&2
      return 1
    fi
  done
  [ -f .env ] || { echo "backup.test: нет .env — cp .env.example .env" >&2; return 1; }
  stack_started=1

  # Реестр, файл-маркер и минимальный configuration.yaml — до первого
  # старта HA, в его собственный том. Без configuration.yaml HA пишет свой
  # с default_config и тянет десятки интеграций; минимальный набор держит
  # реестр маленьким. recorder даёт живую базу home-assistant_v2.db, api —
  # /api/ для проверки старта.
  dcs run --rm --no-deps -T --entrypoint sh homeassistant -c \
    "mkdir -p /config/.storage && cat >/config/.storage/core.entity_registry \
      && echo '$marker' >/config/domovoy-marker.txt \
      && printf 'homeassistant:\n  name: Example Home\nrecorder:\napi:\n' >/config/configuration.yaml" \
    <"$registry_fixture" || return 1

  dcs up -d --build --wait --wait-timeout 300 </dev/null || return 1

  # HA отвечает на /api/ (401 без токена) — старт пройден, рекордер создан.
  local deadline=$((SECONDS + 300)) code=''
  while :; do
    code="$(dcs exec -T homeassistant curl -s -o /dev/null -w '%{http_code}' http://localhost:8123/api/ </dev/null | tr -d '\r')"
    if [ "$code" = '401' ] && dcs exec -T homeassistant test -f /config/home-assistant_v2.db </dev/null; then break; fi
    [ "$SECONDS" -lt "$deadline" ] || { echo "backup.test: HA не стартовал за 300 с" >&2; return 1; }
    sleep 5
  done

  # Маркер в живой базе рекордера — пишется, пока HA работает.
  dcs exec -T homeassistant python3 - "$marker" <<'EOF' || return 1
import sqlite3, sys
c = sqlite3.connect("/config/home-assistant_v2.db", timeout=60)
c.execute("CREATE TABLE IF NOT EXISTS domovoy_marker(v TEXT)")
c.execute("INSERT INTO domovoy_marker VALUES (?)", (sys.argv[1],))
c.commit()
c.close()
EOF

  psql_in "$src_project" <<SQL || return 1
CREATE TABLE domovoy_marker(v text);
INSERT INTO domovoy_marker VALUES ('$marker');
SQL
}

registry_count_in() {
  local project="$1"
  docker compose -p "$project" -f docker-compose.yml --profile ha exec -T homeassistant \
    python3 - count /config/.storage/core.entity_registry <"$here/ha_registry_check.py" | tr -d '\r'
}

single_backup_in() {
  local dir="$1" found=()
  local entry
  for entry in "$dir"/domovoy-backup-*; do
    [[ "${entry##*/}" =~ ^domovoy-backup-[0-9]{8}T[0-9]{6}Z$ ]] && found+=("$entry")
  done
  [ "${#found[@]}" -eq 1 ] && echo "${found[0]}"
}

test_seeded_registry_survives_ha_start() {
  local name=ha_registry_and_recorder_survive_backup/seed
  # HA сохраняет реестр с задержкой и на старте добавляет сущности своих
  # встроенных интеграций (backup). Число берётся, когда оно перестало
  # меняться: три одинаковых чтения подряд с шагом 5 с.
  local count='' previous='' same=0 deadline=$((SECONDS + 180))
  while [ "$same" -lt 3 ]; do
    [ "$SECONDS" -lt "$deadline" ] || { fail "$name" "реестр не успокоился за 180 с"; return 1; }
    sleep 5
    count="$(registry_count_in "$src_project")"
    if [ -n "$count" ] && [ "$count" = "$previous" ]; then same=$((same + 1)); else same=1; fi
    previous="$count"
  done
  # Засеянные записи пережили старт: каждая включённая запись фикстуры есть
  # в живом реестре и не отключена. Иначе тест проверял бы чужие сущности.
  local missing
  missing="$(docker compose -p "$src_project" -f docker-compose.yml --profile ha exec -T homeassistant \
    python3 -c '
import json, sys
fixture = json.load(sys.stdin)["data"]["entities"]
live = json.load(open("/config/.storage/core.entity_registry"))["data"]["entities"]
enabled = {e["entity_id"] for e in live if e.get("disabled_by") is None}
print(sum(1 for e in fixture if e.get("disabled_by") is None and e["entity_id"] not in enabled))
' <"$registry_fixture" | tr -d '\r')"
  if [ "$missing" != '0' ]; then
    fail "$name" "после старта HA из фикстуры пропало включённых записей: «$missing»"
    return 1
  fi
  if ! [[ "$count" =~ ^[0-9]+$ ]] || [ "$count" -lt "$fixture_enabled" ]; then
    fail "$name" "в живом реестре «$count» не отключённых записей, в фикстуре $fixture_enabled"
    return 1
  fi
  expected_ha="$count"
  ok "$name"
}

test_backup_creates_complete_backup() {
  local name=ha_registry_and_recorder_survive_backup/backup
  mkdir "$work/dest"
  # Писатель в базу на всё время бэкапа — как api, который пишет, пока
  # снимается дамп. Числа манифеста обязаны описывать дамп, иначе
  # restore.sh --check ниже откажет при исправном восстановлении. Писатель
  # ограничен флагом и числом итераций: убийство docker compose exec на
  # хосте сессию в контейнере не останавливает.
  psql_in "$src_project" <<'SQL' || { fail "$name" "таблицы писателя не созданы"; return 1; }
CREATE TABLE domovoy_churn(v int);
CREATE TABLE domovoy_churn_stop(v int);
SQL
  psql_in "$src_project" >/dev/null 2>&1 <<'SQL' &
DO $$
BEGIN
  FOR i IN 1..20000 LOOP
    EXIT WHEN EXISTS (SELECT 1 FROM domovoy_churn_stop);
    INSERT INTO domovoy_churn VALUES (i);
    COMMIT;
    PERFORM pg_sleep(0.01);
  END LOOP;
END
$$;
SQL
  local writer=$! churn_live='' deadline=$((SECONDS + 60))
  until [ "$(psql_in "$src_project" -c 'SELECT count(*) > 0 FROM domovoy_churn')" = t ]; do
    [ "$SECONDS" -lt "$deadline" ] || { fail "$name" "писатель не начал писать"; return 1; }
    sleep 1
  done
  run bash ops/backup/backup.sh "$work/dest"
  local backup_rc=$rc
  psql_in "$src_project" -c 'INSERT INTO domovoy_churn_stop VALUES (1)' >/dev/null
  wait "$writer"
  churn_live="$(psql_in "$src_project" -c 'SELECT count(*) FROM domovoy_churn')"
  rc=$backup_rc
  if [ "$rc" -ne 0 ]; then fail "$name" "backup.sh: код $rc"; show_out; return 1; fi
  backup="$(single_backup_in "$work/dest")" || { fail "$name" "ровно одного полного бэкапа нет"; return 1; }
  # Писатель действительно писал во время бэкапа и после дампа: иначе тест
  # не проверяет расхождение живой базы с дампом.
  local churn_dumped
  churn_dumped="$(sed -n 's/^db_table public\.domovoy_churn \([0-9]*\)$/\1/p' "$backup/manifest.txt")"
  if ! [[ "$churn_dumped" =~ ^[0-9]+$ ]] || [ "$churn_dumped" -eq 0 ] || [ "$churn_live" -le "$churn_dumped" ]; then
    fail "$name" "писатель не писал во время бэкапа: в манифесте «$churn_dumped», в живой базе «$churn_live»"; return 1
  fi
  grep -qx 'db_table public.domovoy_marker 1' "$backup/manifest.txt" \
    || { fail "$name" "в манифесте нет строки маркерной таблицы"; return 1; }
  grep -qx "ha_registry_enabled $expected_ha" "$backup/manifest.txt" \
    || { fail "$name" "в манифесте не $expected_ha сущностей: $(grep '^ha_registry_enabled' "$backup/manifest.txt")"; return 1; }
  local listing
  listing="$(tar -tzf "$backup/ha-config.tar.gz")"
  if grep -qE '(-wal|-shm)$' <<<"$listing"; then fail "$name" "в архиве -wal/-shm"; return 1; fi
  grep -qxF 'domovoy-marker.txt' <<<"$listing" || { fail "$name" "в архиве нет файла-маркера"; return 1; }
  grep -q 'успех' "$work/dest/backup.log" || { fail "$name" "в backup.log нет строки успеха"; return 1; }
  if grep -qE 'example_|Bearer|Password=' "$work/dest/backup.log" "$work/out" "$backup/manifest.txt"; then
    fail "$name" "в выводе, логе или манифесте entity_id или секрет"; return 1
  fi
  ok "$name"
}

test_markers_survive_backup_and_restore_check() {
  local name=markers_survive_backup_and_restore_check
  run bash ops/backup/restore.sh --from "$backup" --check --ha-api-check skip --keep
  if [ "$rc" -ne 0 ]; then fail "$name" "restore.sh --check: код $rc"; show_out; return; fi
  grep -q 'проверка HA API пропущена' "$work/out" \
    || { fail "restore_check_reports_skipped_ha_api" "нет строки о пропуске"; }

  local value file count recorder
  value="$(psql_in "$check_project" -c 'SELECT v FROM domovoy_marker')"
  [ "$value" = "$marker" ] || { fail "$name" "маркерная строка БД: «$value»"; return; }
  file="$(docker compose -p "$check_project" -f docker-compose.yml --profile ha exec -T homeassistant \
    cat /config/domovoy-marker.txt </dev/null | tr -d '\r')"
  [ "$file" = "$marker" ] || { fail "$name" "файл-маркер в томе HA: «$file»"; return; }
  count="$(registry_count_in "$check_project")"
  [ "$count" = "$expected_ha" ] || { fail "$name" "реестр в восстановленном томе: «$count»"; return; }
  recorder="$(docker compose -p "$check_project" -f docker-compose.yml --profile ha exec -T homeassistant \
    python3 - <<'EOF' | tr -d '\r'
import sqlite3
c = sqlite3.connect("/config/home-assistant_v2.db", timeout=60)
print(c.execute("PRAGMA integrity_check").fetchone()[0], c.execute("SELECT v FROM domovoy_marker").fetchone()[0])
EOF
  )"
  [ "$recorder" = "ok $marker" ] || { fail "$name" "рекордер в восстановленном томе: «$recorder»"; return; }

  docker compose -p "$check_project" -f docker-compose.yml --profile ha down -v </dev/null >/dev/null 2>&1
  ok "$name"
  ok "ha_registry_and_recorder_survive_backup"
}

elapsed_lines() { grep -cE '^восстановление и проверки: [0-9]+ мин [0-9]+ с$' "$work/out" || true; }

test_restore_check_prints_elapsed_time() {
  local name=restore_check_prints_elapsed_time
  run bash ops/backup/restore.sh --from "$backup" --check --ha-api-check skip
  if [ "$rc" -ne 0 ]; then fail "$name" "код $rc"; show_out; return; fi
  [ "$(elapsed_lines)" = 1 ] || { fail "$name" "строк замера: $(elapsed_lines)"; show_out; return; }
  if [ -n "$(project_volumes "$check_project")" ]; then fail "$name" "тома проверочного проекта не удалены"; return; fi
  ok "$name"
  ok "restore_check_reports_skipped_ha_api/skip"
}

test_restore_check_fails_on_manifest_mismatch() {
  local name=restore_check_fails_on_manifest_mismatch
  cp -R "$backup" "$work/mismatch"
  sed -i 's/^db_table public.domovoy_marker 1$/db_table public.domovoy_marker 2/' "$work/mismatch/manifest.txt"
  grep -qx 'db_table public.domovoy_marker 2' "$work/mismatch/manifest.txt" || { fail "$name" "подмена манифеста не удалась"; return; }
  run bash ops/backup/restore.sh --from "$work/mismatch" --check --ha-api-check skip
  if [ "$rc" -eq 0 ]; then fail "$name" "код 0 на подменённом манифесте"; return; fi
  grep -q 'public.domovoy_marker' "$work/out" || { fail "$name" "расходящаяся таблица не названа"; show_out; return; }
  [ "$(elapsed_lines)" = 0 ] || { fail "restore_check_prints_elapsed_time/failure" "строка замера на отказе"; return; }
  if [ -n "$(project_volumes "$check_project")" ]; then fail "$name" "тома проверочного проекта остались после отказа"; return; fi
  ok "$name"
  ok "restore_check_prints_elapsed_time/failure"
}

test_restore_check_fails_on_missing_marker() {
  local name=restore_check_fails_on_missing_marker
  cp -R "$backup" "$work/no-marker"
  # Дамп той же базы без маркерной строки; манифест — исходный.
  psql_in "$src_project" -c 'DELETE FROM domovoy_marker' >/dev/null
  dcs exec -T postgres sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc' </dev/null >"$work/no-marker/db.dump"
  psql_in "$src_project" -c "INSERT INTO domovoy_marker VALUES ('$marker')" >/dev/null
  run bash ops/backup/restore.sh --from "$work/no-marker" --check --ha-api-check skip
  if [ "$rc" -eq 0 ]; then fail "$name" "код 0 на дампе без маркера"; return; fi
  grep -q 'public.domovoy_marker' "$work/out" || { fail "$name" "расхождение не названо"; show_out; return; }
  ok "$name"
}

test_restore_check_requires_ha_api_by_default() {
  local name=restore_check_reports_skipped_ha_api/required
  # Токен в .env из примера — плейсхолдер: восстановленный HA его не примет,
  # и проверка по умолчанию обязана упасть, а не пропуститься молча.
  run bash ops/backup/restore.sh --from "$backup" --check --keep
  local kept_rc=$rc
  # Реестр, с которым сверяются состояния, — из бэкапа, а не тот, что HA
  # переписал на старте: в контейнере лежит побайтно член архива.
  local same_registry=no
  if docker compose -p "$check_project" -f docker-compose.yml --profile ha exec -T homeassistant \
    cat /tmp/registry.backup.json </dev/null \
    | cmp -s - <(tar -xzOf "$backup/ha-config.tar.gz" .storage/core.entity_registry); then
    same_registry=yes
  fi
  docker compose -p "$check_project" -f docker-compose.yml --profile ha down -v --remove-orphans </dev/null >/dev/null 2>&1
  rc=$kept_rc
  if [ "$rc" -eq 0 ]; then fail "$name" "код 0 без флага на токене-плейсхолдере"; show_out; return; fi
  if grep -q 'пропущена' "$work/out"; then fail "$name" "проверка пропущена без флага"; return; fi
  grep -q 'токен из окружения api не принят' "$work/out" \
    || { fail "$name" "отказ не по токену"; show_out; return; }
  ok "$name"
  if [ "$same_registry" = yes ]; then
    ok "restore_compares_states_with_backup_registry"
  else
    fail "restore_compares_states_with_backup_registry" "в контейнере HA нет реестра из бэкапа"
  fi
}

test_restore_project_refuses_while_other_ha_runs() {
  local name=restore_project_refuses_while_other_ha_runs
  # Работает HA исходного проекта — восстановление в другой проект
  # отказывает и ничего не создаёт.
  API_HTTP_PORT="$fresh_api_port" HA_HTTP_PORT="$fresh_ha_port" \
    run bash ops/backup/restore.sh --from "$backup" --project "$fresh_project" --ha-api-check skip
  if [ "$rc" -eq 0 ]; then fail "$name" "код 0 при работающем HA проекта $src_project"; return; fi
  grep -q "работает Home Assistant проекта $src_project" "$work/out" || { fail "$name" "отказ не по работающему HA"; show_out; return; }
  if [ -n "$(docker ps -aq --filter "label=com.docker.compose.project=$fresh_project")" ] \
    || [ -n "$(project_volumes "$fresh_project")" ]; then
    fail "$name" "в проекте $fresh_project что-то создано до отказа"; return
  fi
  ok "$name"
}

test_restore_into_fresh_project_restores_markers() {
  local name=restore_into_fresh_project_restores_markers
  # Рядом с работающим HA --project отказывает, поэтому HA исходного
  # проекта останавливается. HA вне тестовых проектов (рабочий стек
  # владельца на его машине) тест не трогает — тогда он пропускается.
  dcs stop homeassistant </dev/null >/dev/null 2>&1 || { fail "$name" "HA проекта $src_project не остановлен"; return; }
  local running others
  running="$(docker ps --filter 'label=com.docker.compose.service=homeassistant' \
    --format '{{.Label "com.docker.compose.project"}}' | tr -d '\r' | sort -u)"
  if grep -qxF -e "$src_project" -e "$check_project" -e "$fresh_project" <<<"$running"; then
    fail "$name" "работает HA тестового проекта: $(tr '\n' ' ' <<<"$running")"; return
  fi
  # Пропуск — только из-за HA вне трёх тестовых проектов.
  others="$running"
  if [ -n "$others" ]; then
    skip "$name" "на хосте работает HA проекта $(tr '\n' ' ' <<<"$others")— восстановление в проект рядом с ним запрещено, тест его не останавливает"
    return
  fi
  API_HTTP_PORT="$fresh_api_port" HA_HTTP_PORT="$fresh_ha_port" \
    run bash ops/backup/restore.sh --from "$backup" --project "$fresh_project" --ha-api-check skip
  if [ "$rc" -ne 0 ]; then fail "$name" "код $rc"; show_out; return; fi
  local value file
  value="$(psql_in "$fresh_project" -c 'SELECT v FROM domovoy_marker')"
  [ "$value" = "$marker" ] || { fail "$name" "маркерная строка БД: «$value»"; return; }
  file="$(docker compose -p "$fresh_project" -f docker-compose.yml --profile ha exec -T homeassistant \
    cat /config/domovoy-marker.txt </dev/null | tr -d '\r')"
  [ "$file" = "$marker" ] || { fail "$name" "файл-маркер в томе HA: «$file»"; return; }

  psql_in "$fresh_project" -c "UPDATE domovoy_marker SET v = 'changed-after-restore'" >/dev/null
  API_HTTP_PORT="$fresh_api_port" HA_HTTP_PORT="$fresh_ha_port" \
    run bash ops/backup/restore.sh --from "$backup" --project "$fresh_project" --ha-api-check skip
  if [ "$rc" -eq 0 ]; then fail "$name" "повтор в поднятый проект прошёл"; return; fi
  value="$(psql_in "$fresh_project" -c 'SELECT v FROM domovoy_marker')"
  [ "$value" = 'changed-after-restore' ] || { fail "$name" "данные поднятого проекта перезаписаны: «$value»"; return; }

  docker compose -p "$fresh_project" -f docker-compose.yml --profile ha stop </dev/null >/dev/null 2>&1
  API_HTTP_PORT="$fresh_api_port" HA_HTTP_PORT="$fresh_ha_port" \
    run bash ops/backup/restore.sh --from "$backup" --project "$fresh_project" --ha-api-check skip
  if [ "$rc" -eq 0 ]; then fail "$name" "повтор в остановленный проект с томами прошёл"; return; fi
  ok "$name"
}

old_backups=(domovoy-backup-20200101T000000Z domovoy-backup-20200102T000000Z domovoy-backup-20200103T000000Z)

test_backup_fails_without_entity_registry() {
  local name=backup_fails_without_entity_registry
  mkdir "$work/rotation"
  local dir
  for dir in "${old_backups[@]}" domovoy-backup-20200104T000000Z.partial foreign-dir; do
    mkdir "$work/rotation/$dir"
    : >"$work/rotation/$dir/keep-me"
  done
  dcs exec -T homeassistant mv /config/.storage/core.entity_registry /config/.storage/core.entity_registry.bt-aside </dev/null
  run bash ops/backup/backup.sh "$work/rotation" --keep 1
  dcs exec -T homeassistant mv /config/.storage/core.entity_registry.bt-aside /config/.storage/core.entity_registry </dev/null
  if [ "$rc" -eq 0 ]; then fail "$name" "код 0 без реестра"; return; fi
  grep -q 'реестр сущностей HA' "$work/out" || { fail "$name" "отказ не по реестру"; show_out; return; }
  local entries
  entries="$(ls -A "$work/rotation" | grep -v '^backup.log$' | sort | tr '\n' ' ')"
  if [ "$entries" != "domovoy-backup-20200101T000000Z domovoy-backup-20200102T000000Z domovoy-backup-20200103T000000Z domovoy-backup-20200104T000000Z.partial foreign-dir " ]; then
    fail "$name" "после отказа в каталоге: $entries"; return
  fi
  ok "$name"
  ok "rotation_keeps_foreign_and_partial_directories/failure"
}

test_rotation_keeps_foreign_and_partial_directories() {
  local name=rotation_keeps_foreign_and_partial_directories
  run bash ops/backup/backup.sh "$work/rotation" --keep 2
  if [ "$rc" -ne 0 ]; then fail "$name" "код $rc"; show_out; return; fi
  local complete=() entry
  for entry in "$work/rotation"/domovoy-backup-*; do
    [[ "${entry##*/}" =~ ^domovoy-backup-[0-9]{8}T[0-9]{6}Z$ ]] && complete+=("${entry##*/}")
  done
  if [ "${#complete[@]}" -ne 2 ] || [ "${complete[0]}" != 'domovoy-backup-20200103T000000Z' ]; then
    fail "$name" "остались полные: ${complete[*]}"; return
  fi
  [ -f "$work/rotation/domovoy-backup-20200104T000000Z.partial/keep-me" ] || { fail "$name" "чужой .partial тронут"; return; }
  [ -f "$work/rotation/foreign-dir/keep-me" ] || { fail "$name" "посторонний каталог тронут"; return; }
  ok "$name"
}

# ------------------------------------------------------------------

test_backup_artifacts_are_ignored_in_tree
test_backup_refuses_destination_inside_repository
test_backup_refuses_missing_destination
test_restore_project_refuses_while_other_ha_runs_static
test_restore_refuses_manifest_without_ha_count

if [ "$static_only" -eq 0 ]; then
  tree_before="$(git status --porcelain --ignored)"
  if ! start_source_stack; then
    fail "start_source_stack" "исходный стек не поднят"
  elif test_seeded_registry_survives_ha_start && test_backup_creates_complete_backup; then
    test_markers_survive_backup_and_restore_check
    test_restore_check_prints_elapsed_time
    test_restore_check_fails_on_manifest_mismatch
    test_restore_check_fails_on_missing_marker
    test_restore_check_requires_ha_api_by_default
    test_restore_project_refuses_while_other_ha_runs
    test_backup_fails_without_entity_registry
    test_rotation_keeps_foreign_and_partial_directories
    # Последним: останавливает HA исходного проекта.
    test_restore_into_fresh_project_restores_markers
  fi
  tree_after="$(git status --porcelain --ignored)"
  if [ "$tree_before" = "$tree_after" ]; then
    ok working_tree_unchanged_after_backup_and_restore
  else
    fail working_tree_unchanged_after_backup_and_restore "дерево клона изменилось"
    diff <(echo "$tree_before") <(echo "$tree_after") | sed 's/^/    | /'
  fi
fi

echo "итог: пройдено $passed, упало $failed, пропущено $skipped"
[ "$failed" -eq 0 ]
