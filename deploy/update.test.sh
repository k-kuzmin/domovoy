#!/usr/bin/env bash
#
# Домовой — проверочные сценарии deploy/update.sh, deploy/build-images.sh и
# deploy/windows/update.ps1 (#162).
#
# ЗАЧЕМ
#
# Обновление стека меняет боевой каталог развёртывания: коммит, .env,
# контейнеры и схему базы. Ошибка в порядке шагов здесь тихая — миграция из
# образа прежнего тега, откат, забывший вернуть тег, сухой прогон, тронувший
# .git, или секрет .env в выводе обновления не видны до первого отказа стека.
#
# НА ЧЁМ
#
# Настоящий git на временном bare-origin и его клоне (каталог развёртывания).
# docker, curl, git (обёртка над настоящим — только журнал вызовов), gitleaks
# и команда бэкапа подменяются подделками первыми в PATH: настоящий движок
# тест не трогает и в сеть не ходит. Подделка compose читает .env каталога в
# момент вызова и пишет в журнал DOMOVOY_IMAGE_TAG и COMPOSE_FILE — тег
# compose берёт из .env, в аргументах его нет. Значения .env — метки вида
# VAL_…; ни одно не печатается и в выводе тестов.
#
# Сценарии с flock и setsid (блокировка, обрыв процесса) — только Linux
# (ubuntu-раннер ci-fast): в Git Bash их нет, и там вместо flock в PATH
# лежит подделка, которая блокировку не держит. Сценарий update.ps1 — только
# Windows (powershell.exe).
#
# КАК ЗАПУСКАТЬ
#
#   bash deploy/update.test.sh
#
# Код возврата: 0 — все сценарии прошли, 1 — есть провалившиеся,
# 2 — запустить нечем.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd -P)"

for f in "$SCRIPT_DIR/update.sh" "$SCRIPT_DIR/envfile.sh" "$SCRIPT_DIR/build-images.sh" \
    "$SCRIPT_DIR/docker-compose.deploy.yml" "$REPO/ops/backup/dotenv.sh" "$REPO/docker-compose.yml"; do
    if [ ! -f "$f" ]; then
        printf 'Не найден %s\n' "$f" >&2
        exit 2
    fi
done

REAL_GIT="$(command -v git)" || { printf 'Нет git\n' >&2; exit 2; }

SANDBOX="$(mktemp -d)"
HOLDER_PID=''
cleanup() {
    if [ -n "$HOLDER_PID" ]; then kill "$HOLDER_PID" 2>/dev/null || true; fi
    rm -rf "$SANDBOX"
}
trap cleanup EXIT

PASSED=0
FAILED=0
SKIPPED=0
FAILED_NAMES=()

CASE_NAME=''
CASE_OK=1
CASE_NO=0
CASE=''
OUT=''
ERR=''
STATUS=0

is_linux() { [ "$(uname -s)" = Linux ]; }
is_windows() {
    case "$(uname -s)" in
        MINGW* | MSYS* | CYGWIN*) return 0 ;;
        *) return 1 ;;
    esac
}

begin_case() {
    CASE_NAME="$1"
    CASE_OK=1
    CASE_NO=$((CASE_NO + 1))
    CASE="$SANDBOX/case-$CASE_NO"
    mkdir -p "$CASE"
}

fail_case() {
    CASE_OK=0
    printf '  провал: %s\n' "$1"
}

end_case() {
    if [ "$CASE_OK" -eq 1 ]; then
        PASSED=$((PASSED + 1))
        printf 'ok   %s\n' "$CASE_NAME"
    else
        FAILED=$((FAILED + 1))
        FAILED_NAMES+=("$CASE_NAME")
        printf 'FAIL %s\n' "$CASE_NAME"
    fi
}

skip_case() {
    SKIPPED=$((SKIPPED + 1))
    printf 'skip %s: %s\n' "$1" "$2"
}

expect_status() {
    [ "$STATUS" -eq "$1" ] || fail_case "код $STATUS, ожидался $1"
}

expect_out_has() {
    grep -qF -- "$1" <<<"$OUT" || fail_case "в stdout нет «$1»"
}

expect_out_lacks() {
    if grep -qF -- "$1" <<<"$OUT"; then fail_case "в stdout лишнее «$1»"; fi
}

expect_err_first() {
    local first
    first="$(head -n 1 <<<"$ERR")"
    case "$first" in
        "$1"*) ;;
        *) fail_case "первая строка stderr не начинается с «$1»" ;;
    esac
}

expect_err_has() {
    grep -qF -- "$1" <<<"$ERR" || fail_case "в stderr нет «$1»"
}

# Каждая строка stdout начинается с «update: ».
expect_out_prefixed() {
    local line
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        case "$line" in
            'update: '*) ;;
            *) fail_case 'в stdout строка без префикса «update: »'; return ;;
        esac
    done <<<"$OUT"
}

# ------------------------------------------------------------------
# Подделки
# ------------------------------------------------------------------
# Журнал всех вызовов подделок — $FAKE/calls.log, одна строка на вызов.
# Управление подделками — файлы в $FAKE:
#   info_fail             docker info отвечает ошибкой (движок не работает)
#   ps                    вывод docker ps (служба<TAB>working_dir<TAB>образ)
#   missing               образы, на которые manifest inspect отвечает ошибкой
#   images.<имя>          вывод docker image ls по репозиторию …/<имя>
#   up_fail_tags          теги, на которых compose up падает
#   up_hang_tag           тег, на котором compose up пишет метку hang и спит
#   curl_fail_tags        теги, на которых /health не отвечает
#   backup_fail           команда бэкапа отвечает ошибкой
FAKE_BIN_SRC="$SANDBOX/fake-src"
mkdir -p "$FAKE_BIN_SRC"

