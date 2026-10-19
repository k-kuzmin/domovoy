#!/usr/bin/env bash
#
# Домовой — одноразовый стенд агента в движке domovoy-engine (#164).
#
#   bash scripts/stand.sh up     [--name <N>]
#   bash scripts/stand.sh status [--name <N>]
#   bash scripts/stand.sh logs   [--name <N>] [--] [аргументы compose logs]
#   bash scripts/stand.sh down   [--name <N>]
#   bash scripts/stand.sh probe  [--name <N>] <ресурс>
#
# ЧТО ЭТО
#
# Полный стек — api, postgres и Home Assistant с вымышленными устройствами
# demo — рядом с боевым, не задевая его. N — целое 1…999; без --name берётся
# из имени каталога worktree .claude/worktrees/<N>. Проект compose —
# domovoy-stand-<N>, порты на хосте — 19000+N (api) и 9000+N (HA).
#
# Каталог стенда — ~/domovoy-stand/<N> пользователя дистрибутива, внутри его
# файловой системы. Compose запускается с --project-directory на него и
# двумя файлами: docker-compose.yml из worktree и
# deploy/stand/docker-compose.stand.yml (контекст сборки api — worktree).
# env_file: .env и ./config считаются от каталога стенда, поэтому .env и
# config/ владельца стенду недостижимы при любом каталоге запуска. .env
# стенда собирается только из .env.example, config/ — из config/*.example.*.
#
# up: проверки отказа до первого изменения, среди них — стенд с этим N уже
# поднят или поднимается (свой каталог с меткой) и порты → захват каталога
# стенда одним mkdir с меткой (каталог появился в другой сессии — тот же
# отказ, без сноса) → postgres и HA → затравка
# configuration.yaml HA до его первого старта → онбординг и переименование
# сущностей demo в id реестра-примера (deploy/stand/ha-onboard.py внутри
# контейнера HA) → долгоживущий токен HA в .env стенда, без вывода → сборка
# api своим строителем стенда (buildx, драйвер docker-container) → compose
# up --no-build → /health. Неудача после первого изменения сносит стенд
# тем же путём, что down: частичного стенда не остаётся.
#
# down удаляет только то, что принадлежит стенду по имени или по записи:
# compose down -v --rmi local --remove-orphans проекта стенда (образ api
# без своего тега, тома и сеть проекта), buildx rm строителя стенда без
# --keep-state (контейнер и том состояния с кэшем сборки), базовые образы,
# которые вытянул сам стенд, — по ID из pulled-images каталога стенда, без -f
# и только если их не держит ни один контейнер. Пока жив соседний стенд
# (каталог ~/domovoy-stand/<M> с меткой), такой образ не удаляется, а его ID
# дописывается в pulled-images соседа: образ удаляет последний снесённый
# стенд. Предел: down перечисляет соседей один раз; стенд, захвативший
# каталог позже и заставший образ, его не записал — образ останется в
# движке лишним (утечка, а не потеря: недостающее вытягивают compose и
# buildx). Так же и при одновременном down двух стендов: каждый видит
# другого соседом и передаёт ему запись, оба удаляют свои каталоги —
# запись теряется, образ остаётся. Остаток виден по image ls движка. Общий кэш движка, образы
# боевого стека и чужие объекты не трогаются: prune здесь нет. Каталог
# стенда без метки .domovoy-stand, которую up пишет первой записью, не трогает
# ни одна подкоманда: отказ.
#
# probe — имя, порт и метка временного контейнера пробы вне стенда
# (реестр, postgres): три строки STAND_PROBE_NAME=domovoy-probe-<N>-<ресурс>,
# STAND_PROBE_PORT — первый свободный из 20000+10·N…+9, STAND_PROBE_LABEL —
# метка, по которой down удаляет контейнеры проб с томами (rm -f -v) до
# сноса стенда. Ресурс — [a-z][a-z0-9-]{0,15}. probe ничего не меняет и не
# требует поднятого стенда. Предел: порт не резервируется — два probe подряд
# до запуска первого контейнера вернут один порт; контейнер пробы
# запускается сразу после probe, следующий probe — после его запуска.
#
# Порт занят, если его слушает процесс в дистрибутиве (ss) или на хосте
# (netstat) или он внутри исключённого диапазона Windows (netsh.exe
# excludedportrange). Предел: исключения динамические, и между проверкой и
# bind порт может в них попасть — проброс падает, up сносится через fail_up,
# повтор probe берёт следующий порт десятка.
#
# Коды: 0 — успех; 1 — отказ по существу, первая строка stderr начинается
# с «stand: отказ: »; 2 — ошибка вызова. Стенда нет (нет каталога стенда):
# status печатает «стенд domovoy-stand-<N> не поднят» и выходит с 0 — это
# ответ о состоянии; logs отказывает с 1 — логов нет. Compose не вызывается.
#
# Весь docker идёт в движок через функцию engine(): Docker Desktop не
# запускается никогда. DOMOVOY_ENGINE_DISTRO — другое имя дистрибутива, как
# в deploy/windows/docker-wsl.sh. Токен HA и секреты .env стенда не выводятся
# ни одной подкомандой: токен ходит только через stdin.

