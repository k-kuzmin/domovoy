#!/usr/bin/env bash
#
# Домовой — проверочные сценарии deploy/envfile.sh (#162).
#
# ЗАЧЕМ
#
# deploy/update.sh досинхронизирует .env каталога развёртывания с
# .env.example нового коммита и пишет туда управляемые ключи образа;
# engine-setup.ps1 и install-schedule.ps1 читают настройки хоста через
# `get`. Ошибка здесь тихая: ключ, склеенный с последней строкой файла,
# сгенерированный секрет, напечатанный в лог обновления, или .env,
# потерявший права при перезаписи, не видны до первого отказа стека.
#
# НА ЧЁМ
#
# Только выдуманные файлы во временном каталоге и копия .env.example клона.
# Значения в них — метки вида VAL_…; ни одно значение не печатается и в
# выводе тестов: провал называет сценарий и ожидание, а не содержимое.
#
# КАК ЗАПУСКАТЬ
#
#   bash deploy/envfile.test.sh
#
# Код возврата: 0 — все сценарии прошли, 1 — есть провалившиеся,
# 2 — запустить нечем.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET="$SCRIPT_DIR/envfile.sh"

for f in "$TARGET" "$REPO/.env.example" "$REPO/ops/backup/dotenv.sh"; do
    if [ ! -f "$f" ]; then
        printf 'Не найден %s\n' "$f" >&2
        exit 2
    fi
done

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

PASSED=0
FAILED=0
FAILED_NAMES=()

CASE_NAME=''
CASE_OK=1
OUT=''
ERR=''
STATUS=0
CASE_DIR=''
CASE_NO=0

begin_case() {
    CASE_NAME="$1"
    CASE_OK=1
    CASE_NO=$((CASE_NO + 1))
    CASE_DIR="$SANDBOX/case-$CASE_NO"
    mkdir -p "$CASE_DIR"
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

# run <аргументы envfile.sh> — вывод в OUT и ERR, код в STATUS.
run() {
    bash "$TARGET" "$@" >"$SANDBOX/out" 2>"$SANDBOX/err"
    STATUS=$?
    OUT="$(cat "$SANDBOX/out")"
    ERR="$(cat "$SANDBOX/err")"
}

expect_status() {
    [ "$STATUS" -eq "$1" ] || fail_case "код $STATUS, ожидался $1"
}

expect_out_line() {
    grep -qxF -- "$1" <<<"$OUT" || fail_case "в stdout нет строки «$1»"
}

expect_no_out_line() {
    if grep -qxF -- "$1" <<<"$OUT"; then
        fail_case "в stdout лишняя строка «$1»"
    fi
}

expect_out_empty() {
    [ -z "$OUT" ] || fail_case "stdout не пуст ($(printf '%s' "$OUT" | wc -l) строк)"
}

expect_err_nonempty() {
    [ -n "$ERR" ] || fail_case 'stderr пуст, ожидалась причина'
}

# expect_no_leak <файл-со-значениями> — ни одно значение из файла
# (часть после первого =) не встречается в stdout и stderr.
expect_no_leak() {
    local line value
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        case "$line" in
            '#'* | '') continue ;;
            *=*) value="${line#*=}" ;;
            *) continue ;;
        esac
        [ ${#value} -ge 6 ] || continue
        if grep -qF -- "$value" <<<"$OUT$ERR"; then
            fail_case "значение ключа ${line%%=*} попало в вывод"
        fi
    done <"$1"
}

# file_line_count <файл> <точная строка> — число строк, равных строке
# байт в байт, CR включительно. Не grep: grep Git for Windows снимает CR
# перед сравнением, и CRLF от LF им не отличить. Ожидаемая строка с CR
# передаётся переменной, а не $'…\r' внутри $(…): bash Git for Windows
# теряет такой CR при разборе подстановки команды.
file_line_count() {
    local line n=0
    while IFS= read -r line || [ -n "$line" ]; do
        [ "$line" = "$2" ] && n=$((n + 1))
    done <"$1"
    printf '%s' "$n"
}

file_sum() {
    cksum <"$1"
}

inode() {
    stat -c %i "$1"
}

cr_count() {
    tr -cd '\r' <"$1" | wc -c | tr -d ' '
}

has_cr() {
    [ "$(cr_count "$1")" -gt 0 ]
}

# every_line_crlf <файл> — каждая строка кончается CRLF, CR других нет, и
# файл кончается переводом строки.
every_line_crlf() {
    local line total=0 crlf=0
    while IFS= read -r line; do
        total=$((total + 1))
        case "$line" in *$'\r') crlf=$((crlf + 1)) ;; esac
    done <"$1"
    [ "$total" -gt 0 ] && [ "$total" = "$crlf" ] && [ "$(cr_count "$1")" = "$crlf" ] \
        && [ "$(tail -c 1 "$1" | od -An -tx1 | tr -d ' ')" = '0a' ]
}

