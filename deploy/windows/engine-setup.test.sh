#!/usr/bin/env bash
# Регрессионный сценарий deploy/windows/ (#6) — без WSL и без правок хоста.
#
#   bash deploy/windows/engine-setup.test.sh
#
# Что проверяется:
#   - bash -n и shellcheck (если есть) для provision-engine.sh и docker-wsl.sh;
#   - в deploy/windows нет зашитого порта API — порт берётся из
#     API_HTTP_PORT или из значения по умолчанию в docker-compose.yml;
#   - provision-engine.sh дописывает /etc/wsl.conf, а не затирает его
#     (функция на временном файле);
#   - docker-wsl.sh передаёт аргументы wsl.exe как есть (подделки wsl.exe и
#     cygpath первыми в PATH);
#   - только Windows: BOM и разбор обоих .ps1 в Windows PowerShell 5.1 и
#     pwsh 7; engine-setup.ps1 -Install -DryRun печатает собранные задачи,
#     правило и .wslconfig и ничего не создаёт; measure-boot.ps1 против
#     локальной заглушки /health на python (порт на 127.0.0.1, журнал во
#     временном каталоге).
#
# engine-setup.ps1 -Install и -Check тест не запускает: они меняют и читают
# хост — это живой прогон владельца (README, «Автозапуск после перезагрузки»).

set -uo pipefail
export MSYS_NO_PATHCONV=1

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
root="$(cd "$here/../.." && pwd -P)"
cd "$root" || exit 1

work="$(mktemp -d)"
stub_pid=''
cleanup() {
  if [ -n "$stub_pid" ]; then kill "$stub_pid" 2>/dev/null || true; fi
  rm -rf -- "$work"
}
trap cleanup EXIT

passed=0
failed=0
skipped=0
ok() { echo "ok   $1"; passed=$((passed + 1)); }
fail() { echo "FAIL $1: $2"; failed=$((failed + 1)); }
skip() { echo "skip $1: $2"; skipped=$((skipped + 1)); }

run() {
  "$@" >"$work/out" 2>&1 </dev/null
  rc=$?
}
show_out() { sed 's/^/    | /' "$work/out" | tail -n 20; }

is_windows() {
  case "$(uname -s)" in
    MINGW* | MSYS* | CYGWIN*) return 0 ;;
    *) return 1 ;;
  esac
}

shells=()
if is_windows; then
  command -v pwsh >/dev/null 2>&1 && shells+=(pwsh)
  command -v powershell.exe >/dev/null 2>&1 && shells+=(powershell.exe)
fi

compose_default() {
  sed -nE "s/.*\\\$\\{$1:-([0-9]+)\\}.*/\\1/p" "$root/docker-compose.yml" | head -n 1
}

test_shell_scripts_parse() {
  local name=shell_scripts_parse script
  for script in provision-engine.sh docker-wsl.sh; do
    run bash -n "$here/$script"
    if [ "$rc" -ne 0 ]; then fail "$name" "bash -n $script"; show_out; return; fi
  done
  ok "$name"

  name=shell_scripts_shellcheck
  if ! command -v shellcheck >/dev/null 2>&1; then skip "$name" "нет shellcheck"; return; fi
  # Пути от корня клона: shellcheck для Windows не открывает пути MSYS.
  run shellcheck -S warning deploy/windows/provision-engine.sh deploy/windows/docker-wsl.sh deploy/windows/engine-setup.test.sh
  if [ "$rc" -ne 0 ]; then fail "$name" "замечания shellcheck"; show_out; return; fi
  ok "$name"
}

test_no_hardcoded_api_port() {
  local name=no_hardcoded_api_port half=80
  # Порт контейнера и прежний порт хоста по умолчанию — в сценариях его нет:
  # порт хоста берётся из API_HTTP_PORT, иначе из docker-compose.yml.
  if grep -rn "$half$half" "$here" >"$work/out"; then
    fail "$name" "в deploy/windows есть $half$half"; show_out; return
  fi
  ok "$name"
}

