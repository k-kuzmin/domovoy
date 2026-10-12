#!/usr/bin/env bash
# Тесты ops/backup/ha_registry_check.py на вымышленных фикстурах, без docker.
#
#   bash ops/backup/ha-registry-check.test.sh
#
# Интерпретатор — $PYTHON или python3. В фикстурах только вымышленные
# entity_id вида example_*, и тест следит, чтобы ни один из них не попал
# в вывод модуля: вывод уходит в лог CI и в комментарий issue.

set -uo pipefail
# Тесты импортируют модуль из клона: без этого рядом с ним остаётся __pycache__.
export PYTHONDONTWRITEBYTECODE=1

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
py="${PYTHON:-python3}"
module="$here/ha_registry_check.py"
registry="$here/fixtures/core.entity_registry.json"
states="$here/fixtures/states.json"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

passed=0
failed=0
skipped=0

ok() { echo "ok   $1"; passed=$((passed + 1)); }
fail() { echo "FAIL $1: $2"; failed=$((failed + 1)); }
skip() { echo "skip $1: $2"; skipped=$((skipped + 1)); }

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

  if ! "$py" - "$work/config" "$module" "$work/archive.tar.gz" "$work/archive.err" <<'EOF'
import os, sqlite3, subprocess, sys
config, module, archive, errlog = sys.argv[1:5]
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
with open(archive, "wb") as out, open(errlog, "wb") as err:
    rc = subprocess.run([sys.executable, module, "archive", config], stdout=out, stderr=err).returncode
live.close()
sys.exit(rc)
EOF
  then fail "$name" "archive вернул ненулевой код: $(cat "$work/archive.err")"; return; fi
  # Число реестра — по реестру, легшему в архив, отдельной строкой stderr.
  grep -qx 'registry_enabled 3' "$work/archive.err" \
    || { fail "$name" "в stderr нет «registry_enabled 3»: $(cat "$work/archive.err")"; return; }

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

  # integrity_check — каждой базы из архива, а не только рекордера.
  name=sqlite_check_all_covers_every_archived_database
  run sqlite-check-all "$work/restored"
  if [ "$rc" -ne 0 ] || [ "$(cat "$work/out")" != 2 ]; then
    fail "$name" "целые базы: код $rc, вывод «$(cat "$work/out" "$work/err")»"; return
  fi
  cp -R "$work/restored" "$work/corrupt"
  # Сигнатура zigbee.db цела, страницы за заголовком — мусор.
  "$py" - "$work/corrupt/zigbee.db" <<'EOF'
import os, sys
path = sys.argv[1]
size = os.path.getsize(path)
with open(path, "r+b") as handle:
    handle.seek(100)
    handle.write(b"\xa5" * (size - 100))
EOF
  run sqlite-check-all "$work/corrupt"
  if [ "$rc" -ne 1 ]; then fail "$name" "испорченная zigbee.db: ожидался код 1, получен $rc"; return; fi
  grep -q '^zigbee.db: ' "$work/out" || { fail "$name" "испорченная база не названа: «$(cat "$work/out")»"; return; }
  rm -f "$work/corrupt/home-assistant_v2.db"
  run sqlite-check-all "$work/corrupt"
  if [ "$rc" -ne 2 ]; then fail "$name" "без рекордера: ожидался код 2, получен $rc"; return; fi
  ok "$name"
  name=archive_snapshots_live_sqlite_and_restores

  # Распаковка в непустой каталог — отказ: восстановление не перезаписывает.
  "$py" "$module" extract "$work/restored" <"$work/archive.tar.gz" >"$work/out" 2>"$work/err"
  rc=$?
  if [ "$rc" -eq 0 ]; then fail "$name" "extract в непустой каталог прошёл"; return; fi
  ok "$name"
}