# ------------------------------------------------------------------
# Общий выдуманный пример
# ------------------------------------------------------------------
EXAMPLE="$SANDBOX/example"
cat >"$EXAMPLE" <<'EOF'
# Выдуманный пример
KEEP=VAL_example_keep
PLAIN=VAL_plain_a b # хвост
# env-sync: generate
GEN=<placeholder-gen>
# env-sync: owner
OWN=<placeholder-own>
# env-sync: owner

NOTOWN=VAL_example_notown
# COMMENTED=VAL_commented
EOF

ENV_BASE="KEEP=VAL_env_keep_original
EXTRA=VAL_env_extra_secret
COMPOSE_FILE=VAL_env_compose_file
DOMOVOY_IMAGE_REPO=VAL_env_image_repo
DOMOVOY_IMAGE_TAG=VAL_env_image_tag"

new_env() {
    printf '%s\n' "$ENV_BASE" >"$CASE_DIR/.env"
}

# ------------------------------------------------------------------
# sync
# ------------------------------------------------------------------
begin_case 'sync: ключ без разметки дописывается строкой примера как есть'
new_env
run sync "$EXAMPLE" "$CASE_DIR/.env"
expect_status 0
expect_out_line 'добавлен PLAIN (из примера)'
[ "$(file_line_count "$CASE_DIR/.env" 'PLAIN=VAL_plain_a b # хвост')" = 1 ] \
    || fail_case 'строка PLAIN не дописана дословно'
expect_out_line 'добавлен NOTOWN (из примера)'
[ "$(file_line_count "$CASE_DIR/.env" 'NOTOWN=VAL_example_notown')" = 1 ] \
    || fail_case 'разметка через пустую строку не относится к ключу: NOTOWN должен дописаться из примера'
expect_no_out_line 'добавлен COMMENTED (из примера)'
grep -q '^COMMENTED=' "$CASE_DIR/.env" && fail_case 'закомментированный ключ примера дописан'
end_case

begin_case 'sync: существующие строки .env не меняются, ключи дописываются в конец'
new_env
run sync "$EXAMPLE" "$CASE_DIR/.env"
expect_status 0
[ "$(head -n 5 "$CASE_DIR/.env")" = "$ENV_BASE" ] || fail_case 'начало файла изменилось'
expect_no_out_line 'добавлен KEEP (из примера)'
[ "$(file_line_count "$CASE_DIR/.env" 'KEEP=VAL_env_keep_original')" = 1 ] || fail_case 'значение KEEP заменено'
end_case

begin_case 'sync: generate — 48 символов [A-Za-z0-9], значение не печатается'
new_env
run sync "$EXAMPLE" "$CASE_DIR/.env"
expect_status 0
expect_out_line 'добавлен GEN (сгенерирован)'
gen_lines="$(grep -c '^GEN=' "$CASE_DIR/.env")"
[ "$gen_lines" = 1 ] || fail_case "строк GEN= $gen_lines, ожидалась 1"
gen="$(sed -n 's/^GEN=//p' "$CASE_DIR/.env")"
[[ "$gen" =~ ^[A-Za-z0-9]{48}$ ]] || fail_case 'значение GEN не 48 символов [A-Za-z0-9]'
if [ -n "$gen" ] && grep -qF -- "$gen" <<<"$OUT$ERR"; then
    fail_case 'сгенерированное значение попало в вывод'
fi
expect_no_leak "$CASE_DIR/.env"
end_case