set -uo pipefail

# Git Bash переписывает аргументы вида /tmp/… в пути Windows раньше, чем их
# увидит wsl.exe; движок должен получить их как есть.
export MSYS_NO_PATHCONV=1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PROD_PROJECT='domovoy'
# Тег закреплён: строитель стенда воспроизводим. Совпадает со встроенным
# buildkit движка на момент #164.
BUILDKIT_IMAGE='moby/buildkit:v0.34.0'

distro="${DOMOVOY_ENGINE_DISTRO:-domovoy-engine}"
source_lx=''

usage() {
    [ $# -gt 0 ] && printf 'stand: %s\n' "$1" >&2
    printf 'использование: bash scripts/stand.sh up|down|status|logs [--name <N>] [--] [аргументы logs]\n' >&2
    printf '               bash scripts/stand.sh probe [--name <N>] <ресурс>\n' >&2
    exit 2
}

refuse() {
    printf 'stand: отказ: %s\n' "$1" >&2
    exit 1
}

say() {
    printf 'stand: %s\n' "$*"
}

# --- Разбор аргументов -------------------------------------------------------

[ $# -ge 1 ] || usage
cmd="$1"
shift
case "$cmd" in
    up|down|status|logs|probe) ;;
    *) usage "неизвестная подкоманда: $cmd" ;;
esac

name=''
extra=()
resource=''
have_resource=0
while [ $# -gt 0 ]; do
    case "$1" in
        --name)
            [ $# -ge 2 ] || usage '--name без значения'
            name="$2"
            shift 2
            ;;
        --name=*)
            name="${1#--name=}"
            shift
            ;;
        --)
            shift
            extra=("$@")
            break
            ;;
        *)
            if [ "$cmd" = probe ] && [ "$have_resource" -eq 0 ]; then
                resource="$1"
                have_resource=1
            else
                [ "$cmd" = logs ] || usage "неизвестный аргумент: $1"
                extra+=("$1")
            fi
            shift
            ;;
    esac
done

if [ "$cmd" = probe ]; then
    [ "$have_resource" -eq 1 ] || usage 'probe без ресурса'
    [[ "$resource" =~ ^[a-z][a-z0-9-]{0,15}$ ]] \
        || usage "ресурс пробы — [a-z][a-z0-9-]{0,15}, получено «$resource»"
fi

if [ -z "$name" ]; then
    case "$SOURCE_DIR" in
        */.claude/worktrees/*) name="${SOURCE_DIR##*/}" ;;
        *) refuse "не задан --name, а каталог $SOURCE_DIR — не .claude/worktrees/<N>" ;;
    esac
    [[ "$name" =~ ^[0-9]+$ ]] \
        || refuse "имя каталога worktree «$name» — не номер; задайте --name <N>"
fi

# Боевой проект — первым, до проверки формы: down --name domovoy снёс бы его.
[ "$name" = "$PROD_PROJECT" ] && refuse "$PROD_PROJECT — имя боевого проекта"
[[ "$name" =~ ^[1-9][0-9]{0,2}$ ]] || usage "N — целое 1…999, получено «$name»"