test_archive_counts_registry_from_archived_bytes() {
  local name=archive_counts_registry_from_archived_bytes
  # Реестр подменяется ровно между чтением и следующим шагом обхода:
  # число в stderr обязано описывать реестр из архива, а не тот, что лежит
  # в томе после архивации.
  mkdir -p "$work/swap/.storage"
  cp "$registry" "$work/swap/.storage/core.entity_registry"
  "$py" - "$module" "$work/swap" "$work/swap.tar.gz" "$work/swap.err" <<'EOF'
import importlib.util, json, os, sys
module, config, archive, errlog = sys.argv[1:5]
spec = importlib.util.spec_from_file_location("m", module)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
original = m.add_registry
def add_then_swap(tar, path, arcname):
    result = original(tar, path, arcname)
    with open(path, encoding="utf-8") as handle:
        doc = json.load(handle)
    doc["data"]["entities"].append({"entity_id": "light.example_added_later", "disabled_by": None})
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(doc, handle)
    return result
m.add_registry = add_then_swap
out = open(archive, "wb")
err = open(errlog, "w", encoding="utf-8")
sys.stdout = type(sys.stdout)(out, encoding="utf-8")
sys.stderr = err
sys.exit(m.main(["archive", config]))
EOF
  rc=$?
  if [ "$rc" -ne 0 ]; then fail "$name" "archive: код $rc: $(cat "$work/swap.err")"; return; fi
  grep -qx 'registry_enabled 3' "$work/swap.err" \
    || { fail "$name" "в stderr не число реестра из архива: $(cat "$work/swap.err")"; return; }
  run count "$work/swap/.storage/core.entity_registry"
  [ "$(cat "$work/out")" = 4 ] || { fail "$name" "подмена реестра не удалась: «$(cat "$work/out")»"; return; }
  if grep -q 'example_' "$work/swap.err"; then fail "$name" "в stderr есть entity_id"; return; fi

  # Тома без реестра — отказ с названной причиной, а не архив без реестра.
  mkdir -p "$work/no-registry/.storage"
  "$py" "$module" archive "$work/no-registry" >"$work/no-registry.tar.gz" 2>"$work/err"
  rc=$?
  if [ "$rc" -ne 2 ]; then fail "$name" "без реестра: ожидался код 2, получен $rc"; return; fi
  grep -q 'реестр сущностей HA' "$work/err" || { fail "$name" "без реестра: отказ не по реестру: $(cat "$work/err")"; return; }
  ok "$name"
}

# Обход отдаёт файл, которого на диске уже нет, — как временный файл HA,
# удалённый между os.walk и tar.add. $1 — имя пропавшего файла
# относительно каталога, вывод в $work/vanish.tar.gz и $work/vanish.err.
archive_with_vanished() {
  "$py" - "$module" "$work/vanish" "$1" "$work/vanish.tar.gz" "$work/vanish.err" <<'EOF'
import importlib.util, os, sys
module, config, ghost, archive, errlog = sys.argv[1:6]
spec = importlib.util.spec_from_file_location("m", module)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
ghost_dir, ghost_name = os.path.split(os.path.join(os.path.abspath(config), ghost))
real_walk = os.walk
def walk(top, *args, **kwargs):
    for root, dirs, files in real_walk(top, *args, **kwargs):
        if os.path.abspath(root) == ghost_dir and ghost_name not in files:
            files = files + [ghost_name]
        yield root, dirs, files
m.os.walk = walk
sys.stdout = type(sys.stdout)(open(archive, "wb"), encoding="utf-8")
sys.stderr = open(errlog, "w", encoding="utf-8")
sys.exit(m.main(["archive", config]))
EOF
  rc=$?
}