begin_case 'sync: повторный прогон ничего не дописывает и секрет не перегенерирует'
new_env
run sync "$EXAMPLE" "$CASE_DIR/.env"
before="$(file_sum "$CASE_DIR/.env")"
run sync "$EXAMPLE" "$CASE_DIR/.env"
expect_status 0
[ "$before" = "$(file_sum "$CASE_DIR/.env")" ] || fail_case 'файл изменился на повторном прогоне'
expect_no_out_line 'добавлен GEN (сгенерирован)'
expect_no_out_line 'добавлен PLAIN (из примера)'
expect_out_line 'заполните OWN'
end_case

begin_case 'sync: owner — не дописывается, строка «заполните KEY»'
new_env
run sync "$EXAMPLE" "$CASE_DIR/.env"
expect_status 0
expect_out_line 'заполните OWN'
grep -q '^OWN=' "$CASE_DIR/.env" && fail_case 'owner-ключ дописан'
expect_no_out_line 'добавлен OWN (из примера)'
end_case

begin_case 'sync: лишний ключ — строка отчёта, ключ не удаляется; управляемые не лишние'
new_env
run sync "$EXAMPLE" "$CASE_DIR/.env"
expect_status 0
expect_out_line 'лишний ключ EXTRA'
[ "$(file_line_count "$CASE_DIR/.env" 'EXTRA=VAL_env_extra_secret')" = 1 ] || fail_case 'лишний ключ удалён'
for k in COMPOSE_FILE DOMOVOY_IMAGE_REPO DOMOVOY_IMAGE_TAG; do
    expect_no_out_line "лишний ключ $k"
done
end_case

begin_case 'sync --dry-run: «будет » только у действий, файл не меняется'
new_env
before="$(file_sum "$CASE_DIR/.env")"
run sync --dry-run "$EXAMPLE" "$CASE_DIR/.env"
expect_status 0
[ "$before" = "$(file_sum "$CASE_DIR/.env")" ] || fail_case 'файл изменён в --dry-run'
expect_out_line 'будет добавлен PLAIN (из примера)'
expect_out_line 'будет добавлен GEN (сгенерирован)'
expect_out_line 'заполните OWN'
expect_out_line 'лишний ключ EXTRA'
expect_no_out_line 'будет заполните OWN'
expect_no_out_line 'будет лишний ключ EXTRA'
expect_no_out_line 'добавлен PLAIN (из примера)'
expect_no_leak "$EXAMPLE"
expect_no_leak "$CASE_DIR/.env"
end_case

begin_case 'sync: значения примера и .env не печатаются'
new_env
run sync "$EXAMPLE" "$CASE_DIR/.env"
expect_status 0
expect_no_leak "$EXAMPLE"
expect_no_leak "$CASE_DIR/.env"
end_case

begin_case 'sync: CRLF-файл дописывается тем же CRLF'
printf '%s\n' "$ENV_BASE" | sed 's/$/\r/' >"$CASE_DIR/.env"
run sync "$EXAMPLE" "$CASE_DIR/.env"
expect_status 0
every_line_crlf "$CASE_DIR/.env" || fail_case 'в файле появились строки без CRLF'
want=$'PLAIN=VAL_plain_a b # хвост\r'
[ "$(file_line_count "$CASE_DIR/.env" "$want")" = 1 ] || fail_case 'строка PLAIN не дописана с CRLF'
end_case

begin_case 'sync: LF-файл остаётся LF, CR примера не переносится'
sed 's/$/\r/' "$EXAMPLE" >"$CASE_DIR/example.crlf"
new_env
run sync "$CASE_DIR/example.crlf" "$CASE_DIR/.env"
expect_status 0
expect_out_line 'добавлен GEN (сгенерирован)'
expect_out_line 'заполните OWN'
has_cr "$CASE_DIR/.env" && fail_case 'в LF-файле появился CR'
[ "$(file_line_count "$CASE_DIR/.env" 'PLAIN=VAL_plain_a b # хвост')" = 1 ] || fail_case 'строка PLAIN из CRLF-примера не дописана'
end_case

