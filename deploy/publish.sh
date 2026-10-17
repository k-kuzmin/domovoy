#!/usr/bin/env bash
#
# Домовой — сборка, скан и публикация образов api и migrate (#162).
#
# ЗАЧЕМ
#
# Каталог развёртывания не собирает образ сам: он тянет готовые образы
# коммита из реестра. Образы собираются здесь — в workflow ci-publish.yml
# и на стенде агента, — и до любого push каждый проходит gitleaks по
# распакованным слоям: секрет, попавший в слой, не уходит в реестр.
#
# КАК ЗАПУСКАТЬ
#
#   bash deploy/publish.sh --repo <реестр>/<владелец> --sha <40 hex> \
#       [--push] [--also-tag <тег>] [--gitleaks-config <путь>]
#
# Собирает из корня клона, в котором лежит сценарий (каталог текущей
# оболочки не важен):
#   <repo>/domovoy-api:sha-<sha>      — docker build --target runtime
#   <repo>/domovoy-migrate:sha-<sha>  — docker build --target migrate
# с метками org.opencontainers.image.source и org.opencontainers.image.revision.
# --push пушит оба sha-тега; --also-tag <тег> (в workflow — main) ставит
# образам ещё и этот тег, а с --push пушит и его. Без --push тег ставится
# только локально. Правила gitleaks по умолчанию — .gitleaks.toml клона.
#
# Метка source: $GITHUB_SERVER_URL/$GITHUB_REPOSITORY, если обе переменные
# заданы (workflow); иначе адрес remote origin клона, приведённый к https
# для вида git@host:путь; remote нет — метка не ставится, строка в stderr.
#
# Коды возврата:
#   0 — образы собраны и чисты (и запушены, если просили);
#   1 — отказ по существу: нет docker или gitleaks в PATH, сборка, docker
#       save, распаковка слоя, находка gitleaks (код 1 до любого push), push;
#   2 — ошибка вызова; docker не вызывается.
#
# ШОВ ДЛЯ ТЕСТОВ
#
# docker и gitleaks берутся из PATH — deploy/update.test.sh подкладывает
# подделки. Формы вызовов, других нет:
#   docker build -f <корень>/src/Domovoy.Api/Dockerfile --target <runtime|migrate>
#          --label <ключ>=<значение>… -t <образ> <корень>
#   docker save -o <файл> <образ>   — должен записать tar-архив <файл>:
#          в нём хотя бы один слой (tar) с файлами под путём scan_paths
#          цели и JSON-файл с ключом "rootfs" (конфиг образа)
#   docker tag <образ> <образ с --also-tag>
#   docker push <образ>
#   gitleaks dir <каталог> --config <путь> --redact --no-banner --exit-code 1
# Порядок: build и скан api, build и скан migrate, затем tag и push.
#
# ЧТО СКАНИРУЕТСЯ
#
# Только то, что добавляет наш Dockerfile, — пути scan_paths ниже, — и JSON
# конфига образа из архива docker save (ENV, метки; узнаётся по ключу
# "rootfs", не найден — код 1). Базовые слои
# (aspnet, postgres-alpine) — закреплённые upstream-образы; правила проекта
# дают на их файлах ложные срабатывания (замер #162: dpkg, openssl.cnf,
# perl), поэтому их содержимое не сканируется.
#
# Архив docker save распаковывается; каждый файл в нём, который читается
# как tar (слой; сжатие tar определяет сам), даёт в свой каталог только
# члены под путями scan_paths — файл, удалённый верхним слоем, тоже
# сканируется. Fail closed: путь не найден ни в одном слое или под ним нет
# файлов — код 1.

# Пути, которые добавляет наш Dockerfile, по целям сборки: <цель>:<путь в
# образе без ведущего «/»>. Новая точка COPY в финальных стадиях
# src/Domovoy.Api/Dockerfile (runtime, migrate) добавляется сюда той же
# правкой — иначе её содержимое уйдёт в реестр без скана.
scan_paths='runtime:app migrate:migrations'

