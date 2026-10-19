#!/usr/bin/env bash
#
# Домовой — проверочные сценарии стенда агента (scripts/stand.sh, #164).
#
# ЗАЧЕМ
#
# stand.sh работает в одном движке с боевым стеком владельца. Ошибка в нём
# не тихая, а разрушительная: down, удаливший чужой образ или том, отказ,
# пропущенный на имени domovoy, или токен HA в выводе. Здесь проверяется то,
# что можно проверить без движка: какие команды сценарий отдаёт движку, что
# он пишет в каталог стенда и что печатает.
#
# ДВИЖОК ЭТИ СЦЕНАРИИ НЕ ТРОГАЮТ
#
# Идут на ubuntu-раннере CI без WSL. В начале PATH лежат подделки:
#   - wsl.exe — пишет каждый вызов строкой в журнал; docker внутри
#     «дистрибутива» исполняет подделка движка с состоянием в файлах
#     (образы, строители, контейнеры-потребители образов, слушатели портов),
#     а sh, wslpath и ss исполняются локально, с HOME во временном каталоге —
#     это и есть файловая система «дистрибутива»;
#   - cygpath и wslpath — пути как есть;
#   - ss и netstat — слушатели из файлов состояния;
#   - netsh.exe — исключённые диапазоны портов Windows из файла состояния;
#   - git — подменяет только worktree list, остальное отдаёт настоящему git;
#   - docker — голый docker хоста: пишет свой журнал, который обязан
#     остаться пустым;
#   - curl — /health стенда отвечает 200.
#
# ЧЕГО ЭТИ СЦЕНАРИИ НЕ ЛОВЯТ
#
# Поведение настоящих docker compose, buildx и HA: загрузку образа строителем
# docker-container в хранилище движка, онбординг и переименование сущностей
# demo, разбор аргументов wsl.exe. Это проверяет живой прогон стенда (#164,
# контракт приёмки A-up, A-down, A-df).
#
# КАК ЗАПУСКАТЬ
#
#   bash scripts/stand.test.sh
#
# Код возврата: 0 — все сценарии прошли, 1 — есть провалившиеся,
# 2 — запустить нечем.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET="$SCRIPT_DIR/stand.sh"

for f in "$TARGET" "$REPO/docker-compose.yml" "$REPO/.env.example" \
    "$REPO/config/entities.example.yaml" "$REPO/deploy/stand/docker-compose.stand.yml"; do
    if [ ! -f "$f" ]; then
        printf 'Не найден %s\n' "$f" >&2
        exit 2
    fi
done

REAL_GIT="$(command -v git)" || { printf 'Нет git\n' >&2; exit 2; }

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

