#!/usr/bin/env bash
#
# Домовой — сценарии для scripts/risk.sh.
#
# Каждый сценарий строит свой временный репозиторий в mktemp с bare-remote:
# на origin/main лежит настоящий scripts/risk.json, ветка feat несёт ровно
# одну правку, и уровень сверяется вместе с текстом причины, а не только
# строкой level=. Рабочее дерево проекта сценарии не трогают.
#
# Сценарий «конфиг берётся с origin/main» доказывается парой: ослабленный
# конфиг в дереве уровень не меняет, а тот же прогон с несуществующим ref
# конфига — меняет. Без второй половины первая зеленела бы и тогда, когда
# скрипт конфига не читает вовсе.
#
# КАК ЗАПУСКАТЬ
#
#   bash scripts/risk.test.sh
#
# Код возврата: 0 — все сценарии прошли, 1 — есть провалившиеся.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RISK="$SCRIPT_DIR/risk.sh"
CONF="$SCRIPT_DIR/risk.json"
FIXTURES="$SCRIPT_DIR/fixtures/plans"

for f in "$RISK" "$CONF"; do
    [ -f "$f" ] || { printf 'Не найден %s\n' "$f" >&2; exit 2; }
done
command -v jq >/dev/null 2>&1 || { printf 'Не найден jq\n' >&2; exit 2; }

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

PASSED=0
FAILED=0
FAILED_NAMES=()
CASE_NAME=''
CASE_OK=1
OUTPUT=''
STATUS=0
REPO=''
N=0

g() {
    git -c user.name=risk-test -c user.email=risk-test@example.invalid \
        -c core.autocrlf=false -c core.hooksPath=/dev/null -c commit.gpgsign=false \
        -c init.defaultBranch=main "$@"
}

# Новый репозиторий с bare-remote; на main — настоящий конфиг и нейтральный файл.
new_repo() {
    N=$(( N + 1 ))
    REPO="$SANDBOX/repo$N"
    g init -q --bare "$REPO.git"
    g init -q "$REPO"
    g -C "$REPO" remote add origin "$REPO.git"
    mkdir -p "$REPO/scripts" "$REPO/src/Domovoy.Core/Models"
    cp "$CONF" "$REPO/scripts/risk.json"
    printf 'namespace Domovoy.Core.Models;\n' > "$REPO/src/Domovoy.Core/Models/Base.cs"
    g -C "$REPO" add -A
    g -C "$REPO" commit -q -m base
}
# Файл в текущую ветку отдельным коммитом.
commit_file() {  # commit_file <путь> <содержимое>
    mkdir -p "$(dirname "$REPO/$1")"
    printf '%s\n' "$2" > "$REPO/$1"
    g -C "$REPO" add -A
    g -C "$REPO" commit -q -m "edit $1"
}
# main уходит на origin, дальше работа идёт в ветке feat.
start_branch() {
    g -C "$REPO" push -q origin main
    g -C "$REPO" fetch -q origin
    g -C "$REPO" checkout -q -b feat
}
run_risk() {
    OUTPUT="$(cd "$REPO" && bash "$RISK" "$@" 2>&1)"
    STATUS=$?
}
# Правка в ветке поверх базы: один коммит, затем прогон diff.
branch_with() {  # branch_with <путь> <содержимое>
    new_repo; start_branch; commit_file "$1" "$2"
    run_risk diff origin/main HEAD
}

begin_case() { CASE_NAME="$1"; CASE_OK=1; }
fail() {
    CASE_OK=0
    printf '  ✗ %s\n' "$1"
}
expect_status() { [ "$STATUS" -eq "$1" ] || fail "код $STATUS, ожидался $1"; }
expect_level() {
    expect_status 0
    printf '%s\n' "$OUTPUT" | head -n 1 | grep -qx "level=$1" || fail "ожидался level=$1"
}
expect_output() {
    printf '%s\n' "$OUTPUT" | grep -qF -- "$1" || fail "в выводе нет «$1»"
}
expect_no_output() {
    if printf '%s\n' "$OUTPUT" | grep -qF -- "$1"; then fail "в выводе есть «$1»"; fi
}
end_case() {
    if [ "$CASE_OK" -eq 1 ]; then
        PASSED=$(( PASSED + 1 )); printf 'ok   %s\n' "$CASE_NAME"
    else
        FAILED=$(( FAILED + 1 )); FAILED_NAMES+=("$CASE_NAME")
        printf 'FAIL %s\n' "$CASE_NAME"
        printf '%s\n' "$OUTPUT" | sed 's/^/       | /'
    fi
}

# ------------------------------------------------------------------ слова
begin_case 'Строка с CancellationToken вне путей high и medium — low'
branch_with src/Domovoy.Core/Models/Waiter.cs 'public Task WaitAsync(CancellationToken cancellationToken) => Task.CompletedTask;'
expect_level low
expect_output 'reason: сигналов нет'
expect_no_output 'из дерева'
end_case