begin_case 'sync: файл без перевода строки в конце — ключ не склеивается с последней строкой'
printf 'KEEP=VAL_env_keep_original' >"$CASE_DIR/.env"
run sync "$EXAMPLE" "$CASE_DIR/.env"
expect_status 0
[ "$(file_line_count "$CASE_DIR/.env" 'KEEP=VAL_env_keep_original')" = 1 ] || fail_case 'последняя строка склеена с дописанной'
[ "$(file_line_count "$CASE_DIR/.env" 'NOTOWN=VAL_example_notown')" = 1 ] || fail_case 'ключ NOTOWN не отдельной строкой'
end_case

begin_case 'sync: файл правится на месте — тот же inode и права'
new_env
chmod 600 "$CASE_DIR/.env"
mode_before="$(stat -c %a "$CASE_DIR/.env")"
ino_before="$(inode "$CASE_DIR/.env")"
run sync "$EXAMPLE" "$CASE_DIR/.env"
expect_status 0
[ "$ino_before" = "$(inode "$CASE_DIR/.env")" ] || fail_case 'inode сменился — файл пересоздан'
[ "$mode_before" = "$(stat -c %a "$CASE_DIR/.env")" ] || fail_case 'права файла изменились'
end_case

begin_case 'sync: нет .env или примера — код 1'
run sync "$EXAMPLE" "$CASE_DIR/missing.env"
expect_status 1
expect_err_nonempty
new_env
run sync "$CASE_DIR/missing.example" "$CASE_DIR/.env"
expect_status 1
expect_err_nonempty
end_case

begin_case 'sync: ошибка вызова — код 2'
run sync "$EXAMPLE"
expect_status 2
run sync --bogus "$EXAMPLE" "$CASE_DIR/.env"
expect_status 2
run sync "$EXAMPLE" "$CASE_DIR/.env" extra
expect_status 2
end_case

# ------------------------------------------------------------------
# Настоящий .env.example: разметка по контракту
# ------------------------------------------------------------------
begin_case '.env.example: generate над AUTH_ADMIN_TOKEN, owner над пятью ключами, блок развёртывания закомментирован'
: >"$CASE_DIR/.env"
run sync "$REPO/.env.example" "$CASE_DIR/.env"
expect_status 0
expect_out_line 'добавлен AUTH_ADMIN_TOKEN (сгенерирован)'
for k in POSTGRES_PASSWORD HA_TOKEN LLM_API_KEY NTFY_TOPIC BACKUP_DIR; do
    expect_out_line "заполните $k"
    grep -q "^$k=" "$CASE_DIR/.env" && fail_case "owner-ключ $k дописан"
done
expect_out_line 'добавлен COMPOSE_PROJECT_NAME (из примера)'
for k in COMPOSE_FILE DOMOVOY_IMAGE_REPO DOMOVOY_IMAGE_TAG; do
    grep -q "^$k=" "$REPO/.env.example" && fail_case "$k задан в .env.example без комментария"
    grep -q "^# $k=" "$REPO/.env.example" || fail_case "$k нет в закомментированном блоке развёртывания"
done
expect_no_leak "$REPO/.env.example"
end_case

begin_case '.env.example: .env, скопированный из примера, синхронизации не требует'
cp "$REPO/.env.example" "$CASE_DIR/.env"
run sync "$REPO/.env.example" "$CASE_DIR/.env"
expect_status 0
expect_out_empty
cmp -s "$REPO/.env.example" "$CASE_DIR/.env" || fail_case 'копия примера изменена'
end_case

# ------------------------------------------------------------------
# get
# ------------------------------------------------------------------
cat >"$SANDBOX/get.env" <<'EOF'
API_HTTP_PORT=18081
HA_HTTP_PORT="8124" # кавычки и хвост
COMPOSE_PROJECT_NAME=domovoy-x
COMPOSE_PROJECT_NAME=domovoy-last
BACKUP_DIR=<внешний-диск>/domovoy-backups
POSTGRES_PASSWORD=VAL_get_secret_pg
EOF

begin_case 'get: ключи белого списка — KEY=значение по правилам dotenv_value'
run get "$SANDBOX/get.env" API_HTTP_PORT HA_HTTP_PORT COMPOSE_PROJECT_NAME
expect_status 0
[ "$OUT" = $'API_HTTP_PORT=18081\nHA_HTTP_PORT=8124\nCOMPOSE_PROJECT_NAME=domovoy-last' ] \
    || fail_case 'вывод get не совпал с ожидаемым'