BIN="$SANDBOX/bin"
STATE="$SANDBOX/state"
FAKE_HOME="$SANDBOX/home"
CLONE="$SANDBOX/clone"
WORKTREE="$CLONE/.claude/worktrees/164"
LOG="$SANDBOX/engine.log"
BARE_LOG="$SANDBOX/bare-docker.log"
TOKEN='TOKEN-MARKER-7f3a9c'
OWNER_MARKER='OWNER-VALUE-MARKER-51e2'
BUILDKIT='moby/buildkit:v0.34.0'
HA_IMAGE="$(sed -nE "s/^[[:space:]]*image:[[:space:]]*(ghcr[^[:space:]#]+).*/\1/p" "$REPO/docker-compose.yml")"
PG_IMAGE="$(sed -nE "s/^[[:space:]]*image:[[:space:]]*(postgres[^[:space:]#]+).*/\1/p" "$REPO/docker-compose.yml")"

mkdir -p "$BIN" "$STATE" "$FAKE_HOME"

# --- Временный клон: основное дерево и worktree 164 --------------------------

make_tree() {
    local dir="$1"
    mkdir -p "$dir/scripts" "$dir/config" "$dir/deploy/stand"
    cp "$TARGET" "$dir/scripts/stand.sh"
    cp "$REPO/docker-compose.yml" "$REPO/.env.example" "$dir/"
    cp "$REPO"/config/*.example.* "$dir/config/"
    cp "$REPO"/deploy/stand/* "$dir/deploy/stand/"
    # Значения владельца, которые стенду недостижимы.
    printf 'HA_TOKEN=%s\nPOSTGRES_PASSWORD=%s\n' "$OWNER_MARKER" "$OWNER_MARKER" > "$dir/.env"
    printf 'entities:\n  - entity_id: light.%s\n' "$OWNER_MARKER" > "$dir/config/entities.yaml"
}
make_tree "$CLONE"
make_tree "$WORKTREE"

# --- Подделки ----------------------------------------------------------------

cat > "$BIN/wsl.exe" <<'EOF'
#!/usr/bin/env bash
# Подделка wsl.exe: -d <distro> --exec <команда> …
while [ $# -gt 0 ]; do
    case "$1" in
        -d) shift 2 ;;
        --cd) shift 2 ;;
        --exec) shift; break ;;
        *) shift ;;
    esac
done
if [ -f "$FAKE_STATE/no_distro" ]; then
    echo 'There is no distribution with the supplied name.' >&2
    exit 1
fi
printf '%s\n' "$*" >> "$FAKE_LOG"
cmd="$1"
shift
if [ "$cmd" = env ]; then
    while [ $# -gt 0 ] && [[ "$1" == *=* ]]; do export "$1"; shift; done
    cmd="$1"
    shift
fi
if [ "$cmd" = docker ]; then
    # Настоящий wsl.exe пересылает stdin процессу и читает его, даже когда
    # процессу он не нужен: цикл read вокруг вызова движка теряет остаток.
    case " $* " in *' exec '*) ;; *) cat > /dev/null ;; esac
    exec "$FAKE_BIN/engine-docker" "$@"
fi
HOME="$FAKE_HOME" exec "$cmd" "$@"
EOF

cat > "$BIN/engine-docker" <<'EOF'
#!/usr/bin/env bash
# Подделка docker внутри движка. Состояние — файлы в $FAKE_STATE:
#   images     — строки «<ссылка> <ID>»
#   builders   — имена строителей buildx
#   ancestors  — строки «<ID образа> <ID контейнера>»
#   prod_wd    — метка working_dir контейнеров проекта domovoy
#   engine_down — docker info отвечает ошибкой
#   probes     — строки «<значение метки domovoy-stand.probe> <ID контейнера>»
S="$FAKE_STATE"
touch "$S/images" "$S/builders" "$S/ancestors" "$S/probes"
args="$*"
id_of() { printf 'sha256:id-%s' "$(printf '%s' "$1" | tr -c 'a-z0-9' '-')"; }
add_image() { grep -q "^$1 " "$S/images" || printf '%s %s\n' "$1" "$(id_of "$1")" >> "$S/images"; }
arg_after() { local want="$1"; shift; while [ $# -gt 1 ]; do [ "$1" = "$want" ] && { printf '%s' "$2"; return; }; shift; done; }

case "$1" in
    info)
        [ -f "$S/engine_down" ] && { echo 'Cannot connect to the Docker daemon' >&2; exit 1; }
        echo '29.0.0'
        ;;
    ps)
        case "$args" in
            *label=com.docker.compose.project=domovoy\ *)
                [ -f "$S/prod_wd" ] && cat "$S/prod_wd" ;;
            *ancestor=*)
                id="${args##*ancestor=}"; id="${id%% *}"
                awk -v i="$id" '$1 == i { print $2 }' "$S/ancestors" ;;
            *label=domovoy-stand.probe=*)
                # Метка сравнивается целиком, как в настоящем движке.
                v="${args##*label=domovoy-stand.probe=}"; v="${v%% *}"
                awk -v v="$v" '$1 == v { print $2 }' "$S/probes" ;;
        esac
        ;;
    rm)
        shift
        while [ $# -gt 0 ] && [ "${1#-}" != "$1" ]; do shift; done
        for c in "$@"; do
            awk -v c="$c" '$2 != c' "$S/probes" > "$S/probes.tmp"; mv "$S/probes.tmp" "$S/probes"
        done
        ;;
    image)
        case "$2" in
            inspect)
                ref="${*: -1}"
                line="$(grep "^$ref " "$S/images")" || exit 1
                echo "${line#* }" ;;
            ls)
                ref="${args##*reference=}"; ref="${ref%% *}"
                awk -v r="$ref" '$1 == r { print $2 }' "$S/images" ;;
            rm)
                id="${*: -1}"
                grep -q " $id\$" "$S/images" || { echo "No such image: $id" >&2; exit 1; }
                grep -v " $id\$" "$S/images" > "$S/images.tmp"; mv "$S/images.tmp" "$S/images" ;;
        esac
        ;;
    buildx)
        case "$2" in
            create)
                name="$(arg_after --name "$@")"
                opt="$(arg_after --driver-opt "$@")"
                add_image "${opt#image=}"
                echo "$name" >> "$S/builders" ;;
            inspect) grep -qx "$3" "$S/builders" ;;
            rm)
                grep -vx "$3" "$S/builders" > "$S/builders.tmp"; mv "$S/builders.tmp" "$S/builders" ;;
        esac
        ;;
    compose)
        project="$(arg_after -p "$@")"
        case " $args " in
            *' create '*) add_image "$FAKE_PG_IMAGE"; add_image "$FAKE_HA_IMAGE" ;;
            *' build '*) add_image "$project-api" ;;
            *' down '*)
                grep -v "^$project-api " "$S/images" > "$S/images.tmp"; mv "$S/images.tmp" "$S/images" ;;
            *' onboard '*) echo "$FAKE_TOKEN" ;;
            *' report '*)
                IFS= read -r t
                if [ "$t" = "$FAKE_TOKEN" ]; then echo 'http 200'; else echo 'http 401'; fi
                echo 'renamed 11'
                echo 'missing binary_sensor.example_kitchen_window' ;;
            *' ps --status running -q homeassistant '*)
                [ -f "$S/ha_stopped" ] || echo 'c-stand-ha' ;;
            *' ps '*)
                printf 'api running healthy\npostgres running healthy\nhomeassistant running healthy\n' ;;
            *' logs '*) echo 'api-1  | Now listening on: http://[::]:8080' ;;
        esac
        ;;
esac
exit 0
EOF

cat > "$BIN/cygpath" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${*: -1}"
EOF

cat > "$BIN/wslpath" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${*: -1}"
EOF

cat > "$BIN/ss" <<'EOF'
#!/usr/bin/env bash
[ -f "$FAKE_STATE/ss" ] && cat "$FAKE_STATE/ss"
exit 0
EOF

cat > "$BIN/netstat" <<'EOF'
#!/usr/bin/env bash
[ -f "$FAKE_STATE/netstat" ] && cat "$FAKE_STATE/netstat"
exit 0
EOF

# Перекрывает netsh.exe из System32: исключённые диапазоны портов Windows —
# из файла состояния, по умолчанию их нет.
cat > "$BIN/netsh.exe" <<'EOF'
#!/usr/bin/env bash
[ -f "$FAKE_STATE/excluded" ] && cat "$FAKE_STATE/excluded"
exit 0
EOF

cat > "$BIN/git" <<EOF
#!/usr/bin/env bash
case " \$* " in
    *' worktree list '*) printf 'worktree %s\nHEAD 0000000000000000000000000000000000000000\nbranch refs/heads/main\n' "\$FAKE_MAIN_TREE"; exit 0 ;;
esac
exec "$REAL_GIT" "\$@"
EOF

cat > "$BIN/docker" <<'EOF'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >> "$FAKE_BARE_LOG"
exit 0
EOF

cat > "$BIN/curl" <<'EOF'
#!/usr/bin/env bash
printf '200'
EOF

chmod +x "$BIN"/*

export PATH="$BIN:$PATH"
export FAKE_BIN="$BIN" FAKE_STATE="$STATE" FAKE_HOME FAKE_LOG="$LOG" FAKE_BARE_LOG="$BARE_LOG"
export FAKE_TOKEN="$TOKEN" FAKE_MAIN_TREE="$CLONE" FAKE_HA_IMAGE="$HA_IMAGE" FAKE_PG_IMAGE="$PG_IMAGE"
unset DOMOVOY_ENGINE_DISTRO

# --- Каркас сценариев --------------------------------------------------------

PASSED=0
FAILED=0
FAILED_NAMES=()
CASE_NAME=''
CASE_OK=1
OUT=''
ERR=''
STATUS=0

begin_case() {
    CASE_NAME="$1"
    CASE_OK=1
    printf '\n[ ... ] %s\n' "$CASE_NAME"
    reset_engine
}

fail_case() {
    CASE_OK=0
    printf '        ! %s\n' "$1"
}

end_case() {
    if [ "$CASE_OK" -eq 1 ]; then
        PASSED=$((PASSED + 1))
        printf '[ ok  ] %s\n' "$CASE_NAME"
    else
        FAILED=$((FAILED + 1))
        FAILED_NAMES+=("$CASE_NAME")
        printf '[ FAIL] %s\n' "$CASE_NAME"
        printf '        stdout:\n%s\n' "$OUT" | sed 's/^/        /'
        printf '        stderr:\n%s\n' "$ERR" | sed 's/^/        /'
        printf '        журнал движка:\n%s\n' "$(cat "$LOG" 2>/dev/null)" | sed 's/^/        /'
    fi
}

# Чистый движок: в нём уже есть боевой стек (postgres и HA вытянуты им).
reset_engine() {
    rm -rf "$STATE" "$FAKE_HOME"
    mkdir -p "$STATE" "$FAKE_HOME"
    : > "$LOG"
    : > "$BARE_LOG"
    printf '%s sha256:prod-pg\n%s sha256:prod-ha\ndomovoy-api sha256:prod-api\n' \
        "$PG_IMAGE" "$HA_IMAGE" > "$STATE/images"
    printf '/srv/domovoy-prod\n' > "$STATE/prod_wd"
    printf 'sha256:prod-pg c-prod-pg\nsha256:prod-ha c-prod-ha\nsha256:prod-api c-prod-api\n' > "$STATE/ancestors"
}

# run_stand <каталог дерева> <аргументы…>
run_stand() {
    local tree="$1"
    shift
    local o e
    o="$SANDBOX/out"
    e="$SANDBOX/err"
    bash "$tree/scripts/stand.sh" "$@" > "$o" 2> "$e" < /dev/null
    STATUS=$?
    OUT="$(cat "$o")"
    ERR="$(cat "$e")"
}

expect_status() {
    [ "$STATUS" -eq "$1" ] || fail_case "код $STATUS, ожидался $1"
}

expect_err_first() {
    local first
    first="$(printf '%s\n' "$ERR" | head -n 1)"
    case "$first" in
        "stand: отказ: "*"$1"*) ;;
        *) fail_case "первая строка stderr «$first» не начинается с «stand: отказ: » и не содержит «$1»" ;;
    esac
}

log_has() {
    grep -qF -- "$1" "$LOG" || fail_case "в журнале движка нет «$1»"
}

log_lacks_re() {
    if grep -qE -- "$1" "$LOG"; then
        fail_case "в журнале движка есть /$1/: $(grep -E -- "$1" "$LOG" | head -n 3 | tr '\n' ';')"
    fi
}

# Ни одной меняющей команды: проверки отказа идут до первого изменения.
expect_no_changes() {
    log_lacks_re 'compose .* (up|create|cp|run|build|down)( |$)'
    log_lacks_re 'buildx (create|rm)'
    log_lacks_re 'image rm|mkdir|cat >|rm -rf'
    [ ! -e "$FAKE_HOME/domovoy-stand" ] || fail_case 'каталог стенда создан'
}

expect_no_bare_docker() {
    [ ! -s "$BARE_LOG" ] || fail_case "вызван голый docker: $(head -n 3 "$BARE_LOG" | tr '\n' ';')"
}

pulled_file() { printf '%s/domovoy-stand/%s/pulled-images' "$FAKE_HOME" "$1"; }

probe_port() { printf '%s\n' "$OUT" | sed -n 's/^STAND_PROBE_PORT=//p'; }

# --- Отказы ------------------------------------------------------------------

begin_case 'отказ: имя domovoy'
run_stand "$WORKTREE" up --name domovoy
expect_status 1
expect_err_first 'domovoy — имя боевого проекта'
expect_no_changes
run_stand "$WORKTREE" down --name domovoy
expect_status 1
expect_err_first 'domovoy — имя боевого проекта'
expect_no_changes
log_lacks_re 'compose|image rm|buildx'
end_case

begin_case 'отказ: занятый порт'
printf 'LISTEN 0 4096 0.0.0.0:19007 0.0.0.0:*\n' > "$STATE/ss"
run_stand "$WORKTREE" up --name 7
expect_status 1
expect_err_first 'порт 19007 занят'
expect_no_changes
end_case

begin_case 'отказ: занятый порт по netstat хоста'
printf '  TCP    127.0.0.1:9007         0.0.0.0:0              LISTENING       4242\r\n' > "$STATE/netstat"
run_stand "$WORKTREE" up --name 7
expect_status 1
expect_err_first 'порт 9007 занят'
expect_no_changes
end_case

begin_case 'порты: исключённый диапазон Windows считается занятым'
# Шапка на русском, подвал со звёздочкой, CRLF — как у настоящего netsh.
printf '\r\nДиапазоны исключенных портов для протокола tcp\r\n\r\nНачальный порт    Конечный порт\r\n----------    --------\r\n     20060       20069\r\n     20070       20070\r\n     19007       19007 *\r\n\r\n* - Административно исключенные диапазоны портов.\r\n' \
    > "$STATE/excluded"
run_stand "$WORKTREE" probe --name 7 registry
expect_status 0
[ "$(probe_port)" = 20071 ] || fail_case "порт пробы «$(probe_port)», ожидался 20071 (20070 исключён)"
run_stand "$WORKTREE" up --name 7
expect_status 1
expect_err_first 'порт 19007 занят'
expect_no_changes
rm -f "$STATE/excluded"
: > "$LOG"
run_stand "$WORKTREE" probe --name 7 registry
expect_status 0
[ "$(probe_port)" = 20070 ] || fail_case "без исключений порт пробы «$(probe_port)», ожидался 20070"
end_case

begin_case 'отказ: движок недоступен'
: > "$STATE/engine_down"
run_stand "$WORKTREE" up --name 7
expect_status 1
expect_err_first 'движок domovoy-engine недоступен; Docker Desktop не запускать'
expect_no_changes
expect_no_bare_docker
end_case

begin_case 'отказ: дистрибутива нет'
: > "$STATE/no_distro"
run_stand "$WORKTREE" up --name 7
expect_status 1
expect_err_first 'недоступен; Docker Desktop не запускать'
expect_no_bare_docker
[ ! -e "$FAKE_HOME/domovoy-stand" ] || fail_case 'каталог стенда создан'
end_case

begin_case 'отказ: каталог боевого стека — каталог стенда внутри working_dir'
printf '%s\n' "$FAKE_HOME" > "$STATE/prod_wd"
run_stand "$WORKTREE" up --name 7
expect_status 1
expect_err_first "каталог проекта — каталог боевого стека: $FAKE_HOME"
expect_no_changes
end_case

begin_case 'отказ: каталог боевого стека — каталог стенда равен working_dir'
printf '%s/domovoy-stand/7\n' "$FAKE_HOME" > "$STATE/prod_wd"
run_stand "$WORKTREE" down --name 7
expect_status 1
expect_err_first "каталог проекта — каталог боевого стека: $FAKE_HOME/domovoy-stand/7"
expect_no_changes
end_case

begin_case 'отказ: каталог боевого стека — источник равен основному дереву'
run_stand "$CLONE" up --name 7
expect_status 1
expect_err_first "каталог проекта — каталог боевого стека: $CLONE"
expect_no_changes
end_case

begin_case 'отказ: каталог боевого стека — источник равен working_dir'
printf '%s\n' "$WORKTREE" > "$STATE/prod_wd"
run_stand "$WORKTREE" up --name 7
expect_status 1
expect_err_first "каталог проекта — каталог боевого стека: $WORKTREE"
expect_no_changes
end_case

begin_case 'контроль: worktree вне обоих каталогов проходит'
run_stand "$WORKTREE" up --name 7
expect_status 0
log_has 'compose -p domovoy-stand-7'
# -a: остановленный боевой стек метку working_dir сохраняет.
log_has 'ps -a --filter label=com.docker.compose.project=domovoy'
[ -f "$FAKE_HOME/domovoy-stand/7/.domovoy-stand" ] || fail_case 'нет метки .domovoy-stand в каталоге стенда'
end_case

begin_case 'отказ: каталог стенда без метки при пустом боевом проекте'
# Контейнеров боевого проекта нет — метка working_dir пуста; каталог стенда
# занят чужим содержимым.
rm -f "$STATE/prod_wd"
foreign="$FAKE_HOME/domovoy-stand/7"
mkdir -p "$foreign"
printf 'owner\n' > "$foreign/.env"
for sub in up down status logs; do
    : > "$LOG"
    run_stand "$WORKTREE" "$sub" --name 7
    expect_status 1
    expect_err_first "каталог $foreign существует, но не принадлежит стенду"
    log_lacks_re 'compose .* (up|create|cp|run|build|down)( |$)'
    log_lacks_re 'buildx (create|rm)'
    log_lacks_re 'image rm|mkdir|cat >|rm -rf'
    [ "$(cat "$foreign/.env" 2>/dev/null)" = owner ] || fail_case "$sub: чужой .env в каталоге стенда изменён или удалён"
done
end_case

# --- Имя, порты, проект ------------------------------------------------------

begin_case 'порты и проект выводятся из N'
run_stand "$WORKTREE" up --name 7
expect_status 0
log_has "compose -p domovoy-stand-7 --project-directory $FAKE_HOME/domovoy-stand/7 -f $WORKTREE/docker-compose.yml -f $WORKTREE/deploy/stand/docker-compose.stand.yml"
log_has "DOMOVOY_STAND_SOURCE=$WORKTREE"
env7="$FAKE_HOME/domovoy-stand/7/.env"
grep -qx 'API_HTTP_PORT=19007' "$env7" || fail_case 'нет API_HTTP_PORT=19007'
grep -qx 'HA_HTTP_PORT=9007' "$env7" || fail_case 'нет HA_HTTP_PORT=9007'
reset_engine
run_stand "$WORKTREE" up
expect_status 0
log_has "compose -p domovoy-stand-164 --project-directory $FAKE_HOME/domovoy-stand/164"
grep -qx 'API_HTTP_PORT=19164' "$FAKE_HOME/domovoy-stand/164/.env" || fail_case 'нет API_HTTP_PORT=19164'
for bad in 0 1000 abc; do
    reset_engine
    run_stand "$WORKTREE" up --name "$bad"
    [ "$STATUS" -eq 2 ] || fail_case "--name $bad: код $STATUS, ожидался 2"
done
run_stand "$WORKTREE" restart --name 7
[ "$STATUS" -eq 2 ] || fail_case "неизвестная подкоманда: код $STATUS, ожидался 2"
end_case

begin_case 'отказ: без --name вне .claude/worktrees/<N>'
run_stand "$CLONE" up
expect_status 1
expect_err_first 'не задан --name'
expect_no_changes
end_case

# --- .env и токен ------------------------------------------------------------

begin_case '.env стенда только из примера'
run_stand "$WORKTREE" up --name 7
expect_status 0
env7="$FAKE_HOME/domovoy-stand/7/.env"
want_keys="$( { sed -nE 's/^([A-Z_][A-Z0-9_]*)=.*/\1/p' "$REPO/.env.example"; echo COMPOSE_PROFILES; } | sort -u)"
got_keys="$(sed -nE 's/^([A-Z_][A-Z0-9_]*)=.*/\1/p' "$env7" | sort)"
[ "$want_keys" = "$(printf '%s\n' "$got_keys" | sort -u)" ] || fail_case "ключи .env стенда расходятся с .env.example: $(diff <(echo "$want_keys") <(echo "$got_keys") | tr '\n' ';')"
[ "$(printf '%s\n' "$got_keys" | sort | uniq -d)" = '' ] || fail_case 'ключ повторяется в .env стенда'
grep -qx 'COMPOSE_PROJECT_NAME=domovoy-stand-7' "$env7" || fail_case 'нет COMPOSE_PROJECT_NAME=domovoy-stand-7'
grep -qx 'COMPOSE_PROFILES=ha' "$env7" || fail_case 'нет COMPOSE_PROFILES=ha'
admin="$(sed -n 's/^AUTH_ADMIN_TOKEN=//p' "$env7")"
[ "${#admin}" -ge 32 ] || fail_case "AUTH_ADMIN_TOKEN короче 32: ${#admin}"
[ "$admin" != '<admin-token>' ] || fail_case 'AUTH_ADMIN_TOKEN — плейсхолдер'
pg="$(sed -n 's/^POSTGRES_PASSWORD=//p' "$env7")"
[ "${#pg}" -ge 32 ] || fail_case "POSTGRES_PASSWORD короче 32: ${#pg}"
if grep -rqF "$OWNER_MARKER" "$FAKE_HOME/domovoy-stand/7"; then
    fail_case 'значение владельца попало в каталог стенда'
fi
[ -f "$FAKE_HOME/domovoy-stand/7/config/entities.yaml" ] || fail_case 'нет config/entities.yaml стенда'
cmp -s "$REPO/config/entities.example.yaml" "$FAKE_HOME/domovoy-stand/7/config/entities.yaml" \
    || fail_case 'config/entities.yaml стенда — не копия примера'
end_case

begin_case 'токен не выводится'
run_stand "$WORKTREE" up --name 7
expect_status 0
all="$OUT$ERR"
grep -qx "HA_TOKEN=$TOKEN" "$FAKE_HOME/domovoy-stand/7/.env" || fail_case 'токен не записан в .env стенда'
run_stand "$WORKTREE" status --name 7
expect_status 0
all="$all$OUT$ERR"
printf '%s\n' "$OUT" | grep -qF 'токен HA: принят' || fail_case 'status не печатает «токен HA: принят»'
printf '%s\n' "$OUT" | grep -qF 'переименовано сущностей demo: 11' || fail_case 'status не печатает число переименованных'
printf '%s\n' "$OUT" | grep -qF 'binary_sensor.example_kitchen_window' || fail_case 'status не печатает отсутствующие id'
run_stand "$WORKTREE" logs --name 7 -- --tail 5 api
expect_status 0
all="$all$OUT$ERR"
log_has 'logs --tail 5 api'
case "$all" in *"$TOKEN"*) fail_case 'токен HA в выводе подкоманды' ;; esac
grep -qF "$TOKEN" "$LOG" && fail_case 'токен HA в аргументах команд движка'
end_case

begin_case 'status: HA стенда остановлен — токен не проверяется'
run_stand "$WORKTREE" up --name 7
expect_status 0
: > "$STATE/ha_stopped"
: > "$LOG"
run_stand "$WORKTREE" status --name 7
expect_status 0
printf '%s\n' "$OUT" | grep -qF 'токен HA: не проверен — HA стенда не запущен' \
    || fail_case 'status не печатает «не проверен — HA стенда не запущен»'
log_has 'ps --status running -q homeassistant'
log_lacks_re 'compose .* (cp|exec)( |$)'
end_case

begin_case 'status и logs: стенда нет — строка без compose'
for path in fresh after-down; do
    if [ "$path" = after-down ]; then
        run_stand "$WORKTREE" up --name 7
        expect_status 0
        run_stand "$WORKTREE" down --name 7
        expect_status 0
    fi
    : > "$LOG"
    run_stand "$WORKTREE" status --name 7
    expect_status 0
    [ "$OUT" = 'stand: стенд domovoy-stand-7 не поднят' ] \
        || fail_case "$path: status вывел «$OUT», ожидалась строка «стенд domovoy-stand-7 не поднят»"
    [ -z "$ERR" ] || fail_case "$path: status пишет в stderr: $(printf '%s' "$ERR" | head -n 2 | tr '\n' ';')"
    run_stand "$WORKTREE" logs --name 7 -- --tail 5 api
    expect_status 1
    expect_err_first 'стенд domovoy-stand-7 не поднят'
    log_lacks_re 'compose -p'
    [ ! -e "$FAKE_HOME/domovoy-stand/7" ] || fail_case "$path: status или logs создали каталог стенда"
done
end_case

# --- Сборка ------------------------------------------------------------------

begin_case 'сборка строителем стенда'
run_stand "$WORKTREE" up --name 7
expect_status 0
log_has "buildx create --name domovoy-stand-7-build --driver docker-container --driver-opt image=$BUILDKIT"
log_has 'build --builder domovoy-stand-7-build api'
if grep -E 'compose .* up( |$)' "$LOG" | grep -vq -- '--no-build'; then
    fail_case 'compose up без --no-build'
fi
if grep -E 'compose .* build( |$)' "$LOG" | grep -vq -- '--builder'; then
    fail_case 'compose build без --builder'
fi
# Порядок: строитель → сборка → проверка образа → up всего стека.
order="$(grep -nE 'buildx create|build --builder|image ls --filter reference=domovoy-stand-7-api|up -d --wait --no-build$' "$LOG" | cut -d: -f1 | tr '\n' ' ')"
[ "$(echo "$order" | wc -w)" -eq 4 ] || fail_case "нет одного из шагов сборки: $order"
[ "$order" = "$(echo "$order" | tr ' ' '\n' | grep . | sort -n | tr '\n' ' ')" ] || fail_case "порядок шагов сборки нарушен: $order"
if grep -vE '^[[:space:]]*#' "$REPO/deploy/stand/docker-compose.stand.yml" | grep -qE '^[[:space:]]*image:'; then
    fail_case 'docker-compose.stand.yml задаёт image:'
fi
end_case

begin_case 'образ api не попал в движок — стенд сносится'
cat > "$SANDBOX/engine-docker-noload" <<'EOF'
#!/usr/bin/env bash
case " $* " in *' build --builder '*) exit 0 ;; esac
exec "$FAKE_BIN/engine-docker.orig" "$@"
EOF
mv "$BIN/engine-docker" "$BIN/engine-docker.orig"
cp "$SANDBOX/engine-docker-noload" "$BIN/engine-docker"
chmod +x "$BIN/engine-docker"
run_stand "$WORKTREE" up --name 7
mv "$BIN/engine-docker.orig" "$BIN/engine-docker"
expect_status 1
printf '%s\n' "$ERR" | grep -qF 'образ domovoy-stand-7-api не попал в хранилище движка' || fail_case 'нет причины про образ api'
log_lacks_re 'up -d --wait --no-build$'
log_has 'down -v --rmi local --remove-orphans'
[ ! -e "$FAKE_HOME/domovoy-stand/7" ] || fail_case 'каталог стенда остался'
end_case

begin_case 'шаг вытянул образ и упал — образ сносится вместе со стендом'
cat > "$SANDBOX/engine-docker-bkfail" <<'EOF'
#!/usr/bin/env bash
case " $* " in
    *' buildx create '*) "$FAKE_BIN/engine-docker.orig" "$@"; exit 1 ;;
esac
exec "$FAKE_BIN/engine-docker.orig" "$@"
EOF
mv "$BIN/engine-docker" "$BIN/engine-docker.orig"
cp "$SANDBOX/engine-docker-bkfail" "$BIN/engine-docker"
chmod +x "$BIN/engine-docker"
run_stand "$WORKTREE" up --name 7
mv "$BIN/engine-docker.orig" "$BIN/engine-docker"
expect_status 1
printf '%s\n' "$ERR" | grep -qF 'строитель domovoy-stand-7-build не создан' || fail_case 'нет причины про строитель'
# ID той же формулой, что id_of подделки: состояние и pulled-images к этому
# моменту уже снесены.
bk_id="sha256:id-$(printf '%s' "$BUILDKIT" | tr -c 'a-z0-9' '-')"
log_has "image rm $bk_id"
grep -q "^$BUILDKIT " "$STATE/images" && fail_case 'образ buildkit, вытянутый стендом, остался в движке'
[ ! -e "$FAKE_HOME/domovoy-stand/7" ] || fail_case 'каталог стенда остался'
end_case

# --- down --------------------------------------------------------------------

begin_case 'down удаляет только своё'
run_stand "$WORKTREE" up --name 7
expect_status 0
recorded="$(cat "$(pulled_file 7)" 2>/dev/null)"
bk_id="$(awk -v r="$BUILDKIT" '$1 == r { print $2 }' "$STATE/images")"
[ "$recorded" = "$bk_id" ] || fail_case "pulled-images — «$recorded», ожидался только ID buildkit «$bk_id»"
: > "$LOG"
run_stand "$WORKTREE" down --name 7
expect_status 0
log_has 'compose -p domovoy-stand-7 '
log_has 'down -v --rmi local --remove-orphans'
log_has 'buildx rm domovoy-stand-7-build'
log_lacks_re 'buildx rm .*--keep-state'
log_has "image rm $bk_id"
log_lacks_re "image rm (-f|--force)"
log_lacks_re "image rm [^s]"
[ ! -e "$FAKE_HOME/domovoy-stand/7" ] || fail_case 'каталог стенда не удалён'
grep -q "^$PG_IMAGE " "$STATE/images" || fail_case 'удалён образ postgres боевого стека'
grep -q "^$HA_IMAGE " "$STATE/images" || fail_case 'удалён образ HA боевого стека'
end_case

begin_case 'down: базовый образ был до up — не удаляется'
printf '%s sha256:already-here\n' "$BUILDKIT" >> "$STATE/images"
run_stand "$WORKTREE" up --name 7
expect_status 0
[ ! -s "$(pulled_file 7)" ] || fail_case "pulled-images не пуст: $(cat "$(pulled_file 7)")"
: > "$LOG"
run_stand "$WORKTREE" down --name 7
expect_status 0
log_lacks_re 'image rm'
grep -q 'sha256:already-here' "$STATE/images" || fail_case 'удалён образ, который был до up'
end_case

begin_case 'down: вытянутый стендом образ держит чужой контейнер'
run_stand "$WORKTREE" up --name 7
expect_status 0
bk_id="$(cat "$(pulled_file 7)")"
printf '%s c-foreign\n' "$bk_id" >> "$STATE/ancestors"
: > "$LOG"
run_stand "$WORKTREE" down --name 7
expect_status 0
log_lacks_re 'image rm'
printf '%s\n' "$OUT" | grep -qF "оставлен образ $bk_id" || fail_case 'нет строки про оставленный образ'
end_case

begin_case 'down: тег переставлен на другой образ'
run_stand "$WORKTREE" up --name 7
expect_status 0
bk_id="$(cat "$(pulled_file 7)")"
# Тег теперь указывает на новый образ, записанный ID остался без тега.
grep -v "^$BUILDKIT " "$STATE/images" > "$STATE/images.tmp"
printf '%s sha256:retagged\n<none> %s\n' "$BUILDKIT" "$bk_id" >> "$STATE/images.tmp"
mv "$STATE/images.tmp" "$STATE/images"
: > "$LOG"
run_stand "$WORKTREE" down --name 7
expect_status 0
log_lacks_re 'image rm sha256:retagged'
log_lacks_re "image rm $BUILDKIT"
grep -q 'sha256:retagged' "$STATE/images" || fail_case 'удалён образ под переставленным тегом'
end_case

begin_case 'down не трогает чужое'
run_stand "$WORKTREE" up --name 1
expect_status 0
# Чужие объекты появились за жизнь стенда.
printf 'domovoy-stand-7-api sha256:other-stand\n' >> "$STATE/images"
printf 'domovoy-stand-16-build\n' >> "$STATE/builders"
: > "$LOG"
run_stand "$WORKTREE" down --name 1
expect_status 0
log_lacks_re 'prune'
log_lacks_re '(^| )rmi( |$)'
log_lacks_re 'volume rm'
log_lacks_re 'image rm sha256:(prod|other)'
if grep -E 'buildx rm' "$LOG" | grep -vqE 'buildx rm domovoy-stand-1-build$'; then
    fail_case "buildx rm с чужим именем: $(grep 'buildx rm' "$LOG" | tr '\n' ';')"
fi
grep -qx 'domovoy-stand-16-build' "$STATE/builders" || fail_case 'удалён строитель domovoy-stand-16-build'
grep -q '^domovoy-api ' "$STATE/images" || fail_case 'удалён образ domovoy-api'
grep -q '^domovoy-stand-7-api ' "$STATE/images" || fail_case 'удалён образ domovoy-stand-7-api'
expect_no_bare_docker
end_case

# --- Пробы -------------------------------------------------------------------

begin_case 'probe: имя, порт и метка выводятся из N'
run_stand "$WORKTREE" probe --name 7 registry
expect_status 0
want="$(printf 'STAND_PROBE_NAME=domovoy-probe-7-registry\nSTAND_PROBE_PORT=20070\nSTAND_PROBE_LABEL=domovoy-stand.probe=7')"
[ "$OUT" = "$want" ] || fail_case "stdout probe — «$OUT», ожидались ровно три строки «$want»"
printf 'LISTEN 0 4096 127.0.0.1:20070 0.0.0.0:*\n' > "$STATE/ss"
run_stand "$WORKTREE" probe --name 7 registry
expect_status 0
[ "$(probe_port)" = 20071 ] || fail_case "20070 занят: порт пробы «$(probe_port)», ожидался 20071"
for p in $(seq 20070 20079); do printf 'LISTEN 0 4096 127.0.0.1:%s 0.0.0.0:*\n' "$p"; done > "$STATE/ss"
run_stand "$WORKTREE" probe --name 7 registry
expect_status 1
expect_err_first 'порты проб 20070…20079 заняты'
rm -f "$STATE/ss"
run_stand "$WORKTREE" probe --name 16 registry
[ "$(probe_port)" = 20160 ] || fail_case "--name 16: порт «$(probe_port)», ожидался 20160"
run_stand "$WORKTREE" probe --name 160 registry
[ "$(probe_port)" = 21600 ] || fail_case "--name 160: порт «$(probe_port)», ожидался 21600"
for bad in Reg_1 1reg -reg registry-name-is-long; do
    run_stand "$WORKTREE" probe --name 7 "$bad"
    [ "$STATUS" -eq 2 ] || fail_case "ресурс «$bad»: код $STATUS, ожидался 2"
done
run_stand "$WORKTREE" probe --name 7
[ "$STATUS" -eq 2 ] || fail_case "probe без ресурса: код $STATUS, ожидался 2"
run_stand "$WORKTREE" probe --name 7 registry postgres
[ "$STATUS" -eq 2 ] || fail_case "probe с двумя ресурсами: код $STATUS, ожидался 2"
expect_no_changes
log_lacks_re '(^| )docker (run|rm|create)( |$)'
expect_no_bare_docker
end_case

begin_case 'down: контейнеры проб стенда удаляются с томами'
run_stand "$WORKTREE" up --name 7
expect_status 0
printf '7 c-probe-7a\n7 c-probe-7b\n70 c-probe-70\n' > "$STATE/probes"
: > "$LOG"
run_stand "$WORKTREE" down --name 7
expect_status 0
log_has 'ps -a -q --filter label=domovoy-stand.probe=7'
log_has 'docker rm -f -v c-probe-7a c-probe-7b'
if grep -E '(^| )docker rm ' "$LOG" | grep -vqE ' docker rm -f -v '; then
    fail_case "rm без -f -v: $(grep -E '(^| )docker rm ' "$LOG" | tr '\n' ';')"
fi
grep -E '(^| )docker rm ' "$LOG" | grep -qE 'c-probe-70|c-prod' && fail_case 'rm задел пробу стенда 70 или боевой стек'
grep -q ' c-probe-70$' "$STATE/probes" || fail_case 'удалена проба стенда 70'
grep -q ' c-probe-7[ab]$' "$STATE/probes" && fail_case 'проба стенда 7 осталась'
# Пробы — до compose down стенда.
rm_line="$(grep -nE '(^| )docker rm ' "$LOG" | head -n 1 | cut -d: -f1)"
down_line="$(grep -nE 'compose .* down( |$)' "$LOG" | head -n 1 | cut -d: -f1)"
[ -n "$rm_line" ] && [ -n "$down_line" ] && [ "$rm_line" -lt "$down_line" ] \
    || fail_case "rm проб (строка ${rm_line:-—}) не раньше compose down (строка ${down_line:-—})"
# Проб нет — rm не вызывается вовсе.
run_stand "$WORKTREE" up --name 7
expect_status 0
: > "$LOG"
run_stand "$WORKTREE" down --name 7
expect_status 0
log_lacks_re '(^| )docker rm '
end_case

# --- Голый docker ------------------------------------------------------------

begin_case 'в stand.sh нет голого docker'
# docker как слово-команда: не часть docker-compose.yml, Docker Desktop,
# domovoy-engine или пути. Единственная такая строка — функция engine().
bare="$(grep -nE '(^|[^[:alnum:]_./-])docker([^[:alnum:]_./-]|$)' "$TARGET" \
    | grep -vE '^[0-9]+:[[:space:]]*#' \
    | grep -vE '^[0-9]+:engine\(\) \{ wsl\.exe -d "\$distro" --exec env ')"
[ -z "$bare" ] || fail_case "docker вне engine(): $bare"
grep -qE '^engine\(\) \{ wsl\.exe -d "\$distro" --exec ' "$TARGET" || fail_case 'нет функции engine() через wsl.exe'
bash -n "$TARGET" || fail_case 'bash -n'
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -S warning "$TARGET" || fail_case 'shellcheck'
fi
end_case

# --- Итог --------------------------------------------------------------------

printf '\nПройдено: %d, упало: %d\n' "$PASSED" "$FAILED"
if [ "$FAILED" -gt 0 ]; then
    printf '  - %s\n' "${FAILED_NAMES[@]}"
    exit 1
fi
exit 0
