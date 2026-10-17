#!/usr/bin/env bash
#
# Домовой — обновление стека в каталоге развёртывания (#162).
#
# ЗАЧЕМ
#
# Каталог развёртывания (/srv/domovoy внутри дистрибутива движка) — отдельный
# git-клон только для запуска стека. Обновление переводит его на коммит из
# main и на образы этого коммита из реестра: бэкап, миграция, перезапуск и
# проверка /health — одной командой, без ручных шагов. Провал после первого
# изменения возвращает прежний коммит и образ. Вызывающий не важен:
# deploy/windows/update.ps1 на Windows, кнопка #163 — изнутри Linux.
#
# КАК ЗАПУСКАТЬ
#
#   bash deploy/update.sh [--dir <каталог>] [--ref <коммит>] [--dry-run]
#                         [--adopt] [--image-repo <реестр>/<владелец>]
#
#   --dir         каталог развёртывания; по умолчанию — корень клона, в
#                 котором лежит сценарий;
#   --ref         целевой коммит, 40 шестнадцатеричных символов; по
#                 умолчанию — голова main на origin (git ls-remote);
#   --dry-run     только план: целевой коммит, образы, команда бэкапа,
#                 превью синхронизации .env, план чистки. Ничего не меняет:
#                 ни .git, кроме пустого файла блокировки domovoy-update.lock
#                 (без fetch — .env.example цели берётся из объекта,
#                 если он уже есть, иначе из временного неглубокого клона,
#                 который удаляется), ни .env, ни контейнеры, ни образы;
#   --adopt       стек поднят из другого каталога (клон Windows до переноса)
#                 — первый запуск из каталога развёртывания;
#   --image-repo  реестр образов; по умолчанию — DOMOVOY_IMAGE_REPO из .env,
#                 иначе ghcr.io/<владелец из remote origin в нижнем регистре>.
#
# ШАГИ
#
# Проверки до первого изменения: каталог и его .git; блокировка flock -n на
# <каталог>/.git/domovoy-update.lock (общей блокировки с ночным бэкапом
# ops/backup/backup.sh нет — не запускать обновление в его окне); движок (docker info) и compose ≥ 2.24;
# файл состояния (ниже); .env; чистое рабочее дерево; postgres и
# homeassistant проекта запущены, их метка working_dir — этот каталог (или
# --adopt); целевой коммит; оба образа есть в реестре (docker manifest
# inspect); каталог бэкапов BACKUP_DIR; git fetch цели.
#
# Изменения, строго в этом порядке:
#   1. бэкап — команда DOMOVOY_UPDATE_BACKUP; свой каталог — тот, что она
#      назвала строкой «успех: domovoy-backup-<метка>» (ops/backup/backup.sh),
#      а не новый каталог в BACKUP_DIR: плановый бэкап мог положить туда
#      свой. Путь печатается: «update: бэкап: <путь>». Строки нет, их
#      больше одной или каталога нет — код 1, обновление не начато;
#   2. файл состояния отката;
#   3. git checkout --detach <цель>;
#   4. deploy/envfile.sh sync .env.example → .env;
#   5. управляемые ключи .env, все три: COMPOSE_FILE
#      (docker-compose.yml:deploy/docker-compose.deploy.yml, плюс
#      docker-compose.override.yml, если он есть), DOMOVOY_IMAGE_REPO,
#      DOMOVOY_IMAGE_TAG=sha-<цель>. Тег пишется до pull и migrate: compose
#      берёт его из .env, и migrate запускается из образа целевого коммита;
#   6. compose pull api migrate;
#   7. compose --profile migrate run --rm migrate — схема (psql
#      --single-transaction: провал не оставляет половины);
#   8. compose --profile ha up -d --wait и /health на
#      127.0.0.1:<API_HTTP_PORT> — 200 с телом формы стека; с --adopt —
#      up --force-recreate: пересоздаются все службы, и метка working_dir
#      каждого контейнера становится каталогом развёртывания (без него
#      compose пересоздал бы только api, а postgres и homeassistant
#      остались бы с меткой прежнего каталога); тома именованные — данные
#      сохраняются;
#   9. файл состояния удаляется — сразу после /health, до чистки: обрыв в
#      чистке не откатывает удавшееся обновление;
#  10. чистка: из образов <repo>/domovoy-api и <repo>/domovoy-migrate
#      остаются текущий тег и тот, на котором стек работал до обновления;
#      локальный образ <проект>-api прежней сборки удаляется, если стек
#      работал не на нём; docker image rm без -f; docker builder prune
#      --all --force — встроенного строителя.
#
# Провал шагов 2–8 — откат: прежние значения управляемых ключей (и их
# отсутствие после первого --adopt), git checkout прежнего коммита,
# compose --profile ha up -d --wait (после --adopt — с --force-recreate,
# по строке adopt файла состояния), /health. Схема не откатывается
# (expand/contract: прежний код работает на новой схеме). Ключи, дописанные
# синхронизацией .env, не снимаются: прежний код их не читает.
#
# ФАЙЛ СОСТОЯНИЯ
#
# <каталог>/.git/domovoy-update.state — внутри .git: checkout его не
# трогает. Пишется после бэкапа и до checkout, атомарно (временный файл
# рядом, umask 077, mv). Строки KEY=значение: prev_commit, target_commit,
# backup, adopt=1 (только при --adopt), и на каждый управляемый ключ
# prev.<KEY>=<значение> или prev.<KEY>.absent=1. Прочих ключей .env и секретов в нём нет. Удаляется
# после успеха и после завершённого отката.
#
# Процесс оборвался (закрыто окно WSL, wsl --shutdown, kill) — файл
# остаётся, и следующий запуск сначала доводит откат по нему, а не начинает
# новое обновление: код 3 со строкой «update: откат прерванного обновления
# <цель>: …» или 4. Откат идемпотентен. С --dry-run — только строка
# «update: будет выполнен откат прерванного обновления <цель>» и код 0.
# Движок ещё не поднялся — код 1, файл остаётся.
#
# ВЫВОД И КОДЫ
#
# Строки stdout начинаются с «update: »; вывод git, compose и бэкапа — в
# stderr. Значения .env не печатаются (кроме управляемых ключей и
# несекретных настроек, которые сценарий сам пишет или читает через
# envfile.sh get).
#   0 — обновлено («update: готово: <sha> (образ sha-<sha>)»), или сухой прогон;
#   1 — отказ до первого изменения; первая строка stderr —
#       «update: отказ: <причина>»;
#   2 — ошибка вызова;
#   3 — провал после изменения, откат выполнен, стек на прежнем коммите и
#       образе отвечает (и когда доведён откат прерванного прогона);
#   4 — провал и отказ отката — нужен человек; путь бэкапа в stderr.
#
# ШВЫ ДЛЯ ТЕСТОВ (deploy/update.test.sh)
#
#   DOMOVOY_UPDATE_BACKUP — команда бэкапа (по умолчанию
#                           bash ops/backup/backup.sh), исполняется bash -c
#                           из каталога развёртывания; обязана напечатать
#                           ровно одну строку «успех: <имя каталога>», как
#                           backup.sh;
#   docker, curl, git, flock — из PATH. Формы вызовов docker:
#     docker info
#     docker compose version --short
#     docker ps --filter label=com.docker.compose.project=<проект>
#            --format '<служба>\t<working_dir>\t<образ>'
#     docker manifest inspect [--insecure] <образ>
#     docker compose --profile migrate pull api migrate
#     docker compose --profile migrate run --rm migrate
#     docker compose --profile ha up -d --wait [--force-recreate]
#     docker image ls --format '{{.Repository}}:{{.Tag}}' <репозиторий>
#     docker image rm <образ>
#     docker builder prune --all --force
#   compose вызывается из каталога развёртывания и берёт тег и COMPOSE_FILE
#   из его .env: в аргументах их нет.
#
# Тело — в функции main, вызываемой последней строкой с exit на той же
# строке: checkout собственного файла не ломает исполнение.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

