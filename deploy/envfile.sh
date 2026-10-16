#!/usr/bin/env bash
#
# Домовой — синхронизация и точечная правка .env каталога развёртывания (#162).
#
# ЗАЧЕМ
#
# Новый коммит может принести в .env.example новый ключ. Обновление
# (deploy/update.sh) досинхронизирует .env каталога развёртывания сам:
# ключ без разметки дописывается значением примера, секрет генерируется,
# а то, что знает только владелец, называется строкой отчёта. Настройки
# хоста (порты, проект, каталог бэкапов) engine-setup.ps1 и
# install-schedule.ps1 читают отсюда же — `get`, а не своим разбором.
#
# КАК ЗАПУСКАТЬ
#
#   bash deploy/envfile.sh sync [--dry-run] <пример> <env>
#   bash deploy/envfile.sh get <env> KEY…
#   bash deploy/envfile.sh set <env> KEY VALUE
#   bash deploy/envfile.sh unset <env> KEY
#
# sync. Ключ примера — строка ^[A-Za-z_][A-Za-z0-9_]*=. Разметка — строка
# «# env-sync: generate» или «# env-sync: owner» непосредственно над ключом.
# Для каждого ключа примера, которого в <env> нет:
#   без разметки — строка примера дописывается как написана:
#                  «добавлен KEY (из примера)»;
#   generate     — KEY=<48 символов [A-Za-z0-9] из /dev/urandom>:
#                  «добавлен KEY (сгенерирован)»;
#   owner        — не дописывается: «заполните KEY».
# Ключ <env>, которого нет в примере, не удаляется: «лишний ключ KEY» —
# кроме управляемых COMPOSE_FILE, DOMOVOY_IMAGE_REPO, DOMOVOY_IMAGE_TAG.
# С --dry-run файл не меняется, а строки «добавлен …» идут с префиксом
# «будет »; «заполните KEY» и «лишний ключ KEY» — те же, что без него.
#
# get печатает KEY=значение только для ключей белого списка (ниже); ключ
# вне списка — код 2 без вывода (ни stdout, ни stderr). Значение разбирает dotenv_value
# из ops/backup/dotenv.sh; значение с плейсхолдером <…> — пустое,
# отсутствующий ключ — тоже.
#
# set и unset — только для управляемых ключей: set заменяет все строки
# ключа (или дописывает строку), unset удаляет их.
#
# Значения не печатаются никогда: ни в отчёте sync, ни в сообщениях об
# ошибке. Исключение — get по белому списку несекретных настроек.
#
# Файл правится на месте: дописывание — в конец (>>), замена — перезаписью
# того же файла, а не переименованием; права, владелец и inode остаются.
# Перевод строки дописанных строк — тот же, что в файле (LF или CRLF, по
# первой строке); файл без перевода строки в конце сначала его получает.
#
# Коды возврата:
#   0 — успех;
#   1 — файл не читается или не пишется;
#   2 — ошибка вызова (подкоманда, аргументы, ключ вне списка).
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MANAGED_KEYS=(COMPOSE_FILE DOMOVOY_IMAGE_REPO DOMOVOY_IMAGE_TAG)
GET_KEYS=(API_HTTP_PORT HA_HTTP_PORT COMPOSE_PROJECT_NAME BACKUP_DIR
    BACKUP_MAX_SIZE_GB COMPOSE_FILE DOMOVOY_IMAGE_REPO DOMOVOY_IMAGE_TAG)
KEY_LINE='^([A-Za-z_][A-Za-z0-9_]*)='
SECRET_LENGTH=48

usage_error() {
    printf 'envfile: %s\n' "$1" >&2
    exit 2
}

io_error() {
    printf 'envfile: %s\n' "$1" >&2
    exit 1
}

in_list() {
    local needle="$1" item
    shift
    for item in "$@"; do
        [ "$item" = "$needle" ] && return 0
    done
    return 1
}

