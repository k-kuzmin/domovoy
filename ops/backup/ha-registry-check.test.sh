#!/usr/bin/env bash
# Тесты ops/backup/ha_registry_check.py на вымышленных фикстурах, без docker.
#
#   bash ops/backup/ha-registry-check.test.sh
#
# Интерпретатор — $PYTHON или python3. В фикстурах только вымышленные
# entity_id вида example_*, и тест следит, чтобы ни один из них не попал
# в вывод модуля: вывод уходит в лог CI и в комментарий issue.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
py="${PYTHON:-python3}"
module="$here/ha_registry_check.py"
registry="$here/fixtures/core.entity_registry.json"
states="$here/fixtures/states.json"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

passed=0
failed=0

ok() { echo "ok   $1"; passed=$((passed + 1)); }
fail() { echo "FAIL $1: $2"; failed=$((failed + 1)); }

# Запуск модуля: stdout и stderr в разные файлы, код — в $rc.
run() {
  "$py" "$module" "$@" >"$work/out" 2>"$work/err"
  rc=$?
}

no_entity_ids() {
  ! grep -q 'example_' "$work/out" "$work/err"
}

test_count_counts_only_enabled() {
  local name=registry_compare_counts_only_enabled_entities/count
  run count "$registry"
  if [ "$rc" -ne 0 ]; then fail "$name" "код $rc: $(cat "$work/err")"; return; fi
  if [ "$(cat "$work/out")" != "3" ]; then fail "$name" "ожидалось 3, получено «$(cat "$work/out")»"; return; fi
  no_entity_ids || { fail "$name" "в выводе есть entity_id"; return; }
  ok "$name"
}

test_compare_reports_missing_entity() {
  local name=registry_compare_counts_only_enabled_entities/missing
  run compare "$registry" "$states"
  if [ "$rc" -ne 1 ]; then fail "$name" "ожидался код 1, получен $rc"; return; fi
  grep -qx '2 из 3' "$work/out" || { fail "$name" "ожидалось «2 из 3», получено «$(cat "$work/out")»"; return; }
  no_entity_ids || { fail "$name" "в выводе есть entity_id"; return; }
  ok "$name"
}

test_compare_full_states_and_disabled_ignored() {
  local name=registry_compare_counts_only_enabled_entities/full
  # Полный ответ: недостающая включённая сущность добавлена, отключённых
  # в ответе нет — их отсутствие расхождения не даёт.
  "$py" - "$states" "$work/full.json" <<'EOF'
import json, sys
states = json.load(open(sys.argv[1], encoding="utf-8"))
states.append({"entity_id": "switch.example_kettle", "state": "off", "attributes": {}})
json.dump(states, open(sys.argv[2], "w", encoding="utf-8"))
EOF
  if grep -qE 'example_(humidity|night)' "$work/full.json"; then
    fail "$name" "в ответе состояний есть отключённая сущность — тест не проверяет то, что заявлено"; return
  fi
  run compare "$registry" "$work/full.json"
  if [ "$rc" -ne 0 ]; then fail "$name" "ожидался код 0, получен $rc: $(cat "$work/out" "$work/err")"; return; fi
  grep -qx '3 из 3' "$work/out" || { fail "$name" "ожидалось «3 из 3», получено «$(cat "$work/out")»"; return; }
  no_entity_ids || { fail "$name" "в выводе есть entity_id"; return; }

  # Тот же ответ со стандартного ввода — так его передаёт restore.sh.
  "$py" "$module" compare "$registry" - <"$work/full.json" >"$work/out" 2>"$work/err"
  rc=$?
  if [ "$rc" -ne 0 ] || ! grep -qx '3 из 3' "$work/out"; then
    fail "$name" "ответ со stdin: код $rc, вывод «$(cat "$work/out")»"; return
  fi
  ok "$name"
}

test_compare_expect_mismatch() {
  local name=registry_compare_counts_only_enabled_entities/expect
  # Реестр восстановленного тома сверяется ещё и с числом из манифеста:
  # HA, вычистивший записи на старте, не должен пройти «N из N» на остатке.
  run compare "$registry" "$work/full.json" --expect 4
  if [ "$rc" -ne 1 ]; then fail "$name" "ожидался код 1 при --expect 4, получен $rc"; return; fi
  run compare "$registry" "$work/full.json" --expect 3
  if [ "$rc" -ne 0 ]; then fail "$name" "ожидался код 0 при --expect 3, получен $rc"; return; fi
  ok "$name"
}

test_broken_registry_is_error() {
  local name=registry_check_fails_on_missing_or_broken_registry
  : >"$work/empty.json"
  echo '{"version": 1, "data": {}}' >"$work/no-entities.json"
  echo '{"data": {"entities": [' >"$work/truncated.json"
  local path
  for path in "$work/does-not-exist.json" "$work/empty.json" "$work/no-entities.json" "$work/truncated.json"; do
    run count "$path"
    if [ "$rc" -eq 0 ]; then fail "$name" "$(basename "$path"): код 0"; return; fi
    if grep -qE '^[0-9]+$' "$work/out"; then fail "$name" "$(basename "$path"): напечатано число вместо отказа"; return; fi
    [ -s "$work/err" ] || { fail "$name" "$(basename "$path"): отказ без сообщения"; return; }
    run compare "$path" "$states"
    if [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ]; then fail "$name" "$(basename "$path"): compare дал код $rc, ожидалась ошибка"; return; fi
  done
  ok "$name"
}