MANAGED_KEYS=(COMPOSE_FILE DOMOVOY_IMAGE_REPO DOMOVOY_IMAGE_TAG)
REPO_RE='^[a-z0-9]+([._-][a-z0-9]+)*(:[0-9]+)?(/[a-z0-9]+([._-][a-z0-9]+)*)+$'
COMPOSE_MIN_MAJOR=2
COMPOSE_MIN_MINOR=24
HEALTH_ATTEMPTS=5

say() { printf 'update: %s\n' "$*"; }
warn() { printf 'update: %s\n' "$*" >&2; }
refuse() {
    printf 'update: отказ: %s\n' "$*" >&2
    exit 1
}
usage() {
    printf 'update: %s\n' "$*" >&2
    printf 'использование: bash deploy/update.sh [--dir <каталог>] [--ref <коммит>] [--dry-run] [--adopt] [--image-repo <реестр>/<владелец>]\n' >&2
    exit 2
}

# Состояние прогона.
DIR=''
GIT_DIR_PATH=''
STATE=''
TOOLS=''
ENVFILE=''
PROJECT=''
PORT=''
BACKUP_PATH=''
PREV_COMMIT=''
TARGET=''
REPO=''
ADOPT=0

# git каталога развёртывания; вывод — в stderr, кроме явно читаемого.
dgit() { git -C "$DIR" "$@"; }