test_wsl_conf_is_merged() {
  local name=wsl_conf_is_merged file="$work/wsl.conf" got
  ensure() { (. "$here/provision-engine.sh" && ensure_wsl_conf "$1"); }

  rm -f "$file"
  ensure "$file" || { fail "$name" "нет файла: код $?"; return; }
  got="$(cat "$file")"
  [ "$got" = $'[boot]\nsystemd=true' ] || { fail "$name" "нет файла → «$got»"; return; }

  printf '[network]\nhostname=example-host\n' >"$file"
  ensure "$file"
  got="$(cat "$file")"
  [ "$got" = $'[network]\nhostname=example-host\n\n[boot]\nsystemd=true' ] || { fail "$name" "чужая секция → «$got»"; return; }

  printf '[boot]\ncommand=echo example\n' >"$file"
  ensure "$file"
  got="$(cat "$file")"
  [ "$got" = $'[boot]\nsystemd=true\ncommand=echo example' ] || { fail "$name" "[boot] без systemd → «$got»"; return; }

  printf '[boot]\nsystemd=false\n' >"$file"
  ensure "$file"
  got="$(cat "$file")"
  [ "$got" = $'[boot]\nsystemd=true' ] || { fail "$name" "systemd=false → «$got»"; return; }

  # Повторный запуск ничего не дублирует.
  ensure "$file"
  got="$(cat "$file")"
  [ "$got" = $'[boot]\nsystemd=true' ] || { fail "$name" "повтор → «$got»"; return; }
  ok "$name"
}

test_docker_wsl_passes_arguments() {
  local name=docker_wsl_passes_arguments bin="$work/fakebin"
  mkdir -p "$bin"
  cat >"$bin/cygpath" <<'EOF'
#!/usr/bin/env bash
[ "$1" = -w ] || exit 2
printf 'C:\\example\\clone\n'
EOF
  cat >"$bin/wsl.exe" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >"$work/wsl-args"
printf '%s' "\${MSYS_NO_PATHCONV:-unset}" >"$work/wsl-env"
exit "\${FAKE_WSL_CODE:-0}"
EOF
  chmod +x "$bin/cygpath" "$bin/wsl.exe"

  # shellcheck disable=SC2016
  PATH="$bin:$PATH" run env -u MSYS_NO_PATHCONV bash "$here/docker-wsl.sh" compose exec -T postgres sh -c 'echo "$HOME" a  b' /app/config
  if [ "$rc" -ne 0 ]; then fail "$name" "код $rc"; show_out; return; fi
  local expected
  # shellcheck disable=SC2016
  expected="$(printf '%s\n' -d domovoy-engine --cd 'C:\example\clone' --exec docker compose exec -T postgres sh -c 'echo "$HOME" a  b' /app/config)"
  if [ "$(cat "$work/wsl-args")" != "$expected" ]; then
    fail "$name" "аргументы wsl.exe не те"; diff <(echo "$expected") "$work/wsl-args" | sed 's/^/    | /'; return
  fi
  # Без MSYS_NO_PATHCONV Git Bash переписал бы /app/config в путь Windows.
  [ "$(cat "$work/wsl-env")" = 1 ] || { fail "$name" "MSYS_NO_PATHCONV не 1"; return; }
  ok "$name"

  name=docker_wsl_passes_exit_code
  FAKE_WSL_CODE=7 PATH="$bin:$PATH" run bash "$here/docker-wsl.sh" info
  [ "$rc" -eq 7 ] || { fail "$name" "код $rc, ожидался 7"; return; }
  ok "$name"

  name=docker_wsl_distro_override
  DOMOVOY_ENGINE_DISTRO=example-engine PATH="$bin:$PATH" run bash "$here/docker-wsl.sh" ps
  [ "$(sed -n 2p "$work/wsl-args")" = example-engine ] || { fail "$name" "имя дистрибутива не из DOMOVOY_ENGINE_DISTRO"; return; }
  ok "$name"
}