test_sqlite_backup_and_check() {
  local name=sqlite_online_copy_passes_integrity_check
  "$py" - "$work/live.db" <<'EOF'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("PRAGMA journal_mode=WAL")
c.execute("CREATE TABLE marker(v TEXT)")
c.execute("INSERT INTO marker VALUES ('example-marker')")
c.commit()
c.close()
EOF
  run sqlite-backup "$work/live.db" "$work/copy.db"
  if [ "$rc" -ne 0 ]; then fail "$name" "sqlite-backup: код $rc: $(cat "$work/err")"; return; fi
  if [ -e "$work/copy.db-wal" ] || [ -e "$work/copy.db-shm" ]; then fail "$name" "рядом с копией остались -wal/-shm"; return; fi
  run sqlite-check "$work/copy.db"
  if [ "$rc" -ne 0 ]; then fail "$name" "sqlite-check копии: код $rc"; return; fi

  printf 'это не база sqlite, а мусор достаточной длины для заголовка\n' >"$work/garbage.db"
  run sqlite-check "$work/garbage.db"
  if [ "$rc" -eq 0 ]; then fail "$name" "sqlite-check принял мусор"; return; fi
  run sqlite-check "$work/absent.db"
  if [ "$rc" -eq 0 ]; then fail "$name" "sqlite-check принял отсутствующий файл"; return; fi
  if [ -e "$work/absent.db" ]; then fail "$name" "sqlite-check создал отсутствующий файл"; return; fi
  ok "$name"
}

test_archive_roundtrip_with_live_wal() {
  local name=archive_snapshots_live_sqlite_and_restores
  # База в режиме WAL с незакрытым соединением и данными только в -wal —
  # ровно то, что лежит в томе работающего HA. Архив снимается, пока
  # соединение открыто.
  mkdir -p "$work/config/.storage" "$work/config/empty-dir"
  cp "$registry" "$work/config/.storage/core.entity_registry"
  echo 'example marker' >"$work/config/domovoy-marker.txt"
  echo 'log line' >"$work/config/home-assistant.log"

  if ! "$py" - "$work/config" "$module" "$work/archive.tar.gz" <<'EOF'
import os, sqlite3, subprocess, sys
config, module, archive = sys.argv[1:4]
for name in ("home-assistant_v2.db", "zigbee.db"):
    c = sqlite3.connect(os.path.join(config, name))
    c.execute("PRAGMA journal_mode=WAL")
    c.execute("PRAGMA wal_autocheckpoint=0")
    c.execute("CREATE TABLE marker(v TEXT)")
    c.execute("INSERT INTO marker VALUES ('example-marker')")
    c.commit()
    if name == "home-assistant_v2.db":
        live = c
    else:
        c.close()
assert os.path.getsize(os.path.join(config, "home-assistant_v2.db-wal")) > 0, "нет данных в -wal"
with open(archive, "wb") as out:
    rc = subprocess.run([sys.executable, module, "archive", config], stdout=out).returncode
live.close()
sys.exit(rc)
EOF
  then fail "$name" "archive вернул ненулевой код"; return; fi

  local listing
  listing="$(tar -tzf "$work/archive.tar.gz")" || { fail "$name" "архив не читается tar"; return; }
  local member
  for member in .storage/core.entity_registry home-assistant_v2.db zigbee.db domovoy-marker.txt empty-dir/; do
    grep -qxF "$member" <<<"$listing" || { fail "$name" "в архиве нет $member"; return; }
  done
  if grep -qE '(-wal|-shm|-journal)$|^home-assistant\.log' <<<"$listing"; then
    fail "$name" "в архиве есть -wal/-shm/-journal или лог HA"; return
  fi

  mkdir "$work/restored"
  "$py" "$module" extract "$work/restored" <"$work/archive.tar.gz" >"$work/out" 2>"$work/err"
  rc=$?
  if [ "$rc" -ne 0 ]; then fail "$name" "extract: код $rc: $(cat "$work/err")"; return; fi
  cmp -s "$work/config/domovoy-marker.txt" "$work/restored/domovoy-marker.txt" || { fail "$name" "файл-маркер не совпал"; return; }
  [ -d "$work/restored/empty-dir" ] || { fail "$name" "пустой каталог не восстановлен"; return; }
  local db value
  for db in home-assistant_v2.db zigbee.db; do
    run sqlite-check "$work/restored/$db"
    if [ "$rc" -ne 0 ]; then fail "$name" "$db: integrity_check не прошёл"; return; fi
    value="$("$py" -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute("SELECT v FROM marker").fetchone()[0])' "$work/restored/$db")"
    [ "$value" = 'example-marker' ] || { fail "$name" "$db: строки маркера нет"; return; }
  done
  run count "$work/restored/.storage/core.entity_registry"
  [ "$(cat "$work/out")" = "3" ] || { fail "$name" "реестр после распаковки: «$(cat "$work/out")»"; return; }

  # Распаковка в непустой каталог — отказ: восстановление не перезаписывает.
  "$py" "$module" extract "$work/restored" <"$work/archive.tar.gz" >"$work/out" 2>"$work/err"
  rc=$?
  if [ "$rc" -eq 0 ]; then fail "$name" "extract в непустой каталог прошёл"; return; fi
  ok "$name"
}

test_count_counts_only_enabled
test_compare_reports_missing_entity
test_compare_full_states_and_disabled_ignored
test_compare_expect_mismatch
test_broken_registry_is_error
test_sqlite_backup_and_check
test_archive_roundtrip_with_live_wal

echo "итог: пройдено $passed, упало $failed"
[ "$failed" -eq 0 ]
