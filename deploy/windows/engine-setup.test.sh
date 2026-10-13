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
#     (функция на временном файле); юнит MSS clamp — текст и вызовы
#     systemctl (подменён), юнит во временном каталоге; apt-get (подменён)
#     получает DPkg::Lock::Timeout, в install_docker нет вызовов мимо обёртки;
#   - -Check и замер стучатся на 127.0.0.1, а не localhost;
#   - вывод внешних программ — в UTF-8 (AST engine-setup.ps1), профиль
#     правила firewall и настройка firewall Hyper-V для VM WSL — функциями
#     сценария, извлечёнными из AST;
#   - docker-wsl.sh передаёт аргументы wsl.exe как есть (подделки wsl.exe и
#     cygpath первыми в PATH);
#   - только Windows: BOM и разбор обоих .ps1 в Windows PowerShell 5.1 и
#     pwsh 7; engine-setup.ps1 -Install -DryRun печатает собранные задачи,
#     правило и .wslconfig и ничего не создаёт; -Uninstall -DryRun печатает
#     план сноса движка без отката и не трогает .wslconfig, копию и
#     отметку; measure-boot.ps1 против локальной заглушки /health на python
#     (порт на 127.0.0.1, журнал во временном каталоге);
#   - пути через прежний движок рабочего стола сняты: поиск по сценариям и
#     README пуст, режима переезда нет.
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

# Юнит MSS clamp: текст с правилом TCPMSS по PMTU в mangle FORWARD, -C перед
# -A (повторный старт не дублирует), oneshot с RemainAfterExit; systemctl
# подменён, юнит — во временном каталоге. Повтор с тем же текстом не
# перезаписывает файл и не делает daemon-reload. main вызывает функцию.
test_mss_clamp_unit() {
  local name=mss_clamp_unit unit="$work/mss.service" log="$work/systemctl.log" rule line
  clamp() {
    (
      # shellcheck source=/dev/null
      . "$here/provision-engine.sh"
      systemctl() { printf '%s\n' "$*" >>"$log"; }
      ensure_mss_clamp "$unit"
    )
  }
  rm -f "$unit" "$log"
  clamp || { fail "$name" "код $?"; return; }
  rule='-p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu'
  grep -qxF "ExecStart=/bin/sh -c 'iptables -t mangle -C FORWARD $rule 2>/dev/null || iptables -t mangle -A FORWARD $rule'" "$unit" \
    || { fail "$name" "нет правила с -C … || … -A"; sed 's/^/    | /' "$unit"; return; }
  for line in 'Type=oneshot' 'RemainAfterExit=yes' 'Before=docker.service' 'WantedBy=multi-user.target'; do
    grep -qxF "$line" "$unit" || { fail "$name" "нет «$line»"; sed 's/^/    | /' "$unit"; return; }
  done
  [ "$(tail -c 1 "$unit" | od -An -tx1 | tr -d ' \n')" = 0a ] || { fail "$name" "юнит не кончается переводом строки"; return; }
  [ "$(tr '\n' '|' <"$log")" = 'daemon-reload|enable domovoy-mss-clamp.service|start domovoy-mss-clamp.service|' ] \
    || { fail "$name" "вызовы systemctl не те"; sed 's/^/    | /' "$log"; return; }
  rm -f "$log"
  clamp
  if grep -qx 'daemon-reload' "$log"; then fail "$name" "повтор с тем же юнитом делает daemon-reload"; return; fi
  grep -qx 'enable domovoy-mss-clamp.service' "$log" || { fail "$name" "повтор не включает юнит"; return; }
  sed -n '/^main() {/,/^}/p' "$here/provision-engine.sh" | grep -qx '  ensure_mss_clamp' || { fail "$name" "main не вызывает ensure_mss_clamp"; return; }
  ok "$name"
}

