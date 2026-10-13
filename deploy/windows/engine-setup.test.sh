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
measure_pid=''
cleanup() {
  if [ -n "$stub_pid" ]; then kill "$stub_pid" 2>/dev/null || true; fi
  # Замер в фоне — процесс Windows: kill MSYS его не всегда гасит.
  if [ -n "$measure_pid" ]; then
    taskkill //F //T //PID "$(cat "/proc/$measure_pid/winpid" 2>/dev/null)" >/dev/null 2>&1 || true
    kill "$measure_pid" 2>/dev/null || true
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
  for script in provision-engine.sh docker-wsl.sh boot-probe.sh; do
    run bash -n "$here/$script"
    if [ "$rc" -ne 0 ]; then fail "$name" "bash -n $script"; show_out; return; fi
  done
  ok "$name"

  name=shell_scripts_shellcheck
  if ! command -v shellcheck >/dev/null 2>&1; then skip "$name" "нет shellcheck"; return; fi
  # Пути от корня клона: shellcheck для Windows не открывает пути MSYS.
  run shellcheck -S warning deploy/windows/provision-engine.sh deploy/windows/docker-wsl.sh deploy/windows/boot-probe.sh deploy/windows/engine-setup.test.sh
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

# Журнал systemd на диске со сбросом раз в 10 с: drop-in во временном
# каталоге, systemctl подменён. Повтор с тем же текстом файл не трогает и
# systemctl не зовёт; чужой файл каталога остаётся. Имя через дефис: форма
# domovoy.<суффикс> похожа на имя хоста для правила gitleaks. main вызывает
# функцию.
test_journald_dropin() {
  local name=journald_dropin dir="$work/journald.conf.d" log="$work/systemctl-journald.log" file before
  dropin() {
    (
      # shellcheck source=/dev/null
      . "$here/provision-engine.sh"
      systemctl() { printf '%s\n' "$*" >>"$log"; }
      ensure_journald "$dir"
    )
  }
  rm -rf -- "$dir" "$log"
  mkdir -p "$dir"
  printf '[Journal]\nSystemMaxUse=example\n' >"$dir/00-foreign.conf"
  cp "$dir/00-foreign.conf" "$work/foreign.before"
  dropin || { fail "$name" "код $?"; return; }
  file="$dir/domovoy-journal.conf"
  [ -f "$file" ] || { fail "$name" "нет $file"; ls -la "$dir" | sed 's/^/    | /'; return; }
  [ "$(cat "$file")" = $'[Journal]\nStorage=persistent\nSyncIntervalSec=10s' ] || { fail "$name" "текст drop-in не тот"; sed 's/^/    | /' "$file"; return; }
  [ "$(tail -c 1 "$file" | od -An -tx1 | tr -d ' \n')" = 0a ] || { fail "$name" "drop-in не кончается переводом строки"; return; }
  [ "$(tr '\n' '|' <"$log")" = 'restart systemd-journald.service|' ] || { fail "$name" "вызовы systemctl не те"; sed 's/^/    | /' "$log"; return; }
  before="$(od -An -tx1 "$file")"
  rm -f "$log"
  dropin || { fail "$name" "повтор: код $?"; return; }
  [ "$(od -An -tx1 "$file")" = "$before" ] || { fail "$name" "повтор изменил drop-in"; return; }
  [ ! -s "$log" ] || { fail "$name" "повтор зовёт systemctl"; sed 's/^/    | /' "$log"; return; }
  cmp -s "$dir/00-foreign.conf" "$work/foreign.before" || { fail "$name" "чужой файл каталога изменён"; return; }
  # Каталога нет — создаётся.
  rm -rf -- "$dir" "$log"
  dropin || { fail "$name" "без каталога: код $?"; return; }
  [ -f "$file" ] || { fail "$name" "без каталога drop-in не записан"; return; }
  sed -n '/^main() {/,/^}/p' "$here/provision-engine.sh" | grep -qx '  ensure_journald' || { fail "$name" "main не вызывает ensure_journald"; return; }
  ok "$name"
}

# Драйвер логов движка — journald в /etc/docker/daemon.json (временный
# файл). Нет файла — пишется; уже journald — байты те же; другой драйвер и
# чужие ключи без log-driver — отказ с кодом 1, файл байт в байт прежний.
test_docker_log_driver() {
  local name=docker_log_driver dir="$work/docker-etc" file got code
  file="$dir/daemon.json"
  driver() { (. "$here/provision-engine.sh" && ensure_docker_log_driver "$file") >"$work/out" 2>&1; }
  rm -rf -- "$dir"
  driver || { fail "$name" "нет файла: код $?"; show_out; return; }
  got="$(cat "$file")"
  [ "$got" = '{"log-driver": "journald"}' ] || { fail "$name" "нет файла → «$got»"; return; }
  cp "$file" "$work/daemon.before"
  driver || { fail "$name" "уже journald: код $?"; show_out; return; }
  cmp -s "$file" "$work/daemon.before" || { fail "$name" "уже journald, а файл переписан"; return; }
  printf '{\n  "log-driver" : "journald",\n  "mtu": 1400\n}\n' >"$file"
  cp "$file" "$work/daemon.before"
  driver || { fail "$name" "journald с другими ключами: код $?"; show_out; return; }
  cmp -s "$file" "$work/daemon.before" || { fail "$name" "journald с другими ключами — файл переписан"; return; }
  for got in '{"log-driver": "json-file"}' '{"mtu":1400}'; do
    printf '%s\n' "$got" >"$file"
    cp "$file" "$work/daemon.before"
    driver
    code=$?
    [ "$code" -eq 1 ] || { fail "$name" "«$got»: код $code, ожидался 1"; show_out; return; }
    cmp -s "$file" "$work/daemon.before" || { fail "$name" "«$got»: чужая настройка переписана"; return; }
    grep -qF '"log-driver": "journald"' "$work/out" || { fail "$name" "«$got»: отказ не говорит, что добавить"; show_out; return; }
  done
  sed -n '/^main() {/,/^}/p' "$here/provision-engine.sh" | grep -qx '  ensure_docker_log_driver' || { fail "$name" "main не вызывает ensure_docker_log_driver"; return; }
  ok "$name"
}

# Зонд хронологии (boot-probe.sh) с подменёнными docker, systemctl, ps и
# «сейчас» первыми в PATH. Все моменты — секунды Unix: вывод при TZ=UTC,
# Europe/Moscow и Asia/Yekaterinburg одинаков байт в байт. Подменённые ps и
# systemctl на запросы местного времени (lstart, ActiveEnterTimestamp без
# --timestamp=unix) отвечают по TZ сами — zoneinfo в Git Bash может не
# быть, — так что зонд, взявший местное время, даёт разный вывод.
test_boot_probe_output() {
  local name=boot_probe_output bin="$work/probebin" real_date tz out started_api started_pg expected
  real_date="$(command -v date)"
  mkdir -p "$bin"
  # Сдвиг зоны — по самому TZ, без zoneinfo.
  cat >"$bin/tzoff" <<'EOF'
case "${TZ:-UTC}" in Europe/Moscow) echo 10800 ;; Asia/Yekaterinburg) echo 18000 ;; *) echo 0 ;; esac
EOF
  cat >"$bin/date" <<EOF