cat >"$FAKE_BIN_SRC/docker" <<'EOF'
#!/usr/bin/env bash
F="$FAKE_DIR"
env_value() {
    [ -f .env ] || { printf '<нет .env>'; return; }
    local v
    v="$(sed -n "s/^$1=//p" .env | tr -d '\r' | tail -n 1)"
    if grep -q "^$1=" .env; then printf '%s' "$v"; else printf '<нет>'; fi
}
case "${1-}" in
    info)
        printf 'docker info\n' >>"$F/calls.log"
        if [ -e "$F/info_fail" ]; then echo 'Cannot connect to the Docker daemon' >&2; exit 1; fi
        echo 'Server: example'
        ;;
    compose)
        shift
        if [ "${1-}" = version ]; then echo '2.29.1'; exit 0; fi
        tag="$(env_value DOMOVOY_IMAGE_TAG)"
        cf="$(env_value COMPOSE_FILE)"
        printf 'docker compose %s | tag=%s cf=%s\n' "$*" "$tag" "$cf" >>"$F/calls.log"
        case " $* " in
            *' up '*)
                if [ -f "$F/up_hang_tag" ] && [ "$(cat "$F/up_hang_tag")" = "$tag" ]; then
                    ps -o pgid= -p $$ | tr -d ' ' >"$F/hang.pgid"
                    : >"$F/hang"
                    sleep 60
                fi
                if [ -f "$F/up_fail_tags" ] && grep -qxF -- "$tag" "$F/up_fail_tags"; then
                    echo 'container example-api is unhealthy' >&2
                    exit 1
                fi
                ;;
        esac
        exit 0
        ;;
    ps)
        printf 'docker %s\n' "$*" >>"$F/calls.log"
        [ -f "$F/ps" ] && cat "$F/ps"
        exit 0
        ;;
    manifest)
        printf 'docker %s\n' "$*" >>"$F/calls.log"
        image="${*: -1}"
        if [ -f "$F/missing" ] && grep -qxF -- "$image" "$F/missing"; then
            echo "no such manifest: $image" >&2
            exit 1
        fi
        echo '{}'
        ;;
    image)
        printf 'docker %s\n' "$*" >>"$F/calls.log"
        if [ "${2-}" = ls ]; then
            ref="${*: -1}"
            name="${ref##*/}"
            [ -f "$F/images.$name" ] && cat "$F/images.$name"
        fi
        exit 0
        ;;
    *)
        printf 'docker %s\n' "$*" >>"$F/calls.log"
        exit 0
        ;;
esac
EOF

cat >"$FAKE_BIN_SRC/curl" <<'EOF'
#!/usr/bin/env bash
F="$FAKE_DIR"
printf 'curl %s\n' "$*" >>"$F/calls.log"
tag=''
[ -f .env ] && tag="$(sed -n 's/^DOMOVOY_IMAGE_TAG=//p' .env | tr -d '\r' | tail -n 1)"
out=''
prev=''
for a in "$@"; do
    [ "$prev" = --output ] && out="$a"
    prev="$a"
done
if [ -f "$F/curl_fail_tags" ] && grep -qxF -- "$tag" "$F/curl_fail_tags"; then
    printf '000'
    exit 7
fi
[ -n "$out" ] && printf '{"status":"healthy"}' >"$out"
printf '200'
EOF

cat >"$FAKE_BIN_SRC/git" <<'EOF'
#!/usr/bin/env bash
printf 'git %s\n' "$*" >>"$FAKE_DIR/calls.log"
exec "$REAL_GIT" "$@"
EOF

# Подделка flock — только вне Linux: в Git Bash flock нет, а сценарий
# без него отказывает. Блокировку она не держит.
cat >"$FAKE_BIN_SRC/flock" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat >"$FAKE_BIN_SRC/backup.sh" <<'EOF'
#!/usr/bin/env bash
F="$FAKE_DIR"
printf 'backup\n' >>"$F/calls.log"
[ -e "$F/backup_fail" ] && { echo 'backup: носитель недоступен' >&2; exit 1; }
n=$(( $(cat "$F/backup.count" 2>/dev/null || echo 0) + 1 ))
printf '%s' "$n" >"$F/backup.count"
mkdir -p "$FAKE_BACKUP_DIR/domovoy-backup-2026010${n}T000000Z"
echo "backup: готово"
EOF

# ------------------------------------------------------------------
# Фикстура: origin, клон развёртывания, коммиты
# ------------------------------------------------------------------
g() {
    "$REAL_GIT" -c user.name=example -c user.email=example@example.invalid \
        -c commit.gpgsign=false -c core.autocrlf=false -c init.defaultBranch=main "$@"
}