# compose из каталога развёртывания: проект, COMPOSE_FILE и тег — из его .env.
dc() { (cd "$DIR" && docker compose "$@"); }

envfile() { bash "$ENVFILE" "$@"; }

# env_get KEY — значение из .env через envfile.sh get (белый список).
env_get() {
    local line
    line="$(envfile get "$DIR/.env" "$1" 2>/dev/null)" || return 1
    printf '%s' "${line#*=}"
}

env_has() {
    grep -qE "^$1=" "$DIR/.env"
}

# Копия envfile.sh и dotenv.sh из клона сценария во временный каталог:
# checkout цели и прежнего коммита их не меняет.
prepare_tools() {
    TOOLS="$(mktemp -d)" || refuse 'не создан временный каталог'
    mkdir -p "$TOOLS/deploy" "$TOOLS/ops/backup"
    cp "$SELF_DIR/envfile.sh" "$TOOLS/deploy/envfile.sh" 2>/dev/null \
        && cp "$SELF_DIR/../ops/backup/dotenv.sh" "$TOOLS/ops/backup/dotenv.sh" 2>/dev/null \
        || refuse "нет deploy/envfile.sh или ops/backup/dotenv.sh рядом со сценарием"
    ENVFILE="$TOOLS/deploy/envfile.sh"
}

cleanup() {
    if [ -n "$TOOLS" ]; then rm -rf "$TOOLS"; fi
}

compose_default_port() {
    sed -nE 's/.*\$\{API_HTTP_PORT:-([0-9]+)\}.*/\1/p' "$DIR/docker-compose.yml" 2>/dev/null | head -n 1
}

# check_health — /health отвечает 200 с телом формы стека.
check_health() {
    local i code body="$TOOLS/health"
    for ((i = 1; i <= HEALTH_ATTEMPTS; i++)); do
        rm -f "$body"
        code="$(cd "$DIR" && curl --silent --max-time 5 --output "$body" --write-out '%{http_code}' \
            "http://127.0.0.1:$PORT/health" 2>/dev/null)"
        if [ "$code" = 200 ] && [ -f "$body" ] \
            && grep -qE '^[[:space:]]*\{[[:space:]]*"status"[[:space:]]*:[[:space:]]*"(healthy|degraded)"[[:space:]]*\}[[:space:]]*$' "$body"; then
            return 0
        fi
        [ "$i" -lt "$HEALTH_ATTEMPTS" ] && sleep 1
    done
    return 1
}

# ------------------------------------------------------------------
# Файл состояния
# ------------------------------------------------------------------
write_state() {
    local tmp="$STATE.tmp.$$" key value
    (
        umask 077
        {
            printf 'prev_commit=%s\n' "$PREV_COMMIT"
            printf 'target_commit=%s\n' "$TARGET"
            printf 'backup=%s\n' "$BACKUP_PATH"
            if [ "$ADOPT" -eq 1 ]; then printf 'adopt=1\n'; fi
            for key in "${MANAGED_KEYS[@]}"; do
                if env_has "$key"; then
                    value="$(env_get "$key")"
                    printf 'prev.%s=%s\n' "$key" "$value"
                else
                    printf 'prev.%s.absent=1\n' "$key"
                fi
            done
        } >"$tmp"
    ) || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$STATE"
}

# state_value KEY — значение строки KEY= файла состояния (не source).
state_value() {
    local line
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            "$1="*) printf '%s' "${line#"$1="}"; return 0 ;;
        esac
    done <"$STATE"
    return 1
}