#!/usr/bin/env bash
if [ "\$#" -eq 1 ] && [ "\$1" = '+%s' ]; then echo 1760331100; exit 0; fi
exec "$real_date" "\$@"
EOF
  cat >"$bin/ps" <<EOF
#!/usr/bin/env bash
case "\$*" in
  '-o etimes= -p 1') echo '    100' ;;
  *lstart*) "$real_date" -u -d "@\$((1760331000 + \$(bash "$bin/tzoff")))" '+%a %b %e %H:%M:%S %Y' ;;
  *) exit 2 ;;
esac
EOF
  cat >"$bin/systemctl" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *ActiveEnterTimestamp*--timestamp=unix* | *--timestamp=unix*ActiveEnterTimestamp*)
    case "\$*" in *--value*) echo '@1760331010' ;; *) echo 'ActiveEnterTimestamp=@1760331010' ;; esac ;;
  *ActiveEnterTimestamp*)
    local_time="\$("$real_date" -u -d "@\$((1760331010 + \$(bash "$bin/tzoff")))" '+%a %Y-%m-%d %H:%M:%S')"
    case "\$*" in *--value*) echo "\$local_time" ;; *) echo "ActiveEnterTimestamp=\$local_time" ;; esac ;;
  *) exit 2 ;;
esac
EOF
  # example-old-1 остановлен: StartedAt и healthy прошлого запуска в вывод
  # зонда не попадают.
  cat >"$bin/docker" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$work/probe-docker.log"
[ -z "\${FAKE_DOCKER_FAIL:-}" ] || { echo 'example: docker не отвечает' >&2; exit 1; }
case "\$1" in
  ps) [ -n "\${FAKE_DOCKER_EMPTY:-}" ] || printf 'example-api-1\nexample-postgres-1\nexample-new-1\nexample-old-1\n' ;;
  inspect) printf '/example-api-1|2025-10-13T04:51:20.123456789Z|healthy|true\n/example-postgres-1|2025-10-13T04:51:15Z|none|true\n/example-new-1|0001-01-01T00:00:00Z|none|false\n/example-old-1|2025-10-12T20:00:00Z|healthy|false\n' ;;
  *) exit 2 ;;
esac
EOF
  chmod +x "$bin/date" "$bin/ps" "$bin/systemctl" "$bin/docker"
  started_api="$("$real_date" -u -d '2025-10-13T04:51:20Z' +%s)"
  started_pg="$("$real_date" -u -d '2025-10-13T04:51:15Z' +%s)"
  expected="$(printf 'distro_start=1760331000\ndocker_active=1760331010\ncontainer name=example-api-1 started_at=%s health=healthy\ncontainer name=example-postgres-1 started_at=%s health=none' "$started_api" "$started_pg")"
  for tz in UTC Europe/Moscow Asia/Yekaterinburg; do
    rm -f "$work/probe-docker.log"
    out="$(TZ="$tz" PATH="$bin:$PATH" bash "$here/boot-probe.sh" example 2>"$work/out")" || { fail "$name" "TZ=$tz: код $?"; show_out; return; }
    if [ "$out" != "$expected" ]; then
      fail "$name" "TZ=$tz: вывод не тот"; diff <(echo "$expected") <(echo "$out") | sed 's/^/    | /'; return
    fi
    grep -qF 'ps -a --filter label=com.docker.compose.project=example ' "$work/probe-docker.log" \
      || { fail "$name" "фильтр по проекту не передан docker"; sed 's/^/    | /' "$work/probe-docker.log"; return; }
  done
  ok "$name"

  name=boot_probe_without_containers
  out="$(FAKE_DOCKER_EMPTY=1 PATH="$bin:$PATH" bash "$here/boot-probe.sh" example 2>"$work/out")" || { fail "$name" "код $?"; show_out; return; }
  [ "$out" = $'distro_start=1760331000\ndocker_active=1760331010' ] || { fail "$name" "вывод «$out»"; return; }
  ok "$name"

  name=boot_probe_docker_failure
  out="$(FAKE_DOCKER_FAIL=1 PATH="$bin:$PATH" bash "$here/boot-probe.sh" example 2>"$work/out")" && { fail "$name" "отказ docker — код 0"; return; }
  [ "$(head -n 1 <<<"$out")" = 'distro_start=1760331000' ] || { fail "$name" "до отказа docker не напечатан distro_start"; return; }
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
  fake_clone "$(printf 'API_HTTP_PORT=28081\r\nCOMPOSE_PROJECT_NAME=example-home\r\nHA_TOKEN=<ha-long-lived-token>\r\nBACKUP_DIR="%s"\r\n' "$(cygpath -m "$dest")")"
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
    # Хронология: замер знает дистрибутив и проект compose, чтобы спросить
    # зонд о контейнерах проекта.
    grep -q '^measure.arguments: .* -Distro domovoy-engine -Project example-home ' "$work/out.$shell" \
      || { fail "$name/$shell" "замеру не переданы -Distro и -Project из COMPOSE_PROJECT_NAME"; show_out; return; }
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
  # Без COMPOSE_PROJECT_NAME в .env — имя проекта по умолчанию из docker-compose.yml.
  grep -q "^measure.arguments: .* -Project $(sed -nE 's/^name: \$\{COMPOSE_PROJECT_NAME:-([^}]*)\}.*/\1/p' "$root/docker-compose.yml") " "$work/out.${shells[0]}" \
    || { fail "$name" "проект замера не по умолчанию из docker-compose.yml"; show_out; return; }
  has "${shells[0]}" "firewall.localports: $api_default,$ha_default" || { fail "$name" "порты правила не по умолчанию"; show_out; return; }
  ok "$name"

  # Имя проекта compose не той формы — отказ с кодом 2 до регистрации задач:
  # замер получил бы -Project, который его ValidatePattern не примет, и
  # падал бы на каждой загрузке.
  name=engine_setup_refuses_bad_project_name
  local bad
  for bad in 'Example-Home' 'example home' '-example'; do
    fake_clone "$(printf 'API_HTTP_PORT=28081\r\nCOMPOSE_PROJECT_NAME=%s\r\nBACKUP_DIR="%s"\r\n' "$bad" "$(cygpath -m "$dest")")"
    dry_run "${shells[0]}"
    [ "$rc" -eq 2 ] || { fail "$name" "«$bad»: код $rc, ожидался 2"; show_out; return; }
    grep -qF 'COMPOSE_PROJECT_NAME' "$work/out.${shells[0]}" || { fail "$name" "«$bad»: отказ не называет COMPOSE_PROJECT_NAME"; show_out; return; }
    if grep -qE '^(measure|keeper)\.task:' "$work/out.${shells[0]}"; then fail "$name" "«$bad»: задачи напечатаны после отказа"; show_out; return; fi
  done
  # Следующим сценариям — клон с допустимым .env, как до этого сценария.
  fake_clone "$(printf 'BACKUP_DIR="%s"\r\n' "$(cygpath -m "$dest")")"
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