# make_fixture [adopt] — origin с коммитом C1, клон $DEPLOY на C1, .env,
# подделки. Переменные: ORIGIN WORK DEPLOY FAKE BACKUPS C1 PROJECT DEPLOY_P.
make_fixture() {
    local mode="${1-}"
    ORIGIN="$CASE/origin.git"
    WORK="$CASE/work"
    DEPLOY="$CASE/deploy"
    FAKE="$CASE/fake"
    BACKUPS="$CASE/backups"
    PROJECT=example-proj
    mkdir -p "$FAKE/bin" "$BACKUPS" "$CASE/tmp"
    cp "$FAKE_BIN_SRC/docker" "$FAKE_BIN_SRC/curl" "$FAKE_BIN_SRC/git" "$FAKE/bin/"
    is_linux || cp "$FAKE_BIN_SRC/flock" "$FAKE/bin/"
    cp "$FAKE_BIN_SRC/backup.sh" "$FAKE/backup.sh"
    chmod +x "$FAKE"/bin/*
    : >"$FAKE/calls.log"

    g init -q "$WORK"
    mkdir -p "$WORK/deploy" "$WORK/ops/backup"
    cp "$SCRIPT_DIR/update.sh" "$SCRIPT_DIR/envfile.sh" "$SCRIPT_DIR/docker-compose.deploy.yml" "$WORK/deploy/"
    cp "$REPO/ops/backup/dotenv.sh" "$WORK/ops/backup/"
    cp "$REPO/docker-compose.yml" "$WORK/"
    printf '.env\nconfig/\n' >"$WORK/.gitignore"
    cat >"$WORK/.env.example" <<'EOT'
COMPOSE_PROJECT_NAME=example-proj
API_HTTP_PORT=19999
# env-sync: owner
POSTGRES_PASSWORD=<postgres-password>
# env-sync: owner
HA_TOKEN=<ha-token>
# env-sync: owner
BACKUP_DIR=<backup-dir>
EOT
    g -C "$WORK" add -A
    g -C "$WORK" commit -qm C1
    C1="$(g -C "$WORK" rev-parse HEAD)"
    g clone -q --bare "$WORK" "$ORIGIN"
    g -C "$WORK" remote add origin "$ORIGIN"
    g clone -q "$ORIGIN" "$DEPLOY"
    DEPLOY_P="$(cd "$DEPLOY" && pwd -P)"

    {
        printf 'COMPOSE_PROJECT_NAME=example-proj\n'
        printf 'API_HTTP_PORT=19999\n'
        printf 'POSTGRES_PASSWORD=VAL_pg_password_marker\n'
        printf 'HA_TOKEN=VAL_ha_token_marker\n'
        printf 'BACKUP_DIR=%s\n' "$BACKUPS"
        if [ "$mode" != adopt ]; then
            printf 'COMPOSE_FILE=docker-compose.yml:deploy/docker-compose.deploy.yml\n'
            printf 'DOMOVOY_IMAGE_REPO=example.invalid/owner\n'
            printf 'DOMOVOY_IMAGE_TAG=sha-%s\n' "$C1"
        fi
    } >"$DEPLOY/.env"

    local wd="$DEPLOY_P" api_image="example.invalid/owner/domovoy-api:sha-$C1"
    if [ "$mode" = adopt ]; then
        wd="$CASE/windows-clone"
        api_image="$PROJECT-api"
    fi
    printf 'postgres\t%s\tpostgres:16-alpine\napi\t%s\t%s\nhomeassistant\t%s\tghcr.io/home-assistant/home-assistant:2026.10.1\n' \
        "$wd" "$wd" "$api_image" "$wd" >"$FAKE/ps"
}

# commit_c2 [self-change] — C2 в origin: три размеченных ключа в
# .env.example; с self-change — правка середины deploy/update.sh.
commit_c2() {
    cat >>"$WORK/.env.example" <<'EOT'
NEW_PLAIN=VAL_new_plain_example
# env-sync: generate
NEW_GEN=<generated>
# env-sync: owner
NEW_OWN=<owner-value>
EOT
    if [ "${1-}" = self-change ]; then
        local half
        half=$(( $(wc -l <"$WORK/deploy/update.sh") / 2 ))
        {
            head -n "$half" "$WORK/deploy/update.sh"
            for _ in $(seq 1 40); do printf '# строка-сдвиг новой версии\n'; done
            printf 'say "НОВАЯ_ВЕРСИЯ_СЦЕНАРИЯ"\n'
            tail -n +"$((half + 1))" "$WORK/deploy/update.sh"
            printf 'printf "update: НОВАЯ_ВЕРСИЯ_ХВОСТ\\n"\n'
        } >"$CASE/update.sh.new"
        mv "$CASE/update.sh.new" "$WORK/deploy/update.sh"
    fi
    g -C "$WORK" add -A
    g -C "$WORK" commit -qm C2
    C2="$(g -C "$WORK" rev-parse HEAD)"
    g -C "$WORK" push -q origin main
}

# run_update <аргументы> — deploy/update.sh из клона развёртывания.
run_update() {
    (
        cd "$CASE" || exit 99
        PATH="$FAKE/bin:$PATH" FAKE_DIR="$FAKE" REAL_GIT="$REAL_GIT" \
            FAKE_BACKUP_DIR="$BACKUPS" TMPDIR="$CASE/tmp" \
            DOMOVOY_UPDATE_BACKUP="bash $FAKE/backup.sh" \
            bash "$DEPLOY/deploy/update.sh" "$@" </dev/null >"$CASE/out" 2>"$CASE/err"
    )
    STATUS=$?
    OUT="$(cat "$CASE/out")"
    ERR="$(cat "$CASE/err")"
}

head_of() { g -C "$DEPLOY" rev-parse HEAD; }
env_key() { sed -n "s/^$1=//p" "$DEPLOY/.env" | tr -d '\r' | tail -n 1; }
env_has_key() { grep -q "^$1=" "$DEPLOY/.env"; }
state_file() { printf '%s' "$DEPLOY/.git/domovoy-update.state"; }

# checkout в каталоге развёртывания (обёртка git пишет «git -C <каталог> …»).
GIT_CO='^git -C [^ ]+ checkout'

# Изменяющие вызовы docker в журнале.
mutations() {
    grep -E '^docker (compose .*( pull | run | up | down |pull |run |up |down )|image rm|rmi|tag |builder prune|push)' "$FAKE/calls.log" || true
}

# Номер первой строки журнала, начинающейся с шаблона; нет — пусто.
log_line() { grep -n -E -- "$1" "$FAKE/calls.log" | head -n 1 | cut -d: -f1; }

expect_no_leak() {
    local m
    for m in VAL_pg_password_marker VAL_ha_token_marker; do
        if grep -qF -- "$m" <<<"$OUT$ERR"; then fail_case "значение .env ($m) в выводе"; fi
    done
}

expect_no_state() {
    [ ! -e "$(state_file)" ] || fail_case 'файл .git/domovoy-update.state есть'
}

# ------------------------------------------------------------------
# Сценарии update.sh
# ------------------------------------------------------------------
begin_case 'update_dry_run_changes_nothing'
make_fixture
commit_c2
before_head="$(head_of)"
before_status="$(g -C "$DEPLOY" status --porcelain)"
before_refs="$(g -C "$DEPLOY" for-each-ref)"
before_env="$(sha256sum <"$DEPLOY/.env")"
run_update --dry-run
expect_status 0
expect_out_has "$C2"
expect_out_has "example.invalid/owner/domovoy-api:sha-$C2"
expect_out_has "example.invalid/owner/domovoy-migrate:sha-$C2"
expect_out_has "bash $FAKE/backup.sh"
expect_out_has 'update: .env: будет добавлен NEW_PLAIN (из примера)'
expect_out_has 'update: .env: будет заполните NEW_OWN'
expect_out_has 'update: чистка:'
expect_out_prefixed
expect_no_leak
[ "$before_head" = "$(head_of)" ] || fail_case 'HEAD изменился'
[ "$before_status" = "$(g -C "$DEPLOY" status --porcelain)" ] || fail_case 'git status изменился'
[ "$before_refs" = "$(g -C "$DEPLOY" for-each-ref)" ] || fail_case 'refs изменились'
[ "$before_env" = "$(sha256sum <"$DEPLOY/.env")" ] || fail_case '.env изменился'
[ -z "$(mutations)" ] || fail_case "изменяющие вызовы docker: $(mutations | head -n 1)"
grep -q '^backup' "$FAKE/calls.log" && fail_case 'бэкап вызван'
grep -qE "^git -C $DEPLOY_P (fetch|checkout)" "$FAKE/calls.log" && fail_case 'git fetch или checkout в сухом прогоне'
[ -z "$(ls -A "$CASE/tmp")" ] || fail_case 'временный клон или каталог не удалён'
expect_no_state
end_case

begin_case 'update_refuses_without_engine'
make_fixture
commit_c2
: >"$FAKE/info_fail"
before_env="$(sha256sum <"$DEPLOY/.env")"
run_update
expect_status 1
expect_err_first 'update: отказ: '
head -n 1 <<<"$ERR" | grep -qi 'docker\|движ' || fail_case 'причина не называет движок'
[ "$C1" = "$(head_of)" ] || fail_case 'HEAD изменился'
[ "$before_env" = "$(sha256sum <"$DEPLOY/.env")" ] || fail_case '.env изменился'
grep -q '^backup' "$FAKE/calls.log" && fail_case 'бэкап вызван'
[ -z "$(mutations)" ] || fail_case 'есть изменяющие вызовы docker'
expect_no_state
end_case

begin_case 'update_refuses_missing_deploy_dir'
make_fixture
mkdir -p "$CASE/not-a-clone"
run_update --dir "$CASE/absent"
expect_status 1
expect_err_first 'update: отказ: '
head -n 1 <<<"$ERR" | grep -q 'каталог развёртывания' || fail_case 'причина не про каталог развёртывания (нет каталога)'
run_update --dir "$CASE/not-a-clone"
expect_status 1
expect_err_first 'update: отказ: '
head -n 1 <<<"$ERR" | grep -q 'каталог развёртывания' || fail_case 'причина не про каталог развёртывания (без .git)'
[ ! -e "$CASE/not-a-clone/.git" ] || fail_case 'в каталоге без .git что-то создано'
grep -q '^docker' "$FAKE/calls.log" && fail_case 'docker вызывался'
end_case

begin_case 'update_refuses_when_image_missing'
make_fixture
commit_c2
printf 'example.invalid/owner/domovoy-migrate:sha-%s\n' "$C2" >"$FAKE/missing"
run_update
expect_status 1
expect_err_first 'update: отказ: '
head -n 1 <<<"$ERR" | grep -qF "domovoy-migrate:sha-$C2" || fail_case 'причина не называет образ'
grep -q '^backup' "$FAKE/calls.log" && fail_case 'бэкап вызван'
grep -qE "$GIT_CO" "$FAKE/calls.log" && fail_case 'checkout вызван'
[ "$C1" = "$(head_of)" ] || fail_case 'HEAD изменился'
expect_no_state
end_case

begin_case 'update_refuses_foreign_working_dir'
make_fixture adopt
commit_c2
run_update
expect_status 1
expect_err_first 'update: отказ: '
head -n 1 <<<"$ERR" | grep -qF "$CASE/windows-clone" || fail_case 'причина не называет чужой каталог'
expect_no_state
[ -z "$(mutations)" ] || fail_case 'есть изменяющие вызовы docker'
run_update --adopt --image-repo example.invalid/owner
expect_status 0
expect_out_has "update: готово: $C2 (образ sha-$C2)"
end_case

begin_case 'update_backup_before_migrate_prints_path'
make_fixture
commit_c2
before_dirs="$(ls "$BACKUPS")"
run_update
expect_status 0
b="$(log_line '^backup')"
c="$(log_line "$GIT_CO")"
m="$(log_line '^docker compose --profile migrate run --rm migrate')"
[ -n "$b" ] && [ -n "$c" ] && [ -n "$m" ] || fail_case 'нет бэкапа, checkout или migrate в журнале'
if [ -n "$b" ] && [ -n "$c" ] && [ -n "$m" ]; then
    [ "$b" -lt "$c" ] && [ "$c" -lt "$m" ] || fail_case "порядок: бэкап $b, checkout $c, migrate $m"
fi
new_dir="$(comm -13 <(printf '%s\n' "$before_dirs") <(ls "$BACKUPS"))"
[ -n "$new_dir" ] || fail_case 'бэкап не создал каталог'
expect_out_has "update: бэкап: $BACKUPS/$new_dir"
expect_no_state
end_case

begin_case 'update_backup_failure_refuses_without_checkout'
make_fixture
commit_c2
: >"$FAKE/backup_fail"
run_update
expect_status 1
expect_err_first 'update: отказ: '
grep -qE "$GIT_CO" "$FAKE/calls.log" && fail_case 'checkout после отказа бэкапа'
[ "$C1" = "$(head_of)" ] || fail_case 'HEAD изменился'
expect_no_state
end_case

begin_case 'update_syncs_env_after_checkout'
make_fixture
commit_c2
run_update
expect_status 0
[ "$(env_key NEW_PLAIN)" = VAL_new_plain_example ] || fail_case 'NEW_PLAIN не дописан значением примера'
[[ "$(env_key NEW_GEN)" =~ ^[A-Za-z0-9]{48}$ ]] || fail_case 'NEW_GEN не сгенерирован'
gen="$(env_key NEW_GEN)"
if [ -n "$gen" ] && grep -qF -- "$gen" <<<"$OUT$ERR"; then fail_case 'сгенерированное значение в выводе'; fi
env_has_key NEW_OWN && fail_case 'owner-ключ дописан'
expect_out_has 'заполните NEW_OWN'
[ "$(env_key DOMOVOY_IMAGE_TAG)" = "sha-$C2" ] || fail_case 'DOMOVOY_IMAGE_TAG не sha-<цель>'
[ "$(head_of)" = "$C2" ] || fail_case 'HEAD не целевой коммит'
expect_out_prefixed
expect_no_leak
end_case

# Тег и COMPOSE_FILE, которые видел каждый вызов compose после checkout.
check_tags_before_migrate() {
    local after_checkout line seen_pull=0 seen_run=0
    after_checkout="$(log_line "$GIT_CO")"
    [ -n "$after_checkout" ] || { fail_case 'нет checkout'; return; }
    while IFS= read -r line; do
        case "$line" in
            'docker compose '*) ;;
            *) continue ;;
        esac
        case "$line" in *" pull "*) seen_pull=1 ;; esac
        case "$line" in *'--profile migrate run --rm migrate'*) seen_run=1 ;; esac
        case "$line" in
            *"| tag=sha-$C2 cf="*deploy/docker-compose.deploy.yml*) ;;
            *) fail_case "compose после checkout видит не тот тег или COMPOSE_FILE: ${line%% |*}"; return ;;
        esac
    done < <(tail -n +"$after_checkout" "$FAKE/calls.log")
    [ "$seen_pull" -eq 1 ] || fail_case 'нет compose pull'
    [ "$seen_run" -eq 1 ] || fail_case 'нет compose --profile migrate run --rm migrate'
}

begin_case 'update_sets_target_tag_before_migrate'
make_fixture
commit_c2
run_update
expect_status 0
check_tags_before_migrate
end_case

begin_case 'update_sets_target_tag_before_migrate (первое --adopt)'
make_fixture adopt
commit_c2
run_update --adopt --image-repo example.invalid/owner
expect_status 0
check_tags_before_migrate
[ "$(env_key DOMOVOY_IMAGE_REPO)" = example.invalid/owner ] || fail_case 'DOMOVOY_IMAGE_REPO не записан'
end_case

begin_case 'update_rolls_back_on_failed_health'
make_fixture
commit_c2
printf 'sha-%s\n' "$C2" >"$FAKE/up_fail_tags"
before_cf="$(env_key COMPOSE_FILE)"
run_update
expect_status 3
expect_out_has 'update: откат: '
[ "$(head_of)" = "$C1" ] || fail_case 'HEAD не прежний коммит'
[ "$(env_key DOMOVOY_IMAGE_TAG)" = "sha-$C1" ] || fail_case 'тег не прежний'
[ "$(env_key COMPOSE_FILE)" = "$before_cf" ] || fail_case 'COMPOSE_FILE не прежний'
[ "$(grep -c '^docker compose .* up ' "$FAKE/calls.log")" -ge 2 ] || fail_case 'повторный up не вызван'
grep -qE '^docker (image rm|builder prune)' "$FAKE/calls.log" && fail_case 'чистка после провала'
expect_no_state
expect_no_leak
end_case

begin_case 'update_rolls_back_on_failed_health (/health не отвечает)'
make_fixture
commit_c2
printf 'sha-%s\n' "$C2" >"$FAKE/curl_fail_tags"
run_update
expect_status 3
[ "$(head_of)" = "$C1" ] || fail_case 'HEAD не прежний коммит'
[ "$(env_key DOMOVOY_IMAGE_TAG)" = "sha-$C1" ] || fail_case 'тег не прежний'
grep -qE '^docker (image rm|builder prune)' "$FAKE/calls.log" && fail_case 'чистка после провала'
expect_no_state
end_case

begin_case 'update_rolls_back_on_failed_health (--adopt — ключи сняты)'
make_fixture adopt
commit_c2
printf 'sha-%s\n' "$C2" >"$FAKE/up_fail_tags"
run_update --adopt --image-repo example.invalid/owner
expect_status 3
[ "$(head_of)" = "$C1" ] || fail_case 'HEAD не прежний коммит'
for k in COMPOSE_FILE DOMOVOY_IMAGE_REPO DOMOVOY_IMAGE_TAG; do
    env_has_key "$k" && fail_case "ключ $k не снят"
done
expect_no_state
end_case

begin_case 'update_rollback_failure_exit_4'
make_fixture
commit_c2
printf 'sha-%s\nsha-%s\n' "$C2" "$C1" >"$FAKE/up_fail_tags"
run_update
expect_status 4
bdir="$(ls "$BACKUPS" | head -n 1)"
expect_err_has "$BACKUPS/$bdir"
grep -qi 'вручную\|ручн' <<<"$ERR" || fail_case 'нет указания на ручные шаги'
[ -e "$(state_file)" ] || fail_case 'файл состояния удалён при отказе отката'
end_case

begin_case 'update_prunes_all_but_current_and_previous'
make_fixture
commit_c2
for name in domovoy-api domovoy-migrate; do
    printf 'example.invalid/owner/%s:%s\n' \
        "$name" sha-old1 "$name" sha-old2 "$name" "sha-$C1" "$name" "sha-$C2" >"$FAKE/images.$name"
done
printf '%s-api:latest\n' "$PROJECT" >"$FAKE/images.$PROJECT-api"
run_update
expect_status 0
for name in domovoy-api domovoy-migrate; do
    for t in sha-old1 sha-old2; do
        grep -qxF "docker image rm example.invalid/owner/$name:$t" "$FAKE/calls.log" || fail_case "не удалён $name:$t"
    done
    for t in "sha-$C1" "sha-$C2"; do
        grep -qF "image rm example.invalid/owner/$name:$t" "$FAKE/calls.log" && fail_case "удалён текущий или предыдущий $name"
    done
done
grep -qxF "docker image rm $PROJECT-api" "$FAKE/calls.log" || fail_case 'локальный образ прежней сборки не удалён'
grep -q 'image rm -f\|image rm --force' "$FAKE/calls.log" && fail_case 'image rm с -f'
[ "$(grep -cxF 'docker builder prune --all --force' "$FAKE/calls.log")" = 1 ] || fail_case 'builder prune --all --force не ровно один раз'
grep -q 'builder prune.*--builder' "$FAKE/calls.log" && fail_case 'builder prune с --builder'
h="$(log_line '^curl ')"
r="$(log_line '^docker (image rm|builder prune)')"
[ -n "$h" ] && [ -n "$r" ] && [ "$h" -lt "$r" ] || fail_case 'чистка не после проверки /health'
end_case

begin_case 'update_prune_keeps_local_build_when_it_is_previous (--adopt)'
make_fixture adopt
commit_c2
printf '%s-api:latest\n' "$PROJECT" >"$FAKE/images.$PROJECT-api"
run_update --adopt --image-repo example.invalid/owner
expect_status 0
grep -qF "image rm $PROJECT-api" "$FAKE/calls.log" && fail_case 'удалён образ, на котором работал стек до обновления'
end_case

begin_case 'update_survives_self_change_on_checkout'
make_fixture
commit_c2
run_update
expect_status 0
normalize() {
    sed -e "s|$CASE|CASE|g" -e "s|$C1|C1|g" -e "s|$C2|C2|g" -e 's|tmp\.[A-Za-z0-9]*|tmp.X|g' "$1" | grep -v '^git '
}
normalize "$FAKE/calls.log" >"$SANDBOX/baseline.log"
CASE_NO=$((CASE_NO + 1))
CASE="$SANDBOX/case-$CASE_NO"
mkdir -p "$CASE"
make_fixture
commit_c2 self-change
run_update
expect_status 0
expect_out_has "update: готово: $C2"
expect_out_lacks 'НОВАЯ_ВЕРСИЯ'
grep -qF 'НОВАЯ_ВЕРСИЯ' <<<"$ERR" && fail_case 'строка новой версии в stderr'
normalize "$FAKE/calls.log" >"$SANDBOX/self.log"
cmp -s "$SANDBOX/baseline.log" "$SANDBOX/self.log" || fail_case 'журнал вызовов отличается от прогона без правки'
end_case

begin_case 'update_dry_run_with_ref_not_fetched'
make_fixture
commit_c2
g -C "$WORK" commit -q --allow-empty -m C3
g -C "$WORK" push -q origin main
run_update --dry-run --ref "$C2"
expect_status 0
expect_out_has "$C2"
expect_out_has 'update: .env: будет добавлен NEW_PLAIN (из примера)'
[ -z "$(ls -A "$CASE/tmp")" ] || fail_case 'временный клон не удалён'
end_case

begin_case 'update_usage_errors_exit_2'
make_fixture
run_update --bogus
expect_status 2
run_update --ref not-a-sha
expect_status 2
run_update --image-repo 'Example.Invalid/Owner'
expect_status 2
end_case

begin_case 'docker-compose.deploy.yml: образы из реестра и сервис migrate'
D="$SCRIPT_DIR/docker-compose.deploy.yml"
grep -qF 'image: ${DOMOVOY_IMAGE_REPO:?' "$D" || fail_case 'нет image api из DOMOVOY_IMAGE_REPO'
grep -qF '/domovoy-api:${DOMOVOY_IMAGE_TAG:?' "$D" || fail_case 'нет тега api'
grep -qF '/domovoy-migrate:${DOMOVOY_IMAGE_TAG:?' "$D" || fail_case 'нет тега migrate'
grep -qF 'build: !reset null' "$D" || fail_case 'нет build: !reset null'
grep -qF 'PGPASSWORD: ${POSTGRES_PASSWORD}' "$D" || fail_case 'нет PGPASSWORD из окружения'
grep -qE 'profiles: \[ *migrate *\]' "$D" || fail_case 'нет профиля migrate'
end_case

# ------------------------------------------------------------------
# Только Linux: блокировка и обрыв процесса
# ------------------------------------------------------------------
if is_linux && command -v flock >/dev/null 2>&1; then
    begin_case 'update_lock_refuses_parallel_run'
    make_fixture
    commit_c2
    printf 'prev_commit=%s\ntarget_commit=%s\n' "$C1" "$C2" >"$(state_file)"
    state_sum="$(cksum <"$(state_file)")"
    # exec: kill держателя гасит и sleep, а не оставляет его сиротой с
    # дескриптором блокировки.
    ( flock 9; : >"$CASE/held"; exec sleep 30 ) 9>>"$DEPLOY/.git/domovoy-update.lock" >/dev/null 2>&1 &
    HOLDER_PID=$!
    for _ in $(seq 1 100); do [ -e "$CASE/held" ] && break; sleep 0.1; done
    run_update
    expect_status 1
    expect_err_first 'update: отказ: '
    grep -qF 'обновление уже идёт' <<<"$ERR" || fail_case 'причина не «обновление уже идёт»'
    grep -q '^docker' "$FAKE/calls.log" && fail_case 'docker вызывался'
    [ -e "$(state_file)" ] && [ "$state_sum" = "$(cksum <"$(state_file)")" ] || fail_case 'файл состояния изменён или удалён'
    kill "$HOLDER_PID" 2>/dev/null
    wait "$HOLDER_PID" 2>/dev/null
    HOLDER_PID=''
    end_case
else
    skip_case 'update_lock_refuses_parallel_run' 'только Linux: flock в Git Bash нет'
fi

if is_linux && command -v flock >/dev/null 2>&1 && command -v setsid >/dev/null 2>&1; then
    begin_case 'update_resumes_rollback_after_kill'
    make_fixture
    commit_c2
    printf 'sha-%s\n' "$C2" >"$FAKE/up_hang_tag"
    (
        cd "$CASE" || exit 99
        PATH="$FAKE/bin:$PATH" FAKE_DIR="$FAKE" REAL_GIT="$REAL_GIT" \
            FAKE_BACKUP_DIR="$BACKUPS" TMPDIR="$CASE/tmp" \
            DOMOVOY_UPDATE_BACKUP="bash $FAKE/backup.sh" \
            exec setsid bash "$DEPLOY/deploy/update.sh" </dev/null >"$CASE/out" 2>"$CASE/err"
    ) &
    upd=$!
    for _ in $(seq 1 300); do [ -e "$FAKE/hang" ] && break; sleep 0.1; done
    [ -e "$FAKE/hang" ] || fail_case 'поддельный up не дошёл до метки'
    pgid="$(cat "$FAKE/hang.pgid" 2>/dev/null)"
    own_pgid="$(ps -o pgid= -p $$ | tr -d ' ')"
    if [ -z "$pgid" ] || [ "$pgid" = "$own_pgid" ]; then
        # setsid не отделил группу: kill -9 группы убил бы сам тест.
        fail_case "группа процесса update.sh не отдельная (pgid «$pgid»)"
        pkill -9 -f "$DEPLOY/deploy/update.sh" 2>/dev/null
    else
        kill -9 -- "-$pgid" 2>/dev/null
    fi
    wait "$upd" 2>/dev/null
    rm -f "$FAKE/up_hang_tag"
    [ "$(head_of)" = "$C2" ] || fail_case 'после обрыва HEAD не целевой коммит'
    [ -e "$(state_file)" ] || fail_case 'после обрыва нет файла состояния'
    grep -qxF "prev_commit=$C1" "$(state_file)" || fail_case 'в файле состояния нет prev_commit'
    grep -qxF "prev.DOMOVOY_IMAGE_TAG=sha-$C1" "$(state_file)" || fail_case 'нет prev.DOMOVOY_IMAGE_TAG'
    grep -qF 'VAL_' "$(state_file)" && fail_case 'в файле состояния значение прочих ключей .env'
    [ "$(stat -c %a "$(state_file)")" = 600 ] || fail_case 'права файла состояния не 600'

    backups_before="$(ls "$BACKUPS" | wc -l)"
    env_before="$(sha256sum <"$DEPLOY/.env")"
    state_before="$(sha256sum <"$(state_file)")"
    run_update --dry-run
    expect_status 0
    expect_out_has "update: будет выполнен откат прерванного обновления $C2"
    [ "$(head_of)" = "$C2" ] || fail_case 'сухой прогон сменил HEAD'
    [ "$env_before" = "$(sha256sum <"$DEPLOY/.env")" ] || fail_case 'сухой прогон изменил .env'
    [ "$state_before" = "$(sha256sum <"$(state_file)")" ] || fail_case 'сухой прогон изменил файл состояния'

    : >"$FAKE/info_fail"
    run_update
    expect_status 1
    expect_err_first 'update: отказ: '
    [ "$(head_of)" = "$C2" ] || fail_case 'отказ движка начал откат'
    [ -e "$(state_file)" ] || fail_case 'отказ движка удалил файл состояния'
    rm -f "$FAKE/info_fail"

    printf 'sha-%s\n' "$C1" >"$FAKE/up_fail_tags"
    run_update
    expect_status 4
    [ -e "$(state_file)" ] || fail_case 'отказ отката удалил файл состояния'
    rm -f "$FAKE/up_fail_tags"

    : >"$FAKE/calls.log"
    run_update
    expect_status 3
    expect_out_has "update: откат прерванного обновления $C2"
    [ "$(head_of)" = "$C1" ] || fail_case 'HEAD не прежний коммит'
    [ "$(env_key DOMOVOY_IMAGE_TAG)" = "sha-$C1" ] || fail_case 'тег не прежний'
    [ "$(ls "$BACKUPS" | wc -l)" = "$backups_before" ] || fail_case 'новый бэкап при откате'
    grep -q '^backup' "$FAKE/calls.log" && fail_case 'бэкап вызван при откате'
    grep -E "$GIT_CO" "$FAKE/calls.log" | grep -qvF "$C1" && fail_case 'checkout другой цели'
    expect_no_state
    expect_no_leak
    end_case
else
    skip_case 'update_resumes_rollback_after_kill' 'только Linux: setsid и flock в Git Bash нет'
fi

# ------------------------------------------------------------------
# deploy/build-images.sh
# ------------------------------------------------------------------
make_build_fakes() {
    FAKE="$CASE/fake"
    mkdir -p "$FAKE/bin"
    : >"$FAKE/calls.log"
    cat >"$FAKE/bin/docker" <<'EOF'
#!/usr/bin/env bash
F="$FAKE_DIR"
printf 'docker %s\n' "$*" >>"$F/calls.log"
if [ "${1-}" = save ]; then
    out="$3"
    image="$4"
    t="$(mktemp -d)"
    mkdir -p "$t/layer"
    case "$image" in
        *domovoy-migrate*) mkdir -p "$t/layer/migrations"; echo 'SELECT 1;' >"$t/layer/migrations/migrate.sql" ;;
        *) mkdir -p "$t/layer/app"; echo 'example' >"$t/layer/app/Domovoy.Api.dll" ;;
    esac
    mkdir -p "$t/archive/blobs"
    tar -cf "$t/archive/blobs/layer.tar" -C "$t/layer" .
    printf '{"rootfs":{"type":"layers"},"config":{}}' >"$t/archive/blobs/config.json"
    tar -cf "$out" -C "$t/archive" .
    rm -rf "$t"
fi
exit 0
EOF
    cat >"$FAKE/bin/gitleaks" <<'EOF'
#!/usr/bin/env bash
F="$FAKE_DIR"
dir="$2"
files="$(find "$dir" -type f | wc -l | tr -d ' ')"
printf 'gitleaks %s files=%s\n' "$1" "$files" >>"$F/calls.log"
n=$(( $(cat "$F/gl.count" 2>/dev/null || echo 0) + 1 ))
printf '%s' "$n" >"$F/gl.count"
if [ -f "$F/gl_fail_on" ] && [ "$(cat "$F/gl_fail_on")" = "$n" ]; then
    echo 'leak found' >&2
    exit 1
fi
exit 0
EOF
    chmod +x "$FAKE/bin/docker" "$FAKE/bin/gitleaks"
}

run_build() {
    PATH="$FAKE/bin:$PATH" FAKE_DIR="$FAKE" bash "$SCRIPT_DIR/build-images.sh" "$@" \
        </dev/null >"$CASE/out" 2>"$CASE/err"
    STATUS=$?
    OUT="$(cat "$CASE/out")"
    ERR="$(cat "$CASE/err")"
}

BSHA="$(printf '%040d' 0 | tr 0 a)"

begin_case 'build_images_scans_before_push (находка на втором образе)'
make_build_fakes
printf '2' >"$FAKE/gl_fail_on"
run_build --repo example.invalid/owner --sha "$BSHA" --push
expect_status 1
grep -q '^docker push' "$FAKE/calls.log" && fail_case 'push после находки'
[ "$(grep -c '^gitleaks dir' "$FAKE/calls.log")" = 2 ] || fail_case 'gitleaks не вызван дважды'
grep -q '^gitleaks dir files=0' "$FAKE/calls.log" && fail_case 'gitleaks вызван с пустым каталогом'
end_case

begin_case 'build_images_scans_before_push (чистый скан)'
make_build_fakes
run_build --repo example.invalid/owner --sha "$BSHA" --push
expect_status 0
pushes="$(grep '^docker push' "$FAKE/calls.log" | sort)"
want="$(printf 'docker push example.invalid/owner/domovoy-api:sha-%s\ndocker push example.invalid/owner/domovoy-migrate:sha-%s' "$BSHA" "$BSHA" | sort)"
[ "$pushes" = "$want" ] || fail_case 'push не ровно два sha-тега'
last_scan="$(grep -n '^gitleaks dir' "$FAKE/calls.log" | tail -n 1 | cut -d: -f1)"
first_push="$(grep -n '^docker push' "$FAKE/calls.log" | head -n 1 | cut -d: -f1)"
[ -n "$last_scan" ] && [ -n "$first_push" ] && [ "$last_scan" -lt "$first_push" ] || fail_case 'push раньше второго скана'
grep -q '^gitleaks dir files=0' "$FAKE/calls.log" && fail_case 'gitleaks вызван с пустым каталогом'
grep -q ':main' "$FAKE/calls.log" && fail_case 'тег main без --also-tag'
grep -E '^docker build ' "$FAKE/calls.log" | grep -qF -- '--target runtime' || fail_case 'нет build --target runtime'
grep -E '^docker build ' "$FAKE/calls.log" | grep -qF -- '--target migrate' || fail_case 'нет build --target migrate'
[ "$(grep -E '^docker build ' "$FAKE/calls.log" | grep -cF -- "org.opencontainers.image.revision=$BSHA")" = 2 ] \
    || fail_case 'метка revision не у обоих образов'
end_case

begin_case 'build_images_scans_before_push (--also-tag main)'
make_build_fakes
run_build --repo example.invalid/owner --sha "$BSHA" --push --also-tag main
expect_status 0
grep -qxF 'docker push example.invalid/owner/domovoy-api:main' "$FAKE/calls.log" || fail_case 'нет push api:main'
grep -qxF 'docker push example.invalid/owner/domovoy-migrate:main' "$FAKE/calls.log" || fail_case 'нет push migrate:main'
end_case

# ------------------------------------------------------------------
# Только Windows: deploy/windows/update.ps1
# ------------------------------------------------------------------
# Подделка wsl.exe — пакетный файл: --list отдаёт registered или running,
# прочие вызовы — код из d.code. Журнал — calls.log.
make_fake_wsl() {
    local dir="$1"
    mkdir -p "$dir"
    : >"$dir/calls.log"
    : >"$dir/registered"
    : >"$dir/running"
    printf '0' >"$dir/d.code"
    cat >"$dir/wsl.cmd" <<'EOF'
@echo off
echo %*>>"%~dp0calls.log"
if "%~1"=="--list" goto list
set /p code=<"%~dp0d.code"
exit /b %code%
:list
if "%~2"=="--running" (type "%~dp0running") else (type "%~dp0registered")
exit /b 0
EOF
    sed -i 's/$/\r/' "$dir/wsl.cmd"
}

run_ps1() {
    local shell="$1"
    shift
    # MSYS_NO_PATHCONV: иначе Git Bash перепишет -DeployDir /srv/… в путь Windows.
    MSYS_NO_PATHCONV=1 "$shell" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$(cygpath -w "$SCRIPT_DIR/windows/update.ps1")" \
        "$@" </dev/null >"$CASE/out" 2>"$CASE/err"
    STATUS=$?
    OUT="$(cat "$CASE/out")"
    ERR="$(cat "$CASE/err")"
}

# Номер первой строки журнала подделки с подстрокой.
wsl_line() { grep -nF -- "$2" "$1/calls.log" | head -n 1 | cut -d: -f1; }

if is_windows && command -v powershell.exe >/dev/null 2>&1 && command -v cygpath >/dev/null 2>&1; then
    begin_case 'update_ps1_refuses_stopped_engine'
    W="$CASE/wsl"
    for state in absent stopped nodir; do
        make_fake_wsl "$W"
        case "$state" in
            stopped) printf 'example-engine\r\n' >"$W/registered" ;;
            nodir)
                printf 'example-engine\r\n' >"$W/registered"
                printf 'example-engine\r\n' >"$W/running"
                printf '1' >"$W/d.code"
                ;;
        esac
        run_ps1 powershell.exe -WslExe "$(cygpath -w "$W/wsl.cmd")" -Distro example-engine -DeployDir /srv/example-deploy
        [ "$STATUS" -eq 1 ] || fail_case "$state: код $STATUS, ожидался 1"
        [ -n "$OUT$ERR" ] || fail_case "$state: нет текста причины"
        case "$state" in
            absent) grep -q 'не зарегистрирован' <<<"$OUT$ERR" || fail_case 'absent: причина не «не зарегистрирован»' ;;
            stopped) grep -q 'не работает' <<<"$OUT$ERR" || fail_case 'stopped: причина не «не работает»' ;;
            nodir) grep -qF '/srv/example-deploy' <<<"$OUT$ERR" || fail_case 'nodir: причина не называет каталог' ;;
        esac
        first_d="$(wsl_line "$W" '-d ')"
        running_line="$(wsl_line "$W" '--list --running')"
        if [ -n "$first_d" ]; then
            [ -n "$running_line" ] && [ "$running_line" -lt "$first_d" ] || fail_case "$state: вызов -d до --list --running"
        fi
        if [ "$state" != nodir ] && [ -n "$first_d" ]; then fail_case "$state: был вызов -d"; fi
        grep -qF 'update.sh' "$W/calls.log" && fail_case "$state: update.sh вызван"
    done
    end_case
else
    skip_case 'update_ps1_refuses_stopped_engine' 'только Windows: нужен powershell.exe'
fi

begin_case 'update.ps1: UTF-8 BOM, нет порта контейнера и localhost'
P="$SCRIPT_DIR/windows/update.ps1"
if [ -f "$P" ]; then
    [ "$(head -c 3 "$P" | od -An -tx1 | tr -d ' \n')" = 'efbbbf' ] || fail_case 'без BOM UTF-8'
    half=80
    grep -q "$half$half" "$P" && fail_case 'в update.ps1 порт контейнера'
    grep -qi 'localhost' "$P" && fail_case 'в update.ps1 localhost'
else
    fail_case 'нет deploy/windows/update.ps1'
fi
end_case

# ------------------------------------------------------------------
# README (зеленеет после среза docs)
# ------------------------------------------------------------------
begin_case 'readme_describes_update_and_move'
R="$REPO/README.md"
grep -qxF '### Обновление стека' "$R" || fail_case 'нет «### Обновление стека»'
grep -qxF '### Перенос стека в каталог развёртывания' "$R" || fail_case 'нет «### Перенос стека в каталог развёртывания»'
grep -qF 'deploy/windows/update.ps1' "$R" || fail_case 'нет deploy/windows/update.ps1'
grep -qF '/srv/domovoy' "$R" || fail_case 'нет /srv/domovoy'
grep -qF 'запасной путь' "$R" || fail_case 'нет «запасной путь»'
end_case

# ------------------------------------------------------------------
# Итог
# ------------------------------------------------------------------
printf '\n==================================================\n'
printf 'Сценариев пройдено: %s, провалено: %s, пропущено: %s\n' "$PASSED" "$FAILED" "$SKIPPED"
if [ "$FAILED" -ne 0 ]; then
    printf 'Провалились:\n'
    for name in "${FAILED_NAMES[@]}"; do
        printf '  - %s\n' "$name"
    done
    exit 1
fi
printf 'update.sh, build-images.sh и update.ps1 держат контракт.\n'
exit 0