end_case

begin_case 'get: плейсхолдер <…> и отсутствующий ключ — пустое значение'
run get "$SANDBOX/get.env" BACKUP_DIR BACKUP_MAX_SIZE_GB DOMOVOY_IMAGE_TAG
expect_status 0
[ "$OUT" = $'BACKUP_DIR=\nBACKUP_MAX_SIZE_GB=\nDOMOVOY_IMAGE_TAG=' ] || fail_case 'плейсхолдер или пустой ключ не пусты'
end_case

begin_case 'get: ключ вне белого списка — код 2 без вывода, даже вместе с разрешёнными'
run get "$SANDBOX/get.env" POSTGRES_PASSWORD
expect_status 2
expect_out_empty
[ -z "$ERR" ] || fail_case 'stderr не пуст'
run get "$SANDBOX/get.env" API_HTTP_PORT POSTGRES_PASSWORD
expect_status 2
expect_out_empty
[ -z "$ERR" ] || fail_case 'stderr не пуст'
grep -qF VAL_get_secret_pg <<<"$OUT$ERR" && fail_case 'значение секрета попало в вывод'
end_case

begin_case 'get: работает из чужого каталога (dotenv.sh — от пути сценария)'
(cd "$SANDBOX" && bash "$TARGET" get "$SANDBOX/get.env" API_HTTP_PORT >"$SANDBOX/out" 2>"$SANDBOX/err")
STATUS=$?
OUT="$(cat "$SANDBOX/out")"
expect_status 0
expect_out_line 'API_HTTP_PORT=18081'
end_case

begin_case 'get: нет файла — код 1; нет ключей — код 2'
run get "$SANDBOX/missing.env" API_HTTP_PORT
expect_status 1
expect_out_empty
run get "$SANDBOX/get.env"
expect_status 2
end_case

# ------------------------------------------------------------------
# set / unset
# ------------------------------------------------------------------
begin_case 'set: управляемый ключ заменяется во всех строках, на месте'
printf 'KEEP=VAL_env_keep\nDOMOVOY_IMAGE_TAG=VAL_old_tag_one\nMID=VAL_mid\nDOMOVOY_IMAGE_TAG=VAL_old_tag_two\n' >"$CASE_DIR/.env"
chmod 600 "$CASE_DIR/.env"
ino_before="$(inode "$CASE_DIR/.env")"
mode_before="$(stat -c %a "$CASE_DIR/.env")"
run set "$CASE_DIR/.env" DOMOVOY_IMAGE_TAG VAL_new_tag_value
expect_status 0
expect_no_leak "$CASE_DIR/.env"
[ "$(cat "$CASE_DIR/.env")" = $'KEEP=VAL_env_keep\nDOMOVOY_IMAGE_TAG=VAL_new_tag_value\nMID=VAL_mid\nDOMOVOY_IMAGE_TAG=VAL_new_tag_value' ] \
    || fail_case 'set заменил не те строки'
[ "$ino_before" = "$(inode "$CASE_DIR/.env")" ] || fail_case 'inode сменился — файл пересоздан'
[ "$mode_before" = "$(stat -c %a "$CASE_DIR/.env")" ] || fail_case 'права файла изменились'
end_case

begin_case 'set: отсутствующий управляемый ключ дописывается тем же переводом строки'
printf 'KEEP=VAL_env_keep\r\n' >"$CASE_DIR/.env"
run set "$CASE_DIR/.env" COMPOSE_FILE VAL_compose_a:VAL_compose_b
expect_status 0
every_line_crlf "$CASE_DIR/.env" || fail_case 'перевод строки не CRLF'
want=$'COMPOSE_FILE=VAL_compose_a:VAL_compose_b\r'
[ "$(file_line_count "$CASE_DIR/.env" "$want")" = 1 ] || fail_case 'ключ не дописан'
printf 'KEEP=VAL_env_keep' >"$CASE_DIR/.env"
run set "$CASE_DIR/.env" DOMOVOY_IMAGE_REPO VAL_repo_value
expect_status 0
[ "$(cat "$CASE_DIR/.env")" = $'KEEP=VAL_env_keep\nDOMOVOY_IMAGE_REPO=VAL_repo_value' ] || fail_case 'ключ склеен с последней строкой'
end_case