N="$name"
project="domovoy-stand-$N"
[ "$project" = "$PROD_PROJECT" ] && refuse "$PROD_PROJECT — имя боевого проекта"
# Нечисловой хвост: узел buildx называется <строитель>0, и без хвоста узел
# стенда 16 (domovoy-stand-160) совпал бы с именем стенда 160.
builder="$project-build"
api_port=$((19000 + N))
ha_port=$((9000 + N))
# Пробы вне стенда: десяток портов 20000+10·N…+9 (20010–29999 не задевает
# порты стендов и боевые) и метка, которую down сравнивает целиком. Ключ —
# не «domovoy», точка и слово: такую форму gitleaks принимает за домен.
probe_label="domovoy-stand.probe=$N"
probe_first=$((20000 + 10 * N))
probe_last=$((probe_first + 9))

# --- Движок ------------------------------------------------------------------

# Единственная дорога к docker. DOMOVOY_STAND_SOURCE читает
# deploy/stand/docker-compose.stand.yml; переменная уходит окружением
# процесса, а не в .env стенда.
engine() { wsl.exe -d "$distro" --exec env "DOMOVOY_STAND_SOURCE=$source_lx" docker "$@"; }

# Команда оболочки внутри дистрибутива: script и позиционные аргументы.
in_distro() {
    local script="$1"
    shift
    wsl.exe -d "$distro" --exec sh -c "$script" sh "$@"
}

stand_compose() {
    engine compose -p "$project" --project-directory "$standdir" \
        -f "$source_lx/docker-compose.yml" \
        -f "$source_lx/deploy/stand/docker-compose.stand.yml" \
        --profile ha "$@"
}

engine_down_reason="движок $distro недоступен; Docker Desktop не запускать"
command -v wsl.exe >/dev/null 2>&1 || refuse "$engine_down_reason"
engine info --format '{{.ServerVersion}}' >/dev/null 2>&1 || refuse "$engine_down_reason"

# --- Каталоги ----------------------------------------------------------------

command -v cygpath >/dev/null 2>&1 || refuse 'нужен Git Bash (cygpath): stand.sh запускается с хоста Windows'
src_win="$(cygpath -w "$SOURCE_DIR")"
# cd, а не git -C: при MSYS_NO_PATHCONV=1 git.exe получил бы путь /d/… как есть.
main_tree="$(cd "$SOURCE_DIR" && git worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')"
[ -n "$main_tree" ] || refuse "не удалось прочитать основное дерево: git worktree list в $SOURCE_DIR"
main_win="$(cygpath -w "$main_tree")"

paths="$(in_distro 'printf "%s\n" "$HOME/domovoy-stand/$1"; wslpath -u "$2"; wslpath -u "$3"' \
    "$N" "$src_win" "$main_win")" || refuse "$engine_down_reason"