# ------------------------------------------------------------------
# Откат по файлу состояния
# ------------------------------------------------------------------
# rollback <заголовок строк> — 0 — откат доведён, файл удалён; 1 — нет.
rollback() {
    local label="$1" prev key value
    prev="$(state_value prev_commit)" || { warn "$label: в файле состояния нет prev_commit"; return 1; }
    [[ "$prev" =~ ^[0-9a-f]{40}$ ]] || { warn "$label: prev_commit в файле состояния не коммит"; return 1; }
    BACKUP_PATH="$(state_value backup || true)"

    say "$label: возврат управляемых ключей .env"
    for key in "${MANAGED_KEYS[@]}"; do
        if state_value "prev.$key.absent" >/dev/null; then
            envfile unset "$DIR/.env" "$key" >&2 || { warn "$label: не снят $key"; return 1; }
        elif value="$(state_value "prev.$key")"; then
            envfile set "$DIR/.env" "$key" "$value" >&2 || { warn "$label: не возвращён $key"; return 1; }
        else
            warn "$label: в файле состояния нет prev.$key"
            return 1
        fi
    done

    say "$label: checkout $prev"
    dgit checkout --quiet --detach "$prev" >&2 || { warn "$label: checkout $prev не удался"; return 1; }

    # После --adopt часть контейнеров могла остаться с меткой прежнего
    # каталога: пересоздаются все, как и в самом обновлении.
    local recreate=()
    if [ "$(state_value adopt || true)" = 1 ]; then recreate=(--force-recreate); fi
    say "$label: перезапуск стека"
    dc --profile ha up -d --wait "${recreate[@]+"${recreate[@]}"}" >&2 \
        || { warn "$label: compose up прежнего образа не удался"; return 1; }
    check_health || { warn "$label: /health прежнего образа не отвечает"; return 1; }

    rm -f "$STATE" || { warn "$label: файл состояния не удалён"; return 1; }
    say "$label: стек на прежнем коммите $prev"
    return 0
}

# rollback_or_die <заголовок> — код 3 или 4.
rollback_or_die() {
    if rollback "$1"; then
        exit 3
    fi
    {
        printf 'update: откат не удался — стек нужно вернуть вручную.\n'
        if [ -n "$BACKUP_PATH" ]; then printf 'update: бэкап: %s\n' "$BACKUP_PATH"; fi
        printf 'update: файл состояния оставлен: %s — следующий запуск повторит откат.\n' "$STATE"
        printf 'update: ручные шаги — README, «Обновление стека», запасной путь.\n'
    } >&2
    exit 4
}

# fail_after_change <причина> — провал после первого изменения.
fail_after_change() {
    printf 'update: провал: %s\n' "$1" >&2
    say "откат: $1"
    rollback_or_die 'откат'
}

# ------------------------------------------------------------------
# Чистка образов
# ------------------------------------------------------------------
# prune_candidates <prev_tag> <prev_api_image> — образы к удалению, по одному
# на строку.
prune_candidates() {
    local prev_tag="$1" prev_api="$2" name ref tag current="sha-$TARGET"
    for name in domovoy-api domovoy-migrate; do
        while IFS= read -r ref; do
            ref="${ref%$'\r'}"
            [ -n "$ref" ] || continue
            tag="${ref##*:}"
            [ "$tag" = '<none>' ] && continue
            [ "$tag" = "$current" ] && continue
            [ -n "$prev_tag" ] && [ "$tag" = "$prev_tag" ] && continue
            [ "$ref" = "$prev_api" ] && continue
            printf '%s\n' "$ref"
        done < <(docker image ls --format '{{.Repository}}:{{.Tag}}' "$REPO/$name" 2>/dev/null)
    done
    local local_api="$PROJECT-api"
    case "$prev_api" in
        "$local_api" | "$local_api:latest") ;;
        *)
            if [ -n "$(docker image ls --format '{{.Repository}}:{{.Tag}}' "$local_api" 2>/dev/null)" ]; then
                printf '%s\n' "$local_api"
            fi
            ;;
    esac
}

