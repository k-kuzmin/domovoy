#!/usr/bin/env bash
#
# Домовой — сверка правил шагов работы с промптами и указателем.
#
# ЗАЧЕМ
#
# Правила шагов живут в docs/rules/, промпты .github/workflows/agent-*.yml на
# них ссылаются, а .claude/CLAUDE.md держит указатель. Три места, и разъехаться
# они могут молча: файл переименовали — промпт ссылается в пустоту и агент
# работает без правил; файл добавили — указатель о нём не знает и локальная
# сессия его не откроет.
#
# Проверка механическая именно поэтому. Ссылка, которую никто не проверял, —
# это не источник правил, а надежда на него.
#
# ЧТО ПРОВЕРЯЕТСЯ
#
#   1. Каждая ссылка на docs/rules/*.md из промптов ведёт в существующий файл.
#   2. Каждый файл правил упомянут хотя бы одним промптом (README — указатель,
#      он исключён: на него ссылаются файлы правил, а не промпты).
#   3. Промпт шага ссылается на правила своего шага: agent-triage.yml — на
#      triage.md, agent-review.yml — на review-*.md. Соответствие выводится из
#      имён файлов, а не задано списком: список был бы копией, которая тоже
#      разъезжается.
#   4. Каждый файл правил указан в .claude/CLAUDE.md.
#   5. Относительные markdown-ссылки внутри docs/rules/*.md ведут в
#      существующие файлы.
#
# КАК ЗАПУСКАТЬ
#
#   bash scripts/rules-sync.sh              # корень репозитория
#   bash scripts/rules-sync.sh /путь/к/копии
#
# Код возврата: 0 — сходится, 1 — есть расхождения, 2 — ошибка запуска.
#
set -uo pipefail

ROOT="${1:-}"
if [ -z "$ROOT" ]; then
    ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fi

if [ ! -d "$ROOT" ]; then
    printf 'Не найден каталог: %s\n' "$ROOT" >&2
    exit 2
fi

cd "$ROOT" || exit 2

RULES_DIR='docs/rules'
POINTER='.claude/CLAUDE.md'

if [ ! -d "$RULES_DIR" ]; then
    printf 'Не найден каталог правил: %s/%s\n' "$ROOT" "$RULES_DIR" >&2
    exit 2
fi

VIOLATIONS=0

report() {
    # Формат GitHub Actions: сообщение попадает в аннотации к файлу.
    printf '::error file=%s::%s\n' "$1" "$2"
    VIOLATIONS=$((VIOLATIONS + 1))
}

note() {
    printf '  %s\n' "$1"
}

# Промпты шагов и файлы правил. Оба списка берутся из файловой системы:
# источник истины — то, что лежит в репозитории, а не перечисление в скрипте.
prompts=()
while IFS= read -r f; do
    [ -n "$f" ] && prompts+=("$f")
done < <(find .github/workflows -maxdepth 1 -name 'agent-*.yml' 2>/dev/null | sort)

rules=()
while IFS= read -r f; do
    [ -n "$f" ] && rules+=("$f")
done < <(find "$RULES_DIR" -maxdepth 1 -name '*.md' 2>/dev/null | sort)

if [ "${#prompts[@]}" -eq 0 ]; then
    printf 'Не найдено ни одного .github/workflows/agent-*.yml\n' >&2
    exit 2
fi

if [ "${#rules[@]}" -eq 0 ]; then
    printf 'Не найдено ни одного файла правил в %s\n' "$RULES_DIR" >&2
    exit 2
fi

printf 'Правила: %d файл(ов), промпты: %d\n\n' "${#rules[@]}" "${#prompts[@]}"

# ------------------------------------------------------------------
# Проверка 1. Ссылки из промптов ведут в существующие файлы.
# ------------------------------------------------------------------
for prompt in "${prompts[@]}"; do
    while IFS= read -r ref; do
        [ -z "$ref" ] && continue
        if [ ! -f "$ref" ]; then
            report "$prompt" "ссылка на несуществующие правила: $ref"
        fi
    done < <(grep -ohE 'docs/rules/[A-Za-z0-9._-]+\.md' "$prompt" | sort -u)