begin_case 'set: CRLF-строка заменяется с CRLF'
printf 'A=VAL_a\r\nDOMOVOY_IMAGE_TAG=VAL_old_tag\r\nB=VAL_b\r\n' >"$CASE_DIR/.env"
run set "$CASE_DIR/.env" DOMOVOY_IMAGE_TAG VAL_new_tag
expect_status 0
every_line_crlf "$CASE_DIR/.env" || fail_case 'перевод строки не CRLF'
want=$'DOMOVOY_IMAGE_TAG=VAL_new_tag\r'
[ "$(file_line_count "$CASE_DIR/.env" "$want")" = 1 ] || fail_case 'строка не заменена'
end_case

begin_case 'set: неуправляемый ключ, перевод строки в значении, нехватка аргументов — код 2, файл не меняется'
new_env
before="$(file_sum "$CASE_DIR/.env")"
run set "$CASE_DIR/.env" EXTRA VAL_set_extra
expect_status 2
run set "$CASE_DIR/.env" DOMOVOY_IMAGE_TAG $'VAL_line1\nINJECTED=VAL_line2'
expect_status 2
run set "$CASE_DIR/.env" DOMOVOY_IMAGE_TAG
expect_status 2
[ "$before" = "$(file_sum "$CASE_DIR/.env")" ] || fail_case 'файл изменён отказавшим set'
expect_no_leak "$CASE_DIR/.env"
end_case

begin_case 'set: нет файла — код 1'
run set "$CASE_DIR/missing.env" DOMOVOY_IMAGE_TAG VAL_tag
expect_status 1
expect_err_nonempty
end_case

begin_case 'unset: строки управляемого ключа удаляются на месте, прочие остаются'
printf 'A=VAL_a\r\nCOMPOSE_FILE=VAL_c1\r\nB=VAL_b\r\nCOMPOSE_FILE=VAL_c2\r\n' >"$CASE_DIR/.env"
ino_before="$(inode "$CASE_DIR/.env")"
run unset "$CASE_DIR/.env" COMPOSE_FILE
expect_status 0
expect_out_empty
printf 'A=VAL_a\r\nB=VAL_b\r\n' >"$CASE_DIR/want"
cmp -s "$CASE_DIR/want" "$CASE_DIR/.env" || fail_case 'unset удалил не те строки'
[ "$ino_before" = "$(inode "$CASE_DIR/.env")" ] || fail_case 'inode сменился — файл пересоздан'
before="$(file_sum "$CASE_DIR/.env")"
run unset "$CASE_DIR/.env" COMPOSE_FILE
expect_status 0
[ "$before" = "$(file_sum "$CASE_DIR/.env")" ] || fail_case 'unset отсутствующего ключа изменил файл'
end_case

begin_case 'unset: неуправляемый ключ — код 2; нет файла — код 1'
new_env
before="$(file_sum "$CASE_DIR/.env")"
run unset "$CASE_DIR/.env" EXTRA
expect_status 2
[ "$before" = "$(file_sum "$CASE_DIR/.env")" ] || fail_case 'файл изменён отказавшим unset'
run unset "$CASE_DIR/missing.env" COMPOSE_FILE
expect_status 1
end_case

begin_case 'вызов без подкоманды или с неизвестной — код 2'
run
expect_status 2
expect_err_nonempty
run bogus
expect_status 2
expect_err_nonempty
end_case

# ------------------------------------------------------------------
# Итог
# ------------------------------------------------------------------
printf '\n==================================================\n'
printf 'Сценариев пройдено: %s, провалено: %s\n' "$PASSED" "$FAILED"
if [ "$FAILED" -ne 0 ]; then
    printf 'Провалились:\n'
    for name in "${FAILED_NAMES[@]}"; do
        printf '  - %s\n' "$name"
    done
    exit 1
fi

printf 'envfile.sh: sync, get, set и unset держат контракт и не печатают значений.\n'
exit 0