# apt-get ждёт чужую блокировку dpkg (unattended-upgrades после старта
# дистрибутива), а не падает с кодом 100: обёртка apt_get передаёт
# DPkg::Lock::Timeout, apt-get подменён и пишет аргументы. В install_docker
# нет вызовов apt-get мимо обёртки.
test_apt_waits_for_lock() {
  local name=apt_waits_for_lock bin="$work/aptbin" args="$work/apt-args"
  mkdir -p "$bin"
  cat >"$bin/apt-get" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >"$args"
EOF
  chmod +x "$bin/apt-get"
  rm -f "$args"
  # shellcheck source=/dev/null
  (. "$here/provision-engine.sh" && PATH="$bin:$PATH" apt_get install -y git) || { fail "$name" "код $?"; return; }
  [ "$(sed -n 1p "$args" 2>/dev/null)" = -o ] && grep -Eqx 'DPkg::Lock::Timeout=[1-9][0-9]*' "$args" \
    || { fail "$name" "apt-get без -o DPkg::Lock::Timeout"; sed 's/^/    | /' "$args" 2>/dev/null; return; }
  [ "$(tail -n 3 "$args" | tr '\n' ' ')" = 'install -y git ' ] || { fail "$name" "аргументы не переданы как есть"; sed 's/^/    | /' "$args"; return; }
  ok "$name"

  name=apt_calls_through_wrapper
  local body
  body="$(sed -n '/^install_docker() {/,/^}/p' "$here/provision-engine.sh")"
  [ "$(grep -c '^  apt_get ' <<<"$body")" -eq 4 ] || { fail "$name" "в install_docker не четыре вызова apt_get"; return; }
  if grep -n 'apt-get' <<<"$body" >"$work/out"; then fail "$name" "apt-get мимо обёртки"; show_out; return; fi
  ok "$name"
}