begin_case 'Строка с access_token — high, причина называет слово и файл'
branch_with src/Domovoy.Core/Models/Login.cs 'var name = "access_token";'
expect_level high
expect_output 'слово «access_token» в добавленной строке: src/Domovoy.Core/Models/Login.cs'
end_case

begin_case 'authoriz — префикс: Authorization поднимает до high'
branch_with src/Domovoy.Core/Models/Header.cs 'const string H = "Authorization";'
expect_level high
expect_output 'слово «authoriz…»'
end_case

begin_case 'Удалённая строка с RequireAuthorization — high'
new_repo
commit_file src/Domovoy.Core/Models/Map.cs 'group.RequireAuthorization();'
start_branch
commit_file src/Domovoy.Core/Models/Map.cs '// пусто'
run_risk diff origin/main HEAD
expect_level high
expect_output 'слово «RequireAuthorization» в удалённой строке: src/Domovoy.Core/Models/Map.cs'
end_case

begin_case 'Слово в тексте правил (docs/**, *.md) уровень не поднимает'
branch_with docs/notes.md 'секрет — это secret, а password не пишется сюда.'
expect_level low
end_case

# ------------------------------------------------------------------ пути
begin_case 'Правка .claude/hooks/** — high'
branch_with .claude/hooks/rule-injector.sh 'exit 0'
expect_level high
expect_output 'high: путь «.claude/hooks/**»: .claude/hooks/rule-injector.sh'
end_case

begin_case 'Правка scripts/risk.json — high'
new_repo; start_branch
jq '.size.files = 99' "$REPO/scripts/risk.json" > "$SANDBOX/c.json" && cp "$SANDBOX/c.json" "$REPO/scripts/risk.json"
g -C "$REPO" commit -q -am 'ослабить порог'
run_risk diff origin/main HEAD
expect_level high
expect_output 'high: путь «scripts/risk.*»: scripts/risk.json'
end_case

begin_case 'Кириллический путь под src/Domovoy.Ha/** — high, путь печатается кириллицей'
branch_with 'src/Domovoy.Ha/Комната.cs' '// комната'
expect_level high
expect_output 'high: путь «src/Domovoy.Ha/**»: src/Domovoy.Ha/Комната.cs'
end_case

begin_case 'Кириллический путь в причине по слову печатается кириллицей'
branch_with 'src/Domovoy.Core/Models/Вход.cs' 'var name = "access_token";'
expect_level high
expect_output 'слово «access_token» в добавленной строке: src/Domovoy.Core/Models/Вход.cs'
end_case

begin_case 'Переименование видно обоими путями: старым под high и новым под medium'
new_repo
commit_file src/Domovoy.Ha/Client.cs '// клиент'
start_branch
g -C "$REPO" mv src/Domovoy.Ha/Client.cs scripts/Client.cs
g -C "$REPO" commit -q -m mv
run_risk diff origin/main HEAD
expect_level high
expect_output 'high: путь «src/Domovoy.Ha/**»: src/Domovoy.Ha/Client.cs'
expect_output 'medium: путь «scripts/**»: scripts/Client.cs'
end_case

begin_case 'Правка обвязки (scripts/**) — medium'
branch_with scripts/other.sh 'echo ok'
expect_level medium
expect_output 'medium: путь «scripts/**»: scripts/other.sh'
end_case

begin_case 'Удаление gitleaks.yml — high'
new_repo
commit_file .github/workflows/gitleaks.yml 'name: gitleaks'
start_branch
g -C "$REPO" rm -q .github/workflows/gitleaks.yml
g -C "$REPO" commit -q -m rm
run_risk diff origin/main HEAD
expect_level high
expect_output 'high: удалён «.github/workflows/gitleaks.yml»'
end_case

begin_case 'Удалённая строка gitleaks в workflow — high, добавленная — только medium'
new_repo
commit_file .github/workflows/ci.yml 'name: ci'
start_branch
commit_file .github/workflows/ci.yml "$(printf 'name: ci\nrun: gitleaks git')"
run_risk diff origin/main HEAD
expect_level medium
g -C "$REPO" checkout -q main
g -C "$REPO" checkout -q -b feat2
commit_file .github/workflows/ci.yml "$(printf 'name: ci\nrun: gitleaks git')"
g -C "$REPO" push -q origin feat2:main
g -C "$REPO" fetch -q origin
commit_file .github/workflows/ci.yml 'name: ci'
run_risk diff origin/main HEAD
expect_level high
expect_output 'high: слово «gitleaks» в удалённой строке workflow: .github/workflows/ci.yml'
end_case