standdir="$(printf '%s\n' "$paths" | sed -n 1p)"
source_lx="$(printf '%s\n' "$paths" | sed -n 2p)"
main_lx="$(printf '%s\n' "$paths" | sed -n 3p)"
case "$standdir" in
    /*/domovoy-stand/"$N") ;;
    *) refuse "каталог стенда не разрешился: «$standdir»" ;;
esac
[ -n "$source_lx" ] && [ -n "$main_lx" ] || refuse 'пути worktree внутри дистрибутива не разрешились (wslpath)'

# Метка working_dir называет каталог, из которого боевой стек реально
# запущен, — без константы пути. Только чтение.
prod_dirs="$(engine ps -a --filter "label=com.docker.compose.project=$PROD_PROJECT" \
    --format '{{.Label "com.docker.compose.project.working_dir"}}')" \
    || refuse "$engine_down_reason"

while IFS= read -r wd; do
    [ -n "$wd" ] || continue
    wd="${wd%/}"
    case "$standdir" in
        "$wd"|"$wd"/*) refuse "каталог проекта — каталог боевого стека: $wd" ;;
    esac
    [ "$source_lx" = "$wd" ] && refuse "каталог проекта — каталог боевого стека: $wd"
done <<< "$(printf '%s\n' "$prod_dirs" | sort -u)"
# Основное дерево — клон разработки, а не каталог боевого стека (тот после
# #162 в /srv/domovoy и узнаётся по метке выше); стенд из него не
# запускается (.claude/CLAUDE.md, «Первые ходы»): только из worktree задачи.
[ "$source_lx" = "${main_lx%/}" ] \
    && refuse "каталог проекта — основное дерево (клон разработки); стенд запускается из worktree задачи: $main_lx"

# Метка working_dir есть, только пока у боевого проекта есть контейнеры
# (ps -a видит и остановленные). Не зависит от них принадлежность самого
# каталога стенда: up пишет метку первой записью, и каталог без неё ни одна
# подкоманда не трогает — ни .env в него, ни rm -rf, ни compose с ним.
# Каталога нет — status и logs отвечают без compose: compose без .env стенда
# засыпал бы вывод предупреждениями о незаданных переменных.
STAND_MARK='.domovoy-stand'
owner="$(in_distro 'if [ ! -e "$1" ]; then echo absent; elif [ -f "$1/$2" ]; then echo own; else echo foreign; fi' \
    "$standdir" "$STAND_MARK")" || refuse "$engine_down_reason"
[ "$owner" = foreign ] \
    && refuse "каталог $standdir существует, но не принадлежит стенду: нет метки $STAND_MARK"
# Свой каталог с меткой при up — стенд с этим N уже поднят или поднимается в
# другой сессии. Проверка до портов: иначе живой стенд отказывал бы текстом
# «порт занят», а не называл бы номер.
busy_reason="стенд $project уже поднят или поднимается в другой сессии: bash scripts/stand.sh down --name $N или другой --name"
[ "$cmd" = up ] && [ "$owner" = own ] && refuse "$busy_reason"
if [ "$owner" = absent ]; then
    case "$cmd" in
        status) say "стенд $project не поднят"; exit 0 ;;
        logs) refuse "стенд $project не поднят" ;;
    esac
fi

# id реестра-примера: их ждёт api стенда, в них переименовываются сущности demo.
mapfile -t wanted_ids < <(sed -nE \
    's/^[[:space:]]*-?[[:space:]]*(entity_id|script_id):[[:space:]]*([^[:space:]#]+).*/\2/p' \
    "$SOURCE_DIR/config/entities.example.yaml" | tr -d '\r')

# --- Подкоманды --------------------------------------------------------------

port_busy() {
    local port="$1" listeners
    listeners="$(in_distro 'ss -ltnH' 2>/dev/null)" || true
    if printf '%s\n' "$listeners" | awk -v p=":$port" '{ if (substr($4, length($4) - length(p) + 1) == p) f = 1 } END { exit !f }'; then
        return 0
    fi
    if command -v netstat >/dev/null 2>&1; then
        netstat -ano 2>/dev/null | tr -d '\r' \
            | awk -v p=":$port" '$1 ~ /^TCP/ { if (substr($2, length($2) - length(p) + 1) == p) f = 1 } END { exit !f }' \
            && return 0
    fi
    # Исключённые диапазоны Windows (Hyper-V, WSL): слушателя там нет, а
    # проброс порта на хосте падает. Строки из двух чисел — «начало конец»
    # включительно; шапка на языке системы и подвал отсеиваются сами.
    if command -v netsh.exe >/dev/null 2>&1; then
        netsh.exe int ipv4 show excludedportrange protocol=tcp 2>/dev/null | tr -d '\r*' \
            | awk -v p="$port" 'NF == 2 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ { if ($1 + 0 <= p + 0 && p + 0 <= $2 + 0) f = 1 } END { exit !f }' \
            && return 0
    fi
    return 1
}

base_images() {
    sed -nE "s/^[[:space:]]*image:[[:space:]]*['\"]?([^'\"[:space:]#]+).*/\1/p" \
        "$SOURCE_DIR/docker-compose.yml" | tr -d '\r'
    printf '%s\n' "$BUILDKIT_IMAGE"
}

# Базовые образы, которых не было до up: их ID после появления — метка на
# объект, вытянутый самим стендом. down удаляет только записанные ID.
absent_images=()
record_pulled() {
    local ref id
    for ref in "${absent_images[@]}"; do
        id="$(engine image inspect -f '{{.Id}}' "$ref" 2>/dev/null)" || continue
        [ -n "$id" ] || continue
        in_distro 'grep -qxF "$2" "$1" 2>/dev/null || printf "%s\n" "$2" >> "$1"' \
            "$standdir/pulled-images" "$id"
    done
}