is_managed() {
    in_list "$1" "${MANAGED_KEYS[@]}"
}

require_readable() {
    [ -f "$1" ] && [ -r "$1" ] || io_error "файл не читается: $1"
}

require_writable() {
    require_readable "$1"
    [ -w "$1" ] || io_error "файл не пишется: $1"
}

# file_eol <файл> — перевод строки файла по первой строке: CRLF или LF.
file_eol() {
    local first=''
    IFS= read -r first <"$1" || true
    case "$first" in
        *$'\r') printf '\r\n' ;;
        *) printf '\n' ;;
    esac
}

# lacks_final_newline <файл> — файл не пуст и не кончается переводом строки.
lacks_final_newline() {
    [ -s "$1" ] && [ -n "$(tail -c 1 "$1")" ]
}

# new_secret — SECRET_LENGTH символов [A-Za-z0-9] из /dev/urandom.
new_secret() {
    local secret='' chunk
    while [ "${#secret}" -lt "$SECRET_LENGTH" ]; do
        chunk="$(head -c 512 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9')" \
            || io_error 'не прочитан /dev/urandom'
        secret+="$chunk"
    done
    printf '%s' "${secret:0:$SECRET_LENGTH}"
}

# append_lines <файл> <строка>… — дописать строки в конец на месте,
# переводом строки файла.
append_lines() {
    local file="$1" eol payload='' line
    shift
    eol="$(file_eol "$file"; printf x)"
    eol="${eol%x}"
    lacks_final_newline "$file" && payload+="$eol"
    for line in "$@"; do
        payload+="$line$eol"
    done
    printf '%s' "$payload" >>"$file" || io_error "файл не пишется: $file"
}

cmd_sync() {
    local dry_run=0 positional=() arg
    for arg in "$@"; do
        case "$arg" in
            --dry-run) dry_run=1 ;;
            -*) usage_error "sync: неизвестный ключ $arg" ;;
            *) positional+=("$arg") ;;
        esac
    done
    [ "${#positional[@]}" -eq 2 ] || usage_error 'sync [--dry-run] <пример> <env>'
    local example="${positional[0]}" env="${positional[1]}"
    require_readable "$example"
    if [ "$dry_run" -eq 1 ]; then
        require_readable "$env"
    else
        require_writable "$env"
    fi

    local -A env_has=() example_has=()
    local env_order=() line key
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        [[ "$line" =~ $KEY_LINE ]] || continue
        key="${BASH_REMATCH[1]}"
        [ -n "${env_has[$key]+x}" ] && continue
        env_has[$key]=1
        env_order+=("$key")
    done <"$env"

    local prev='' report=() additions=() generated
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        if [[ "$line" =~ $KEY_LINE ]]; then
            key="${BASH_REMATCH[1]}"
            if [ -z "${example_has[$key]+x}" ]; then
                example_has[$key]=1
                if [ -z "${env_has[$key]+x}" ]; then
                    case "$prev" in
                        '# env-sync: generate')
                            report+=("добавлен $key (сгенерирован)")
                            if [ "$dry_run" -eq 0 ]; then
                                # Подоболочка: io_error внутри new_secret
                                # завершил бы только её — код проверяется здесь.
                                generated="$(new_secret)" \
                                    || io_error 'не прочитан /dev/urandom'
                                [ "${#generated}" -eq "$SECRET_LENGTH" ] \
                                    || io_error "секрет для $key не сгенерирован"
                                additions+=("$key=$generated")
                            fi
                            ;;
                        '# env-sync: owner')
                            report+=("заполните $key")
                            ;;
                        *)
                            report+=("добавлен $key (из примера)")
                            additions+=("$line")
                            ;;
                    esac
                fi
            fi
        fi
        prev="$line"
    done <"$example"

    for key in "${env_order[@]}"; do
        [ -n "${example_has[$key]+x}" ] && continue
        is_managed "$key" && continue
        report+=("лишний ключ $key")
    done

    if [ "$dry_run" -eq 0 ] && [ "${#additions[@]}" -gt 0 ]; then
        append_lines "$env" "${additions[@]}"
    fi

    # «будет » — только у действия (дописывания); «заполните» и «лишний
    # ключ» — не действия sync, а отчёт, одинаковый в обоих режимах.
    local prefix
    for line in "${report[@]}"; do
        prefix=''
        if [ "$dry_run" -eq 1 ]; then
            case "$line" in 'добавлен '*) prefix='будет ' ;; esac
        fi
        printf '%s%s\n' "$prefix" "$line"
    done
}