test_archive_skips_vanished_file_but_not_registry() {
  local name=archive_skips_vanished_file_but_not_registry
  mkdir -p "$work/vanish/.storage"
  cp "$registry" "$work/vanish/.storage/core.entity_registry"
  echo 'example marker' >"$work/vanish/domovoy-marker.txt"

  archive_with_vanished .storage/core.restore_state.tmp-example
  if [ "$rc" -ne 0 ]; then fail "$name" "исчезнувший временный файл: код $rc: $(cat "$work/vanish.err")"; return; fi
  grep -q 'исчез во время архивации' "$work/vanish.err" || { fail "$name" "нет предупреждения: $(cat "$work/vanish.err")"; return; }
  if grep -q 'tmp-example' "$work/vanish.err"; then fail "$name" "в предупреждении имя файла"; return; fi
  local listing
  listing="$(tar -tzf "$work/vanish.tar.gz")" || { fail "$name" "архив не читается tar"; return; }
  for member in .storage/core.entity_registry domovoy-marker.txt; do
    grep -qxF "$member" <<<"$listing" || { fail "$name" "в архиве нет $member"; return; }
  done

  # Реестр, пропавший так же, — ошибка, а не пропуск.
  mv "$work/vanish/.storage/core.entity_registry" "$work/registry.aside"
  archive_with_vanished .storage/core.entity_registry
  mv "$work/registry.aside" "$work/vanish/.storage/core.entity_registry"
  if [ "$rc" -ne 2 ]; then fail "$name" "исчезнувший реестр: ожидался код 2, получен $rc"; return; fi
  grep -q 'реестр сущностей HA' "$work/vanish.err" || { fail "$name" "исчезнувший реестр: отказ не по реестру"; return; }
  ok "$name"
}

test_archive_reads_replaced_file_whole() {
  local name=archive_reads_replaced_file_whole
  # HA пишет .storage/* атомарной заменой: временный файл и os.replace.
  # Каждое обращение lstat к файлу подменяет его версией длиннее прежней —
  # замена приходится между тем, как модуль узнал о файле, и тем, как его
  # читает. В архиве обязана лечь одна из версий целиком, а не размер
  # одной с байтами другой.
  mkdir -p "$work/replaced/.storage"
  cp "$registry" "$work/replaced/.storage/core.entity_registry"
  "$py" - "$module" "$work/replaced" "$work/replaced.tar.gz" "$work/replaced.err" <<'EOF'
import importlib.util, json, os, sys
module, config, archive, errlog = sys.argv[1:5]
spec = importlib.util.spec_from_file_location("m", module)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
target = os.path.join(os.path.abspath(config), ".storage", "core.restore_state")
def version(k):
    return json.dumps({"version": k, "pad": "x" * (1000 * (k + 1))}).encode()
with open(target, "wb") as handle:
    handle.write(version(0))
written = [0]
real_lstat = os.lstat
def lstat(path, *args, **kwargs):
    result = real_lstat(path, *args, **kwargs)
    if os.path.abspath(os.fspath(path)) == target:
        written[0] += 1
        with open(target + ".tmp", "wb") as handle:
            handle.write(version(written[0]))
        os.replace(target + ".tmp", target)
    return result
m.os.lstat = lstat
sys.stdout = type(sys.stdout)(open(archive, "wb"), encoding="utf-8")
sys.stderr = open(errlog, "w", encoding="utf-8")
rc = m.main(["archive", config])
m.os.lstat = real_lstat
sys.stderr.write(f"versions {written[0] + 1}\n")
sys.exit(rc)
EOF
  rc=$?
  if [ "$rc" -ne 0 ]; then fail "$name" "archive: код $rc: $(cat "$work/replaced.err")"; return; fi
  grep -q '^versions [2-9]' "$work/replaced.err" || { fail "$name" "подмена не случилась: $(cat "$work/replaced.err")"; return; }
  "$py" - "$work/replaced.tar.gz" <<'EOF'
import json, sys, tarfile
with tarfile.open(sys.argv[1], "r:gz") as tar:
    raw = tar.extractfile(".storage/core.restore_state").read()
doc = json.loads(raw)
expected = json.dumps({"version": doc["version"], "pad": "x" * (1000 * (doc["version"] + 1))}).encode()
sys.exit(0 if raw == expected else 1)
EOF
  rc=$?
  if [ "$rc" -ne 0 ]; then fail "$name" "в архиве не целая версия файла (обрезан или смешан)"; return; fi
  ok "$name"
}