test_ps1_encoding_and_parse() {
  local name script path shell
  for script in engine-setup.ps1 measure-boot.ps1; do
    name="ps1_has_utf8_bom/$script"
    # Windows PowerShell 5.1 читает файл без BOM в кодировке ANSI.
    if [ "$(head -c 3 "$here/$script" | od -An -tx1 | tr -d ' \n')" = 'efbbbf' ]; then ok "$name"; else fail "$name" "без BOM UTF-8"; fi
  done
  name=ps1_parses
  if [ "${#shells[@]}" -eq 0 ]; then
    if command -v pwsh >/dev/null 2>&1; then shells_parse=(pwsh); else skip "$name" "нет PowerShell"; return; fi
  else
    shells_parse=("${shells[@]}")
  fi
  for shell in "${shells_parse[@]}"; do
    for script in engine-setup.ps1 measure-boot.ps1; do
      path="$here/$script"
      if command -v cygpath >/dev/null 2>&1; then path="$(cygpath -w "$path")"; fi
      # shellcheck disable=SC2016
      PS1_PATH="$path" run "$shell" -NoProfile -NonInteractive -Command '
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($env:PS1_PATH, [ref]$null, [ref]$errors)
        if ($errors) { $errors | ForEach-Object { $_.ToString() }; exit 1 }'
      if [ "$rc" -ne 0 ]; then fail "$name/$shell/$script" "ошибки разбора"; show_out; return; fi
    done
  done
  ok "$name"
}

# Копия сценариев и compose в отдельный корень со своим .env: сценарии берут
# корень клона из своего пути, .env владельца не читается.
fake_clone() {
  rm -rf -- "$work/clone"
  mkdir -p "$work/clone/deploy" "$work/clone/ops"
  cp -R "$here" "$work/clone/deploy/windows"
  cp -R "$root/ops/backup" "$work/clone/ops/backup"
  cp "$root/docker-compose.yml" "$work/clone/docker-compose.yml"
  printf '%s' "$1" >"$work/clone/.env"
}

dry_run() {
  local shell="$1"
  shift
  run "$shell" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$(cygpath -w "$work/clone/deploy/windows/engine-setup.ps1")" \
    -Install -DryRun -WslConfigPath "$(cygpath -w "$work/wslconfig")" "$@"
  tr -d '\r' <"$work/out" >"$work/out.$shell"
}

has() { grep -qxF -- "$2" "$work/out.$1"; }

# Содержимое .wslconfig из сухого прогона байт в байт против ожидаемого.
wslconfig_bytes_are() {
  local name="$1" expected="$2"
  sed -n 's/^wslconfig\.base64: //p' "$work/out.${shells[0]}" | base64 -d >"$work/wslconfig.got" 2>/dev/null
  printf '%s' "$expected" >"$work/wslconfig.expected"
  cmp -s "$work/wslconfig.got" "$work/wslconfig.expected" && return 0
  fail "$name" "содержимое .wslconfig не то (od -c: получено / ожидалось)"
  od -c "$work/wslconfig.got" | sed 's/^/    | /'
  od -c "$work/wslconfig.expected" | sed 's/^/    | /'
  return 1
}