do_down() {
    local rc=0 pulled id users neighbors m
    case "$standdir" in
        /*/domovoy-stand/[1-9]*) ;;
        *) refuse "каталог стенда не разрешился: «$standdir»" ;;
    esac
    # Каталог проекта нужен compose для разбора файлов; .env в нём, если есть.
    in_distro 'mkdir -p "$1"' "$standdir"
    stand_compose down -v --rmi local --remove-orphans || rc=1
    if engine buildx inspect "$builder" >/dev/null 2>&1; then
        engine buildx rm "$builder" || rc=1
    fi
    pulled="$(in_distro 'cat "$1" 2>/dev/null || true' "$standdir/pulled-images")"
    # Базовый образ, вытянутый стендом, удаляет последний снесённый стенд:
    # пока жив соседний (каталог с меткой), запись переходит к нему, а образ
    # остаётся — сосед, который ещё собирается, его не потеряет.
    neighbors="$(in_distro 'for d in "$1"/*; do m="${d##*/}"; [ "$m" = "$2" ] && continue; case "$m" in [1-9]|[1-9][0-9]|[1-9][0-9][0-9]) ;; *) continue ;; esac; [ -f "$d/$3" ] && printf "%s\n" "$m"; done; exit 0' \
        "${standdir%/*}" "$N" "$STAND_MARK")"
    for id in $pulled; do
        if [ -n "$neighbors" ]; then
            for m in $neighbors; do
                if in_distro 'grep -qxF "$2" "$1" 2>/dev/null || printf "%s\n" "$2" >> "$1"' \
                    "${standdir%/*}/$m/pulled-images" "$id"; then
                    say "образ $id передан стенду domovoy-stand-$m"
                else
                    say "образ $id не передан стенду domovoy-stand-$m: запись не дописана"
                    rc=1
                fi
            done
            continue
        fi
        users="$(engine ps -a -q --filter "ancestor=$id")"
        if [ -n "$users" ]; then
            say "оставлен образ $id: его использует контейнер вне стенда"
            continue
        fi
        engine image rm "$id" >/dev/null \
            || say "оставлен образ $id: удаление без -f не прошло (чужой тег или контейнер)"
    done
    in_distro 'rm -rf -- "$1"' "$standdir" || rc=1
    return "$rc"
}

fail_up() {
    printf 'stand: up не удался: %s; стенд сносится\n' "$1" >&2
    # Упавший шаг мог успеть вытянуть базовый образ: без записи до сноса
    # do_down о нём не узнает и оставит в движке.
    record_pulled
    do_down >&2
    exit 1
}

new_secret() {
    od -An -tx1 -N24 /dev/urandom | tr -d ' \n'
}

build_env() {
    local line pg admin profiles=0
    pg="$(new_secret)"
    admin="$(new_secret)"
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        case "$line" in
            COMPOSE_PROJECT_NAME=*) line="COMPOSE_PROJECT_NAME=$project" ;;
            API_HTTP_PORT=*) line="API_HTTP_PORT=$api_port" ;;
            HA_HTTP_PORT=*) line="HA_HTTP_PORT=$ha_port" ;;
            POSTGRES_PASSWORD=*) line="POSTGRES_PASSWORD=$pg" ;;
            AUTH_ADMIN_TOKEN=*) line="AUTH_ADMIN_TOKEN=$admin" ;;
            COMPOSE_PROFILES=*|'# COMPOSE_PROFILES='*)
                line='COMPOSE_PROFILES=ha'
                profiles=1
                ;;
        esac
        printf '%s\n' "$line"
    done < "$SOURCE_DIR/.env.example"
    [ "$profiles" -eq 1 ] || printf 'COMPOSE_PROFILES=ha\n'
}

cmd_up() {
    local port ref refs token code api_image claim
    for port in "$api_port" "$ha_port"; do
        port_busy "$port" && refuse "порт $port занят"
    done

    # --- Первое изменение: захват каталога стенда. ---
    # mkdir без -p — атомарный захват номера: из двух одновременных up каталог
    # создаёт один, второй получает taken. Родитель общий для всех стендов и
    # до первого up в дистрибутиве его нет — ему -p. Метка — тем же вызовом:
    # каталога без метки, созданного up, не бывает; не записалась — каталог
    # снимается, иначе down отказывал бы на нём как на чужом. umask 022:
    # config/ внутри читает непривилегированный пользователь контейнера api.
    say "проект $project, api :$api_port, HA :$ha_port, каталог $standdir"
    claim="$(in_distro 'umask 022; mkdir -p "${1%/*}" 2>/dev/null; if mkdir "$1" 2>/dev/null; then if { printf "%s\n" "$3" > "$1/$2"; } 2>/dev/null; then echo claimed; else rmdir "$1"; echo error; fi; elif [ -e "$1" ]; then echo taken; else echo error; fi' \
        "$standdir" "$STAND_MARK" "$project" 2>/dev/null)" || claim=''
    # Пустой ответ — вызов не прошёл целиком (движок пропал, wsl.exe вернул
    # ошибку): причина — движок, а не права на родителя. stderr вызова
    # глушится, чтобы строка отказа шла в stderr первой.
    case "$claim" in
        claimed) ;;
        taken) refuse "$busy_reason" ;;
        '') refuse "$engine_down_reason" ;;
        *) refuse "каталог стенда $standdir не создан: родитель ~/domovoy-stand недоступен или нет прав" ;;
    esac
    # Дальше refuse нет: каждый выход — через fail_up, который сносит каталог
    # вместе с меткой. Обрыв процесса оставляет каталог с меткой — его снимает
    # down, названный в отказе занятого номера.

    # Список — заранее, а не циклом read: wsl.exe читает stdin и съел бы
    # остаток списка после первого образа.
    mapfile -t refs < <(base_images)
    for ref in "${refs[@]}"; do
        [ -n "$ref" ] || continue
        engine image inspect -f '{{.Id}}' "$ref" >/dev/null 2>&1 < /dev/null || absent_images+=("$ref")
    done

    # config/ — копии примеров, секретов в них нет; читать их должен
    # непривилегированный пользователь контейнера api, поэтому umask 022.
    # .env — 077: его читает только compose. Метка уже записана захватом.
    in_distro 'umask 022; mkdir -p "$1/config" && for f in "$2"/config/*.example.*; do b="${f##*/}"; cp "$f" "$1/config/${b%%.example.*}.${b#*.example.}" || exit 1; done' \
        "$standdir" "$source_lx" || fail_up 'config/ стенда не скопирован'
    build_env | in_distro 'umask 077; cat > "$1"' "$standdir/.env" || fail_up '.env стенда не записан'

    stand_compose create homeassistant || fail_up 'контейнер HA не создан'
    stand_compose cp "$source_lx/deploy/stand/ha-configuration.yaml" homeassistant:/config/configuration.yaml \
        || fail_up 'затравка configuration.yaml HA не скопирована'
    stand_compose up -d --wait --no-build postgres homeassistant || fail_up 'postgres и HA не поднялись'
    record_pulled

    stand_compose cp "$source_lx/deploy/stand/ha-onboard.py" homeassistant:/tmp/ha-onboard.py \
        || fail_up 'ha-onboard.py не скопирован в HA'
    token="$(stand_compose exec -T homeassistant python3 /tmp/ha-onboard.py onboard "${wanted_ids[@]}")" \
        || fail_up 'онбординг HA не прошёл'
    [ -n "$token" ] || fail_up 'онбординг HA не вернул токен'
    printf '%s\n' "$token" | in_distro 'umask 077; IFS= read -r t; export t; awk '"'"'/^HA_TOKEN=/ { print "HA_TOKEN=" ENVIRON["t"]; next } { print }'"'"' "$1" > "$1.tmp" && mv "$1.tmp" "$1"' \
        "$standdir/.env" || fail_up 'токен HA не записан в .env стенда'
    token=''
    say 'токен HA получен и записан в .env стенда'

    engine buildx create --name "$builder" --driver docker-container \
        --driver-opt "image=$BUILDKIT_IMAGE" --bootstrap >/dev/null \
        || fail_up "строитель $builder не создан"
    record_pulled
    stand_compose build --builder "$builder" api || fail_up "сборка api строителем $builder"
    api_image="$(engine image ls --filter "reference=$project-api" -q)"
    [ -n "$api_image" ] \
        || fail_up "образ $project-api не попал в хранилище движка после сборки строителем $builder"
    say "образ $project-api в хранилище движка: $api_image"

    if ! stand_compose up -d --wait --no-build; then
        # Хвост лога api — до сноса, иначе причину не узнать. Токены api не
        # логирует (.claude/CLAUDE.md, «Безопасность», правило 3).
        stand_compose logs --no-color --tail 40 api >&2
        fail_up 'стек стенда не поднялся'
    fi

    # Без curl — строка, а не отказ: здоровье api уже подтвердил compose up
    # --wait по healthcheck, а снос поднятого стенда из-за инструмента хоста
    # отнял бы проверку целиком.
    if command -v curl >/dev/null 2>&1; then
        code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:$api_port/health")"
        [ "$code" = 200 ] || fail_up "/health стенда ответил $code"
        say "/health стенда: $code"
    else
        say '/health стенда: не проверен — нет curl'
    fi
    say "стенд поднят: api http://127.0.0.1:$api_port, HA http://127.0.0.1:$ha_port"
}