done

# ------------------------------------------------------------------
# Проверка 2. Каждый файл правил упомянут хотя бы одним промптом.
#
# README исключён намеренно: это указатель, и ссылаются на него файлы
# правил. Промпт ревью на него ссылается, но требовать этого от всех —
# значит требовать лишнего чтения на каждом шаге.
# ------------------------------------------------------------------
for rule in "${rules[@]}"; do
    base="$(basename "$rule")"
    [ "$base" = 'README.md' ] && continue
    if ! grep -qF "$rule" "${prompts[@]}"; then
        report "$rule" "файл правил не упомянут ни одним промптом agent-*.yml"
    fi
done

# ------------------------------------------------------------------
# Проверка 3. Промпт шага ссылается на правила своего шага.
#
# Шаг берётся из имени файла: agent-<шаг>.yml. Правила шага — файл, чьё
# имя начинается с того же слова: review → review-correctness.md и
# review-security.md. Так соответствие выводится из имён, а не задано
# списком, который сам разъезжается.
# ------------------------------------------------------------------
for prompt in "${prompts[@]}"; do
    step="$(basename "$prompt" .yml)"
    step="${step#agent-}"

    expected=()
    for rule in "${rules[@]}"; do
        base="$(basename "$rule" .md)"
        if [ "$base" = "$step" ] || [ "${base#"$step"-}" != "$base" ]; then
            expected+=("$rule")
        fi
    done

    if [ "${#expected[@]}" -eq 0 ]; then
        report "$prompt" "у шага «$step» нет файла правил в $RULES_DIR"
        continue
    fi

    for rule in "${expected[@]}"; do
        if ! grep -qF "$rule" "$prompt"; then
            report "$prompt" "промпт шага «$step» не ссылается на свои правила: $rule"
        fi
    done
done

# ------------------------------------------------------------------
# Проверка 4. Каждый файл правил указан в .claude/CLAUDE.md.
#
# Указатель — единственное, что читает локальная сессия, не заходя в
# .github/**. Файл правил, которого в нём нет, для живого режима не
# существует.
# ------------------------------------------------------------------
if [ ! -f "$POINTER" ]; then
    report "$POINTER" "не найден указатель на правила"
else
    for rule in "${rules[@]}"; do
        [ "$(basename "$rule")" = 'README.md' ] && continue
        if ! grep -qF "$rule" "$POINTER"; then
            report "$POINTER" "правила не указаны в файле правил проекта: $rule"
        fi
    done
fi

# ------------------------------------------------------------------
# Проверка 5. Относительные ссылки внутри правил ведут в существующие
# файлы. Правила ссылаются на записи решений и друг на друга — битая
# ссылка здесь стоит того же, что битая ссылка из промпта.
# ------------------------------------------------------------------
for rule in "${rules[@]}"; do
    dir="$(dirname "$rule")"
    while IFS= read -r target; do
        [ -z "$target" ] && continue
        case "$target" in
            http*|'#'*) continue ;;
        esac
        # Якорь после пути к файлу отбрасывается: проверяется файл.
        target="${target%%#*}"
        [ -z "$target" ] && continue
        resolved="$dir/$target"
        # Нормализация ../ вручную: realpath есть не в каждом окружении, а
        # путей здесь единицы.
        while printf '%s' "$resolved" | grep -q '/[^/][^/]*/\.\./'; do
            resolved="$(printf '%s' "$resolved" | sed -E 's#/[^/]+/\.\./#/#')"
        done
        if [ ! -e "$resolved" ]; then
            report "$rule" "битая ссылка: $target"
        fi
    done < <(grep -ohE '\]\([^)]+\.md[^)]*\)' "$rule" \
        | sed -E 's/^\]\(//; s/\)$//' | sort -u)
done

# ------------------------------------------------------------------
printf '\n'
if [ "$VIOLATIONS" -gt 0 ]; then
    printf 'Расхождений: %d. Правила и промпты разъехались.\n' "$VIOLATIONS"
    note 'Правило без работающей ссылки — не источник, а надежда на него.'
    exit 1
fi

printf 'Правила, промпты и указатель сходятся.\n'
exit 0