test_engine_setup_dry_run() {
  local name=engine_setup_dry_run
  if ! is_windows; then skip "$name" "не Windows — задачи собирает модуль ScheduledTasks"; return; fi
  if [ "${#shells[@]}" -eq 0 ]; then skip "$name" "нет ни pwsh, ни powershell.exe"; return; fi
  local dest="$work/backups" shell first='' line ha_default api_default
  mkdir -p "$dest"
  ha_default="$(compose_default HA_HTTP_PORT)"
  api_default="$(compose_default API_HTTP_PORT)"
  [ -n "$ha_default" ] && [ -n "$api_default" ] || { fail "$name" "в docker-compose.yml нет значений по умолчанию портов"; return; }
  fake_clone "$(printf 'API_HTTP_PORT=28081\r\nHA_TOKEN=<ha-long-lived-token>\r\nBACKUP_DIR="%s"\r\n' "$(cygpath -m "$dest")")"
  rm -f "$work/wslconfig"*

  for shell in "${shells[@]}"; do
    dry_run "$shell"
    if [ "$rc" -ne 0 ]; then fail "$name/$shell" "код $rc"; show_out; return; fi
    # Держалка: при запуске системы, без входа и без хранимого пароля, без
    # предела времени, не боится батареи (UPS), перезапускается при сбое.
    for line in 'keeper.task: domovoy-engine' 'keeper.trigger: MSFT_TaskBootTrigger' \
      'keeper.arguments: -d domovoy-engine --exec sleep infinity' 'keeper.logontype: S4U' 'keeper.runlevel: Limited' \
      'keeper.executiontimelimit: PT0S' 'keeper.disallowstartifonbatteries: False' 'keeper.stopifgoingonbatteries: False' \
      'keeper.restartcount: 3' 'keeper.restartinterval: PT1M' \
      'measure.task: domovoy-measure-boot' 'measure.trigger: MSFT_TaskBootTrigger' \
      'firewall.name: domovoy-engine-ports' 'firewall.direction: Inbound' 'firewall.protocol: TCP' \
      'firewall.vmcreatorid: {40E0AC32-46A5-438A-A0B2-2B479E8F2E90}' \
      "firewall.localports: 28081,$ha_default" 'firewall.remoteaddresses: LocalSubnet,127.0.0.1,::1' \
      'wslconfig.exists: False' 'wslconfig.changed: True' 'wslconfig.line: [wsl2]' 'wslconfig.line: networkingMode=mirrored' \
      'backup.LogonType: S4U' 'backup.exitcode: 0' 'DryRun: nothing changed'; do
      has "$shell" "$line" || { fail "$name/$shell" "нет «$line»"; show_out; return; }
    done
    grep -qix 'keeper.execute: .*\\system32\\wsl\.exe' "$work/out.$shell" || { fail "$name/$shell" "держалка не wsl.exe"; show_out; return; }
    # Замер исполняет файл из клона, который пользователь может менять, —
    # поэтому тем же принципалом, что держалка: пользователь, S4U, Limited,
    # и никогда SYSTEM (S-1-5-18) или Highest.
    has "$shell" 'measure.logontype: S4U' || { fail "$name/$shell" "замер не S4U"; show_out; return; }
    has "$shell" 'measure.runlevel: Limited' || { fail "$name/$shell" "замер не Limited"; show_out; return; }
    if grep -q '^measure.usersid: S-1-5-18$' "$work/out.$shell"; then fail "$name/$shell" "замер под SYSTEM"; return; fi
    [ "$(sed -n 's/^measure.usersid: //p' "$work/out.$shell")" = "$(sed -n 's/^keeper.usersid: //p' "$work/out.$shell")" ]       || { fail "$name/$shell" "принципал замера не тот, что у держалки"; show_out; return; }
    # Ни одна задача -Install не идёт с повышенными правами.
    if grep -qE '^(keeper|measure|backup\.)(\.)?[Rr]un[Ll]evel: Highest$' "$work/out.$shell"; then fail "$name/$shell" "задача с Highest"; return; fi
    grep -q '^measure.arguments: .* -LogPath "[^"]*measure-boot\.log"$' "$work/out.$shell" || { fail "$name/$shell" "журнал замера не задан при регистрации"; show_out; return; }
    grep -q '^measure.arguments: .*measure-boot\.ps1" -Port 28081 ' "$work/out.$shell" || { fail "$name/$shell" "порт замера не из API_HTTP_PORT"; show_out; return; }
    grep -q '^provision: wsl.exe -d domovoy-engine -u root --cd .* --exec bash deploy/windows/provision-engine.sh$' "$work/out.$shell" \
      || { fail "$name/$shell" "нет строки провижининга"; show_out; return; }
    if grep -q 'ha-long-lived-token' "$work/out.$shell"; then fail "$name/$shell" "в выводе значения .env"; return; fi
    [ ! -e "$work/wslconfig" ] || { fail "$name/$shell" "сухой прогон записал .wslconfig"; return; }
    if [ -z "$first" ]; then first="$shell"; elif ! cmp -s "$work/out.$first" "$work/out.$shell"; then
      fail "$name" "вывод $first и $shell различается"; diff "$work/out.$first" "$work/out.$shell" | sed 's/^/    | /' | head; return
    fi
  done
  ok "$name"

  # Без API_HTTP_PORT в .env — значение по умолчанию из docker-compose.yml.
  name=engine_setup_port_from_compose_default
  fake_clone "$(printf 'BACKUP_DIR="%s"\r\n' "$(cygpath -m "$dest")")"
  dry_run "${shells[0]}"
  grep -q "^measure.arguments: .* -Port $api_default " "$work/out.${shells[0]}" || { fail "$name" "порт не $api_default"; show_out; return; }
  has "${shells[0]}" "firewall.localports: $api_default,$ha_default" || { fail "$name" "порты правила не по умолчанию"; show_out; return; }
  ok "$name"

  name=engine_setup_wslconfig_kept
  printf '[wsl2]\r\nmemory=4GB\r\n' >"$work/wslconfig"
  cp "$work/wslconfig" "$work/wslconfig.before"
  dry_run "${shells[0]}"
  [ "$(grep '^wslconfig.line: ' "$work/out.${shells[0]}" | tr '\n' '|')" = 'wslconfig.line: [wsl2]|wslconfig.line: networkingMode=mirrored|wslconfig.line: memory=4GB|' ] \
    || { fail "$name" "прежние строки .wslconfig не сохранены"; show_out; return; }
  # Байтовое сравнение: строки wslconfig.line делятся по \r?\n, а dry_run
  # срезает CR — лишний CR после [wsl2] виден только здесь.
  wslconfig_bytes_are "$name" $'[wsl2]\r\nnetworkingMode=mirrored\r\nmemory=4GB\r\n' || return
  cmp -s "$work/wslconfig" "$work/wslconfig.before" || { fail "$name" "сухой прогон изменил .wslconfig"; return; }
  # Файл с LF остаётся с LF: перевод строки берётся из самого файла.
  printf '[wsl2]\nmemory=4GB\n' >"$work/wslconfig"
  dry_run "${shells[0]}"
  wslconfig_bytes_are "$name" $'[wsl2]\nnetworkingMode=mirrored\nmemory=4GB\n' || return
  printf '[wsl2]\nnetworkingMode=mirrored\n' >"$work/wslconfig"
  dry_run "${shells[0]}"
  has "${shells[0]}" 'wslconfig.changed: False' || { fail "$name" "mirrored уже задан, а файл меняется"; show_out; return; }
  ok "$name"

  name=engine_setup_refuses_foreign_networking_mode
  printf '[wsl2]\nnetworkingMode=nat\n' >"$work/wslconfig"
  dry_run "${shells[0]}"
  if [ "$rc" -eq 0 ]; then fail "$name" "networkingMode=nat принят"; show_out; return; fi
  has "${shells[0]}" 'wslconfig.conflict: networkingMode=nat' || { fail "$name" "конфликт не назван"; show_out; return; }
  ok "$name"

  name=engine_setup_requires_mode
  run "${shells[0]}" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$(cygpath -w "$work/clone/deploy/windows/engine-setup.ps1")"
  [ "$rc" -eq 2 ] || { fail "$name" "без режима код $rc, ожидался 2"; show_out; return; }
  run "${shells[0]}" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$(cygpath -w "$work/clone/deploy/windows/engine-setup.ps1")" -Check -DryRun
  [ "$rc" -eq 2 ] || { fail "$name" "-Check -DryRun код $rc, ожидался 2"; show_out; return; }
  ok "$name"
}