cmd_get() {
    [ "$#" -ge 2 ] || usage_error 'get <env> KEY…'
    local env="$1" key
    shift
    for key in "$@"; do
        # Вне списка — молча: контракт «код 2 без вывода», а вызывающий
        # (engine-setup.ps1 через wsl.exe) разбирает весь вывод.
        in_list "$key" "${GET_KEYS[@]}" || exit 2
    done
    require_readable "$env"
    # shellcheck source=ops/backup/dotenv.sh
    . "$SCRIPT_DIR/../ops/backup/dotenv.sh" || io_error 'не прочитан ops/backup/dotenv.sh'
    local value out=''
    for key in "$@"; do
        value="$(dotenv_value "$env" "$key")"
        case "$value" in
            *'<'*'>'*) value='' ;;
        esac
        out+="$key=$value"$'\n'
    done
    printf '%s' "$out"
}

# rewrite_key <env> <KEY> <set|unset> [VALUE] — заменить или удалить все
# строки ключа; set без строки ключа дописывает её. Пишет тот же файл.
rewrite_key() {
    local env="$1" key="$2" mode="$3" value="${4-}"
    local line content='' found=0 changed=0 terminated cr
    while true; do
        if IFS= read -r line; then
            terminated=1
        elif [ -n "$line" ]; then
            terminated=0
        else
            break
        fi
        cr=''
        case "$line" in *$'\r') cr=$'\r' ;; esac
        if [[ "${line%$'\r'}" == "$key="* ]]; then
            found=1
            changed=1
            if [ "$mode" = unset ]; then
                [ "$terminated" -eq 1 ] && continue
                break
            fi
            line="$key=$value$cr"
        fi
        content+="$line"
        [ "$terminated" -eq 1 ] && content+=$'\n'
        [ "$terminated" -eq 1 ] || break
    done <"$env"

    if [ "$mode" = set ] && [ "$found" -eq 0 ]; then
        append_lines "$env" "$key=$value"
        return
    fi
    if [ "$changed" -eq 1 ]; then
        printf '%s' "$content" >"$env" || io_error "файл не пишется: $env"
    fi
}

cmd_set() {
    [ "$#" -eq 3 ] || usage_error 'set <env> KEY VALUE'
    local env="$1" key="$2" value="$3"
    is_managed "$key" || usage_error "set: ключ $key не управляемый"
    case "$value" in
        *$'\n'* | *$'\r'*) usage_error "set: перевод строки в значении $key" ;;
    esac
    require_writable "$env"
    rewrite_key "$env" "$key" set "$value"
}

cmd_unset() {
    [ "$#" -eq 2 ] || usage_error 'unset <env> KEY'
    local env="$1" key="$2"
    is_managed "$key" || usage_error "unset: ключ $key не управляемый"
    require_writable "$env"
    rewrite_key "$env" "$key" unset
}

main() {
    [ "$#" -ge 1 ] || usage_error 'нет подкоманды: sync | get | set | unset'
    local sub="$1"
    shift
    case "$sub" in
        sync) cmd_sync "$@" ;;
        get) cmd_get "$@" ;;
        set) cmd_set "$@" ;;
        unset) cmd_unset "$@" ;;
        *) usage_error "неизвестная подкоманда: $sub" ;;
    esac
}

main "$@"