# ------------------------------------------------------------------ размер
begin_case 'Порог числа файлов: 11 — нет, 12 — medium'
new_repo; start_branch
for i in $(seq 1 11); do printf 'x\n' > "$REPO/src/Domovoy.Core/Models/F$i.cs"; done
g -C "$REPO" add -A; g -C "$REPO" commit -q -m files
run_risk diff origin/main HEAD
expect_level low
printf 'x\n' > "$REPO/src/Domovoy.Core/Models/F12.cs"
g -C "$REPO" add -A; g -C "$REPO" commit -q -m file12
run_risk diff origin/main HEAD
expect_level medium
expect_output 'файлов 12 > 11'
end_case

begin_case 'Порог числа строк: 1538 — нет, 1539 — medium'
new_repo; start_branch
seq 1 1538 > "$REPO/src/Domovoy.Core/Models/Big.cs"
g -C "$REPO" add -A; g -C "$REPO" commit -q -m big
run_risk diff origin/main HEAD
expect_level low
seq 1 1539 > "$REPO/src/Domovoy.Core/Models/Big.cs"
g -C "$REPO" commit -q -am big2
run_risk diff origin/main HEAD
expect_level medium
expect_output 'строк 1539 > 1538'
end_case

# ------------------------------------------------------------------ конфиг
begin_case 'Ослабленный risk.json в дереве на уровень не влияет: конфиг с origin/main'
new_repo; start_branch
commit_file src/Domovoy.Core/Models/Login.cs 'var name = "access_token";'
jq '.high.words -= ["access_token"]' "$REPO/scripts/risk.json" > "$SANDBOX/w.json" && cp "$SANDBOX/w.json" "$REPO/scripts/risk.json"
run_risk diff origin/main HEAD
expect_level high
expect_output 'слово «access_token»'
expect_no_output 'из дерева'
# Контроль: без конфига на ref тот же прогон берёт дерево — и уровень другой.
OUTPUT="$(cd "$REPO" && RISK_CONFIG_REF=refs/heads/nonexistent bash "$RISK" diff origin/main HEAD 2>&1)"; STATUS=$?
expect_level low
expect_output 'конфиг взят из дерева: на refs/heads/nonexistent файла scripts/risk.json нет'
end_case

begin_case 'Сломанный конфиг на origin/main — код 2, а не low'
new_repo
printf '{"size": {}}\n' > "$REPO/scripts/risk.json"
g -C "$REPO" commit -q -am broken
start_branch
run_risk diff origin/main HEAD
expect_status 2
expect_output 'не разбирается или неполон'
end_case

# ------------------------------------------------------------------ plan
begin_case 'plan: пути из files[].path, слова не читаются, число файлов считается'
new_repo; start_branch
jq -n '{files: [
    {path: "src/Domovoy.Ha/Комната.cs", action: "modify", why: "access_token"},
    {path: "src/Domovoy.Core/Models/A.cs", action: "create", why: "x"}]}' > "$SANDBOX/p1.json"
run_risk plan "$SANDBOX/p1.json"
expect_level high
expect_output 'high: путь «src/Domovoy.Ha/**»: src/Domovoy.Ha/Комната.cs'
expect_output 'режим plan'
expect_no_output 'access_token'
jq -n '{files: [range(12) | {path: "src/Domovoy.Core/Models/P\(.).cs", action: "create", why: "x"}]}' > "$SANDBOX/p2.json"
run_risk plan "$SANDBOX/p2.json"
expect_level medium
expect_output 'файлов 12 > 11'
jq -n '{files: [{path: ".github/workflows/gitleaks.yml", action: "delete", why: "x"}]}' > "$SANDBOX/p3.json"
run_risk plan "$SANDBOX/p3.json"
expect_level high
expect_output 'удалён «.github/workflows/gitleaks.yml»'
end_case

begin_case 'plan на фикстурах scripts/fixtures/plans печатает уровень и причины'
new_repo; start_branch
found=0
for fx in "$FIXTURES"/*.json; do
    [ -f "$fx" ] || continue
    found=1
    run_risk plan "$fx"
    expect_status 0
    printf '%s\n' "$OUTPUT" | head -n 1 | grep -qE '^level=(low|medium|high)$' || fail "$(basename "$fx"): нет level="
    printf '%s\n' "$OUTPUT" | grep -q '^reason: \(high\|medium\): путь' || fail "$(basename "$fx"): нет причины по пути"
done
[ "$found" -eq 1 ] || fail 'фикстур нет'
end_case

# ------------------------------------------------------------------ запуск
begin_case 'Ошибки запуска — код 2'
new_repo; start_branch
run_risk
expect_status 2
run_risk diff origin/main no-such-ref
expect_status 2
expect_output 'ref не разрешается'
run_risk plan "$SANDBOX/нет.json"
expect_status 2
end_case

# ------------------------------------------------------------------
printf '\n'
if [ "$FAILED" -gt 0 ]; then
    printf 'Провалившиеся сценарии:\n'
    for name in "${FAILED_NAMES[@]}"; do printf '  - %s\n' "$name"; done
    printf '\n'
fi
printf 'Пройдено: %d, провалено: %d, пропущено: 0\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ] || exit 1
exit 0