# Имя, порт и метка пробы. Ничего не создаёт и порт не резервирует.
cmd_probe() {
    local port
    for ((port = probe_first; port <= probe_last; port++)); do
        port_busy "$port" && continue
        printf 'STAND_PROBE_NAME=domovoy-probe-%s-%s\n' "$N" "$resource"
        printf 'STAND_PROBE_PORT=%s\n' "$port"
        printf 'STAND_PROBE_LABEL=%s\n' "$probe_label"
        return 0
    done
    refuse "порты проб $probe_first…$probe_last заняты"
}

# Контейнеры проб стенда — с анонимными томами. Только при down: неудача up
# через fail_up пробы не трогает.
remove_probes() {
    local out ids
    out="$(engine ps -a -q --filter "label=$probe_label")" || return 1
    [ -n "$out" ] || return 0
    mapfile -t ids <<< "$out"
    engine rm -f -v "${ids[@]}" >/dev/null
}

cmd_status() {
    local report code renamed missing
    say "проект $project, api :$api_port, HA :$ha_port"
    stand_compose ps -a --format '{{.Service}} {{.State}} {{.Health}}'
    # cp проходит и в остановленный контейнер, поэтому «запущен» — по ps.
    if [ -z "$(stand_compose ps --status running -q homeassistant 2>/dev/null)" ]; then
        say 'токен HA: не проверен — HA стенда не запущен'
        return 0
    fi
    if ! stand_compose cp "$source_lx/deploy/stand/ha-onboard.py" homeassistant:/tmp/ha-onboard.py >/dev/null 2>&1; then
        say 'токен HA: не проверен — ha-onboard.py не скопирован в HA стенда'
        return 0
    fi
    report="$(in_distro 'sed -n "s/^HA_TOKEN=//p" "$1"' "$standdir/.env" \
        | stand_compose exec -T homeassistant python3 /tmp/ha-onboard.py report "${wanted_ids[@]}")"
    code="$(printf '%s\n' "$report" | sed -n 's/^http //p')"
    renamed="$(printf '%s\n' "$report" | sed -n 's/^renamed //p')"
    missing="$(printf '%s\n' "$report" | sed -n 's/^missing //p')"
    if [ "$code" = 200 ]; then
        say "токен HA: принят (HTTP $code)"
    else
        say "токен HA: отклонён (HTTP ${code:-нет ответа})"
    fi
    say "переименовано сущностей demo: ${renamed:-0}"
    say "нет в HA стенда: ${missing:-—}"
}

case "$cmd" in
    up) cmd_up ;;
    down)
        rc=0
        remove_probes || rc=1
        do_down || rc=1
        [ "$rc" -eq 0 ] || { printf 'stand: down завершился с ошибками\n' >&2; exit 1; }
        say "стенд $project снесён"
        ;;
    status) cmd_status ;;
    logs) stand_compose logs "${extra[@]}" ;;
    probe) cmd_probe ;;
esac