python_cmd() {
  local candidate
  for candidate in python3 python; do
    if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import http.server' >/dev/null 2>&1; then
      echo "$candidate"; return 0
    fi
  done
  return 1
}

free_port() {
  local port
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    port=$((30000 + RANDOM % 20000))
    if ! (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then echo "$port"; return 0; fi
  done
  return 1
}

# Заглушка /health: файл health с заданным телом, python http.server на 127.0.0.1.
start_stub() {
  local body="$1" port="$2" python
  python="$(python_cmd)"
  rm -rf -- "$work/stub" && mkdir -p "$work/stub"
  printf '%s' "$body" >"$work/stub/health"
  local dir="$work/stub"
  # python Windows не понимает путь MSYS, а MSYS_NO_PATHCONV его не переводит.
  if command -v cygpath >/dev/null 2>&1; then dir="$(cygpath -w "$dir")"; fi
  "$python" -m http.server "$port" --bind 127.0.0.1 --directory "$dir" >/dev/null 2>&1 &
  stub_pid=$!
  for _ in $(seq 1 50); do
    if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then return 0; fi
    sleep 0.2
  done
  return 1
}

stop_stub() {
  if [ -n "$stub_pid" ]; then kill "$stub_pid" 2>/dev/null; wait "$stub_pid" 2>/dev/null; stub_pid=''; fi
}

measure() {
  local shell="$1" port="$2"
  rm -f "$work/measure.log"
  run "$shell" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$(cygpath -w "$here/measure-boot.ps1")" \
    -Port "$port" -TimeoutMinutes 0.15 -IntervalSeconds 1 -LogPath "$(cygpath -w "$work/measure.log")"
}

log_has() { grep -qF -- "$1" "$work/measure.log"; }

test_measure_boot() {
  local name=measure_boot
  if ! is_windows; then skip "$name" "не Windows — замер читает журнал событий и реестр Windows"; return; fi
  if [ "${#shells[@]}" -eq 0 ]; then skip "$name" "нет ни pwsh, ни powershell.exe"; return; fi
  if ! python_cmd >/dev/null; then skip "$name" "нет python для заглушки /health"; return; fi
  local port shell
  port="$(free_port)" || { skip "$name" "не нашёлся свободный порт"; return; }

  for shell in "${shells[@]}"; do
    name="measure_boot_counts_stack_health/$shell"
    start_stub '{"status":"healthy"}' "$port" || { fail "$name" "заглушка не поднялась"; stop_stub; return; }
    measure "$shell" "$port"
    stop_stub
    if [ "$rc" -ne 0 ]; then fail "$name" "код $rc"; show_out; return; fi
    [ "$(wc -l <"$work/measure.log" | tr -d ' ')" = 1 ] || { fail "$name" "в журнале не одна строка"; return; }
    for line in 'os_start=' 'last_boot=' 'fw_post_ms=' "port=$port" 'first_response=' 'код 200' 'result=ok'; do
      log_has "$line" || { fail "$name" "нет «$line»"; sed 's/^/    | /' "$work/measure.log"; return; }
    done
    if log_has 'first_200=нет'; then fail "$name" "ответ формы стека не засчитан"; return; fi
    if log_has 'foreign='; then fail "$name" "ответ формы стека назван чужим"; return; fi
    ok "$name"

    name="measure_boot_marks_foreign_listener/$shell"
    start_stub 'example foreign page' "$port" || { fail "$name" "заглушка не поднялась"; stop_stub; return; }
    measure "$shell" "$port"
    stop_stub
    if [ "$rc" -eq 0 ]; then fail "$name" "чужой ответ 200 засчитан (код 0)"; return; fi
    for line in 'first_200=нет' 'foreign=' 'чужой слушатель' 'result=нет ответа 200'; do
      log_has "$line" || { fail "$name" "нет «$line»"; sed 's/^/    | /' "$work/measure.log"; return; }
    done
    ok "$name"

    name="measure_boot_writes_line_without_answer/$shell"
    measure "$shell" "$port"
    if [ "$rc" -eq 0 ]; then fail "$name" "код 0 без слушателя"; return; fi
    for line in 'first_response=нет' 'first_200=нет' 'result=нет ответа 200'; do
      log_has "$line" || { fail "$name" "нет «$line»"; sed 's/^/    | /' "$work/measure.log"; return; }
    done
    ok "$name"
  done
}

test_shell_scripts_parse
test_no_hardcoded_api_port
test_wsl_conf_is_merged
test_docker_wsl_passes_arguments
test_ps1_encoding_and_parse
test_engine_setup_dry_run
test_measure_boot

echo "итог: пройдено $passed, упало $failed, пропущено $skipped"
[ "$failed" -eq 0 ]