set -euo pipefail

say() { printf 'publish: %s\n' "$*"; }
fail() { printf 'publish: отказ: %s\n' "$*" >&2; exit 1; }
usage() {
  printf 'publish: %s\n' "$*" >&2
  printf 'использование: bash deploy/publish.sh --repo <реестр>/<владелец> --sha <40 hex> [--push] [--also-tag <тег>] [--gitleaks-config <путь>]\n' >&2
  exit 2
}

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

repo=''
sha=''
push=0
also_tag=''
gitleaks_config="$root/.gitleaks.toml"

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)            [ $# -ge 2 ] || usage "--repo без значения"; repo="$2"; shift 2 ;;
    --sha)             [ $# -ge 2 ] || usage "--sha без значения"; sha="$2"; shift 2 ;;
    --push)            push=1; shift ;;
    --also-tag)        [ $# -ge 2 ] || usage "--also-tag без значения"; also_tag="$2"; shift 2 ;;
    --gitleaks-config) [ $# -ge 2 ] || usage "--gitleaks-config без значения"; gitleaks_config="$2"; shift 2 ;;
    *)                 usage "неизвестный аргумент: $1" ;;
  esac
done

[ -n "$repo" ] || usage "нужен --repo"
[ -n "$sha" ] || usage "нужен --sha"
# Имя в реестре — нижний регистр (требование формата ссылки на образ).
[[ "$repo" =~ ^[a-z0-9]+([._-][a-z0-9]+)*(:[0-9]+)?(/[a-z0-9]+([._-][a-z0-9]+)*)+$ ]] \
  || usage "--repo не похож на <реестр>/<владелец> в нижнем регистре: $repo"
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || usage "--sha — 40 шестнадцатеричных символов в нижнем регистре"
if [ -n "$also_tag" ]; then
  [[ "$also_tag" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || usage "--also-tag — недопустимый тег: $also_tag"
fi
[ -f "$gitleaks_config" ] || usage "нет файла правил gitleaks: $gitleaks_config"

command -v docker >/dev/null 2>&1 || fail "docker не найден в PATH"
command -v gitleaks >/dev/null 2>&1 || fail "gitleaks не найден в PATH"

source_url=''
if [ -n "${GITHUB_SERVER_URL:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
  source_url="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY"
elif origin="$(git -C "$root" remote get-url origin 2>/dev/null)" && [ -n "$origin" ]; then
  case "$origin" in
    git@*:*) origin="${origin#git@}"; source_url="https://${origin%%:*}/${origin#*:}" ;;
    *)       source_url="$origin" ;;
  esac
  source_url="${source_url%.git}"
fi

labels=(--label "org.opencontainers.image.revision=$sha")
if [ -n "$source_url" ]; then
  labels+=(--label "org.opencontainers.image.source=$source_url")
else
  printf 'publish: remote origin не найден — метка org.opencontainers.image.source не ставится\n' >&2
fi

work="$(mktemp -d)"
trap 'chmod -R u+rwX "$work" 2>/dev/null || true; rm -rf "$work"' EXIT

api="$repo/domovoy-api:sha-$sha"
migrate="$repo/domovoy-migrate:sha-$sha"

# Сборка одного образа: build_image <target> <образ>.
build_image() {
  say "сборка $2 (--target $1)"
  docker build -f "$root/src/Domovoy.Api/Dockerfile" --target "$1" "${labels[@]}" -t "$2" "$root" \
    || fail "сборка $2 не удалась"
}

# Пути scan_paths цели: paths_for <цель> — по одному на строку.
paths_for() {
  local entry
  for entry in $scan_paths; do
    [ "${entry%%:*}" = "$1" ] && printf '%s\n' "${entry#*:}"
  done
  return 0
}

# Скан одного образа: scan_image <цель> <образ> <имя каталога>.
scan_image() {
  local target="$1" image="$2" dir="$work/$3" n=0 f p dest
  local -a paths
  mapfile -t paths < <(paths_for "$target")
  [ "${#paths[@]}" -gt 0 ] || fail "для цели $target нет путей в scan_paths"

  mkdir -p "$dir/archive" "$dir/scan"
  say "скан $image: ${paths[*]} и конфиг образа"
  docker save -o "$dir/image.tar" "$image" || fail "docker save $image не удался"
  tar -xf "$dir/image.tar" -C "$dir/archive" || fail "архив docker save $image не распаковывается"
  rm -f "$dir/image.tar"

  while IFS= read -r -d '' f; do
    if tar -tf "$f" > "$dir/members" 2>/dev/null; then
      n=$((n + 1))
      # Только члены под путями scan_paths (имена с «./» и без).
      : > "$dir/wanted"
      for p in "${paths[@]}"; do
        grep -E "^(\./)?${p}(/|$)" "$dir/members" >> "$dir/wanted" || true
      done
      if [ -s "$dir/wanted" ]; then
        dest="$dir/scan/layer-$n"
        mkdir -p "$dest"
        tar -xf "$f" -C "$dest" --no-same-owner --no-same-permissions \
            --no-recursion --verbatim-files-from -T "$dir/wanted" \
          || fail "слой $n образа $image не распаковывается — скан был бы неполным"
      fi
      rm -f "$f"
    fi
  done < <(find "$dir/archive" -type f -print0)
  rm -f "$dir/members" "$dir/wanted"
  [ "$n" -gt 0 ] || fail "в архиве $image не найдено ни одного слоя"

  # Fail closed: каждый путь цели найден и не пуст.
  for p in "${paths[@]}"; do
    if [ -z "$(find "$dir/scan" -path "$dir/scan/layer-*/$p/*" -type f -print -quit 2>/dev/null)" ]; then
      fail "в слоях $image нет файлов под /$p — скан был бы пустым"
    fi
  done

  # Из остатка архива сканируется только JSON конфига образа (ENV, метки,
  # история) — его отличает ключ "rootfs". index.json, manifest.json и
  # repositories несут лишь имя и тег, которые задаёт сам сценарий: тег
  # domovoy-api:sha-<40 hex> правило generic-api-key принимает за ключ
  # (замер #162).
  local configs=0
  mkdir -p "$dir/scan/image-config"
  while IFS= read -r -d '' f; do
    if grep -q '"rootfs"' "$f" 2>/dev/null; then
      configs=$((configs + 1))
      cp "$f" "$dir/scan/image-config/config-$configs.json"
    fi
  done < <(find "$dir/archive" -type f -print0)
  [ "$configs" -gt 0 ] || fail "в архиве $image не найден JSON конфига образа"
  rm -rf "$dir/archive"
  chmod -R u+rwX "$dir/scan" 2>/dev/null || true

  local rc=0
  gitleaks dir "$dir/scan" --config "$gitleaks_config" --redact --no-banner --exit-code 1 || rc=$?
  [ "$rc" -eq 0 ] || fail "gitleaks: код $rc по образу $image — push не выполняется"
  say "чисто: $image (слоёв в архиве: $n)"
  rm -rf "$dir"
}

build_image runtime "$api"
scan_image runtime "$api" api
build_image migrate "$migrate"
scan_image migrate "$migrate" migrate

images=("$migrate" "$api")
extra=()
if [ -n "$also_tag" ]; then
  for image in "${images[@]}"; do
    docker tag "$image" "${image%:*}:$also_tag" || fail "docker tag ${image%:*}:$also_tag не удался"
    extra+=("${image%:*}:$also_tag")
  done
fi

if [ "$push" -eq 1 ]; then
  for image in "${images[@]}" "${extra[@]+"${extra[@]}"}"; do
    say "push $image"
    docker push "$image" || fail "push $image не удался"
  done
fi

say "готово: $api, $migrate"