test_archive_keeps_directory_links_and_survives_vanished_directory() {
  local name=archive_keeps_directory_links
  # Ссылка на каталог: os.walk в неё не спускается и в files её не кладёт —
  # без отдельной обработки она пропадает из архива молча.
  mkdir -p "$work/dirlink/.storage" "$work/dirlink/themes"
  cp "$registry" "$work/dirlink/.storage/core.entity_registry"
  echo 'example theme' >"$work/dirlink/themes/example.yaml"
  if ! "$py" -c 'import os,sys; os.symlink("themes", sys.argv[1], target_is_directory=True)' "$work/dirlink/themes-link" 2>/dev/null; then
    skip "$name" "симлинки в этом окружении недоступны"
  else
    run archive "$work/dirlink"
    cp "$work/out" "$work/dirlink.tar.gz"
    if [ "$rc" -ne 0 ]; then fail "$name" "archive: код $rc: $(cat "$work/err")"; return; fi
    if ! "$py" - "$work/dirlink.tar.gz" <<'EOF'
import sys, tarfile
with tarfile.open(sys.argv[1], "r:gz") as tar:
    member = tar.getmember("themes-link")
    names = tar.getnames()
sys.exit(0 if member.issym() and member.linkname == "themes" and "themes/example.yaml" in names
         and not any(n.startswith("themes-link/") for n in names) else 1)
EOF
    then fail "$name" "ссылки на каталог нет в архиве ссылкой"; return; fi
    ok "$name"
  fi

  # Каталог, исчезнувший между os.walk и записью его заголовка, — пропуск
  # с предупреждением без имени, а не отказ всего архива.
  name=archive_skips_vanished_directory
  "$py" - "$module" "$work/dirlink" "$work/vanished-dir.tar.gz" "$work/vanished-dir.err" <<'EOF'
import importlib.util, os, sys
module, config, archive, errlog = sys.argv[1:5]
spec = importlib.util.spec_from_file_location("m", module)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
real_walk = os.walk
def walk(top, *args, **kwargs):
    yield from real_walk(top, *args, **kwargs)
    yield os.path.join(os.path.abspath(top), "gone-example"), [], ["file-example"]
m.os.walk = walk
sys.stdout = type(sys.stdout)(open(archive, "wb"), encoding="utf-8")
sys.stderr = open(errlog, "w", encoding="utf-8")
sys.exit(m.main(["archive", config]))
EOF
  rc=$?
  if [ "$rc" -ne 0 ]; then fail "$name" "archive: код $rc: $(cat "$work/vanished-dir.err")"; return; fi
  grep -q 'каталог исчез во время архивации' "$work/vanished-dir.err" || { fail "$name" "нет предупреждения: $(cat "$work/vanished-dir.err")"; return; }
  if grep -q 'gone-example' "$work/vanished-dir.err"; then fail "$name" "в предупреждении имя каталога"; return; fi
  tar -tzf "$work/vanished-dir.tar.gz" | grep -qxF .storage/core.entity_registry || { fail "$name" "архив неполон"; return; }
  ok "$name"
}

test_count_counts_only_enabled
test_compare_reports_missing_entity
test_compare_full_states_and_disabled_ignored
test_compare_expect_mismatch
test_broken_registry_is_error
test_sqlite_backup_and_check
test_archive_roundtrip_with_live_wal
test_archive_counts_registry_from_archived_bytes
test_archive_skips_vanished_file_but_not_registry
test_archive_reads_replaced_file_whole
test_archive_keeps_directory_links_and_survives_vanished_directory

echo "итог: пройдено $passed, упало $failed, пропущено $skipped"
[ "$failed" -eq 0 ]