# Путей через прежний настольный движок нет: поиск слов из $desktop_words
# по сценариям движка, расписанию бэкапа и README пуст (ключ -w с учётом
# регистра: слово типа входа внутри -NonInteractive словом не считается), а
# прежний режим переезда отвергается как неизвестный параметр. Слова
# собираются из частей, чтобы сам этот файл не попадал в поиск по дереву;
# ищутся по одному: GNU grep 3.0 из Git for Windows с -w и несколькими -e
# находит слово внутри -NonInteractive.
desktop_words=('Docker'' Desktop' 'Mi''grate' 'Inter''active')
test_no_docker_desktop_paths() {
  local name=no_docker_desktop_paths word
  : >"$work/out"
  for word in "${desktop_words[@]}"; do
    grep -nw -e "$word" "$root/deploy/windows/engine-setup.ps1" "$root/ops/backup/install-schedule.ps1" "$root/README.md" >>"$work/out"
  done
  if [ -s "$work/out" ]; then fail "$name" "остались упоминания"; show_out; return; fi
  ok "$name"

  name=engine_setup_refuses_migrate
  if ! is_windows || [ "${#shells[@]}" -eq 0 ]; then skip "$name" "нет PowerShell Windows"; return; fi
  local shell mode="${desktop_words[1]}"
  fake_clone "$(printf 'API_HTTP_PORT=28081\r\n')"
  for shell in "${shells[@]}"; do
    engine_setup "$shell" "-$mode" -DryRun
    [ "$rc" -ne 0 ] || { fail "$name/$shell" "-$mode принят, код 0"; show_out; return; }
    grep -q "$mode" "$work/out.$shell" || { fail "$name/$shell" "отказ не называет параметр"; show_out; return; }
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

# Звено -Check «журнал systemd на диске, сброс ≤ 10 с»: вывод
# systemd-analyze cat-config systemd/journald.conf, действует последнее
# присваивание; без SyncIntervalSec — 5 мин по умолчанию.
test_journald_config_problems() {
  local name=journald_config_problems shell
  if ! is_windows || [ "${#shells[@]}" -eq 0 ]; then skip "$name" "нет PowerShell Windows"; return; fi
  for shell in "${shells[@]}"; do
    # shellcheck disable=SC2016
    ps_functions "$shell" "$here/engine-setup.ps1" '
      $base = "# /etc/systemd/journald.conf`n[Journal]`n#Storage=auto`n#SyncIntervalSec=5m`n`n"
      $good = $base + "# /etc/systemd/journald.conf.d/domovoy-journal.conf`n[Journal]`nStorage=persistent`nSyncIntervalSec=10s`n"
      if (@(Get-JournaldProblems $good).Count) { "drop-in не принят: $(Get-JournaldProblems $good)"; exit 1 }
      foreach ($v in "10", "10s", "10sec", "9500ms", "1s 500ms", "5000000us") {
        $t = $base + "[Journal]`nStorage=persistent`nSyncIntervalSec=$v`n"
        if (@(Get-JournaldProblems $t).Count) { "отвергнут SyncIntervalSec=$v"; exit 1 }
      }
      $bad = @(
        ($base + "[Journal]`nStorage=persistent`n"),
        ($base + "[Journal]`nStorage=persistent`nSyncIntervalSec=30s`n"),
        ($base + "[Journal]`nStorage=persistent`nSyncIntervalSec=1min`n"),
        ($base + "[Journal]`nStorage=persistent`nSyncIntervalSec=`n"),
        ($base + "[Journal]`nStorage=volatile`nSyncIntervalSec=10s`n"),
        ($base + "[Journal]`nStorage=auto`nSyncIntervalSec=10s`n"),
        ($base + "[Journal]`nSyncIntervalSec=10s`n"),
        ($good + "# /etc/systemd/journald.conf.d/zz.conf`n[Journal]`nSyncIntervalSec=5min`n"),
        ($good + "[Journal]`nStorage=volatile`n"),
        ($base + "[Journal]`n#Storage=persistent`n;SyncIntervalSec=10s`n")
      )
      foreach ($t in $bad) { if (-not @(Get-JournaldProblems $t).Count) { "принято: $($t -replace "`n", "|")"; exit 1 } }
      $late = $base + "[Journal]`nStorage=volatile`nSyncIntervalSec=5min`n[Journal]`nStorage=persistent`nSyncIntervalSec=10s`n"
      if (@(Get-JournaldProblems $late).Count) { "последнее присваивание не перекрыло раннее"; exit 1 }' \
      Get-JournaldProblems ConvertFrom-SystemdTimeSpan
    [ "$rc" -eq 0 ] || { fail "$name/$shell" "код $rc"; show_out; return; }
  done
  ok "$name"
}

# Звено -Check «логи контейнеров проекта в journald»: строки docker inspect
# «/имя драйвер» против списка контейнеров; неполный ответ — не OK.
test_container_log_problems() {
  local name=container_log_problems shell
  if ! is_windows || [ "${#shells[@]}" -eq 0 ]; then skip "$name" "нет PowerShell Windows"; return; fi
  for shell in "${shells[@]}"; do
    # shellcheck disable=SC2016
    ps_functions "$shell" "$here/engine-setup.ps1" '
      $names = @("example-api-1", "example-postgres-1")
      if (@(Get-ContainerLogProblems $names @("/example-api-1 journald", "/example-postgres-1 journald")).Count) { "все journald — не OK"; exit 1 }
      $p = @(Get-ContainerLogProblems $names @("/example-api-1 journald", "/example-postgres-1 json-file"))
      if (-not $p.Count) { "json-file принят"; exit 1 }
      if (($p -join " ") -notmatch "example-postgres-1") { "замечание без имени контейнера: $p"; exit 1 }
      if (($p -join " ") -notmatch "--force-recreate") { "замечание без подсказки --force-recreate: $p"; exit 1 }
      if (($p -join " ") -match "example-api-1") { "назван контейнер с journald: $p"; exit 1 }
      if (-not @(Get-ContainerLogProblems $names @("/example-api-1 journald")).Count) { "неполный ответ принят"; exit 1 }
      if (-not @(Get-ContainerLogProblems $names @()).Count) { "пустой ответ принят"; exit 1 }' \
      Get-ContainerLogProblems
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

# Заглушка /health: python на 127.0.0.1, ответы «код тело» по очереди на
# каждый запрос, последний повторяется. Порт выбирает ОС (bind на 0) и
# кладёт в stub_port: случайный порт из теста попадал в диапазоны, которые
# Windows резервирует под Hyper-V, и заглушка не поднималась.
stub_port=''
start_stub_seq() {
  local python i=0 response
  stub_port=''
  python="$(python_cmd)"
  rm -rf -- "$work/stub" && mkdir -p "$work/stub"
  for response in "$@"; do printf '%s' "$response" >"$work/stub/resp.$i"; i=$((i + 1)); done
  cat >"$work/stub/server.py" <<'EOF'
import http.server, os, sys
folder = sys.argv[1]
names = sorted((f for f in os.listdir(folder) if f.startswith('resp.')), key=lambda f: int(f.split('.')[1]))
responses = [open(os.path.join(folder, f), encoding='utf-8').read() for f in names]
served = [0]
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        code, _, body = responses[min(served[0], len(responses) - 1)].partition(' ')
        served[0] += 1
        data = body.encode('utf-8')
        self.send_response(int(code))
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def log_message(self, *args):
        pass
server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
with open(os.path.join(folder, 'port.tmp'), 'w') as f:
    f.write(str(server.server_address[1]))
os.replace(os.path.join(folder, 'port.tmp'), os.path.join(folder, 'port'))
server.serve_forever()
EOF
  # python Windows не понимает путь MSYS, а MSYS_NO_PATHCONV его не переводит.
  "$python" "$(cygpath -w "$work/stub/server.py")" "$(cygpath -w "$work/stub")" >/dev/null 2>&1 &
  stub_pid=$!
  for _ in $(seq 1 100); do
    if [ -s "$work/stub/port" ]; then
      stub_port="$(cat "$work/stub/port")"
      if (exec 3<>"/dev/tcp/127.0.0.1/$stub_port") 2>/dev/null; then return 0; fi
    fi
    sleep 0.2
  done
  return 1
}

# Заглушка с одним ответом 200.
start_stub() { start_stub_seq "200 $1"; }

stop_stub() {
  if [ -n "$stub_pid" ]; then kill "$stub_pid" 2>/dev/null; wait "$stub_pid" 2>/dev/null; stub_pid=''; fi
}

# Подменённый wsl.exe в каталоге $1: .cmd над python-сценарием, который
# пишет сырые байты. Вызовы — в calls.log; --list отдаёт имена из файла
# running (UTF-16LE, если есть файл utf16: с BOM, если в нём «bom»; иначе
# UTF-8); вызов зонда
# с номером n (с нуля) — файлы probe.<n>.out, .err, .code, после последнего
# повторяется последний.
make_fake_wsl() {
  local dir="$1" python
  python="$(command -v "$(python_cmd)")"
  rm -rf -- "$dir" && mkdir -p "$dir"
  : >"$dir/running"
  cat >"$dir/wsl.py" <<'EOF'
import os, sys
folder = os.path.dirname(os.path.abspath(__file__))
args = sys.argv[1:]
with open(os.path.join(folder, 'calls.log'), 'a', encoding='utf-8') as f:
    f.write(' '.join(args) + '\n')
out = sys.stdout.buffer
if '--list' in args:
    text = ''.join(n + '\r\n' for n in open(os.path.join(folder, 'running'), encoding='utf-8').read().split())
    marker = os.path.join(folder, 'utf16')
    if os.path.exists(marker):
        out.write((b'\xff\xfe' if open(marker).read().strip() == 'bom' else b'') + text.encode('utf-16-le'))
    else:
        out.write(text.encode('utf-8'))
    sys.exit(0)
counter = os.path.join(folder, 'probe.count')
n = int(open(counter).read()) if os.path.exists(counter) else 0
open(counter, 'w').write(str(n + 1))
steps = sorted(int(f.split('.')[1]) for f in os.listdir(folder) if f.startswith('probe.') and f.endswith('.out'))
if not steps:
    sys.exit(1)
base = os.path.join(folder, 'probe.%d' % min(n, steps[-1]))
out.write(open(base + '.out', 'rb').read())
out.flush()
if os.path.exists(base + '.err'):
    sys.stderr.buffer.write(open(base + '.err', 'rb').read())
    sys.stderr.flush()
sys.exit(int(open(base + '.code').read()) if os.path.exists(base + '.code') else 0)
EOF
  printf '@"%s" "%s" %%*\r\n' "$(cygpath -w "$python")" "$(cygpath -w "$dir/wsl.py")" >"$dir/wsl.cmd"
}

# probe_step <каталог> <n> <код> <stdout> [<stderr>]
probe_step() {
  printf '%s' "$4" >"$1/probe.$2.out"
  printf '%s' "$3" >"$1/probe.$2.code"
  if [ -n "${5:-}" ]; then printf '%s' "$5" >"$1/probe.$2.err"; fi
}

# Замер в $work/measure.log. Дистрибутив по умолчанию — заведомо не
# зарегистрированное имя: настоящий движок на машине разработчика тест не
# трогает; с подменённым wsl.exe имя задаёт measure_distro. Малый
# -StableMinutes — устоявшееся состояние кончает замер; пределы меняют
# measure_timeout и measure_stable (повтор параметра PowerShell не примет).
measure_run() {
  local shell="$1" port="$2"
  shift 2
  run "$shell" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$(cygpath -w "$here/measure-boot.ps1")" \
    -Port "$port" -Project example -Distro "${measure_distro:-example-not-registered}" -TimeoutMinutes "${measure_timeout:-0.25}" -StableMinutes "${measure_stable:-0.05}" \
    -IntervalSeconds 1 -LogPath "$(cygpath -w "$work/measure.log")" "$@"
}

measure() {
  rm -f "$work/measure.log"
  measure_run "$@"
}

log_has() { grep -qF -- "$1" "$work/measure.log"; }
show_log() { sed 's/^/    | /' "$work/measure.log"; }

# Номер первой строки журнала с подстрокой; нет — пусто.
log_line() { grep -nF -- "$1" "$work/measure.log" | head -n 1 | cut -d: -f1; }

test_measure_boot() {
  local name=measure_boot
  if ! is_windows; then skip "$name" "не Windows — замер читает журнал событий и реестр Windows"; return; fi
  if [ "${#shells[@]}" -eq 0 ]; then skip "$name" "нет ни pwsh, ни powershell.exe"; return; fi
  if ! python_cmd >/dev/null; then skip "$name" "нет python для заглушки /health"; return; fi
  local port shell line
  port="$(free_port)" || { skip "$name" "не нашёлся свободный порт"; return; }

  for shell in "${shells[@]}"; do
    # Ответ формы стека засчитан, но без данных о контейнерах итог не
    # зелёный: дистрибутив не зарегистрирован.
    name="measure_boot_counts_stack_health/$shell"
    start_stub '{"status":"healthy"}' || { fail "$name" "заглушка не поднялась"; stop_stub; return; }
    port="$stub_port"
    measure "$shell" "$port"
    stop_stub
    if [ "$rc" -eq 0 ]; then fail "$name" "без данных о контейнерах код 0"; show_log; return; fi
    for line in 'os_start=' 'last_boot=' 'fw_post_ms=' "port=$port" 'first_response=' 'код 200' 'status=healthy' \
      'distro_start=нет данных' 'result=нет данных о контейнерах'; do
      log_has "$line" || { fail "$name" "нет «$line»"; show_log; return; }
    done
    if log_has 'first_200=нет'; then fail "$name" "ответ формы стека не засчитан"; return; fi
    if log_has 'foreign='; then fail "$name" "ответ формы стека назван чужим"; return; fi
    if log_has 'result=ok'; then fail "$name" "итог ok без данных о контейнерах"; return; fi
    ok "$name"

    # Журнал прежней версии — UTF-8 без BOM: BOM дописывается в начало,
    # прежняя строка цела байт в байт, второй замер BOM не повторяет.
    name="measure_boot_adds_bom_to_old_log/$shell"
    local old_line='os_start=2026-01-01T00:00:00; result=нет ответа 200 за 30 мин'
    printf '%s\r\n' "$old_line" >"$work/measure.log"
    start_stub '{"status":"healthy"}' || { fail "$name" "заглушка не поднялась"; stop_stub; return; }
    port="$stub_port"
    measure_run "$shell" "$port"
    [ "$(head -c 3 "$work/measure.log" | od -An -tx1 | tr -d ' \n')" = 'efbbbf' ] || { stop_stub; fail "$name" "в начале журнала нет BOM"; return; }
    [ "$(tail -c +4 "$work/measure.log" | head -n 1 | tr -d '\r')" = "$old_line" ] || { stop_stub; fail "$name" "прежняя строка изменилась"; return; }
    measure_run "$shell" "$port"
    stop_stub
    [ "$(tail -c +4 "$work/measure.log" | head -c 3 | od -An -tx1 | tr -d ' \n')" != 'efbbbf' ] || { fail "$name" "BOM записан дважды"; return; }
    [ "$(grep -c 'first_response=' "$work/measure.log")" = 2 ] || { fail "$name" "в журнале не две итоговые строки"; show_log; return; }
    ok "$name"

    name="measure_boot_marks_foreign_listener/$shell"
    start_stub 'example foreign page' || { fail "$name" "заглушка не поднялась"; stop_stub; return; }
    port="$stub_port"
    measure "$shell" "$port"
    stop_stub
    if [ "$rc" -eq 0 ]; then fail "$name" "чужой ответ 200 засчитан (код 0)"; return; fi
    for line in 'first_200=нет' 'foreign=' 'чужой слушатель' 'result=нет ответа 200'; do
      log_has "$line" || { fail "$name" "нет «$line»"; show_log; return; }
    done
    if log_has 'status='; then fail "$name" "чужой ответ записан статусом /health"; show_log; return; fi
    ok "$name"

    # Без слушателя состояние не меняется: опрос кончается по
    # -StableMinutes (0.05), и итог называет эту причину и фактическое
    # время, а не -TimeoutMinutes (0.25).
    name="measure_boot_writes_line_without_answer/$shell"
    measure "$shell" "$port"
    if [ "$rc" -eq 0 ]; then fail "$name" "код 0 без слушателя"; return; fi
    for line in 'first_response=нет' 'first_200=нет' 'stop=stable через ' 'result=нет ответа 200 за '; do
      log_has "$line" || { fail "$name" "нет «$line»"; show_log; return; }
    done
    if log_has 'за 0.25 мин' || log_has 'за 30 мин' || log_has 'stop=timeout'; then fail "$name" "итог называет тайм-аут, а опрос кончился по стабильности"; show_log; return; fi
    grep -qE 'stop=stable через [0-9]+(\.[0-9]+)? мин; result=нет ответа 200 за [0-9]+(\.[0-9]+)? мин опроса' "$work/measure.log" \
      || { fail "$name" "время опроса не числом с точкой"; show_log; return; }
    ok "$name"

    # Состояние не меняется, но тайм-аут короче окна стабильности: причина
    # конца опроса — timeout.
    name="measure_boot_reports_timeout/$shell"
    measure_timeout=0.05 measure_stable=1 measure "$shell" "$port"
    if [ "$rc" -eq 0 ]; then fail "$name" "код 0 без слушателя"; return; fi
    log_has 'stop=timeout через ' || { fail "$name" "нет «stop=timeout»"; show_log; return; }
    if log_has 'stop=stable'; then fail "$name" "тайм-аут назван стабильностью"; show_log; return; fi
    ok "$name"
  done
}

# Смены статуса /health — строками по мере наступления, в порядке, с
# моментом и секундами от старта ОС; 503 {"status":"unhealthy"} — статус.
test_measure_boot_records_health_transitions() {
  local name=measure_boot_records_health_transitions
  if ! is_windows || [ "${#shells[@]}" -eq 0 ] || ! python_cmd >/dev/null; then skip "$name" "нет PowerShell Windows или python"; return; fi
  local port shell a b c
  port="$(free_port)" || { skip "$name" "не нашёлся свободный порт"; return; }
  for shell in "${shells[@]}"; do
    name="measure_boot_records_health_transitions/$shell"
    start_stub_seq '503 {"status":"unhealthy"}' '200 {"status":"degraded"}' '200 {"status":"healthy"}' \
      || { fail "$name" "заглушка не поднялась"; stop_stub; return; }
    port="$stub_port"
    measure "$shell" "$port"
    stop_stub
    [ "$rc" -eq 1 ] || { fail "$name" "код $rc, ожидался 1"; show_log; return; }
    a="$(log_line '; status=unhealthy')"; b="$(log_line '; status=degraded')"; c="$(log_line '; status=healthy')"
    [ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ] \
      || { fail "$name" "нет смен unhealthy → degraded → healthy по порядку"; show_log; return; }
    [ "$(grep -c '; status=' "$work/measure.log")" = 3 ] || { fail "$name" "строк смены статуса не три"; show_log; return; }
    grep '; status=' "$work/measure.log" | grep -qvE '^boot=[^;]*; health=[0-9T:-]+ \(\+[0-9]+ с\); status=[a-z]+; src=windows' \
      && { fail "$name" "строка смены без метки загрузки, момента, секунд или src"; show_log; return; }
    log_has 'result=нет данных о контейнерах' || { fail "$name" "итог не «нет данных о контейнерах»"; show_log; return; }
    ok "$name"
  done
}

# Статус не меняется — замер кончается по -StableMinutes, до тайм-аута.
test_measure_boot_stops_on_stable_status() {
  local name=measure_boot_stops_on_stable_status
  if ! is_windows || [ "${#shells[@]}" -eq 0 ] || ! python_cmd >/dev/null; then skip "$name" "нет PowerShell Windows или python"; return; fi
  local port shell began elapsed
  port="$(free_port)" || { skip "$name" "не нашёлся свободный порт"; return; }
  for shell in "${shells[@]}"; do
    name="measure_boot_stops_on_stable_status/$shell"
    start_stub '{"status":"degraded"}' || { fail "$name" "заглушка не поднялась"; stop_stub; return; }
    port="$stub_port"
    began=$SECONDS
    # -TimeoutMinutes 0.25 (15 с) у measure_run, -StableMinutes 0.05 (3 с).
    measure "$shell" "$port"
    elapsed=$((SECONDS - began))
    stop_stub
    [ "$rc" -ne 0 ] || { fail "$name" "код 0 без данных о контейнерах"; show_log; return; }
    [ "$elapsed" -lt 13 ] || { fail "$name" "замер шёл $elapsed с — не кончился по -StableMinutes до тайм-аута"; show_log; return; }
    [ "$(grep -c '; status=degraded' "$work/measure.log")" = 1 ] || { fail "$name" "строк status=degraded не одна"; show_log; return; }
    log_has 'first_response=' || { fail "$name" "нет итоговой строки"; show_log; return; }
    log_has 'stop=stable через ' || { fail "$name" "итог не называет остановку по стабильности"; show_log; return; }
    ok "$name"
  done
}

# Событие пишется сразу, а не после цикла: до конца замера в журнале уже
# есть os_start и смена статуса. Процесс затем останавливается тестом.
test_measure_boot_appends_events_before_finish() {
  local name=measure_boot_appends_events_before_finish
  if ! is_windows || [ "${#shells[@]}" -eq 0 ] || ! python_cmd >/dev/null; then skip "$name" "нет PowerShell Windows или python"; return; fi
  local port pid winpid seen=''
  port="$(free_port)" || { skip "$name" "не нашёлся свободный порт"; return; }
  start_stub_seq '503 {"status":"unhealthy"}' || { fail "$name" "заглушка не поднялась"; stop_stub; return; }
  port="$stub_port"
  rm -f "$work/measure.log"
  "${shells[0]}" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$(cygpath -w "$here/measure-boot.ps1")" \
    -Port "$port" -Project example -Distro example-not-registered -TimeoutMinutes 5 -StableMinutes 5 \
    -IntervalSeconds 1 -LogPath "$(cygpath -w "$work/measure.log")" >/dev/null 2>&1 </dev/null &
  pid=$!
  measure_pid="$pid"
  for _ in $(seq 1 60); do
    if [ -f "$work/measure.log" ] && log_has 'os_start=' && log_has '; status=unhealthy'; then seen=1; break; fi
    sleep 0.5
  done
  local alive=''
  kill -0 "$pid" 2>/dev/null && alive=1
  winpid="$(cat "/proc/$pid/winpid" 2>/dev/null || true)"
  if [ -n "$winpid" ]; then taskkill //F //T //PID "$winpid" >/dev/null 2>&1 || true; fi
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null
  measure_pid=''
  stop_stub
  [ -n "$seen" ] || { fail "$name" "за 30 с в журнале нет os_start и status=unhealthy"; [ -f "$work/measure.log" ] && show_log; return; }
  [ -n "$alive" ] || { fail "$name" "замер кончился до проверки — событие не доказано записанным до конца"; show_log; return; }
  if log_has 'first_response='; then fail "$name" "итоговая строка есть — замер уже кончился"; show_log; return; fi
  ok "$name"
}

# Дистрибутив не работает — wsl.exe -d не вызывается: замер не поднимает
# дистрибутив сам; хронология /health идёт дальше.
test_measure_boot_skips_engine_when_distro_not_running() {
  local name=measure_boot_skips_engine_when_distro_not_running
  if ! is_windows || [ "${#shells[@]}" -eq 0 ] || ! python_cmd >/dev/null; then skip "$name" "нет PowerShell Windows или python"; return; fi
  local port shell fake="$work/fakewsl"
  port="$(free_port)" || { skip "$name" "не нашёлся свободный порт"; return; }
  for shell in "${shells[@]}"; do
    name="measure_boot_skips_engine_when_distro_not_running/$shell"
    make_fake_wsl "$fake"
    printf 'example-other\n' >"$fake/running"
    start_stub '{"status":"degraded"}' || { fail "$name" "заглушка не поднялась"; stop_stub; return; }
    port="$stub_port"
    measure_distro=example-engine measure "$shell" "$port" -WslExe "$(cygpath -w "$fake/wsl.cmd")"
    stop_stub
    grep -q -- '--list --running --quiet' "$fake/calls.log" 2>/dev/null || { fail "$name" "список работающих не запрошен"; return; }
    if grep -q -- '^-d ' "$fake/calls.log"; then fail "$name" "wsl.exe -d вызван при неработающем дистрибутиве"; sed 's/^/    | /' "$fake/calls.log"; return; fi
    log_has 'distro_start=нет данных' || { fail "$name" "нет distro_start=нет данных"; show_log; return; }
    log_has '; status=degraded' || { fail "$name" "хронология /health не записана"; show_log; return; }
    ok "$name"
  done
}

# wsl.exe не учёл WSL_UTF8 и отдал список UTF-16LE — с BOM и без него: в
# обоих вариантах между буквами имени остаются NUL, с BOM в начале ещё и
# U+FFFD. Имя всё равно сопоставляется, зонд вызывается; кириллица из
# stderr зонда в журнале цела. Нагрузку на разбор даёт сравнение ordinal в
# measure-boot.ps1: культурное -contains пропускает NUL.
test_measure_boot_reads_utf16_wsl_list() {
  local name=measure_boot_reads_utf16_wsl_list
  if ! is_windows || [ "${#shells[@]}" -eq 0 ] || ! python_cmd >/dev/null; then skip "$name" "нет PowerShell Windows или python"; return; fi
  local port shell bom fake="$work/fakewsl"
  port="$(free_port)" || { skip "$name" "не нашёлся свободный порт"; return; }
  for shell in "${shells[@]}"; do
   for bom in bom nobom; do
    name="measure_boot_reads_utf16_wsl_list/$shell/$bom"
    make_fake_wsl "$fake"
    printf 'example-other\nexample-engine\n' >"$fake/running"
    printf '%s' "$bom" >"$fake/utf16"
    probe_step "$fake" 0 1 $'distro_start=1760331000\n' $'boot-probe: docker.service ещё не active\n'
    start_stub '{"status":"degraded"}' || { fail "$name" "заглушка не поднялась"; stop_stub; return; }
    port="$stub_port"
    measure_distro=example-engine measure "$shell" "$port" -WslExe "$(cygpath -w "$fake/wsl.cmd")"
    stop_stub
    grep -q -- '^-d example-engine -u root --cd .* --exec bash deploy/windows/boot-probe.sh example$' "$fake/calls.log" \
      || { fail "$name" "зонд не вызван — имя в UTF-16 не сопоставлено"; sed 's/^/    | /' "$fake/calls.log"; show_log; return; }
    grep -qE '; distro_start=[0-9T:-]+ .*; src=engine$' <(tr -d '\r' <"$work/measure.log") || { fail "$name" "нет события distro_start"; show_log; return; }
    log_has 'text=boot-probe: docker.service ещё не active' || { fail "$name" "кириллица stderr зонда в журнале искажена или не записана"; show_log; return; }
    ok "$name"
   done
  done
}

# Зонд отказывает, затем отдаёт только distro_start, затем всё: замер не
# падает, события появляются по мере данных, distro_start — один раз.
test_measure_boot_survives_probe_failures() {
  local name=measure_boot_survives_probe_failures
  if ! is_windows || [ "${#shells[@]}" -eq 0 ] || ! python_cmd >/dev/null; then skip "$name" "нет PowerShell Windows или python"; return; fi
  local port shell fake="$work/fakewsl" first_docker first_data
  port="$(free_port)" || { skip "$name" "не нашёлся свободный порт"; return; }
  for shell in "${shells[@]}"; do
    name="measure_boot_survives_probe_failures/$shell"
    make_fake_wsl "$fake"
    printf 'example-engine\n' >"$fake/running"
    probe_step "$fake" 0 1 '' $'boot-probe: возраст PID 1 не разобран\n'
    probe_step "$fake" 1 1 '' $'boot-probe: возраст PID 1 не разобран\n'
    probe_step "$fake" 2 1 '' $'boot-probe: возраст PID 1 не разобран\n'
    probe_step "$fake" 3 1 $'distro_start=1760331000\n' $'boot-probe: docker.service ещё не active\n'
    probe_step "$fake" 4 0 $'distro_start=1760331000\ndocker_active=1760331010\ncontainer name=example-api-1 started_at=1760331020 health=healthy\ncontainer name=example-postgres-1 started_at=1760331015 health=none\n'
    start_stub '{"status":"healthy"}' || { fail "$name" "заглушка не поднялась"; stop_stub; return; }
    port="$stub_port"
    # Три одинаковых отказа подряд — не смена состояния; окно стабильности
    # (12 с) и тайм-аут (60 с) шире серии отказов, иначе на медленном
    # powershell.exe опрос кончается до данных зонда. Зелёный случай
    # кончается по готовности, а не по пределам.
    measure_distro=example-engine measure_stable=0.2 measure_timeout=1 measure "$shell" "$port" -WslExe "$(cygpath -w "$fake/wsl.cmd")"
    stop_stub
    [ "$rc" -eq 0 ] || { fail "$name" "код $rc — все контейнеры healthy, ожидался 0"; show_log; return; }
    log_has 'stop=ready через ' || { fail "$name" "итог не называет остановку по готовности"; show_log; return; }
    [ "$(grep -c '; distro_start=' "$work/measure.log")" = 1 ] || { fail "$name" "distro_start не одной строкой"; show_log; return; }
    first_docker="$(log_line '; docker_active=')"
    first_data="$(log_line '; distro_start=')"
    [ -n "$first_docker" ] && [ "$first_data" -lt "$first_docker" ] || { fail "$name" "docker_active не после distro_start"; show_log; return; }
    [ "$(cat "$fake/probe.count")" -ge 5 ] || { fail "$name" "зонд вызван меньше пяти раз — отказы прервали опрос"; return; }
    for line in '; container_start=' 'name=example-api-1' '; container_healthy=' 'healthcheck=нет' 'result=ok'; do
      log_has "$line" || { fail "$name" "нет «$line»"; show_log; return; }
    done
    [ "$(grep -c 'probe_error=' "$work/measure.log")" = 2 ] || { fail "$name" "строк probe_error не две (по смене текста)"; show_log; return; }
    ok "$name"
  done
}

# Зонд отказывает всегда, /health healthy: пустой набор контейнеров «все
# healthy» не выполняет — замер не кончается на healthy /health и итог не ok.
test_measure_boot_probe_always_fails_not_ok() {
  local name=measure_boot_probe_always_fails_not_ok
  if ! is_windows || [ "${#shells[@]}" -eq 0 ] || ! python_cmd >/dev/null; then skip "$name" "нет PowerShell Windows или python"; return; fi
  local port shell fake="$work/fakewsl"
  port="$(free_port)" || { skip "$name" "не нашёлся свободный порт"; return; }
  for shell in "${shells[@]}"; do
    name="measure_boot_probe_always_fails_not_ok/$shell"
    make_fake_wsl "$fake"
    printf 'example-engine\n' >"$fake/running"
    probe_step "$fake" 0 1 '' $'boot-probe: возраст PID 1 не разобран\n'
    start_stub '{"status":"healthy"}' || { fail "$name" "заглушка не поднялась"; stop_stub; return; }
    port="$stub_port"
    # Окно стабильности (12 с) вмещает не меньше трёх вызовов зонда и на
    # медленном шелле: при 3 с опрос кончался по стабильности после двух.
    measure_distro=example-engine measure_stable=0.2 measure_timeout=1 measure "$shell" "$port" -WslExe "$(cygpath -w "$fake/wsl.cmd")"
    stop_stub
    [ "$rc" -eq 1 ] || { fail "$name" "код $rc, ожидался 1"; show_log; return; }
    [ "$(cat "$fake/probe.count")" -ge 3 ] || { fail "$name" "замер кончился на healthy /health, не дождавшись контейнеров"; show_log; return; }
    if grep -qE '; (docker_active|container_start|container_healthy)=' "$work/measure.log"; then fail "$name" "события движка без данных зонда"; show_log; return; fi
    log_has 'result=нет данных о контейнерах' || { fail "$name" "итог не «нет данных о контейнерах»"; show_log; return; }
    if log_has 'result=ok'; then fail "$name" "итог ok без данных о контейнерах"; return; fi
    ok "$name"
  done
}

# Перезапуск контейнера в окне замера: новый started_at — вторая строка
# container_start с пометкой restart, healthy ждётся заново; без смены
# started_at повтора нет.
test_measure_boot_records_container_restart() {
  local name=measure_boot_records_container_restart
  if ! is_windows || [ "${#shells[@]}" -eq 0 ] || ! python_cmd >/dev/null; then skip "$name" "нет PowerShell Windows или python"; return; fi
  local port shell fake="$work/fakewsl" starts healthies restart second_healthy
  port="$(free_port)" || { skip "$name" "не нашёлся свободный порт"; return; }
  for shell in "${shells[@]}"; do
    name="measure_boot_records_container_restart/$shell"
    make_fake_wsl "$fake"
    printf 'example-engine\n' >"$fake/running"
    local probe_head=$'distro_start=1760331000\ndocker_active=1760331010\n'
    probe_step "$fake" 0 0 "${probe_head}container name=example-api-1 started_at=1760331020 health=healthy"$'\n'
    probe_step "$fake" 1 0 "${probe_head}container name=example-api-1 started_at=1760331090 health=starting"$'\n'
    probe_step "$fake" 2 0 "${probe_head}container name=example-api-1 started_at=1760331090 health=starting"$'\n'
    probe_step "$fake" 3 0 "${probe_head}container name=example-api-1 started_at=1760331090 health=healthy"$'\n'
    start_stub_seq '200 {"status":"degraded"}' '200 {"status":"degraded"}' '200 {"status":"degraded"}' '200 {"status":"healthy"}' \
      || { fail "$name" "заглушка не поднялась"; stop_stub; return; }
    port="$stub_port"
    # Между перезапуском и healthy два опроса без смены: окно стабильности
    # (12 с) их вмещает и на медленном шелле; зелёный случай кончается по
    # готовности.
    measure_distro=example-engine measure_stable=0.2 measure_timeout=1 measure "$shell" "$port" -WslExe "$(cygpath -w "$fake/wsl.cmd")"
    stop_stub
    starts="$(grep -c '; container_start=.*name=example-api-1' "$work/measure.log")"
    healthies="$(grep -c '; container_healthy=.*name=example-api-1' "$work/measure.log")"
    [ "$starts" = 2 ] || { fail "$name" "строк container_start $starts, ожидалось 2"; show_log; return; }
    [ "$healthies" = 2 ] || { fail "$name" "строк container_healthy $healthies, ожидалось 2"; show_log; return; }
    restart="$(grep -n '; container_start=.*; restart; ' "$work/measure.log" | head -n 1 | cut -d: -f1)"
    second_healthy="$(grep -n '; container_healthy=.*name=example-api-1' "$work/measure.log" | sed -n 2p | cut -d: -f1)"
    [ -n "$restart" ] && [ -n "$second_healthy" ] && [ "$restart" -lt "$second_healthy" ] \
      || { fail "$name" "второй старт без пометки restart или healthy не после него"; show_log; return; }
    log_has 'result=ok' || { fail "$name" "итог не ok"; show_log; return; }
    ok "$name"
  done
}

# Разбор вывода зонда и статуса /health — функциями measure-boot.ps1 из
# AST: секунды Unix → тот же местный момент, что FromUnixTimeSeconds(…)
# .ToLocalTime(); местное время вместо секунд — нет данных, а не сдвиг.
test_boot_probe_parse() {
  local name=boot_probe_parse shell
  if ! is_windows || [ "${#shells[@]}" -eq 0 ]; then skip "$name" "нет PowerShell Windows"; return; fi
  for shell in "${shells[@]}"; do
    # shellcheck disable=SC2016
    ps_functions "$shell" "$here/measure-boot.ps1" '
      $d = ConvertFrom-BootProbe @("distro_start=1760331000", "docker_active=1760331010", "container name=example-api-1 started_at=1760331020 health=healthy", "container name=example-postgres-1 started_at=1760331015 health=none", "noise")
      $want = [DateTimeOffset]::FromUnixTimeSeconds(1760331000).ToLocalTime().DateTime
      if ($d.DistroStart -ne $want) { "distro_start $($d.DistroStart), ожидалось $want"; exit 1 }
      if ($d.DockerActive -ne [DateTimeOffset]::FromUnixTimeSeconds(1760331010).ToLocalTime().DateTime) { "docker_active не тот"; exit 1 }
      if (@($d.Containers).Count -ne 2) { "контейнеров $(@($d.Containers).Count)"; exit 1 }
      $api = @($d.Containers)[0]
      if ($api.Name -ne "example-api-1" -or $api.Health -ne "healthy" -or $api.StartedAt -ne [DateTimeOffset]::FromUnixTimeSeconds(1760331020).ToLocalTime().DateTime) { "контейнер api разобран не так"; exit 1 }
      if (@($d.Containers)[1].Health -ne "none") { "health=none потерян"; exit 1 }
      $local = ConvertFrom-BootProbe @("distro_start=Mon Oct 13 08:50:00 2025", "docker_active=2025-10-13T08:50:10+03:00", "container name=example-api-1 started_at=2025-10-13T05:50:20Z health=healthy")
      if ($null -ne $local.DistroStart -or $null -ne $local.DockerActive -or @($local.Containers).Count) { "местное время принято за момент"; exit 1 }
      $partial = ConvertFrom-BootProbe @("distro_start=1760331000")
      if ($null -eq $partial.DistroStart -or $null -ne $partial.DockerActive) { "частичный вывод не засчитан построчно"; exit 1 }
      foreach ($case in @(@(200, "{`"status`":`"healthy`"}", "healthy", $false), @(200, "{`"status`":`"degraded`"}", "degraded", $false), @(503, "{`"status`":`"unhealthy`"}", "unhealthy", $false),
                          @(200, "example foreign page", "", $true), @(200, "{`"status`":`"unhealthy`"}", "", $true), @(503, "example error", "", $false), @(503, "{`"status`":`"healthy`"}", "", $false))) {
        $h = Get-HealthStatus $case[0] $case[1]
        if ($h.Status -ne $case[2] -or $h.Foreign -ne $case[3]) { "Get-HealthStatus $($case[0]) $($case[1]): $($h.Status)/$($h.Foreign)"; exit 1 }
      }
      $names = ConvertFrom-WslList @(([char]0xFFFD + [char]0xFFFD + "e`0x`0a`0m`0p`0l`0e`0-`0e`0n`0g`0i`0n`0e`0`r`0"), "`0")
      if ($names -notcontains "example-engine") { "имя из UTF-16 не разобрано: $($names -join "|")"; exit 1 }' \
      ConvertFrom-BootProbe ConvertFrom-UnixSeconds Get-HealthStatus ConvertFrom-WslList
    [ "$rc" -eq 0 ] || { fail "$name/$shell" "код $rc"; show_out; return; }
  done
  ok "$name"
}

# README говорит, где читать логи и хронологию, и держит опоры пути нового
# ПК. Полноту и выполнимость шагов проверяет чтение, не этот поиск.
test_readme_points_to_logs() {
  local name=readme_points_to_logs pattern
  for pattern in 'journalctl CONTAINER_NAME=' 'measure-boot.log' 'engine-setup.ps1 -Install' 'restore.sh --project <COMPOSE_PROJECT_NAME> --from '; do
    grep -qF -- "$pattern" "$root/README.md" || { fail "$name" "в README нет «$pattern»"; return; }
  done
  ok "$name"
}

test_shell_scripts_parse
test_no_hardcoded_api_port
test_wsl_conf_is_merged
test_mss_clamp_unit
test_journald_dropin
test_docker_log_driver
test_boot_probe_output
test_apt_waits_for_lock
test_no_localhost_url
test_docker_wsl_passes_arguments
test_ps1_encoding_and_parse
test_no_docker_desktop_paths
test_engine_setup_dry_run
test_uninstall_dry_run_without_rollback
test_rule_profile_private_only
test_vm_firewall_problems
test_journald_config_problems
test_container_log_problems
test_native_output_encoding
test_boot_probe_parse
test_measure_boot
test_measure_boot_records_health_transitions
test_measure_boot_stops_on_stable_status
test_measure_boot_appends_events_before_finish
test_measure_boot_skips_engine_when_distro_not_running
test_measure_boot_reads_utf16_wsl_list
test_measure_boot_survives_probe_failures
test_measure_boot_probe_always_fails_not_ok
test_measure_boot_records_container_restart
test_readme_points_to_logs

echo "итог: пройдено $passed, упало $failed, пропущено $skipped"
[ "$failed" -eq 0 ]
