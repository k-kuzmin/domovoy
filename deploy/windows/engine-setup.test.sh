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
#     правило и .wslconfig и ничего не создаёт; -Uninstall -DryRun печатает
#     план отката (с возвратом AutoStart Docker Desktop) и не трогает
#     .wslconfig, копию и отметку; -Migrate -DryRun печатает шаги переезда
#     в порядке контракта, без down, отказывает без установленного движка и
#     не трогает настройки Docker Desktop; запись автозапуска Desktop в
#     реестре — во временной ветке HKCU\Software\domovoy-test\…, которая
#     убирается при выходе, настоящие Run и StartupApproved не читаются;
#     measure-boot.ps1 против
#     локальной заглушки /health на python (порт на 127.0.0.1, журнал во
#     временном каталоге).
#
# engine-setup.ps1 -Install, -Migrate и -Check тест не запускает: они меняют и читают
# хост — это живой прогон владельца (README, «Автозапуск после перезагрузки»).

set -uo pipefail
export MSYS_NO_PATHCONV=1

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
root="$(cd "$here/../.." && pwd -P)"
cd "$root" || exit 1

work="$(mktemp -d)"
stub_pid=''
# Ветка реестра для записи автозапуска Docker Desktop — своя, под
# HKCU\Software\domovoy-test: настоящие Run и StartupApproved тест не
# читает и не трогает. Создаётся по требованию, убирается при выходе.
reg_root="HKCU:\\Software\\domovoy-test\\engine-setup-$$-$RANDOM"
reg_used=''
cleanup() {
  if [ -n "$stub_pid" ]; then kill "$stub_pid" 2>/dev/null || true; fi
  if [ -n "$reg_used" ]; then reg_helper remove >/dev/null 2>&1 || true; fi
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

# Настройки Docker Desktop — во временном каталоге: сухие прогоны не читают
# файл владельца из %APPDATA%.
mkdir -p "$work/docker"

# engine-setup.ps1 копии клона с временными .wslconfig и настройками Desktop.
engine_setup() {
  local shell="$1"
  shift
  run "$shell" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$(cygpath -w "$work/clone/deploy/windows/engine-setup.ps1")" \
    "$@" -WslConfigPath "$(cygpath -w "$work/wslconfig")" -DockerSettingsDir "$(cygpath -w "$work/docker")" \
    -StartupRegistryRoot "$reg_root"
  tr -d '\r' <"$work/out" >"$work/out.$shell"
}

dry_run() {
  local shell="$1"
  shift
  engine_setup "$shell" -Install -DryRun "$@"
}

has() { grep -qxF -- "$2" "$work/out.$1"; }

# Ветка $reg_root: set <запись Run 0|1> <hex StartupApproved или ''>,
# dump — состояние одной строкой, remove — убрать ветку теста.
reg_helper() {
  if [ ! -f "$work/reg.ps1" ]; then
    cat >"$work/reg.ps1" <<'EOF'
param([string]$Root, [string]$Action, [string]$Run = '0', [string]$Approved = '')
$ErrorActionPreference = 'Stop'
$name = 'Docker Desktop'
$runKey = Join-Path $Root 'Run'
$approvedKey = Join-Path $Root 'Explorer\StartupApproved\Run'
if ($Root -notlike 'HKCU:\Software\domovoy-test\*') { throw "not a test key: $Root" }
switch ($Action) {
  'set' {
    if (Test-Path -LiteralPath $Root) { Remove-Item -LiteralPath $Root -Recurse -Force }
    $null = New-Item -Path $runKey -Force
    $null = New-Item -Path $approvedKey -Force
    if ($Run -eq '1') { $null = New-ItemProperty -LiteralPath $runKey -Name $name -Value 'C:\example\Docker Desktop.exe -Autostart' -PropertyType String }
    if ($Approved) { $null = New-ItemProperty -LiteralPath $approvedKey -Name $name -PropertyType Binary -Value ([byte[]]@($Approved -split '-' | ForEach-Object { [Convert]::ToByte($_, 16) })) }
  }
  'dump' {
    $r = Get-ItemProperty -LiteralPath $runKey -Name $name -ErrorAction SilentlyContinue
    $a = Get-ItemProperty -LiteralPath $approvedKey -Name $name -ErrorAction SilentlyContinue
    'run=' + [bool]$r + ' approved=' + $(if ($a) { [BitConverter]::ToString([byte[]]@($a.$name)) } else { '' })
  }
  'remove' {
    if (Test-Path -LiteralPath $Root) { Remove-Item -LiteralPath $Root -Recurse -Force }
    $parent = Split-Path -Parent $Root
    if ((Test-Path -LiteralPath $parent) -and -not @(Get-ChildItem -LiteralPath $parent).Count) { Remove-Item -LiteralPath $parent -Force }
  }
}
EOF
  fi
  reg_used=1
  powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$(cygpath -w "$work/reg.ps1")" -Root "$reg_root" -Action "$@"
}

reg_set() { reg_helper set -Run "$1" -Approved "$2" >/dev/null; }

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

# Файл настроек Docker Desktop, который запишет сценарий, из строки
# <ключ>.base64 сухого прогона — байт в байт против ожидаемого.
settings_bytes_are() {
  local name="$1" shell="$2" key="$3" expected="$4"
  sed -n "s/^$key\.base64: \([^ ]*\).*/\1/p" "$work/out.$shell" | base64 -d >"$work/settings.got" 2>/dev/null
  printf '%s' "$expected" >"$work/settings.expected"
  cmp -s "$work/settings.got" "$work/settings.expected" && return 0
  fail "$name" "$key: текст настроек Desktop не тот (od -c: получено / ожидалось)"
  od -c "$work/settings.got" | sed 's/^/    | /'
  od -c "$work/settings.expected" | sed 's/^/    | /'
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

  name=engine_setup_requires_mode
  run "${shells[0]}" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$(cygpath -w "$work/clone/deploy/windows/engine-setup.ps1")"
  [ "$rc" -eq 2 ] || { fail "$name" "без режима код $rc, ожидался 2"; show_out; return; }
  run "${shells[0]}" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$(cygpath -w "$work/clone/deploy/windows/engine-setup.ps1")" -Check -DryRun
  [ "$rc" -eq 2 ] || { fail "$name" "-Check -DryRun код $rc, ожидался 2"; show_out; return; }
  run "${shells[0]}" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$(cygpath -w "$work/clone/deploy/windows/engine-setup.ps1")" -Install -Uninstall -DryRun
  [ "$rc" -eq 2 ] || { fail "$name" "-Install -Uninstall код $rc, ожидался 2"; show_out; return; }
  # -Migrate — один или с -Install; с -Check и -Uninstall — отказ разбора.
  run "${shells[0]}" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$(cygpath -w "$work/clone/deploy/windows/engine-setup.ps1")" -Migrate -Check
  [ "$rc" -eq 2 ] || { fail "$name" "-Migrate -Check код $rc, ожидался 2"; show_out; return; }
  run "${shells[0]}" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$(cygpath -w "$work/clone/deploy/windows/engine-setup.ps1")" -Migrate -Uninstall -DryRun
  [ "$rc" -eq 2 ] || { fail "$name" "-Migrate -Uninstall код $rc, ожидался 2"; show_out; return; }
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

# Откат (-Uninstall): стек останавливается до снятия задач, задачи
# автозапуска снимаются, бэкап — под Docker Desktop (Interactive),
# .wslconfig возвращается из копии или удаляется по отметке, дистрибутив
# с томами остаётся. Проверяется сухим прогоном: он ничего не меняет.
test_engine_setup_uninstall_dry_run() {
  local name=engine_setup_uninstall_dry_run
  if ! is_windows; then skip "$name" "не Windows — задачи собирает модуль ScheduledTasks"; return; fi
  if [ "${#shells[@]}" -eq 0 ]; then skip "$name" "нет ни pwsh, ни powershell.exe"; return; fi
  local dest="$work/backups" shell line why
  mkdir -p "$dest"
  fake_clone "$(printf 'API_HTTP_PORT=28081\r\nBACKUP_DIR="%s"\r\n' "$(cygpath -m "$dest")")"

  for shell in "${shells[@]}"; do
    name="engine_setup_uninstall_dry_run/$shell"
    # Движок работает, есть копия прежнего .wslconfig.
    rm -f "$work/wslconfig"*
    printf '[wsl2]\nnetworkingMode=mirrored\n' >"$work/wslconfig"
    printf '[wsl2]\r\nmemory=4GB\r\n' >"$work/wslconfig.domovoy-backup"
    snapshot_wslconfig
    # -Migrate выключил автозапуск Docker Desktop и оставил копию настроек:
    # откат возвращает прежнее значение ключа.
    rm -rf -- "$work/docker" "$work/docker.before" && mkdir -p "$work/docker"
    printf '{\n  "AutoStart": false,\n  "Example": 1\n}\n' >"$work/docker/settings-store.json"
    printf '{\n  "AutoStart": true,\n  "Example": 1\n}\n' >"$work/docker/settings-store.json.domovoy-backup"
    cp -R "$work/docker" "$work/docker.before"
    uninstall_dry_run "$shell" -AssumeEngineState Running
    [ "$rc" -eq 0 ] || { fail "$name" "код $rc"; show_out; return; }
    has "$shell" 'uninstall.desktop_autostart: restore AutoStart=true from settings-store.json.domovoy-backup' \
      || { fail "$name" "возврат AutoStart Docker Desktop не в плане отката"; show_out; return; }
    settings_bytes_are "$name" "$shell" uninstall.desktop_autostart $'{\n  "AutoStart": true,\n  "Example": 1\n}\n' || return
    diff -r "$work/docker.before" "$work/docker" >/dev/null || { fail "$name" "сухой прогон изменил настройки Docker Desktop"; return; }
    # В копии ключа не было — он убирается: первым, последним, единственным.
    printf '{\n  "Example": 1\n}\n' >"$work/docker/settings-store.json.domovoy-backup"
    uninstall_dry_run "$shell" -AssumeEngineState Running
    settings_bytes_are "$name" "$shell" uninstall.desktop_autostart $'{\n  "Example": 1\n}\n' || return
    printf '{\n  "Example": 1,\n  "AutoStart": false\n}\n' >"$work/docker/settings-store.json"
    uninstall_dry_run "$shell" -AssumeEngineState Running
    settings_bytes_are "$name" "$shell" uninstall.desktop_autostart $'{\n  "Example": 1\n}\n' || return
    printf '{\n  "AutoStart": false\n}\n' >"$work/docker/settings-store.json"
    uninstall_dry_run "$shell" -AssumeEngineState Running
    settings_bytes_are "$name" "$shell" uninstall.desktop_autostart $'{\n  \n}\n' || return
    rm -rf -- "$work/docker" && cp -R "$work/docker.before" "$work/docker"
    uninstall_dry_run "$shell" -AssumeEngineState Running
    has "$shell" 'uninstall.desktop_logon_entry: keep (no StartupApproved-Run.domovoy-backup copy and no StartupApproved-Run.domovoy-absent marker)' \
      || { fail "$name" "без копии и отметки откат трогает запись автозапуска"; show_out; return; }
    # Копия прежнего значения StartupApproved — откат возвращает его; отметка — убирает.
    printf '02-00-00-00-00-00-00-00-00-00-00-00' >"$work/docker/StartupApproved-Run.domovoy-backup"
    cp -R "$work/docker/." "$work/docker.before/"
    uninstall_dry_run "$shell" -AssumeEngineState Running
    has "$shell" "uninstall.desktop_logon_entry: restore StartupApproved\\Run 'Docker Desktop' = 02-00-00-00-00-00-00-00-00-00-00-00 from StartupApproved-Run.domovoy-backup" \
      || { fail "$name" "возврат записи автозапуска не в плане отката"; show_out; return; }
    rm -f "$work/docker/StartupApproved-Run.domovoy-backup" "$work/docker.before/StartupApproved-Run.domovoy-backup"
    : >"$work/docker/StartupApproved-Run.domovoy-absent"
    cp -R "$work/docker/." "$work/docker.before/"
    uninstall_dry_run "$shell" -AssumeEngineState Running
    has "$shell" "uninstall.desktop_logon_entry: remove StartupApproved\\Run 'Docker Desktop' (marker StartupApproved-Run.domovoy-absent)" \
      || { fail "$name" "отметка «не было» не учтена"; show_out; return; }
    rm -f "$work/docker/StartupApproved-Run.domovoy-absent" "$work/docker.before/StartupApproved-Run.domovoy-absent"
    uninstall_dry_run "$shell" -AssumeEngineState Running
    diff -r "$work/docker.before" "$work/docker" >/dev/null || { fail "$name" "сухой прогон изменил настройки Docker Desktop"; return; }
    for line in 'uninstall.engine.running: True' \
      'uninstall.task.unregister: domovoy-engine' 'uninstall.task.unregister: domovoy-measure-boot' \
      'backup.LogonType: Interactive' 'backup.exitcode: 0' \
      'uninstall.terminate: wsl.exe --terminate domovoy-engine' 'uninstall.firewall.remove: domovoy-engine-ports' \
      'uninstall.wslconfig: restore from wslconfig.domovoy-backup' 'DryRun: nothing changed'; do
      has "$shell" "$line" || { fail "$name" "нет «$line»"; show_out; return; }
    done
    grep -q '^uninstall\.stack\.stop: wsl\.exe -d domovoy-engine -u root --cd .* --exec docker compose --profile ha stop$' "$work/out.$shell" \
      || { fail "$name" "стек не останавливается командой stop внутри движка"; show_out; return; }
    # stop, а не down: тома стека остаются.
    if grep -q '^uninstall\.stack\.stop: .* down' "$work/out.$shell"; then fail "$name" "стек сносится down"; show_out; return; fi
    grep -qi '^backup\.Execute: .*\\bash\.exe$' "$work/out.$shell" || { fail "$name" "бэкап не через bash Git for Windows"; show_out; return; }
    grep -q '^uninstall\.distro\.kept: .*wsl --unregister domovoy-engine' "$work/out.$shell" \
      || { fail "$name" "не сказано, что дистрибутив с томами остаётся и как его удалить"; show_out; return; }
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
    rm -f "$work/docker/settings-store.json.domovoy-backup"
    uninstall_dry_run "$shell" -AssumeEngineState Stopped
    has "$shell" 'uninstall.desktop_autostart: keep (no settings-store.json.domovoy-backup or settings.json.domovoy-backup copy)' \
      || { fail "$name" "без копии настроек Desktop откат их трогает"; show_out; return; }
    why="$(wslconfig_files_untouched)" || { fail "$name" "сухой прогон: $why"; return; }

    # Ни копии, ни отметки — .wslconfig не трогается.
    rm -f "$work/wslconfig"*
    printf '[wsl2]\nnetworkingMode=mirrored\n' >"$work/wslconfig"
    snapshot_wslconfig
    uninstall_dry_run "$shell" -AssumeEngineState Stopped
    has "$shell" 'uninstall.wslconfig: keep (no .domovoy-backup copy and no .domovoy-absent marker)' || { fail "$name" "решение о .wslconfig не то"; show_out; return; }
    why="$(wslconfig_files_untouched)" || { fail "$name" "сухой прогон: $why"; return; }
    ok "$name"
  done
}

# Переезд одной командой (-Migrate): сухой прогон печатает шаги в порядке
# контракта и ничего не трогает — ни docker.exe, ни WSL, ни настроек Desktop.
# План и настоящий прогон идут по одному списку $migrateSteps, поэтому
# порядок строк плана — это порядок действий.
# Состояние движка подменяется: на машине владельца он может быть и
# установлен, и нет.
migrate_order=(migrate.stop_api migrate.backup migrate.stop_stack migrate.desktop_stop migrate.desktop_autostart
  migrate.desktop_logon_entry migrate.keeper_stop migrate.wsl_shutdown migrate.keeper_start migrate.engine_wait migrate.restore migrate.check)

test_engine_setup_migrate_dry_run() {
  local name=engine_setup_migrate_dry_run
  if ! is_windows; then skip "$name" "не Windows — сценарий на PowerShell"; return; fi
  if [ "${#shells[@]}" -eq 0 ]; then skip "$name" "нет ни pwsh, ни powershell.exe"; return; fi
  local dest="$work/backups" shell key line previous first=''
  mkdir -p "$dest"
  fake_clone "$(printf 'API_HTTP_PORT=28081\r\nCOMPOSE_PROJECT_NAME=example-home\r\nHA_TOKEN=<ha-long-lived-token>\r\nBACKUP_DIR="%s"\r\n' "$(cygpath -m "$dest")")"
  rm -f "$work/wslconfig"*
  rm -rf -- "$work/docker" "$work/docker.before" && mkdir -p "$work/docker"
  printf '{\n  "AutoStart": true,\n  "Example": 1\n}\n' >"$work/docker/settings-store.json"
  cp -R "$work/docker" "$work/docker.before"

  for shell in "${shells[@]}"; do
    name="engine_setup_migrate_dry_run/$shell"
    engine_setup "$shell" -Migrate -DryRun -AssumeEngineState Running
    [ "$rc" -eq 0 ] || { fail "$name" "код $rc"; show_out; return; }
    # Шаги — в порядке контракта: бэкап при работающем стеке и до его
    # остановки, Desktop гасится до wsl --shutdown, восстановление — в
    # запущенном движке, последним — -Check.
    previous=0
    for key in "${migrate_order[@]}"; do
      line="$(grep -n -m1 "^$key: " "$work/out.$shell" | cut -d: -f1)"
      [ -n "$line" ] || { fail "$name" "нет шага $key"; show_out; return; }
      [ "$line" -gt "$previous" ] || { fail "$name" "шаг $key не на своём месте"; show_out; return; }
      previous="$line"
    done
    grep -q '^migrate\.stop_api: docker\.exe compose stop api$' "$work/out.$shell" || { fail "$name" "api не останавливается первым"; show_out; return; }
    grep -qi '^migrate\.backup: .*\\bash\.exe ops/backup/backup\.sh <BACKUP_DIR>$' "$work/out.$shell" || { fail "$name" "бэкап не через bash Git for Windows"; show_out; return; }
    if grep -qi '^migrate\.backup: .*\\system32\\bash\.exe' "$work/out.$shell"; then fail "$name" "бэкап через bash WSL"; show_out; return; fi
    grep -q '^migrate\.stop_stack: docker\.exe compose --profile ha stop ' "$work/out.$shell" || { fail "$name" "стек Desktop не останавливается stop"; show_out; return; }
    # Тома Desktop — путь отката: ни down, ни -v нигде в плане.
    if grep -E '^migrate\.' "$work/out.$shell" | grep -qE '(^|[^a-z])down([^a-z]|$)| -v( |$)'; then fail "$name" "в плане переезда есть down или -v"; show_out; return; fi
    grep -q '^migrate\.desktop_autostart: settings-store\.json AutoStart true -> false ' "$work/out.$shell" || { fail "$name" "автозапуск Desktop не выключается"; show_out; return; }
    grep -q '^migrate\.wsl_shutdown: wsl\.exe --shutdown - stops ALL WSL distributions' "$work/out.$shell" || { fail "$name" "не сказано, что wsl --shutdown гасит все дистрибутивы"; show_out; return; }
    # wsl --shutdown убивает держалку; задача с IgnoreNew молча пропустила
    # бы запуск при «зависшем» Running — поэтому сначала остановка, а после
    # запуска ожидание State Running.
    grep -q '^migrate\.keeper_stop: Stop-ScheduledTask domovoy-engine if its State is Running' "$work/out.$shell" || { fail "$name" "держалка не останавливается до wsl --shutdown"; show_out; return; }
    grep -q '^migrate\.keeper_start: Start-ScheduledTask domovoy-engine; wait up to [0-9]* s for task State Running' "$work/out.$shell" || { fail "$name" "запуск держалки без ожидания Running"; show_out; return; }
    grep -q '^migrate\.restore: wsl\.exe -d domovoy-engine -u root --cd .* --exec bash ops/backup/restore\.sh --project example-home --from ' "$work/out.$shell" \
      || { fail "$name" "восстановление не restore.sh --project внутри движка"; show_out; return; }
    grep -q '^migrate\.check: .*-Check' "$work/out.$shell" || { fail "$name" "итог не -Check"; show_out; return; }
    grep -q '^migrate\.rollback: .*-Uninstall' "$work/out.$shell" || { fail "$name" "нет команд отката"; show_out; return; }
    # docker desktop stop проверяется до шага 1; его отказ — откат стадии
    # Desktop (docker desktop start), а не -Uninstall.
    grep -q '^migrate\.precheck: .*docker\.exe desktop version answers' "$work/out.$shell" || { fail "$name" "нет пробы docker desktop до шага 1"; show_out; return; }
    # HA другого проекта в движке — до шага 1, как running_ha в restore.sh;
    # формат без кавычек: 5.1 их внешней программе не передаёт.
    has "$shell" 'migrate.precheck: no running homeassistant of another compose project in domovoy-engine, as restore.sh checks (docker ps --filter label=com.docker.compose.service=homeassistant --format {{.Labels}})' \
      || { fail "$name" "нет пробы Home Assistant другого проекта в движке"; show_out; return; }
    grep -q '^migrate\.rollback: .*up to and including migrate\.desktop_stop: docker desktop start' "$work/out.$shell" || { fail "$name" "откат при отказе docker desktop stop не тот"; show_out; return; }
    has "$shell" 'DryRun: nothing changed' || { fail "$name" "нет строки сухого прогона"; show_out; return; }
    if grep -q 'ha-long-lived-token' "$work/out.$shell"; then fail "$name" "в выводе значения .env"; return; fi
    diff -r "$work/docker.before" "$work/docker" >/dev/null || { fail "$name" "сухой прогон изменил настройки Docker Desktop"; return; }
    if [ -z "$first" ]; then first="$shell"; elif ! cmp -s "$work/out.$first" "$work/out.$shell"; then
      fail "$name" "вывод $first и $shell различается"; diff "$work/out.$first" "$work/out.$shell" | sed 's/^/    | /' | head; return
    fi
    ok "$name"
  done

  # AutoStart в файле настроек Desktop — байт в байт: замена значения,
  # вставка ключа в непустой и в пустой объект.
  name=engine_setup_migrate_desktop_settings_bytes
  engine_setup "${shells[0]}" -Migrate -DryRun -AssumeEngineState Running
  settings_bytes_are "$name" "${shells[0]}" migrate.desktop_autostart $'{\n  "AutoStart": false,\n  "Example": 1\n}\n' || return
  printf '{\n  "Example": 1\n}\n' >"$work/docker/settings-store.json"
  engine_setup "${shells[0]}" -Migrate -DryRun -AssumeEngineState Running
  settings_bytes_are "$name" "${shells[0]}" migrate.desktop_autostart $'{"AutoStart": false,\n  "Example": 1\n}\n' || return
  printf '{}' >"$work/docker/settings-store.json"
  engine_setup "${shells[0]}" -Migrate -DryRun -AssumeEngineState Running
  settings_bytes_are "$name" "${shells[0]}" migrate.desktop_autostart '{"AutoStart": false}' || return
  printf '{\n  "AutoStart": true,\n  "Example": 1\n}\n' >"$work/docker/settings-store.json"
  ok "$name"

  # Запись автозапуска Desktop в реестре (ветка теста): включённая —
  # выключается через StartupApproved с копией прежнего значения или
  # отметкой «не было»; выключенная и отсутствующая — не трогаются. Сухой
  # прогон ветку не меняет.
  name=engine_setup_migrate_logon_entry
  local reg_case reg_before
  for reg_case in \
    "1||StartupApproved\\Run 'Docker Desktop' -> 03-00-00-00 + FILETIME (disabled; previous value absent, marker StartupApproved-Run.domovoy-absent; -Uninstall restores it)" \
    "1|02-00-00-00-00-00-00-00-00-00-00-00|StartupApproved\\Run 'Docker Desktop' -> 03-00-00-00 + FILETIME (disabled; previous value 02-00-00-00-00-00-00-00-00-00-00-00, copy StartupApproved-Run.domovoy-backup; -Uninstall restores it)" \
    "1|03-00-00-00-00-00-00-00-00-00-00-00|StartupApproved\\Run 'Docker Desktop' 03-00-00-00-00-00-00-00-00-00-00-00 already disabled - unchanged" \
    "0|02-00-00-00-00-00-00-00-00-00-00-00|no value 'Docker Desktop' in $reg_root\\Run - unchanged"; do
    reg_set "${reg_case%%|*}" "$(echo "$reg_case" | cut -d'|' -f2)" || { fail "$name" "ветка теста в реестре не создана"; return; }
    reg_before="$(reg_helper dump)"
    engine_setup "${shells[0]}" -Migrate -DryRun -AssumeEngineState Running
    [ "$rc" -eq 0 ] || { fail "$name" "код $rc"; show_out; return; }
    has "${shells[0]}" "migrate.desktop_logon_entry: ${reg_case#*|*|}" || { fail "$name" "нет «migrate.desktop_logon_entry: ${reg_case#*|*|}»"; show_out; return; }
    [ "$(reg_helper dump)" = "$reg_before" ] || { fail "$name" "сухой прогон изменил ветку реестра"; return; }
  done
  [ ! -e "$work/docker/StartupApproved-Run.domovoy-backup" ] && [ ! -e "$work/docker/StartupApproved-Run.domovoy-absent" ] \
    || { fail "$name" "сухой прогон записал копию или отметку"; return; }
  ok "$name"

  # Один -Migrate без установленного движка — отказ с подсказкой, плана нет.
  name=engine_setup_migrate_requires_engine
  engine_setup "${shells[0]}" -Migrate -DryRun -AssumeEngineState Absent
  [ "$rc" -ne 0 ] || { fail "$name" "без движка код 0"; show_out; return; }
  grep -q -- '-Install -Migrate' "$work/out.${shells[0]}" || { fail "$name" "нет подсказки -Install -Migrate"; show_out; return; }
  if grep -q '^migrate\.stop_api:' "$work/out.${shells[0]}"; then fail "$name" "план напечатан при отказе"; show_out; return; fi
  ok "$name"

  # С -Install движок ставится первым: план установки, затем план переезда.
  name=engine_setup_install_then_migrate
  engine_setup "${shells[0]}" -Install -Migrate -DryRun -AssumeEngineState Absent
  [ "$rc" -eq 0 ] || { fail "$name" "код $rc"; show_out; return; }
  local install_line migrate_line
  install_line="$(grep -n -m1 '^keeper\.task: ' "$work/out.${shells[0]}" | cut -d: -f1)"
  migrate_line="$(grep -n -m1 '^migrate\.stop_api: ' "$work/out.${shells[0]}" | cut -d: -f1)"
  [ -n "$install_line" ] && [ -n "$migrate_line" ] && [ "$install_line" -lt "$migrate_line" ] \
    || { fail "$name" "план установки не перед планом переезда"; show_out; return; }
  [ "$(grep -c '^DryRun: nothing changed$' "$work/out.${shells[0]}")" = 1 ] || { fail "$name" "строка сухого прогона не одна в конце"; show_out; return; }
  ok "$name"

  # С -Install предусловия переезда без движка — до установки: негодное
  # имя проекта отказывает раньше, чем печатается план установки.
  name=engine_setup_install_migrate_precheck_first
  fake_clone "$(printf 'API_HTTP_PORT=28081\r\nCOMPOSE_PROJECT_NAME=Example-Home\r\nBACKUP_DIR="%s"\r\n' "$(cygpath -m "$dest")")"
  engine_setup "${shells[0]}" -Install -Migrate -DryRun -AssumeEngineState Absent
  [ "$rc" -ne 0 ] || { fail "$name" "негодное имя проекта принято"; show_out; return; }
  grep -q 'COMPOSE_PROJECT_NAME' "$work/out.${shells[0]}" || { fail "$name" "отказ не называет COMPOSE_PROJECT_NAME"; show_out; return; }
  if grep -q '^keeper\.task: ' "$work/out.${shells[0]}"; then fail "$name" "план установки напечатан до отказа переезда"; show_out; return; fi
  fake_clone "$(printf 'API_HTTP_PORT=28081\r\nCOMPOSE_PROJECT_NAME=example-home\r\nBACKUP_DIR="%s"\r\n' "$(cygpath -m "$dest")")"
  ok "$name"

  # Нет файла настроек Desktop — предупреждение, не отказ.
  name=engine_setup_migrate_without_desktop_settings
  rm -rf -- "$work/docker" && mkdir -p "$work/docker"
  engine_setup "${shells[0]}" -Migrate -DryRun -AssumeEngineState Stopped
  [ "$rc" -eq 0 ] || { fail "$name" "код $rc"; show_out; return; }
  grep -q '^migrate\.desktop_autostart: WARN ' "$work/out.${shells[0]}" || { fail "$name" "нет предупреждения"; show_out; return; }
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
test_engine_setup_uninstall_dry_run
test_engine_setup_migrate_dry_run
test_measure_boot

echo "итог: пройдено $passed, упало $failed, пропущено $skipped"
[ "$failed" -eq 0 ]