# -Check и замер стучатся на 127.0.0.1: localhost на хосте с движком висит —
# Windows пробует сначала ::1, а ::1 правило Hyper-V не принимает.
test_no_localhost_url() {
  local name=no_localhost_url
  if grep -n '//localhost' "$here/engine-setup.ps1" "$here/measure-boot.ps1" >"$work/out"; then
    fail "$name" "адрес localhost в сценариях"; show_out; return
  fi
  grep -q "'http://127.0.0.1:{0}/health'" "$here/measure-boot.ps1" || { fail "$name" "замер не на 127.0.0.1"; return; }
  grep -q "Get-Health ('http://127.0.0.1:{0}/health'" "$here/engine-setup.ps1" || { fail "$name" "-Check не на 127.0.0.1"; return; }
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

# engine-setup.ps1 копии клона с временным .wslconfig.
engine_setup() {
  local shell="$1"
  shift
  run "$shell" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$(cygpath -w "$work/clone/deploy/windows/engine-setup.ps1")" \
    "$@" -WslConfigPath "$(cygpath -w "$work/wslconfig")"
  tr -d '\r' <"$work/out" >"$work/out.$shell"
}

dry_run() {
  local shell="$1"
  shift
  engine_setup "$shell" -Install -DryRun "$@"
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
      "firewall.localports: 28081,$ha_default" 'firewall.remoteaddresses: LocalSubnet,127.0.0.1' \
      'firewall.profiles: Private' 'firewall.profiles.private_only: True' \
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
    # Расписание бэкапа — одно, S4U: выбора типа входа больше нет.
    has "$shell" 'backup: install-schedule.ps1 -Install -DryRun' || { fail "$name/$shell" "нет строки вызова расписания бэкапа"; show_out; return; }
    if grep -q -- '-LogonType' "$work/out.$shell"; then fail "$name/$shell" "расписанию бэкапа передаётся -LogonType"; show_out; return; fi
    if grep -q 'ha-long-lived-token' "$work/out.$shell"; then fail "$name/$shell" "в выводе значения .env"; return; fi
    [ ! -e "$work/wslconfig" ] || { fail "$name/$shell" "сухой прогон записал .wslconfig"; return; }
    if [ -z "$first" ]; then first="$shell"; elif ! cmp -s "$work/out.$first" "$work/out.$shell"; then
      fail "$name" "вывод $first и $shell различается"; diff "$work/out.$first" "$work/out.$shell" | sed 's/^/    | /' | head; return
    fi
  done
  ok "$name"

  # Повторный -Install гасит дистрибутив (wsl --terminate): держалка, если
  # работала, запускается снова. Состояние хоста подменяется — на машине
  # владельца после переезда держалка работает, и ветка «не работала» иначе
  # не проверялась бы.
  name=engine_setup_resumes_keeper
  dry_run "${shells[0]}" -AssumeEngineState Running
  [ "$rc" -eq 0 ] || { fail "$name" "код $rc"; show_out; return; }
  has "${shells[0]}" 'engine.running: True' || { fail "$name" "состояние Running не учтено"; show_out; return; }
  has "${shells[0]}" 'keeper.resume: Start-ScheduledTask domovoy-engine' || { fail "$name" "держалка не запускается снова"; show_out; return; }
  dry_run "${shells[0]}" -AssumeEngineState Stopped
  [ "$rc" -eq 0 ] || { fail "$name" "код $rc"; show_out; return; }
  has "${shells[0]}" 'engine.running: False' || { fail "$name" "состояние Stopped не учтено"; show_out; return; }
  if grep -q '^keeper.resume: Start-ScheduledTask' "$work/out.${shells[0]}"; then fail "$name" "держалка запускается, хотя не работала"; show_out; return; fi
  grep -q '^keeper.resume: none ' "$work/out.${shells[0]}" || { fail "$name" "решение о держалке не напечатано"; show_out; return; }
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
  # Без секции [wsl2] она дописывается в конец — тоже переводом строки файла.
  printf '[boot]\nsystemd=true\n' >"$work/wslconfig"
  dry_run "${shells[0]}"
  wslconfig_bytes_are "$name" $'[boot]\nsystemd=true\n\n[wsl2]\nnetworkingMode=mirrored\n' || return
  printf '[boot]\r\nsystemd=true\r\n' >"$work/wslconfig"
  dry_run "${shells[0]}"
  wslconfig_bytes_are "$name" $'[boot]\r\nsystemd=true\r\n\r\n[wsl2]\r\nnetworkingMode=mirrored\r\n' || return
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

  # firewall=false выключает firewall Hyper-V для VM WSL: правило ничего не
  # сужало бы, порты стека видны всем в сети. Отказ — и рядом с mirrored.
  name=engine_setup_refuses_wsl_firewall_off
  local wsl_case
  for wsl_case in $'[wsl2]\nfirewall=false\n|firewall=false' $'[wsl2]\nnetworkingMode=mirrored\nFirewall = False\n|firewall=False'; do
    printf '%s' "${wsl_case%|*}" >"$work/wslconfig"
    dry_run "${shells[0]}"
    if [ "$rc" -eq 0 ]; then fail "$name" "${wsl_case#*|} принят"; show_out; return; fi
    has "${shells[0]}" "wslconfig.conflict: ${wsl_case#*|}" || { fail "$name" "конфликт ${wsl_case#*|} не назван"; show_out; return; }
  done
  printf '[wsl2]\nnetworkingMode=mirrored\nfirewall=true\n' >"$work/wslconfig"
  dry_run "${shells[0]}"
  [ "$rc" -eq 0 ] || { fail "$name" "firewall=true — отказ, код $rc"; show_out; return; }
  has "${shells[0]}" 'wslconfig.changed: False' || { fail "$name" "firewall=true: файл меняется"; show_out; return; }
  ok "$name"

  name=engine_setup_requires_mode
  run "${shells[0]}" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$(cygpath -w "$work/clone/deploy/windows/engine-setup.ps1")"
  [ "$rc" -eq 2 ] || { fail "$name" "без режима код $rc, ожидался 2"; show_out; return; }
  run "${shells[0]}" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$(cygpath -w "$work/clone/deploy/windows/engine-setup.ps1")" -Check -DryRun
  [ "$rc" -eq 2 ] || { fail "$name" "-Check -DryRun код $rc, ожидался 2"; show_out; return; }
  run "${shells[0]}" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$(cygpath -w "$work/clone/deploy/windows/engine-setup.ps1")" -Install -Uninstall -DryRun
  [ "$rc" -eq 2 ] || { fail "$name" "-Install -Uninstall код $rc, ожидался 2"; show_out; return; }
  # Подменённое состояние — только для сухого прогона. Проба через -Check:
  # при сломанной защите он лишь читает хост, а -Install без -DryRun тест
  # не запускает.
  run "${shells[0]}" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$(cygpath -w "$work/clone/deploy/windows/engine-setup.ps1")" -Check -AssumeEngineState Running
  [ "$rc" -eq 2 ] || { fail "$name" "-AssumeEngineState без -DryRun код $rc, ожидался 2"; show_out; return; }
  ok "$name"

  # stderr внешней программы — отдельным полем: в строках stdout его нет,
  # в выводе он виден с пометкой. Отказ вложенного install-schedule.ps1
  # (нет BACKUP_DIR) пишется в stderr.
  fake_clone "$(printf 'API_HTTP_PORT=28081\r\n')"
  rm -f "$work/wslconfig"*
  for shell in "${shells[@]}"; do
    name="engine_setup_stderr_apart/$shell"
    dry_run "$shell"
    [ "$rc" -ne 0 ] || { fail "$name" "отказ расписания бэкапа не дал ненулевой код"; show_out; return; }
    grep -q '^backup\.stderr: .*BACKUP_DIR' "$work/out.$shell" || { fail "$name" "текст отказа не показан отдельной строкой stderr"; show_out; return; }
    if grep -q '^backup\.install-schedule:' "$work/out.$shell"; then fail "$name" "stderr попал в строки stdout"; show_out; return; fi
    has "$shell" 'backup.exitcode: 1' || { fail "$name" "нет кода расписания"; show_out; return; }
    ok "$name"
  done
}

uninstall_dry_run() {
  local shell="$1"
  shift
  engine_setup "$shell" -Uninstall -DryRun "$@"
}

# Файлы .wslconfig, копия и отметка — байт в байт как до сухого прогона.
wslconfig_files_untouched() {
  local f
  for f in wslconfig wslconfig.domovoy-backup wslconfig.domovoy-absent; do
    if [ -e "$work/before/$f" ]; then
      cmp -s "$work/before/$f" "$work/$f" || { echo "$f изменён или удалён"; return 1; }
    elif [ -e "$work/$f" ]; then
      echo "$f создан"; return 1
    fi
  done
}

snapshot_wslconfig() {
  rm -rf -- "$work/before" && mkdir -p "$work/before"
  local f
  for f in wslconfig wslconfig.domovoy-backup wslconfig.domovoy-absent; do
    [ -e "$work/$f" ] && cp "$work/$f" "$work/before/$f"
  done
  return 0
}

# Снос движка (-Uninstall): стек останавливается до снятия задач, задачи
# автозапуска и расписание бэкапа снимаются, .wslconfig возвращается из
# копии или удаляется по отметке, дистрибутив с томами остаётся; отката
# на другой движок нет. Проверяется сухим прогоном: он ничего не меняет.
test_uninstall_dry_run_without_rollback() {
  local name=uninstall_dry_run_without_rollback
  if ! is_windows; then skip "$name" "не Windows — задачи собирает модуль ScheduledTasks"; return; fi
  if [ "${#shells[@]}" -eq 0 ]; then skip "$name" "нет ни pwsh, ни powershell.exe"; return; fi
  local dest="$work/backups" shell line why first=''
  mkdir -p "$dest"
  fake_clone "$(printf 'API_HTTP_PORT=28081\r\nBACKUP_DIR="%s"\r\n' "$(cygpath -m "$dest")")"

  for shell in "${shells[@]}"; do
    name="uninstall_dry_run_without_rollback/$shell"
    # Движок работает, есть копия прежнего .wslconfig.
    rm -f "$work/wslconfig"*
    printf '[wsl2]\nnetworkingMode=mirrored\n' >"$work/wslconfig"
    printf '[wsl2]\r\nmemory=4GB\r\n' >"$work/wslconfig.domovoy-backup"
    snapshot_wslconfig
    uninstall_dry_run "$shell" -AssumeEngineState Running
    [ "$rc" -eq 0 ] || { fail "$name" "код $rc"; show_out; return; }
    for line in 'uninstall.engine.running: True' \
      'uninstall.task.unregister: domovoy-engine' 'uninstall.task.unregister: domovoy-measure-boot' \
      'uninstall.backup: install-schedule.ps1 -Uninstall' \
      'uninstall.terminate: wsl.exe --terminate domovoy-engine' 'uninstall.firewall.remove: domovoy-engine-ports' \
      'uninstall.wslconfig: restore from wslconfig.domovoy-backup' 'DryRun: nothing changed'; do
      has "$shell" "$line" || { fail "$name" "нет «$line»"; show_out; return; }
    done
    grep -q '^uninstall\.stack\.stop: wsl\.exe -d domovoy-engine -u root --cd .* --exec docker compose --profile ha stop$' "$work/out.$shell" \
      || { fail "$name" "стек не останавливается командой stop внутри движка"; show_out; return; }
    # stop, а не down: тома стека остаются.
    if grep -q '^uninstall\.stack\.stop: .* down' "$work/out.$shell"; then fail "$name" "стек сносится down"; show_out; return; fi
    grep -q '^uninstall\.distro\.kept: .*wsl --unregister domovoy-engine' "$work/out.$shell" \
      || { fail "$name" "не сказано, что дистрибутив с томами остаётся и как его удалить"; show_out; return; }
    # Отката нет: ни другого движка, ни входа пользователя у расписания,
    # ни повторной установки расписания.
    if grep -qiE 'desktop|interactive|install-schedule\.ps1 .*-Install' "$work/out.$shell"; then
      fail "$name" "в плане сноса есть откат"; grep -niE 'desktop|interactive|install-schedule\.ps1 .*-Install' "$work/out.$shell" | sed 's/^/    | /'; return
    fi
    # Сухой прогон расписание бэкапа не снимает и не вызывает: у
    # install-schedule.ps1 -Uninstall сухого прогона нет.
    if grep -q '^backup\.' "$work/out.$shell"; then fail "$name" "сухой прогон вызвал install-schedule.ps1"; show_out; return; fi
    why="$(wslconfig_files_untouched)" || { fail "$name" "сухой прогон: $why"; return; }

    # Движок не работает, до -Install .wslconfig не было — отметка.
    rm -f "$work/wslconfig"*
    printf '[wsl2]\nnetworkingMode=mirrored\n' >"$work/wslconfig"
    : >"$work/wslconfig.domovoy-absent"
    snapshot_wslconfig
    uninstall_dry_run "$shell" -AssumeEngineState Stopped
    [ "$rc" -eq 0 ] || { fail "$name" "код $rc"; show_out; return; }
    has "$shell" 'uninstall.engine.running: False' || { fail "$name" "состояние Stopped не учтено"; show_out; return; }
    grep -q '^uninstall\.stack\.stop: none ' "$work/out.$shell" || { fail "$name" "стек останавливается в неработающем дистрибутиве"; show_out; return; }
    has "$shell" 'uninstall.wslconfig: remove (marker wslconfig.domovoy-absent)' || { fail "$name" "отметка не учтена"; show_out; return; }
    why="$(wslconfig_files_untouched)" || { fail "$name" "сухой прогон: $why"; return; }

    # Ни копии, ни отметки — .wslconfig не трогается.
    rm -f "$work/wslconfig"*
    printf '[wsl2]\nnetworkingMode=mirrored\n' >"$work/wslconfig"
    snapshot_wslconfig
    uninstall_dry_run "$shell" -AssumeEngineState Stopped
    has "$shell" 'uninstall.wslconfig: keep (no .domovoy-backup copy and no .domovoy-absent marker)' || { fail "$name" "решение о .wslconfig не то"; show_out; return; }
    why="$(wslconfig_files_untouched)" || { fail "$name" "сухой прогон: $why"; return; }
    if [ -z "$first" ]; then first="$shell"; elif ! cmp -s "$work/out.$first" "$work/out.$shell"; then
      fail "$name" "вывод $first и $shell различается"; diff "$work/out.$first" "$work/out.$shell" | sed 's/^/    | /' | head; return
    fi
    ok "$name"
  done
}

# Путей через Docker Desktop нет: поиск по сценариям движка, расписанию
# бэкапа и README пуст (ключ -w с учётом регистра: -NonInteractive словом
# Interactive не считается), а режим -Migrate отвергается как неизвестный
# параметр. Слова ищутся по одному: GNU grep 3.0 из Git for Windows с -w и
# несколькими -e находит Interactive внутри -NonInteractive.
test_no_docker_desktop_paths() {
  local name=no_docker_desktop_paths word
  : >"$work/out"
  for word in 'Docker Desktop' Migrate Interactive; do
    grep -nw -e "$word" "$root/deploy/windows/engine-setup.ps1" "$root/ops/backup/install-schedule.ps1" "$root/README.md" >>"$work/out"
  done
  if [ -s "$work/out" ]; then fail "$name" "остались упоминания"; show_out; return; fi
  ok "$name"

  name=engine_setup_refuses_migrate
  if ! is_windows || [ "${#shells[@]}" -eq 0 ]; then skip "$name" "нет PowerShell Windows"; return; fi
  local shell
  fake_clone "$(printf 'API_HTTP_PORT=28081\r\n')"
  for shell in "${shells[@]}"; do
    engine_setup "$shell" -Migrate -DryRun
    [ "$rc" -ne 0 ] || { fail "$name/$shell" "-Migrate принят, код 0"; show_out; return; }
    grep -q 'Migrate' "$work/out.$shell" || { fail "$name/$shell" "отказ не называет параметр"; show_out; return; }
    if grep -q '^migrate\.' "$work/out.$shell"; then fail "$name/$shell" "напечатан план переезда"; show_out; return; fi
  done
  ok "$name"
}

# Функции сценария по имени — из AST, без исполнения самого сценария (он
# разбирает режим и выходит). ps_functions <shell> <сценарий> <выражение>
# <функция>…: определения, затем выражение; вывод — в $work/out.
ps_functions() {
  local shell="$1" script="$2" expr="$3"
  shift 3
  # shellcheck disable=SC2016
  PS1_PATH="$(cygpath -w "$script")" PS1_FUNCS="$*" PS1_EXPR="$expr" run "$shell" -NoProfile -NonInteractive -Command '
    $ErrorActionPreference = "Stop"
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($env:PS1_PATH, [ref]$null, [ref]$null)
    foreach ($fn in $env:PS1_FUNCS -split " ") {
      $def = $ast.Find({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq $fn }, $true)
      if (-not $def) { "нет функции $fn"; exit 9 }
      . ([scriptblock]::Create($def.Extent.Text))
    }
    . ([scriptblock]::Create($env:PS1_EXPR))'
}

# Профиль правила firewall: только Private — перечислением или числом 2.
# Any (0), Public и сочетания с ним — не Private. -Check читает Profiles
# правила этой же функцией.
test_rule_profile_private_only() {
  local name=rule_profile_private_only shell
  if ! is_windows || [ "${#shells[@]}" -eq 0 ]; then skip "$name" "нет PowerShell Windows"; return; fi
  for shell in "${shells[@]}"; do
    # shellcheck disable=SC2016
    ps_functions "$shell" "$here/engine-setup.ps1" '
      foreach ($v in "Private", "2", 2) { if (-not (Test-PrivateProfileOnly $v)) { "отвергнут $v"; exit 1 } }
      foreach ($v in "Any", "0", 0, "Public", "Private, Public", "Domain, Private", "") { if (Test-PrivateProfileOnly $v) { "принят $v"; exit 1 } }' \
      Test-PrivateProfileOnly
    [ "$rc" -eq 0 ] || { fail "$name/$shell" "код $rc"; show_out; return; }
  done
  ok "$name"
}

# Вывод внешних программ в UTF-8: Invoke-Native ставит
# кодировку до вызова и возвращает в finally; каждый прямой вызов
# & $wslExe — тоже, внутри try с Restore в finally. Для собственного
# PowerShell кодировка не переключается: Set-NativeOutputEncoding отдаёт $null.
test_native_output_encoding() {
  local name=native_output_encoding shell
  if ! is_windows || [ "${#shells[@]}" -eq 0 ]; then skip "$name" "нет PowerShell Windows"; return; fi
  for shell in "${shells[@]}"; do
    # shellcheck disable=SC2016
    ps_functions "$shell" "$here/engine-setup.ps1" '
      $script = [System.Management.Automation.Language.Parser]::ParseFile($env:PS1_PATH, [ref]$null, [ref]$null)
      foreach ($fn in "Invoke-Native") {
        $def = $script.Find({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq $fn }, $true)
        $try = $def.Body.Find({ param($a) $a -is [System.Management.Automation.Language.TryStatementAst] }, $true)
        if (-not $try) { "$fn без try"; exit 1 }
        $before = $def.Body.Extent.Text.Substring(0, $try.Extent.StartOffset - $def.Body.Extent.StartOffset)
        if ($before -notmatch "Set-NativeOutputEncoding \`$Exe") { "$fn не ставит кодировку до вызова"; exit 1 }
        if ($try.Finally.Extent.Text -notmatch "Restore-NativeOutputEncoding") { "$fn не возвращает кодировку в finally"; exit 1 }
      }
      $direct = @($script.FindAll({ param($a) $a -is [System.Management.Automation.Language.CommandAst] -and $a.InvocationOperator -eq "Ampersand" -and $a.CommandElements[0].Extent.Text -eq "`$wslExe" }, $true))
      if ($direct.Count -lt 3) { "прямых вызовов wsl.exe $($direct.Count), ожидалось не меньше 3"; exit 1 }
      foreach ($call in $direct) {
        $p = $call.Parent
        while ($p -and -not ($p -is [System.Management.Automation.Language.TryStatementAst])) { $p = $p.Parent }
        if (-not $p -or -not $p.Finally -or $p.Finally.Extent.Text -notmatch "Restore-NativeOutputEncoding") { "строка $($call.Extent.StartLineNumber): & `$wslExe без Restore в finally"; exit 1 }
        $block = $p.Parent
        $index = [array]::IndexOf(@($block.Statements), $p)
        if ($index -lt 1 -or @($block.Statements)[$index - 1].Extent.Text -notmatch "Set-NativeOutputEncoding \`$wslExe") { "строка $($call.Extent.StartLineNumber): & `$wslExe без Set-NativeOutputEncoding перед try"; exit 1 }
      }
      if ($null -ne (Set-NativeOutputEncoding (Get-Process -Id $PID).Path)) { "кодировка переключена для собственного PowerShell"; exit 1 }' \
      Set-NativeOutputEncoding
    [ "$rc" -eq 0 ] || { fail "$name/$shell" "код $rc"; show_out; return; }
  done
  ok "$name"
}

# Звено -Check «firewall Hyper-V для VM WSL»: OK только при Enabled True и
# DefaultInboundAction Block; NotConfigured хранилища по умолчанию — не OK.
test_vm_firewall_problems() {
  local name=vm_firewall_problems shell
  if ! is_windows || [ "${#shells[@]}" -eq 0 ]; then skip "$name" "нет PowerShell Windows"; return; fi
  for shell in "${shells[@]}"; do
    # shellcheck disable=SC2016
    ps_functions "$shell" "$here/engine-setup.ps1" '
      function s($e, $d) { [pscustomobject]@{ Enabled = $e; DefaultInboundAction = $d } }
      if (@(Get-VmFirewallProblems (s "True" "Block")).Count) { "True/Block не OK"; exit 1 }
      foreach ($bad in (s "False" "Block"), (s "True" "Allow"), (s "NotConfigured" "NotConfigured"), (s "True" "NotConfigured")) {
        if (-not @(Get-VmFirewallProblems $bad).Count) { "принято $($bad.Enabled)/$($bad.DefaultInboundAction)"; exit 1 }
      }' \
      Get-VmFirewallProblems
    [ "$rc" -eq 0 ] || { fail "$name/$shell" "код $rc"; show_out; return; }
  done
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
  rm -f "$work/measure.log"
  measure_append "$@"
}

# Замер в существующий журнал — без удаления прежнего файла.
measure_append() {
  local shell="$1" port="$2"
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

    # Журнал прежней версии — UTF-8 без BOM: BOM дописывается в начало,
    # прежняя строка цела байт в байт, второй замер BOM не повторяет.
    name="measure_boot_adds_bom_to_old_log/$shell"
    local old_line='os_start=2026-01-01T00:00:00; result=нет ответа 200 за 30 мин'
    printf '%s\r\n' "$old_line" >"$work/measure.log"
    start_stub '{"status":"healthy"}' "$port" || { fail "$name" "заглушка не поднялась"; stop_stub; return; }
    measure_append "$shell" "$port"
    [ "$(head -c 3 "$work/measure.log" | od -An -tx1 | tr -d ' \n')" = 'efbbbf' ] || { stop_stub; fail "$name" "в начале журнала нет BOM"; return; }
    [ "$(tail -c +4 "$work/measure.log" | head -n 1 | tr -d '\r')" = "$old_line" ] || { stop_stub; fail "$name" "прежняя строка изменилась"; return; }
    measure_append "$shell" "$port"
    stop_stub
    [ "$(tail -c +4 "$work/measure.log" | head -c 3 | od -An -tx1 | tr -d ' \n')" != 'efbbbf' ] || { fail "$name" "BOM записан дважды"; return; }
    [ "$(grep -c 'result=ok' "$work/measure.log")" = 2 ] || { fail "$name" "в журнале не две новые строки"; sed 's/^/    | /' "$work/measure.log"; return; }
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
test_mss_clamp_unit
test_apt_waits_for_lock
test_no_localhost_url
test_docker_wsl_passes_arguments
test_ps1_encoding_and_parse
test_no_docker_desktop_paths
test_engine_setup_dry_run
test_uninstall_dry_run_without_rollback
test_rule_profile_private_only
test_vm_firewall_problems
test_native_output_encoding
test_measure_boot

echo "итог: пройдено $passed, упало $failed, пропущено $skipped"
[ "$failed" -eq 0 ]