# ------------------------------------------------------------------
# Основное тело
# ------------------------------------------------------------------
main() {
    local dir_arg='' ref='' dry_run=0 adopt=0 repo_arg=''
    while [ $# -gt 0 ]; do
        case "$1" in
            --dir) [ $# -ge 2 ] || usage '--dir без значения'; dir_arg="$2"; shift 2 ;;
            --ref) [ $# -ge 2 ] || usage '--ref без значения'; ref="$2"; shift 2 ;;
            --image-repo) [ $# -ge 2 ] || usage '--image-repo без значения'; repo_arg="$2"; shift 2 ;;
            --dry-run) dry_run=1; shift ;;
            --adopt) adopt=1; ADOPT=1; shift ;;
            *) usage "неизвестный аргумент: $1" ;;
        esac
    done
    if [ -n "$ref" ] && ! [[ "$ref" =~ ^[0-9a-f]{40}$ ]]; then
        usage '--ref — 40 шестнадцатеричных символов в нижнем регистре'
    fi
    if [ -n "$repo_arg" ] && ! [[ "$repo_arg" =~ $REPO_RE ]]; then
        usage "--image-repo не похож на <реестр>/<владелец> в нижнем регистре: $repo_arg"
    fi

    # Значения из окружения вызывающего не должны перекрывать .env каталога:
    # compose предпочитает окружение файлу.
    unset COMPOSE_FILE DOMOVOY_IMAGE_REPO DOMOVOY_IMAGE_TAG COMPOSE_PROJECT_NAME

    # --- каталог развёртывания ---
    [ -n "$dir_arg" ] || dir_arg="$SELF_DIR/.."
    [ -d "$dir_arg" ] || refuse "каталог развёртывания не найден: $dir_arg"
    DIR="$(cd "$dir_arg" && pwd -P)" || refuse "каталог развёртывания не читается: $dir_arg"
    [ -d "$DIR/.git" ] || refuse "каталог развёртывания $DIR — не git-клон (нет .git)"
    GIT_DIR_PATH="$DIR/.git"
    STATE="$GIT_DIR_PATH/domovoy-update.state"

    # --- блокировка ---
    command -v flock >/dev/null 2>&1 || refuse 'нет flock (util-linux) — сценарий запускается внутри дистрибутива движка'
    exec 9>>"$GIT_DIR_PATH/domovoy-update.lock" || refuse "блокировка $GIT_DIR_PATH/domovoy-update.lock не открывается"
    flock -n 9 || refuse 'обновление уже идёт (занята блокировка .git/domovoy-update.lock)'

    prepare_tools
    trap cleanup EXIT

    # --- движок ---
    command -v docker >/dev/null 2>&1 || refuse 'docker не найден — движок не установлен'
    # Без curl провалились бы и /health нового образа, и /health отката —
    # код 4 на каждом запуске. Проверка — до первого изменения.
    command -v curl >/dev/null 2>&1 || refuse 'curl не найден — /health после обновления нечем проверить'
    docker info >/dev/null 2>&1 || refuse 'движок Docker не отвечает (docker info) — дистрибутив ещё не поднялся или docker не запущен'
    local cv major minor
    cv="$(docker compose version --short 2>/dev/null)" || refuse 'docker compose не отвечает'
    cv="${cv#v}"
    major="${cv%%.*}"
    minor="${cv#*.}"
    minor="${minor%%.*}"
    if ! [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]] \
        || [ "$major" -lt "$COMPOSE_MIN_MAJOR" ] \
        || { [ "$major" -eq "$COMPOSE_MIN_MAJOR" ] && [ "$minor" -lt "$COMPOSE_MIN_MINOR" ]; }; then
        refuse "docker compose $cv старше $COMPOSE_MIN_MAJOR.$COMPOSE_MIN_MINOR — надстройке нужен build: !reset"
    fi

    # --- прерванный прогон ---
    if [ -f "$STATE" ]; then
        local interrupted
        interrupted="$(state_value target_commit || true)"
        if [ "$dry_run" -eq 1 ]; then
            say "будет выполнен откат прерванного обновления $interrupted"
            exit 0
        fi
        [ -f "$DIR/.env" ] || refuse "нет $DIR/.env — откат прерванного обновления невозможен"
        PROJECT="$(env_get COMPOSE_PROJECT_NAME)"
        [ -n "$PROJECT" ] || PROJECT=domovoy
        PORT="$(env_get API_HTTP_PORT)"
        [ -n "$PORT" ] || PORT="$(compose_default_port)"
        say "откат прерванного обновления $interrupted: найден файл состояния $STATE"
        rollback_or_die "откат прерванного обновления $interrupted"
    fi

    # --- .env и дерево ---
    [ -f "$DIR/.env" ] || refuse "нет $DIR/.env — скопируйте .env в каталог развёртывания"
    PROJECT="$(env_get COMPOSE_PROJECT_NAME)"
    [ -n "$PROJECT" ] || PROJECT=domovoy
    PORT="$(env_get API_HTTP_PORT)"
    [ -n "$PORT" ] || PORT="$(compose_default_port)"
    [[ "$PORT" =~ ^[0-9]+$ ]] || refuse 'порт API не определён (API_HTTP_PORT, docker-compose.yml)'

    local dirty
    dirty="$(dgit status --porcelain 2>/dev/null)" || refuse "git status в $DIR не удался"
    [ -z "$dirty" ] || refuse "в каталоге развёртывания $DIR есть изменения (git status) — он только для запуска"
    PREV_COMMIT="$(dgit rev-parse HEAD 2>/dev/null)" || refuse "нет HEAD в $DIR"

    # --- контейнеры ---
    local ps_out service wd image prev_api='' have_pg=0 have_ha=0 foreign=''
    ps_out="$(docker ps --filter "label=com.docker.compose.project=$PROJECT" \
        --format '{{.Label "com.docker.compose.service"}}\t{{.Label "com.docker.compose.project.working_dir"}}\t{{.Image}}' 2>/dev/null)" \
        || refuse 'docker ps не удался'
    while IFS=$'\t' read -r service wd image; do
        [ -n "$service" ] || continue
        case "$service" in
            postgres) have_pg=1 ;;
            homeassistant) have_ha=1 ;;
            api) prev_api="$image" ;;
        esac
        if [ "$wd" != "$DIR" ] && [ -z "$foreign" ]; then foreign="$wd"; fi
    done <<<"$ps_out"
    [ "$have_pg" -eq 1 ] || refuse "postgres проекта $PROJECT не запущен"
    [ "$have_ha" -eq 1 ] || refuse "homeassistant проекта $PROJECT не запущен"
    if [ -n "$foreign" ] && [ "$adopt" -eq 0 ]; then
        refuse "стек $PROJECT поднят из другого каталога: $foreign — первый запуск из $DIR делается с --adopt"
    fi

    # --- реестр ---
    if [ -n "$repo_arg" ]; then
        REPO="$repo_arg"
    else
        REPO="$(env_get DOMOVOY_IMAGE_REPO)"
        if [ -z "$REPO" ]; then
            local url owner path
            url="$(dgit remote get-url origin 2>/dev/null)" || refuse 'нет remote origin — задайте --image-repo'
            path="${url%.git}"
            path="${path%/}"
            case "$path" in
                *://*) path="${path#*://}"; path="${path#*/}" ;;
                *:*) path="${path#*:}" ;;
            esac
            owner="${path%/*}"
            owner="${owner##*/}"
            owner="$(printf '%s' "$owner" | tr '[:upper:]' '[:lower:]')"
            REPO="ghcr.io/$owner"
        fi
        [[ "$REPO" =~ $REPO_RE ]] || refuse "реестр образов не похож на <реестр>/<владелец>: $REPO — задайте --image-repo"
    fi

    # --- цель ---
    if [ -n "$ref" ]; then
        TARGET="$ref"
    else
        local remote_head
        remote_head="$(dgit ls-remote origin refs/heads/main 2>/dev/null)" || refuse 'git ls-remote origin не удался — нет сети или origin'
        TARGET="${remote_head%%[[:space:]]*}"
        [[ "$TARGET" =~ ^[0-9a-f]{40}$ ]] || refuse 'на origin нет ветки main'
    fi

    local api_image="$REPO/domovoy-api:sha-$TARGET" migrate_image="$REPO/domovoy-migrate:sha-$TARGET"
    local insecure=()
    case "$REPO" in
        127.0.0.1[:/]* | localhost[:/]*) insecure=(--insecure) ;;
    esac
    local img
    for img in "$api_image" "$migrate_image"; do
        docker manifest inspect "${insecure[@]+"${insecure[@]}"}" "$img" >/dev/null 2>&1 \
            || refuse "образа $img нет в реестре — CI ещё публикует его или публикация не удалась"
    done

    # --- каталог бэкапов ---
    local backup_cmd="${DOMOVOY_UPDATE_BACKUP:-bash ops/backup/backup.sh}" backup_dir
    if [ -n "${BACKUP_DIR+x}" ]; then
        backup_dir="$BACKUP_DIR"
    else
        backup_dir="$(env_get BACKUP_DIR)"
    fi
    [ -n "$backup_dir" ] || refuse 'BACKUP_DIR не задан в .env каталога развёртывания — бэкап перед миграцией некуда писать'
    # shellcheck source=ops/backup/dotenv.sh
    . "$TOOLS/ops/backup/dotenv.sh"
    backup_dir="$(host_path "$backup_dir")"
    [ -d "$backup_dir" ] || refuse "каталог бэкапов недоступен: $backup_dir"

    local prev_tag=''
    env_has DOMOVOY_IMAGE_TAG && prev_tag="$(env_get DOMOVOY_IMAGE_TAG)"

    # --- сухой прогон ---
    if [ "$dry_run" -eq 1 ]; then
        say "сухой прогон — ничего не меняется"
        say "каталог: $DIR, проект: $PROJECT"
        say "текущий коммит: $PREV_COMMIT"
        say "целевой коммит: $TARGET"
        say "образы: $api_image, $migrate_image"
        say "бэкап: будет выполнен: $backup_cmd (в $backup_dir)"
        local example="$TOOLS/example"
        if dgit cat-file -e "$TARGET^{commit}" 2>/dev/null; then
            dgit show "$TARGET:.env.example" >"$example" 2>/dev/null \
                || refuse "в коммите $TARGET нет .env.example"
        else
            local url shallow="$TOOLS/shallow"
            url="$(dgit remote get-url origin 2>/dev/null)" || refuse 'нет remote origin'
            case "$url" in
                /*) url="file://$url" ;;
            esac
            git init --quiet "$shallow" >/dev/null 2>&1 \
                && git -C "$shallow" fetch --quiet --depth 1 "$url" "$TARGET" >/dev/null 2>&1 \
                && git -C "$shallow" show "$TARGET:.env.example" >"$example" 2>/dev/null \
                || refuse "не получен .env.example коммита $TARGET из origin"
            rm -rf "$shallow"
        fi
        local line
        while IFS= read -r line; do
            say ".env: $line"
        done < <(envfile sync --dry-run "$example" "$DIR/.env")
        say "ключи .env: будут записаны COMPOSE_FILE, DOMOVOY_IMAGE_REPO=$REPO, DOMOVOY_IMAGE_TAG=sha-$TARGET"
        say "миграция: compose --profile migrate run --rm migrate (образ $migrate_image)"
        local cand any=0
        while IFS= read -r cand; do
            [ -n "$cand" ] || continue
            any=1
            say "чистка: будет удалён образ $cand"
        done < <(prune_candidates "$prev_tag" "$prev_api")
        [ "$any" -eq 1 ] || say 'чистка: старых образов нет'
        say 'чистка: будет выполнен docker builder prune --all --force'
        exit 0
    fi

    # --- git fetch цели (меняет только refs origin) ---
    dgit fetch --quiet origin >/dev/null 2>&1 || refuse 'git fetch origin не удался'
    if ! dgit cat-file -e "$TARGET^{commit}" 2>/dev/null; then
        dgit fetch --quiet origin "$TARGET" >/dev/null 2>&1 || true
        dgit cat-file -e "$TARGET^{commit}" 2>/dev/null || refuse "коммита $TARGET нет на origin"
    fi

    # --- 1. бэкап ---
    local entry
    say "бэкап: $backup_cmd"
    # Вывод бэкапа — в stderr после строки отказа: при отказе первая строка
    # stderr — строка отказа (контракт кода 1).
    if ! (cd "$DIR" && bash -c "$backup_cmd") >"$TOOLS/backup.log" 2>&1; then
        printf 'update: отказ: бэкап не удался (%s) — обновление не начато\n' "$backup_cmd" >&2
        cat "$TOOLS/backup.log" >&2
        exit 1
    fi
    # Свой бэкап — тот, который назвала команда строкой «успех: <имя>»
    # (ops/backup/backup.sh), а не новый каталог в BACKUP_DIR: плановый
    # бэкап за то же время кладёт туда свой.
    local named
    named="$(tr -d '\r' <"$TOOLS/backup.log" \
        | sed -nE 's/^успех: (domovoy-backup-[0-9]{8}T[0-9]{6}Z)( .*)?$/\1/p')"
    BACKUP_PATH=''
    if [ -n "$named" ] && [ "$(wc -l <<<"$named")" -eq 1 ] && [ -d "$backup_dir/$named" ]; then
        BACKUP_PATH="$backup_dir/$named"
    fi
    if [ -z "$BACKUP_PATH" ]; then
        printf 'update: отказ: бэкап не назвал свой каталог строкой «успех: domovoy-backup-<метка>» или его нет в %s — обновление не начато\n' "$backup_dir" >&2
        cat "$TOOLS/backup.log" >&2
        exit 1
    fi
    cat "$TOOLS/backup.log" >&2
    say "бэкап: $BACKUP_PATH"

    # --- 2. файл состояния ---
    write_state || refuse "файл состояния $STATE не записан — обновление не начато"

    # --- 3. checkout ---
    say "checkout $TARGET"
    dgit checkout --quiet --detach "$TARGET" >&2 || fail_after_change "checkout $TARGET не удался"

    # --- 4. синхронизация .env ---
    local sync_out
    sync_out="$(envfile sync "$DIR/.env.example" "$DIR/.env")" || fail_after_change 'синхронизация .env не удалась'
    while IFS= read -r entry; do
        [ -n "$entry" ] && say ".env: $entry"
    done <<<"$sync_out"

    # --- 5. управляемые ключи ---
    local compose_file='docker-compose.yml:deploy/docker-compose.deploy.yml'
    [ -f "$DIR/docker-compose.override.yml" ] && compose_file+=':docker-compose.override.yml'
    envfile set "$DIR/.env" COMPOSE_FILE "$compose_file" >&2 \
        && envfile set "$DIR/.env" DOMOVOY_IMAGE_REPO "$REPO" >&2 \
        && envfile set "$DIR/.env" DOMOVOY_IMAGE_TAG "sha-$TARGET" >&2 \
        || fail_after_change 'управляемые ключи .env не записаны'
    say ".env: COMPOSE_FILE, DOMOVOY_IMAGE_REPO, DOMOVOY_IMAGE_TAG=sha-$TARGET"

    # --- 6–7. образы и миграция ---
    say "pull $api_image, $migrate_image"
    dc --profile migrate pull api migrate >&2 || fail_after_change 'compose pull не удался'
    say 'миграция схемы'
    dc --profile migrate run --rm migrate >&2 || fail_after_change 'миграция не удалась (psql откатил свою транзакцию)'

    # --- 8. перезапуск и /health ---
    # compose up пересоздаёт только службы с изменённой конфигурацией: у
    # postgres и homeassistant при --adopt она та же (именованные тома, те
    # же env), и их метка working_dir осталась бы прежним каталогом —
    # следующий запуск без --adopt отказал бы. При --adopt пересоздаются
    # все службы; тома именованные и сохраняются.
    local recreate=()
    if [ "$adopt" -eq 1 ]; then recreate=(--force-recreate); fi
    say 'перезапуск стека'
    dc --profile ha up -d --wait "${recreate[@]+"${recreate[@]}"}" >&2 || fail_after_change "compose up -d --wait на sha-$TARGET не удался"
    check_health || fail_after_change "/health на 127.0.0.1:$PORT не отвечает 200 формы стека"

    # --- 9. файл состояния ---
    # Сразу после /health, до чистки: обрыв во время чистки не должен
    # откатывать удавшееся обновление на следующем запуске.
    rm -f "$STATE" || warn "файл состояния $STATE не удалён — следующий запуск откатит обновление"

    # --- 10. чистка ---
    local cand
    while IFS= read -r cand; do
        [ -n "$cand" ] || continue
        if docker image rm "$cand" >&2; then
            say "чистка: удалён образ $cand"
        else
            warn "чистка: образ $cand не удалён (используется?)"
        fi
    done < <(prune_candidates "$prev_tag" "$prev_api")
    docker builder prune --all --force >&2 || warn 'чистка: docker builder prune не удался'

    say "готово: $TARGET (образ sha-$TARGET)"
    exit 0
}

main "$@"; exit $?
