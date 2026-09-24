#!/usr/bin/env bash
#
# Домовой — проверочные сценарии для гейта целостности scripts/guard.sh.
#
# ЗАЧЕМ
#
# Гейт, который никто не проверял, — это не гейт, а надежда. Здесь для
# каждой проверки гейта собирается временный git-репозиторий, в нём
# воспроизводится ровно то нарушение, ради которого проверка написана, и
# сверяется код возврата и текст вывода. Отдельно проверяется главное:
# на нормальном PR гейт молчит. Гейт, который шумит на нормальной работе,
# перестают читать, и тогда он не ловит уже ничего.
#
# КАК ЗАПУСКАТЬ
#
#   bash scripts/guard.test.sh
#
# Код возврата: 0 — все сценарии прошли, 1 — есть провалившиеся.
# Временные репозитории создаются в каталоге mktemp и удаляются в конце.
#
# ЗАВИСИМОСТИ
#
#   git, awk, sed — обязательны.
#   gitleaks      — нужен только сценарию про секрет; без него сценарий
#                   помечается как пропущенный, остальные идут как обычно.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GUARD="$SCRIPT_DIR/guard.sh"

if [ ! -f "$GUARD" ]; then
    printf 'Не найден %s\n' "$GUARD" >&2
    exit 2
fi

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

PASSED=0
FAILED=0
SKIPPED=0
FAILED_NAMES=()

CASE_NAME=''
CASE_OK=1

begin_case() {
    CASE_NAME="$1"
    CASE_OK=1
    printf '\n[ ... ] %s\n' "$CASE_NAME"
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
        printf '        --- вывод гейта ---\n'
        printf '%s\n' "$GUARD_OUTPUT" | sed 's/^/        /'
        printf '        --- конец вывода ---\n'
    fi
}

skip_case() {
    SKIPPED=$((SKIPPED + 1))
    printf '[ skip] %s — %s\n' "$CASE_NAME" "$1"
}

# ------------------------------------------------------------------
# Фикстура: репозиторий, похожий по структуре на «Домового».
#
# Содержимое намеренно бедное: проверяются пути и формы строк, а не код.
# ------------------------------------------------------------------
#
# new_fixture присваивает путь к новому репозиторию глобальной переменной
# repo, а не печатает его. Через $(new_fixture) не получится: подстановка
# запускает функцию в подоболочке, счётчик FIXTURE_SEQ там не растёт, и все
# сценарии получают один и тот же каталог.
FIXTURE_SEQ=0
repo=''

new_fixture() {
    FIXTURE_SEQ=$((FIXTURE_SEQ + 1))
    repo="$SANDBOX/repo-$FIXTURE_SEQ"

    mkdir -p "$repo"
    git init -q -b main "$repo"
    git -C "$repo" config user.email 'guard-test@example.invalid'
    git -C "$repo" config user.name 'Guard Test'
    git -C "$repo" config commit.gpgsign false
    git -C "$repo" config core.autocrlf false
    # Хуки настоящего клона во временном репозитории только мешают.
    mkdir -p "$SANDBOX/no-hooks"
    git -C "$repo" config core.hooksPath "$SANDBOX/no-hooks"

    mkdir -p "$repo/src/Domovoy.Api" "$repo/tests/Domovoy.Tests" \
        "$repo/.github/workflows" "$repo/contracts" "$repo/docs/decisions"

    cat > "$repo/Directory.Build.props" <<'EOF'
<Project>
  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
    <TreatWarningsAsErrors>true</TreatWarningsAsErrors>
    <NoWarn>$(NoWarn);CS1591</NoWarn>
  </PropertyGroup>
</Project>
EOF

    cat > "$repo/.editorconfig" <<'EOF'
root = true

[*.cs]
indent_size = 4
EOF

    cat > "$repo/.github/workflows/build.yml" <<'EOF'
name: build
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
EOF

    cat > "$repo/src/Domovoy.Api/Program.cs" <<'EOF'
namespace Domovoy.Api;

internal static class Program
{
    private static void Main() => System.Console.WriteLine("Домовой");
}
EOF

    cat > "$repo/tests/Domovoy.Tests/HealthEndpointTests.cs" <<'EOF'
namespace Domovoy.Tests;

public sealed class HealthEndpointTests
{
    [Fact(DisplayName = "Анонимный /health отвечает без деталей")]
    public void AnonymousHealthAnswers()
    {
    }

    [Fact(DisplayName = "Подробный /health требует аутентификации")]
    public void DetailedHealthRequiresAuth()
    {
    }

    [Theory(DisplayName = "Незаполненный секрет даёт «не сконфигурировано»")]
    [InlineData("")]
    public void MissingSecretIsNotConfigured(string value)
    {
    }
}
EOF

    cat > "$repo/contracts/openapi.json" <<'EOF'
{
  "openapi": "3.0.3",
  "info": { "title": "Домовой", "version": "1.0.0" },
  "paths": {}
}
EOF

    printf '# Домовой\n\nПерсональный агент для умного дома.\n' > "$repo/README.md"

    git -C "$repo" add -A
    git -C "$repo" commit -qm 'chore: базовое состояние фикстуры'
    git -C "$repo" branch -f base HEAD
}

commit_all() {
    local target="$1" message="$2"
    git -C "$target" add -A
    git -C "$target" commit -qm "$message"
}

# Снимок числа выполненных тестовых случаев — база инварианта из
# scripts/test-count-invariant.sh. В фикстуру он не входит: половине
# сценариев проверки 7 нужна как раз базовая ревизия без него.
seed_baseline() {
    local target="$1" value="$2"
    mkdir -p "$target/tests"
    cat > "$target/tests/test-count.baseline" <<EOF
# Снимок числа выполненных тестовых случаев.
$value
EOF
}

# ------------------------------------------------------------------
# Запуск гейта. Переменные окружения передаются перед именем функции:
#   GUARD_ALLOW_PROTECTED=1 run_guard "$repo"
# ------------------------------------------------------------------
GUARD_OUTPUT=''
GUARD_STATUS=0

run_guard() {
    local target="$1"
    shift
    GUARD_OUTPUT="$(cd "$target" && env "$@" bash "$GUARD" base 2>&1)"
    GUARD_STATUS=$?
}

expect_status() {
    local expected="$1"
    if [ "$GUARD_STATUS" -ne "$expected" ]; then
        fail_case "код возврата $GUARD_STATUS, ожидался $expected"
    fi
}

expect_output() {
    local needle="$1"
    if ! printf '%s' "$GUARD_OUTPUT" | grep -qF -- "$needle"; then
        fail_case "в выводе нет: $needle"
    fi
}

expect_no_output() {
    local needle="$1"
    if printf '%s' "$GUARD_OUTPUT" | grep -qF -- "$needle"; then
        fail_case "в выводе есть лишнее: $needle"
    fi
}

# ------------------------------------------------------------------
# Сценарий 0. Нормальный PR — гейт молчит.
# ------------------------------------------------------------------
begin_case 'нормальный PR: гейт молчит'
new_fixture
cat > "$repo/src/Domovoy.Api/StateFormatter.cs" <<'EOF'
namespace Domovoy.Api;

internal static class StateFormatter
{
    public static string Describe(string name, string state) => $"{name}: {state}";
}
EOF
cat > "$repo/tests/Domovoy.Tests/StateFormatterTests.cs" <<'EOF'
namespace Domovoy.Tests;

public sealed class StateFormatterTests
{
    [Fact(DisplayName = "Описание состояния собирается из имени и значения")]
    public void DescribeJoinsNameAndState()
    {
    }
}
EOF
printf '\nОписание состояний собирается в StateFormatter.\n' >> "$repo/README.md"
commit_all "$repo" 'feat: описание состояния сущности'
run_guard "$repo"
expect_status 0
expect_output 'нарушений нет'
expect_no_output '::error'
end_case

# ------------------------------------------------------------------
# Сценарий 1а. Защищённый путь без метки.
# ------------------------------------------------------------------
begin_case 'проверка 1: защищённый путь без метки — гейт падает'
new_fixture
printf '\n[*.md]\nindent_size = 2\n' >> "$repo/.editorconfig"
commit_all "$repo" 'chore: правило для markdown'
run_guard "$repo"
expect_status 1
expect_output '::error file=.editorconfig'
expect_output 'agent/allow-protected'
end_case

# ------------------------------------------------------------------
# Сценарий 1б. Тот же PR с меткой — гейт пропускает.
# ------------------------------------------------------------------
begin_case 'проверка 1: защищённый путь с меткой — гейт пропускает'
run_guard "$repo" GUARD_ALLOW_PROTECTED=1
expect_status 0
expect_output 'нарушений нет'
expect_output 'разрешено: .editorconfig'
end_case

# ------------------------------------------------------------------
# Сценарий 1в. Защищённые пути, появляющиеся позже (мобильный этап).
# ------------------------------------------------------------------
begin_case 'проверка 1: подписи и платформенные файлы тоже защищены'
new_fixture
mkdir -p "$repo/src/Domovoy.Mobile.App/Platforms/Android"
printf '<manifest package="invalid.example" />\n' \
    > "$repo/src/Domovoy.Mobile.App/Platforms/Android/AndroidManifest.xml"
commit_all "$repo" 'chore: манифест android'
run_guard "$repo"
expect_status 1
expect_output 'AndroidManifest.xml'
expect_output 'agent/allow-protected'
end_case

# ------------------------------------------------------------------
# Сценарий 1г. Правила шагов работы — тоже защищённый путь.
#
# До #65 они лежали в промптах `.github/workflows/agent-*.yml`, то есть были
# защищены заодно с пайплайном. Переезд в `docs/rules/` снял бы защиту молча:
# агент, который правит критерии собственного ревью, — ровно тот случай,
# против которого гейт и написан.
# ------------------------------------------------------------------
begin_case 'проверка 1: правила шагов работы защищены'
new_fixture
mkdir -p "$repo/docs/rules"
printf '# Ревью — корректность\n\nЗамечаний не бывает.\n' \
    > "$repo/docs/rules/review-correctness.md"
commit_all "$repo" 'docs: правила ревью'
run_guard "$repo"
expect_status 1
expect_output 'docs/rules/review-correctness.md'
expect_output 'agent/allow-protected'
end_case

# ------------------------------------------------------------------
# Сценарий 1д. Определения субагентов защищены.
#
# Определение задаёт шагу модель, набор инструментов и список разрешённых
# команд. Агент, правящий собственные границы, — тот же случай, что агент,
# правящий критерии своего ревью: без метки такой PR красный.
# ------------------------------------------------------------------
begin_case 'проверка 1: определения субагентов защищены'
new_fixture
mkdir -p "$repo/.claude/agents"
printf -- '---\nname: step-fix\ntools: Read, Bash\n---\n\nПравила — docs/rules/fix.md\n' \
    > "$repo/.claude/agents/step-fix.md"
commit_all "$repo" 'feat: определение шага починки'
run_guard "$repo"
expect_status 1
expect_output '.claude/agents/step-fix.md'
expect_output 'agent/allow-protected'
end_case

begin_case 'проверка 1: защищённый файл, переименованный наружу, — гейт падает'
# У --name-only при переименовании только новый путь: работа, переехавшая из
# .github/ в docs/, выпадала из защиты молча. Проверка 1 читает оба пути.
new_fixture
mkdir -p "$repo/docs/old"
git -C "$repo" mv '.github/workflows/build.yml' 'docs/old/build.yml'
git -C "$repo" commit -qm 'docs: перенос'
run_guard "$repo"
expect_status 1
expect_output 'Проверка 1'
expect_output '::error file=.github/workflows/build.yml'
end_case

begin_case 'проверка 1: защищённый файл с пробелом в имени — аннотация на изменённой строке'
# first_changed_line ищет путь в DIFF_LINES через awk -F'\t', где пустые поля
# не склеиваются: хвостовая табуляция после имени с пробелом в заголовке
# «+++ b/…» дала бы строку 1 вместо изменённой.
new_fixture
mkdir -p "$repo/docs/rules"
printf 'первая\nвторая\nтретья\n' > "$repo/docs/rules/a b.md"
commit_all "$repo" 'docs: правило'
git -C "$repo" branch -f base HEAD
printf 'первая\nвторая\nтретья, иначе\n' > "$repo/docs/rules/a b.md"
commit_all "$repo" 'docs: правило иначе'
run_guard "$repo"
expect_status 1
expect_output '::error file=docs/rules/a b.md,line=3::'
end_case

begin_case 'проверка 1: определение субагента с меткой — гейт пропускает'
new_fixture
mkdir -p "$repo/.claude/agents"
printf -- '---\nname: step-fix\ntools: Read, Bash\n---\n\nПравила — docs/rules/fix.md\n' \
    > "$repo/.claude/agents/step-fix.md"
commit_all "$repo" 'feat: определение шага починки'
run_guard "$repo" GUARD_ALLOW_PROTECTED=1
expect_status 0
end_case

# ------------------------------------------------------------------
# Сценарий 2а. Подавление проверок в обычном файле.
# ------------------------------------------------------------------
begin_case 'проверка 2: подавление в обычном файле — гейт падает с номером строки'
new_fixture
cat > "$repo/src/Domovoy.Api/Program.cs" <<'EOF'
namespace Domovoy.Api;

#pragma warning disable CS8618
internal static class Program
{
    private static void Main() => System.Console.WriteLine("Домовой");
}
EOF
commit_all "$repo" 'fix: сборка стала зелёной'
run_guard "$repo"
expect_status 1
expect_output '#pragma warning disable'
# Номер строки должен быть номером в файле, а не в потоке диффа.
expected_line="$(grep -n 'pragma warning disable' "$repo/src/Domovoy.Api/Program.cs" | cut -d: -f1)"
expect_output "src/Domovoy.Api/Program.cs,line=$expected_line"
expect_output "src/Domovoy.Api/Program.cs:$expected_line:"
end_case

# ------------------------------------------------------------------
# Сценарий 2б. Остальные формы подавления.
# ------------------------------------------------------------------
begin_case 'проверка 2: Skip, [Ignore], [ExcludeFromCodeCoverage], --filter'
new_fixture
cat > "$repo/tests/Domovoy.Tests/SkippedTests.cs" <<'EOF'
namespace Domovoy.Tests;

[ExcludeFromCodeCoverage]
public sealed class SkippedTests
{
    [Fact(DisplayName = "Временно выключен", Skip = "разберусь позже")]
    public void Disabled()
    {
    }

    [Ignore]
    public void AlsoDisabled()
    {
    }
}
EOF
printf 'dotnet test --filter "FullyQualifiedName!~Architecture"\n' > "$repo/run-tests.sh"
commit_all "$repo" 'test: временно выключенные проверки'
run_guard "$repo"
expect_status 1
expect_output 'Skip = "…"'
expect_output '[Ignore]'
expect_output '[ExcludeFromCodeCoverage]'
expect_output '--filter с отрицанием'
end_case

# ------------------------------------------------------------------
# Сценарий 2в. Дублирующего срабатывания на защищённом файле нет.
#
# Directory.Build.props законно содержит <NoWarn>. Проверка 1 сообщает о
# нём как о защищённом пути; проверка 2 не должна сообщать о том же файле
# второй раз.
# ------------------------------------------------------------------
begin_case 'проверка 2: на защищённом файле не срабатывает второй раз'
new_fixture
cat > "$repo/Directory.Build.props" <<'EOF'
<Project>
  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
    <TreatWarningsAsErrors>false</TreatWarningsAsErrors>
    <NoWarn>$(NoWarn);CS1591;CA1062</NoWarn>
  </PropertyGroup>
</Project>
EOF
commit_all "$repo" 'chore: ослабление конфигурации сборки'
run_guard "$repo"
expect_status 1
expect_output 'Проверка 1'
expect_output 'Directory.Build.props'
expect_no_output 'Проверка 2'
expect_no_output 'Подавление проверки'
end_case

# ------------------------------------------------------------------
# Сценарий 3а. Удалён файл с тестами.
# ------------------------------------------------------------------
begin_case 'проверка 3: удалён файл с тестами'
new_fixture
rm "$repo/tests/Domovoy.Tests/HealthEndpointTests.cs"
commit_all "$repo" 'test: убраны мешающие проверки'
run_guard "$repo"
expect_status 1
expect_output 'Файл с тестами удалён'
expect_output 'tests/Domovoy.Tests/HealthEndpointTests.cs'
end_case

begin_case 'проверка 3: файл с тестами, переименованный из tests/ наружу, — гейт падает'
# Переименование без правки содержимого: строк в диффе нет, счёт атрибутов
# молчит, а при -M это R, а не D. Тесты вне tests/ не прогоняются.
new_fixture
mkdir -p "$repo/docs/old"
git -C "$repo" mv 'tests/Domovoy.Tests/HealthEndpointTests.cs' 'docs/old/HealthEndpointTests.cs'
git -C "$repo" commit -qm 'docs: пример тестов'
run_guard "$repo"
expect_status 1
expect_output 'Проверка 3'
expect_output 'Файл с тестами удалён или вынесен из tests/: tests/Domovoy.Tests/HealthEndpointTests.cs'
end_case

# ------------------------------------------------------------------
# Сценарий 3б. Тестов удалено больше, чем добавлено.
#
# Форма атрибутов здесь такая же, как в настоящем репозитории:
# [Fact(DisplayName = "…")], голого [Fact] нет ни одного.
# ------------------------------------------------------------------
begin_case 'проверка 3: [Fact(DisplayName = …)] удалено больше, чем добавлено'
new_fixture
cat > "$repo/tests/Domovoy.Tests/HealthEndpointTests.cs" <<'EOF'
namespace Domovoy.Tests;

public sealed class HealthEndpointTests
{
    [Fact(DisplayName = "Анонимный /health отвечает без деталей")]
    public void AnonymousHealthAnswers()
    {
    }
}
EOF
commit_all "$repo" 'test: сокращение набора проверок'
run_guard "$repo"
expect_status 1
expect_output 'Тест удалён'
expect_output 'удалено [Fact]/[Theory]: 2, добавлено: 0'
end_case

# ------------------------------------------------------------------
# Сценарий 3в. Тесты переписаны, но их не стало меньше — гейт молчит.
# ------------------------------------------------------------------
begin_case 'проверка 3: переписанные тесты того же числа — гейт молчит'
new_fixture
cat > "$repo/tests/Domovoy.Tests/HealthEndpointTests.cs" <<'EOF'
namespace Domovoy.Tests;

public sealed class HealthEndpointTests
{
    [Fact(DisplayName = "Анонимный /health отвечает ровно «Healthy»")]
    public void AnonymousHealthAnswers()
    {
    }

    [Fact(DisplayName = "Подробный /health закрыт для анонима")]
    public void DetailedHealthRequiresAuth()
    {
    }

    [Theory(DisplayName = "Пустой секрет даёт «не сконфигурировано»")]
    [InlineData("")]
    public void MissingSecretIsNotConfigured(string value)
    {
    }
}
EOF
commit_all "$repo" 'test: уточнённые формулировки'
run_guard "$repo"
expect_status 0
expect_output 'нарушений нет'
end_case

# ------------------------------------------------------------------
# Сценарий 3г. Строки, похожие на атрибуты, вне tests/ — не тесты.
#
# В документации и в фикстурах проверочных сценариев [Fact(DisplayName = …)]
# встречается как пример. Их сокращение не должно выглядеть как удаление
# тестов: иначе гейт начал бы срабатывать на собственном харнессе.
# ------------------------------------------------------------------
begin_case 'проверка 3: похожие на тесты строки вне tests/ не считаются'
new_fixture
cat > "$repo/docs/decisions/0001-test-naming.md" <<'EOF'
# Именование тестов

Пример:

    [Fact(DisplayName = "Первый пример")]
    [Fact(DisplayName = "Второй пример")]
    [Theory(DisplayName = "Третий пример")]
EOF
commit_all "$repo" 'docs: примеры именования тестов'
cat > "$repo/docs/decisions/0001-test-naming.md" <<'EOF'
# Именование тестов

Пример:

    [Fact(DisplayName = "Первый пример")]
EOF
commit_all "$repo" 'docs: короче пример именования'
run_guard "$repo" GUARD_ALLOW_PROTECTED=1
expect_status 0
expect_output 'нарушений нет'
expect_no_output 'Тест удалён'
end_case

# ------------------------------------------------------------------
# Сценарий 4а. Деструктивная миграция без метки.
#
# Каталога миграций в базовой версии нет — проверка обязана работать и
# при его отсутствии.
# ------------------------------------------------------------------
begin_case 'проверка 4: деструктивная миграция без метки'
new_fixture
mkdir -p "$repo/src/Domovoy.Data/Migrations"
cat > "$repo/src/Domovoy.Data/Migrations/20260821120000_Cleanup.cs" <<'EOF'
namespace Domovoy.Data.Migrations;

public partial class Cleanup
{
    protected override void Up(MigrationBuilder migrationBuilder)
    {
        migrationBuilder.DropColumn(name: "Legacy", table: "Conversations");
        migrationBuilder.RenameTable(name: "Old", newName: "New");
    }
}
EOF
commit_all "$repo" 'feat: чистка схемы'
run_guard "$repo" GUARD_ALLOW_PROTECTED=1
expect_status 1
expect_output 'Деструктивная операция в миграции'
expect_output 'agent/allow-destructive-migration'
expect_output 'DropColumn'
end_case

# ------------------------------------------------------------------
# Сценарий 4б. Та же миграция с меткой.
# ------------------------------------------------------------------
begin_case 'проверка 4: деструктивная миграция с меткой — гейт пропускает'
run_guard "$repo" GUARD_ALLOW_PROTECTED=1 GUARD_ALLOW_DESTRUCTIVE_MIGRATION=1
expect_status 0
expect_output 'нарушений нет'
end_case

# ------------------------------------------------------------------
# Сценарий 4в. Обычная миграция без деструктивных операций.
# ------------------------------------------------------------------
begin_case 'проверка 4: обычная миграция без деструктивных операций — гейт молчит'
new_fixture
mkdir -p "$repo/src/Domovoy.Data/Migrations"
cat > "$repo/src/Domovoy.Data/Migrations/20260821120000_Initial.cs" <<'EOF'
namespace Domovoy.Data.Migrations;

public partial class Initial
{
    protected override void Up(MigrationBuilder migrationBuilder)
    {
        migrationBuilder.CreateTable(name: "Conversations", columns: null);
    }
}
EOF
commit_all "$repo" 'feat: первая миграция'
run_guard "$repo" GUARD_ALLOW_PROTECTED=1
expect_status 0
expect_output 'нарушений нет'
end_case

# ------------------------------------------------------------------
# Сценарий 5а. Контракт API без метки.
# ------------------------------------------------------------------
begin_case 'проверка 5: контракт API без метки'
new_fixture
cat > "$repo/contracts/openapi.json" <<'EOF'
{
  "openapi": "3.0.3",
  "info": { "title": "Домовой", "version": "2.0.0" },
  "paths": { "/ask": {} }
}
EOF
commit_all "$repo" 'feat: эндпоинт запроса в контракте'
run_guard "$repo" GUARD_ALLOW_PROTECTED=1
expect_status 1
expect_output 'Контракт API изменён'
expect_output 'agent/allow-contract'
end_case

# ------------------------------------------------------------------
# Сценарий 5б. Контракт API с меткой.
# ------------------------------------------------------------------
begin_case 'проверка 5: контракт API с меткой — гейт пропускает'
run_guard "$repo" GUARD_ALLOW_PROTECTED=1 GUARD_ALLOW_CONTRACT=1
expect_status 0
expect_output 'нарушений нет'
end_case

# ------------------------------------------------------------------
# Сценарий 6а. Секрет в диффе.
#
# Значение собирается из случайных байт в момент прогона и никогда не
# попадает в файлы репозитория: секретоподобных литералов в исходниках
# «Домового» быть не должно (ТЗ 5.1). Форма — github pat, её ловит
# правило gitleaks по умолчанию; во временном репозитории .gitleaks.toml
# нет, поэтому работает набор правил по умолчанию, а не конфиг проекта.
# ------------------------------------------------------------------
begin_case 'проверка 6: захардкоженный секрет ловится gitleaks'
if ! command -v gitleaks > /dev/null 2>&1; then
    skip_case 'gitleaks не установлен'
else
    new_fixture
    fake_secret="gh""p_$(od -An -tx1 -N18 /dev/urandom | tr -d ' \n')"
    printf 'internal const string Token = "%s";\n' "$fake_secret" \
        > "$repo/src/Domovoy.Api/Secrets.cs"
    commit_all "$repo" 'chore: временно зашитый токен'
    run_guard "$repo"
    expect_status 1
    expect_output 'gitleaks нашёл секрет'
    expect_no_output "$fake_secret"
    end_case
fi

# ------------------------------------------------------------------
# Сценарий 6б. gitleaks недоступен — гейт объясняет, кто ищет секреты.
# ------------------------------------------------------------------
begin_case 'проверка 6: без gitleaks гейт сообщает, где выполняется проверка'
new_fixture
printf '\nЕщё строка документации.\n' >> "$repo/README.md"
commit_all "$repo" 'docs: строка в README'
run_guard "$repo" GUARD_GITLEAKS="$SANDBOX/нет-такого-бинаря"
expect_status 0
expect_output 'gitleaks не найден'
expect_output 'gitleaks.yml'
end_case

# ------------------------------------------------------------------
# Сценарий 7а. Число в снимке понижено — гейт падает.
#
# tests/test-count.baseline — база инварианта числа выполненных случаев
# (scripts/test-count-invariant.sh). Понижение числа в диффе означает
# «тестов стало меньше», и метки-обхода на это нет вовсе: законное
# уменьшение проводит человек вручную, а не PR агента.
# ------------------------------------------------------------------
begin_case 'проверка 7: число в снимке понижено — гейт падает'
new_fixture
seed_baseline "$repo" 42
commit_all "$repo" 'chore: снимок числа выполненных тестов'
git -C "$repo" branch -f base HEAD
seed_baseline "$repo" 41
commit_all "$repo" 'test: сокращение набора проверок'
run_guard "$repo"
expect_status 1
expect_output '::error file=tests/test-count.baseline'
expect_output 'Снимок числа тестов понижен'
expect_output '42'
expect_output 'вручную'
end_case

# ------------------------------------------------------------------
# Сценарий 7б. Метки-обхода нет: та же правка с любой меткой всё равно
# красная. Проверяется именно это, потому что решение владельца —
# «обхода у инварианта нет» — иначе не отличить от забытой переменной.
# ------------------------------------------------------------------
begin_case 'проверка 7: понижение не снимается ни одной меткой'
run_guard "$repo" GUARD_ALLOW_PROTECTED=1 GUARD_ALLOW_CONTRACT=1 \
    GUARD_ALLOW_DESTRUCTIVE_MIGRATION=1
expect_status 1
expect_output 'Снимок числа тестов понижен'
end_case

# ------------------------------------------------------------------
# Сценарий 7в. Число повышено — гейт молчит: тестов стало больше.
# ------------------------------------------------------------------
begin_case 'проверка 7: число в снимке повышено — гейт молчит'
new_fixture
seed_baseline "$repo" 42
commit_all "$repo" 'chore: снимок числа выполненных тестов'
git -C "$repo" branch -f base HEAD
seed_baseline "$repo" 45
commit_all "$repo" 'test: три новых проверки'
run_guard "$repo"
expect_status 0
expect_output 'нарушений нет'
end_case

# ------------------------------------------------------------------
# Сценарий 7г. В базовой ревизии снимка нет — этот PR его вводит.
# Печатная заметка, а не нарушение: сравнивать не с чем, и это штатно
# ровно один раз в жизни репозитория.
# ------------------------------------------------------------------
begin_case 'проверка 7: снимка нет в базовой ревизии — заметка, не нарушение'
new_fixture
seed_baseline "$repo" 42
commit_all "$repo" 'feat: снимок числа выполненных тестов'
run_guard "$repo"
expect_status 0
expect_output 'нарушений нет'
expect_output 'снимок числа тестов появился'
end_case

# ------------------------------------------------------------------
# Сценарий 7д. Правка комментария в снимке — гейт молчит.
#
# Сравниваются только строки из одних цифр. Иначе правка шапки читалась
# бы как «42 → 0», и гейт начал бы шуметь на законной работе, а шумящий
# гейт перестают читать.
# ------------------------------------------------------------------
begin_case 'проверка 7: правка комментария в снимке — гейт молчит'
new_fixture
seed_baseline "$repo" 42
commit_all "$repo" 'chore: снимок числа выполненных тестов'
git -C "$repo" branch -f base HEAD
cat > "$repo/tests/test-count.baseline" <<'EOF'
# Снимок числа выполненных тестовых случаев.
# Обновляется тем же PR, который меняет число тестов.
42
EOF
commit_all "$repo" 'docs: пояснение к снимку'
run_guard "$repo"
expect_status 0
expect_output 'нарушений нет'
end_case

# ------------------------------------------------------------------
# Сценарий 7е. Снимок удалён — гейт падает.
#
# Самый прямой способ обойти инвариант: сравнивать станет не с чем.
# Проверка 3 сообщит о том же удалении как о файле под tests/ — второе
# сообщение здесь не мешает, важно, что причина названа своим именем.
# ------------------------------------------------------------------
begin_case 'проверка 7: снимок удалён — гейт падает'
new_fixture
seed_baseline "$repo" 42
commit_all "$repo" 'chore: снимок числа выполненных тестов'
git -C "$repo" branch -f base HEAD
rm "$repo/tests/test-count.baseline"
commit_all "$repo" 'chore: снимок мешал'
run_guard "$repo"
expect_status 1
expect_output 'Снимок числа тестов удалён'
end_case

# ------------------------------------------------------------------
# Проверка 8. Отчёт о прогоне в диффе.
#
# .gitignore фикстуры повторяет строки настоящего: каталог результатов и
# *.trx. Файлы добавляются через git add -f — ровно тот обход, от которого
# .gitignore не защищает, — поэтому сценарии и доказывают, что защищает гейт,
# а не .gitignore.
# ------------------------------------------------------------------
seed_report_gitignore() {
    local target="$1"
    cat > "$target/.gitignore" <<'EOF'
# Результаты тестов и покрытие
[Tt]est[Rr]esult*/
*.trx
EOF
    commit_all "$target" 'chore: результаты тестов вне git'
    git -C "$target" branch -f base HEAD
}

# Отчёт с тем же устройством, что пишет логгер trx: сумму executed по таким
# файлам и считает scripts/test-count-invariant.sh.
put_report() {
    local target="$1" path="$2"
    mkdir -p "$(dirname "$target/$path")"
    cat > "$target/$path" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<TestRun>
  <ResultSummary outcome="Completed">
    <Counters total="5" executed="5" passed="5" failed="0" />
  </ResultSummary>
</TestRun>
EOF
    git -C "$target" add -f "$path"
}

begin_case 'проверка 8: закоммиченный trx-отчёт — гейт падает'
new_fixture
seed_report_gitignore "$repo"
put_report "$repo" 'TestResults/tests.trx'
commit_all "$repo" 'test: отчёт прогона'
run_guard "$repo"
expect_status 1
expect_output 'Проверка 8'
expect_output '::error file=TestResults/tests.trx'
expect_output 'Отчёт о прогоне тестов закоммичен'
expect_output 'вход инварианта'
end_case

begin_case 'проверка 8: отчёт прогона не снимается ни одной меткой'
run_guard "$repo" GUARD_ALLOW_PROTECTED=1 GUARD_ALLOW_CONTRACT=1 \
    GUARD_ALLOW_DESTRUCTIVE_MIGRATION=1
expect_status 1
expect_output 'Проверка 8'
expect_output '::error file=TestResults/tests.trx'
expect_output 'Метки, снимающей эту проверку, нет'
end_case

begin_case 'проверка 8: файл под каталогом результатов прогона — гейт падает'
# Отчёт покрытия лежит под тем же каталогом, что и trx, и порог покрытия в CI
# суммирует его по глобу: шаблон *.trx в одиночку оставил бы его открытым.
# Второй путь — каталог результатов на глубине, у тестового проекта.
new_fixture
seed_report_gitignore "$repo"
put_report "$repo" 'TestResults/pad/coverage.cobertura.xml'
put_report "$repo" 'tests/Domovoy.Tests/TestResults/x.xml'
commit_all "$repo" 'test: отчёт покрытия'
run_guard "$repo"
expect_status 1
expect_output 'Проверка 8'
expect_output '::error file=TestResults/pad/coverage.cobertura.xml'
expect_output '::error file=tests/Domovoy.Tests/TestResults/x.xml'
expect_output 'Файл под каталогом результатов прогона закоммичен'
end_case

begin_case 'проверка 8: опустошённый [InlineData] и подложенный отчёт — гейт падает на проверке 8'
# Обход из #90 целиком: набор [InlineData] у [Theory] опустошён, атрибуты
# [Fact]/[Theory] не убыли — проверка 3 молчит; строк подавления нет —
# проверка 2 молчит. Подложенный отчёт добил бы сумму executed до снимка, и
# инвариант остался бы зелёным. Ловит только проверка 8.
new_fixture
seed_report_gitignore "$repo"
cat > "$repo/tests/Domovoy.Tests/HealthEndpointTests.cs" <<'EOF'
namespace Domovoy.Tests;

public sealed class HealthEndpointTests
{
    [Fact(DisplayName = "Анонимный /health отвечает без деталей")]
    public void AnonymousHealthAnswers()
    {
    }

    [Fact(DisplayName = "Подробный /health требует аутентификации")]
    public void DetailedHealthRequiresAuth()
    {
    }

    [Theory(DisplayName = "Незаполненный секрет даёт «не сконфигурировано»")]
    public void MissingSecretIsNotConfigured(string value)
    {
    }
}
EOF
put_report "$repo" 'TestResults/pad.trx'
commit_all "$repo" 'test: набор случаев упрощён'
run_guard "$repo"
expect_status 1
expect_output 'Проверка 8'
expect_output '::error file=TestResults/pad.trx'
expect_no_output 'Проверка 2'
expect_no_output 'Проверка 3'
end_case

begin_case 'проверка 8: удаление ранее закоммиченного отчёта — гейт молчит'
# Отчёт, попавший в main раньше, убирают из репозитория — это починка, а не
# нарушение.
new_fixture
seed_report_gitignore "$repo"
put_report "$repo" 'TestResults/old.trx'
commit_all "$repo" 'test: отчёт, закоммиченный по ошибке'
git -C "$repo" branch -f base HEAD
git -C "$repo" rm -q --cached 'TestResults/old.trx'
commit_all "$repo" 'chore: отчёт убран из репозитория'
run_guard "$repo"
expect_status 0
expect_output 'нарушений нет'
expect_no_output 'Проверка 8'
end_case

begin_case 'проверка 8: изменённый ранее закоммиченный отчёт — гейт падает'
# Отчёт уже лежит в main, PR переписывает его содержимое: сумма executed
# меняется так же, как от нового файла. Сценарий краснеет при сужении
# --diff-filter до добавленных.
new_fixture
seed_report_gitignore "$repo"
put_report "$repo" 'TestResults/old.trx'
commit_all "$repo" 'test: отчёт, закоммиченный по ошибке'
git -C "$repo" branch -f base HEAD
sed 's/executed="5"/executed="42"/' "$repo/TestResults/old.trx" > "$repo/TestResults/old.trx.new"
mv "$repo/TestResults/old.trx.new" "$repo/TestResults/old.trx"
git -C "$repo" add -f 'TestResults/old.trx'
commit_all "$repo" 'test: отчёт обновлён'
run_guard "$repo"
expect_status 1
expect_output 'Проверка 8'
expect_output '::error file=TestResults/old.trx'
expect_output 'Отчёт о прогоне тестов закоммичен'
end_case

begin_case 'проверка 8: файл, переименованный под каталог результатов, — гейт падает'
# git mv обычного файла под TestResults/ — переименование, а не добавление:
# сценарий краснеет, если --diff-filter перестаёт пропускать R.
new_fixture
seed_report_gitignore "$repo"
mkdir -p "$repo/notes"
printf '<summary executed="5" />\n' > "$repo/notes/summary.xml"
commit_all "$repo" 'docs: сводка'
git -C "$repo" branch -f base HEAD
mkdir -p "$repo/TestResults"
git -C "$repo" mv 'notes/summary.xml' 'TestResults/summary.xml'
git -C "$repo" commit -qm 'test: сводка переехала к результатам'
run_guard "$repo"
expect_status 1
expect_output 'Проверка 8'
expect_output '::error file=TestResults/summary.xml'
expect_output 'Файл под каталогом результатов прогона закоммичен'
end_case

# ------------------------------------------------------------------
# Проверка 9. Разрушительный и неидемпотентный SQL в миграции.
#
# Материал целиком синтетический: миграций в дереве ноль, и формы, которые
# даст настоящий генератор EF, могут отличаться. Фикстуры повторяют формы
# сгенерированного кода — migrationBuilder.Sql, table.Column, b.Property.
#
# Каждый сценарий под Migrations/ идёт с GUARD_ALLOW_PROTECTED=1: иначе код 1
# пришёл бы от проверки 1, и сценарий оставался бы зелёным при выключенной
# проверке 9. Положительные ждут раздел «Проверка 9» и имя правила, а не код.
# ------------------------------------------------------------------
put_migration() {
    local target="$1" name="$2" line
    shift 2
    mkdir -p "$target/src/Domovoy.Data/Migrations"
    {
        printf 'namespace Domovoy.Data.Migrations;\n\n'
        printf 'public partial class %s\n{\n' "$name"
        printf '    protected override void Up(MigrationBuilder migrationBuilder)\n    {\n'
        for line in "$@"; do
            printf '        %s\n' "$line"
        done
        printf '    }\n}\n'
    } > "$target/src/Domovoy.Data/Migrations/20260901120000_$name.cs"
}

migration_line() {
    local target="$1" name="$2" needle="$3"
    grep -nF -- "$needle" "$target/src/Domovoy.Data/Migrations/20260901120000_$name.cs" \
        | head -n 1 | cut -d: -f1
}

begin_case 'проверка 9: каждое из пяти правил B.4 ловится на добавленной строке и называет себя'
for rule in \
    'DeleteRows|DELETE FROM или TRUNCATE|migrationBuilder.Sql("DELETE FROM \"Conversations\" WHERE \"Archived\";");|migrationBuilder.Sql("TRUNCATE TABLE \"Messages\";");' \
    'DropTable|DROP без IF EXISTS|migrationBuilder.Sql("DROP TABLE \"Legacy\";");|' \
    'LockTable|ACCESS EXCLUSIVE|migrationBuilder.Sql("LOCK TABLE \"Conversations\" IN ACCESS EXCLUSIVE MODE;");|' \
    'PrimaryKey|ADD CONSTRAINT … PRIMARY KEY|migrationBuilder.Sql("ALTER TABLE \"Messages\" ADD CONSTRAINT \"PK_Messages\" PRIMARY KEY (\"Id\");");|' \
    'NotIdempotent|CREATE TABLE или ADD COLUMN без IF NOT EXISTS|migrationBuilder.Sql("CREATE TABLE \"Notes\" (\"Id\" integer);");|migrationBuilder.Sql("ALTER TABLE \"Notes\" ADD COLUMN \"Text\" text;");'; do
    IFS='|' read -r mig_name rule_name first_sql second_sql <<< "$rule"
    new_fixture
    if [ -n "$second_sql" ]; then
        put_migration "$repo" "$mig_name" "$first_sql" "$second_sql"
    else
        put_migration "$repo" "$mig_name" "$first_sql"
    fi
    commit_all "$repo" "feat: миграция $mig_name"
    run_guard "$repo" GUARD_ALLOW_PROTECTED=1
    expect_status 1
    expect_output 'Проверка 9'
    expect_output "правило «$rule_name»"
    mig_path="src/Domovoy.Data/Migrations/20260901120000_$mig_name.cs"
    expect_output "::error file=$mig_path,line=$(migration_line "$repo" "$mig_name" "$first_sql")::"
    if [ -n "$second_sql" ]; then
        expect_output "::error file=$mig_path,line=$(migration_line "$repo" "$mig_name" "$second_sql")::"
    fi
done
end_case

begin_case 'проверка 9: SQL в смешанном регистре ловится так же'
# Шаблоны правил записаны в нижнем регистре, и совпасть со строкой
# «Truncate Table» они могут только сравнением без учёта регистра.
new_fixture
put_migration "$repo" 'MixedCase' 'migrationBuilder.Sql("Truncate Table \"Messages\";");'
commit_all "$repo" 'feat: миграция в смешанном регистре'
run_guard "$repo" GUARD_ALLOW_PROTECTED=1
expect_status 1
expect_output 'Проверка 9'
expect_output 'правило «DELETE FROM или TRUNCATE»'
end_case

begin_case 'проверка 9: идемпотентные IF NOT EXISTS и DROP … IF EXISTS не срабатывают'
new_fixture
put_migration "$repo" 'Idempotent' \
    'migrationBuilder.Sql("ALTER TABLE \"Notes\" ADD COLUMN IF NOT EXISTS \"Text\" text;");' \
    'migrationBuilder.Sql("CREATE TABLE IF NOT EXISTS \"Notes\" (\"Id\" integer);");' \
    'migrationBuilder.Sql("CREATE INDEX IF NOT EXISTS \"IX_Notes_Text\" ON \"Notes\" (\"Text\");");' \
    'migrationBuilder.Sql("DROP INDEX IF EXISTS \"IX_Notes_Old\";");' \
    'migrationBuilder.Sql("DROP INDEX CONCURRENTLY IF EXISTS \"IX_Notes_Older\";");' \
    'migrationBuilder.Sql("ALTER TABLE \"Notes\" DROP COLUMN IF EXISTS \"Old\", DROP CONSTRAINT IF EXISTS \"FK_Old\";");'
commit_all "$repo" 'feat: идемпотентная миграция'
run_guard "$repo" GUARD_ALLOW_PROTECTED=1
expect_status 0
expect_output 'нарушений нет'
expect_no_output 'Проверка 9'
end_case

begin_case 'проверка 9: IF [NOT] EXISTS снимает срабатывание только со своего оператора'
# Исключение привязано к ключевому слову, а не к строке: идемпотентная форма
# соседнего оператора, комментарий или хвост C# после литерала неидемпотентный
# оператор не прячут.
for rule in \
    'TwoDrops|DROP без IF EXISTS|migrationBuilder.Sql("DROP TABLE \"A\"; DROP TABLE IF EXISTS \"B\";");' \
    'DropComment|DROP без IF EXISTS|migrationBuilder.Sql("DROP TABLE \"X\"; -- if exists");' \
    'CreateThenAdd|CREATE TABLE или ADD COLUMN без IF NOT EXISTS|migrationBuilder.Sql("CREATE TABLE \"A\" (\"Id\" integer); ALTER TABLE \"B\" ADD COLUMN IF NOT EXISTS \"C\" integer;");' \
    'CsharpTail|DROP без IF EXISTS|migrationBuilder.Sql("DROP TABLE \"Users\";"); // IF EXISTS'; do
    IFS='|' read -r mig_name rule_name sql <<< "$rule"
    new_fixture
    put_migration "$repo" "$mig_name" "$sql"
    commit_all "$repo" "feat: миграция $mig_name"
    run_guard "$repo" GUARD_ALLOW_PROTECTED=1
    expect_status 1
    expect_output 'Проверка 9'
    expect_output "правило «$rule_name»"
    expect_output "::error file=src/Domovoy.Data/Migrations/20260901120000_$mig_name.cs,line=$(migration_line "$repo" "$mig_name" "$sql")::"
done
end_case

begin_case 'проверка 9: идентификаторы EF со словом Truncate не срабатывают'
# Однословное truncate без границ совпало бы с именами сгенерированного кода.
# Материал держит обе границы: shouldTruncate с пробелом после — ведущую,
# TruncateAfter и .Truncate( — замыкающую.
new_fixture
put_migration "$repo" 'TruncatedFlag' \
    'migrationBuilder.AddColumn<bool>(name: "IsTruncated", table: "Messages", nullable: false);' \
    'var shouldTruncate = false;' \
    'var preview = text.Truncate(80);'
cat > "$repo/src/Domovoy.Data/Migrations/20260901120000_TruncatedFlag.Designer.cs" <<'EOF'
namespace Domovoy.Data.Migrations;

partial class TruncatedFlag
{
    protected override void BuildTargetModel(ModelBuilder modelBuilder)
    {
        modelBuilder.Entity("Domovoy.Data.Message", b =>
        {
            b.Property<bool>("IsTruncated");
            b.Property<int>("TruncateAfter");
        });
    }
}
EOF
commit_all "$repo" 'feat: флаг усечения сообщения'
run_guard "$repo" GUARD_ALLOW_PROTECTED=1
expect_status 0
expect_output 'нарушений нет'
expect_no_output 'Проверка 9'
end_case

begin_case 'проверка 9: разрушительный SQL с меткой agent/allow-destructive-migration — гейт пропускает'
# DELETE FROM в миграции переноса данных законен, и решение за человеком —
# та же метка, что у проверки 4. Раздел проверки называет, что разрешено.
new_fixture
put_migration "$repo" 'MoveData' \
    'migrationBuilder.Sql("DELETE FROM \"Conversations\" WHERE \"Archived\";");'
commit_all "$repo" 'feat: перенос данных'
run_guard "$repo" GUARD_ALLOW_PROTECTED=1 GUARD_ALLOW_DESTRUCTIVE_MIGRATION=1
expect_status 0
expect_output 'нарушений нет'
expect_output 'Проверка 9'
expect_output "разрешено: src/Domovoy.Data/Migrations/20260901120000_MoveData.cs:$(migration_line "$repo" 'MoveData' 'DELETE FROM')"
end_case

# ------------------------------------------------------------------
# Проверка 4: AddPrimaryKey — аналог правила «ADD CONSTRAINT … PRIMARY KEY»
# проверки 9 на API EF. Сценарии стоят здесь, а не рядом с 4а-4в: им нужны
# put_migration и migration_line. Каждый идёт с GUARD_ALLOW_PROTECTED=1 по той
# же причине, что сценарии проверки 9.
# ------------------------------------------------------------------
begin_case 'проверка 4: вызов migrationBuilder.AddPrimaryKey — гейт падает и называет вызов'
new_fixture
put_migration "$repo" 'MessagesKey' \
    'migrationBuilder.AddPrimaryKey(name: "PK_Messages", table: "Messages", column: "Id");'
commit_all "$repo" 'feat: первичный ключ сообщений'
run_guard "$repo" GUARD_ALLOW_PROTECTED=1
expect_status 1
expect_output 'Проверка 4: деструктивная миграция'
expect_output "::error file=src/Domovoy.Data/Migrations/20260901120000_MessagesKey.cs,line=$(migration_line "$repo" 'MessagesKey' 'AddPrimaryKey')::"
expect_output 'первичного ключа'
expect_output 'migrationBuilder.AddPrimaryKey(name: "PK_Messages"'
expect_no_output 'Проверка 9'
end_case

begin_case 'проверка 4: AddPrimaryKey с меткой agent/allow-destructive-migration — гейт пропускает'
# Та же миграция, что в предыдущем сценарии: репозиторий не пересоздаётся.
run_guard "$repo" GUARD_ALLOW_PROTECTED=1 GUARD_ALLOW_DESTRUCTIVE_MIGRATION=1
expect_status 0
expect_output 'нарушений нет'
expect_output 'Проверка 4: деструктивная миграция разрешена меткой agent/allow-destructive-migration'
expect_output 'разрешено: src/Domovoy.Data/Migrations/20260901120000_MessagesKey.cs'
end_case

begin_case 'проверка 4: первичный ключ внутри CreateTable и HasKey снимка модели — гейт молчит'
# Ключ, объявленный вместе с таблицей, живую таблицу не перестраивает. Материал
# держит границу альтернативы: table.PrimaryKey и b.HasKey совпали бы с
# шаблоном PrimaryKey без Add.
new_fixture
put_migration "$repo" 'Notes' \
    'migrationBuilder.CreateTable(name: "Notes", columns: null,' \
    '    constraints: table => { table.PrimaryKey("PK_Notes", x => x.Id); });'
cat > "$repo/src/Domovoy.Data/Migrations/20260901120000_Notes.Designer.cs" <<'EOF'
namespace Domovoy.Data.Migrations;

partial class Notes
{
    protected override void BuildTargetModel(ModelBuilder modelBuilder)
    {
        modelBuilder.Entity("Domovoy.Data.Note", b =>
        {
            b.HasKey("Id");
            b.ToTable("Notes");
        });
    }
}
EOF
commit_all "$repo" 'feat: таблица заметок'
run_guard "$repo" GUARD_ALLOW_PROTECTED=1
expect_status 0
expect_output 'нарушений нет'
expect_no_output 'Проверка 4'
expect_no_output 'Проверка 9'
end_case

# ------------------------------------------------------------------
# Проверка 11. Снятие ограничений схемы вызовом API EF.
#
# Сценарии стоят здесь по той же причине, что сценарии AddPrimaryKey: им нужны
# put_migration и migration_line; GUARD_ALLOW_PROTECTED=1 — по той же причине,
# что у проверки 9. Раздел ждётся строкой «Проверка 11:» с двоеточием: «Проверка
# 1» — её подстрока. expect_no_output 'Проверка 4' держит решение владельца:
# вызов ловит своя проверка, а не расширенный список проверки 4.
# ------------------------------------------------------------------
CONSTRAINT_DROPS=(
    'DropIndex|migrationBuilder.DropIndex(name: "IX_Messages_SentAt", table: "Messages");'
    'DropForeignKey|migrationBuilder.DropForeignKey(name: "FK_Messages_Conversations", table: "Messages");'
    'DropPrimaryKey|migrationBuilder.DropPrimaryKey(name: "PK_Messages", table: "Messages");'
    'DropUniqueConstraint|migrationBuilder.DropUniqueConstraint(name: "AK_Messages_Key", table: "Messages");'
)

begin_case 'проверка 11: каждый из четырёх вызовов снятия ограничений схемы без метки — гейт падает и называет вызов'
for drop in "${CONSTRAINT_DROPS[@]}"; do
    IFS='|' read -r call_name call_line <<< "$drop"
    # Имя класса без Drop: иначе строка «public partial class …» сама совпала
    # бы с шаблоном и дала второе попадание.
    mig_name="Remove${call_name#Drop}"
    new_fixture
    put_migration "$repo" "$mig_name" "$call_line"
    commit_all "$repo" "feat: миграция $mig_name"
    run_guard "$repo" GUARD_ALLOW_PROTECTED=1
    expect_status 1
    expect_output 'Проверка 11: снятие ограничений схемы в миграции'
    mig_path="src/Domovoy.Data/Migrations/20260901120000_$mig_name.cs"
    call_at="$(migration_line "$repo" "$mig_name" "migrationBuilder.$call_name(")"
    expect_output "::error file=$mig_path,line=$call_at::"
    expect_output "    $mig_path:$call_at: "
    expect_output "$call_line"
    expect_no_output 'Проверка 4'
    expect_no_output 'Проверка 9'
done
end_case

begin_case 'проверка 11: снятие ограничений схемы с меткой agent/allow-destructive-migration — гейт пропускает'
# Без ожиданий раздела и строки «разрешено» сценарий остался бы зелёным при
# выключенной проверке: код 0 дала бы и пустая проверка.
for drop in "${CONSTRAINT_DROPS[@]}"; do
    IFS='|' read -r call_name call_line <<< "$drop"
    mig_name="Remove${call_name#Drop}"
    new_fixture
    put_migration "$repo" "$mig_name" "$call_line"
    commit_all "$repo" "feat: миграция $mig_name"
    run_guard "$repo" GUARD_ALLOW_PROTECTED=1 GUARD_ALLOW_DESTRUCTIVE_MIGRATION=1
    expect_status 0
    expect_output 'нарушений нет'
    expect_output 'Проверка 11: снятие ограничений схемы разрешено меткой agent/allow-destructive-migration'
    expect_output "разрешено: src/Domovoy.Data/Migrations/20260901120000_$mig_name.cs:$(migration_line "$repo" "$mig_name" "migrationBuilder.$call_name(")"
    expect_no_output 'Проверка 4'
done
end_case

begin_case 'проверка 11: создание индекса, внешнего и уникального ключа — гейт молчит'
# Материал держит границу шаблона: без Drop в альтернативах CreateIndex,
# AddForeignKey и AddUniqueConstraint совпали бы с ним.
new_fixture
put_migration "$repo" 'MessagesConstraints' \
    'migrationBuilder.CreateIndex(name: "IX_Messages_SentAt", table: "Messages", column: "SentAt");' \
    'migrationBuilder.AddForeignKey(name: "FK_Messages_Conversations", table: "Messages", column: "ConversationId", principalTable: "Conversations", principalColumn: "Id");' \
    'migrationBuilder.AddUniqueConstraint(name: "AK_Messages_Key", table: "Messages", column: "Key");'
commit_all "$repo" 'feat: индекс и ключи сообщений'
run_guard "$repo" GUARD_ALLOW_PROTECTED=1
expect_status 0
expect_output 'нарушений нет'
expect_no_output 'Проверка 11:'
expect_no_output 'Проверка 4'
expect_no_output 'Проверка 9'
end_case

# ------------------------------------------------------------------
# Разбор диффа: заголовок файла — только в зоне заголовка.
#
# В -U0 добавленная строка «++ x» выглядит как «+++ x». Шаблон заголовка на
# любой строке принимал её за имя файла, и следующие строки уходили мимо
# каталога миграций. Строка стоит в колонке 0, поэтому файл пишется heredoc'ом,
# а не put_migration: тот отступает каждую строку.
# ------------------------------------------------------------------
begin_case 'разбор диффа: строка «++ …» в содержимом не подменяет путь файла'
new_fixture
mkdir -p "$repo/src/Domovoy.Data/Migrations"
cat > "$repo/src/Domovoy.Data/Migrations/20260901120000_Plus.cs" <<'EOF'
namespace Domovoy.Data.Migrations;
++ x
migrationBuilder.Sql("DROP TABLE \"Legacy\";");
EOF
commit_all "$repo" 'feat: миграция с плюсами'
run_guard "$repo" GUARD_ALLOW_PROTECTED=1
expect_status 1
expect_output 'Проверка 9'
expect_output '::error file=src/Domovoy.Data/Migrations/20260901120000_Plus.cs,line=3::'
end_case

begin_case 'разбор диффа: удалённая строка «-- …» не подменяет путь файла'
# Зеркальный случай: удалённая «-- x» выглядит как «--- x», и удалённый следом
# [Fact] уходил бы в файл «x» вне tests/ — проверка 3 его не считала.
new_fixture
cat > "$repo/tests/Domovoy.Tests/MinusTests.cs" <<'EOF'
namespace Domovoy.Tests;
-- x
[Fact(DisplayName = "Пример")]
public void Example() { }
EOF
commit_all "$repo" 'test: пример'
git -C "$repo" branch -f base HEAD
printf 'namespace Domovoy.Tests;\npublic void Example() { }\n' > "$repo/tests/Domovoy.Tests/MinusTests.cs"
commit_all "$repo" 'test: пример короче'
run_guard "$repo"
expect_status 1
expect_output 'Проверка 3'
expect_output '::error file=tests/Domovoy.Tests/MinusTests.cs,line=3::'
end_case

begin_case 'разбор диффа: имя с кириллицей и пробелом — номер строки из файла, кавычек нет'
# Отказ по кавычкам (проверка 10) на таком имени молчит: core.quotepath=false
# не экранирует кириллицу, а пробел git в кавычки не берёт. Гейт, шумящий на
# обычном имени файла, перестают читать.
new_fixture
cat > "$repo/src/Domovoy.Api/Сводка дома.cs" <<'EOF'
namespace Domovoy.Api;

#pragma warning disable CS8618
EOF
commit_all "$repo" 'feat: сводка дома'
run_guard "$repo"
expect_status 1
expect_output 'Проверка 2'
expect_output '::error file=src/Domovoy.Api/Сводка дома.cs,line=3::'
expect_no_output 'git берёт в кавычки'
end_case

# ------------------------------------------------------------------
# Проверка 10. Путь, который git берёт в кавычки.
#
# Имена с «"» и табуляцией в рабочем дереве Windows не создаются, поэтому
# записи заводятся прямо в индекс: блоб через hash-object, путь через
# update-index. commit_all здесь не годится — его git add -A застейджил бы
# удаление записей, у которых нет файла в рабочем дереве.
# ------------------------------------------------------------------
put_index_file() {
    local target="$1" path="$2" content="$3" blob
    blob="$(printf '%s\n' "$content" | git -C "$target" hash-object -w --stdin)"
    git -C "$target" -c core.protectNTFS=false update-index --add \
        --cacheinfo "100644,$blob,$path"
}

commit_index() {
    git -C "$1" -c core.protectNTFS=false commit -qm "$2"
}

begin_case 'проверка 10: отчёт с кавычкой в имени — гейт падает'
new_fixture
put_index_file "$repo" 'TestResults/a"b.trx' '<TestRun />'
commit_index "$repo" 'test: отчёт прогона'
run_guard "$repo"
expect_status 1
expect_output 'Проверка 10'
expect_output 'git берёт в кавычки'
expect_output '"TestResults/a\"b.trx"'
end_case

begin_case 'проверка 10: отчёт с табуляцией в имени — гейт падает'
new_fixture
put_index_file "$repo" $'TestResults/c\tb.trx' '<TestRun />'
commit_index "$repo" 'test: отчёт прогона'
run_guard "$repo"
expect_status 1
expect_output 'Проверка 10'
expect_output '"TestResults/c\tb.trx"'
end_case

begin_case 'проверка 10: миграция с кавычкой в имени и DROP TABLE — гейт падает'
new_fixture
put_index_file "$repo" 'src/Domovoy.Data/Migrations/a"b.cs' 'migrationBuilder.Sql("DROP TABLE \"Legacy\";");'
commit_index "$repo" 'feat: миграция'
run_guard "$repo" GUARD_ALLOW_PROTECTED=1 GUARD_ALLOW_DESTRUCTIVE_MIGRATION=1
expect_status 1
expect_output 'Проверка 10'
expect_output '"src/Domovoy.Data/Migrations/a\"b.cs"'
end_case

begin_case 'проверка 10: защищённый путь с кавычкой в имени без метки — гейт падает'
# Без метки: до отказа по кавычкам этот PR проходил проверку 1 с кодом 0.
new_fixture
put_index_file "$repo" '.github/workflows/a"b.yml' 'name: build'
commit_index "$repo" 'ci: работа'
run_guard "$repo"
expect_status 1
expect_output 'Проверка 10'
expect_output '".github/workflows/a\"b.yml"'
end_case

begin_case 'проверка 10: путь в кавычках не снимается ни одной меткой'
run_guard "$repo" GUARD_ALLOW_PROTECTED=1 GUARD_ALLOW_CONTRACT=1 \
    GUARD_ALLOW_DESTRUCTIVE_MIGRATION=1
expect_status 1
expect_output 'Проверка 10'
expect_output 'Метки, снимающей эту проверку, нет'
end_case

begin_case 'проверка 10: старый путь переименования в кавычках — гейт падает'
# У --name-only при переименовании только новый путь; старый, под tests/,
# прячет удалённые [Fact] от проверки 3 через заголовок «--- ».
new_fixture
put_index_file "$repo" 'tests/Domovoy.Tests/a"b.cs' '[Fact(DisplayName = "Пример")]'
commit_index "$repo" 'test: пример'
git -C "$repo" branch -f base HEAD
git -C "$repo" -c core.protectNTFS=false update-index --force-remove 'tests/Domovoy.Tests/a"b.cs'
put_index_file "$repo" 'tests/Domovoy.Tests/Ab.cs' '[Fact(DisplayName = "Пример")]'
commit_index "$repo" 'test: имя без кавычки'
run_guard "$repo"
expect_status 1
expect_output 'Проверка 10'
expect_output '"tests/Domovoy.Tests/a\"b.cs"'
end_case

# ------------------------------------------------------------------
# Сценарий «запуск». Ошибка запуска: неизвестная база.
# ------------------------------------------------------------------
begin_case 'запуск: неизвестная база — код 2 и понятное сообщение'
new_fixture
GUARD_OUTPUT="$(cd "$repo" && bash "$GUARD" no/such/ref 2>&1)"
GUARD_STATUS=$?
expect_status 2
expect_output 'Неизвестная ревизия'
end_case

# ------------------------------------------------------------------
# Итог
# ------------------------------------------------------------------
printf '\n==================================================\n'
printf 'Сценариев пройдено: %s, провалено: %s, пропущено: %s\n' \
    "$PASSED" "$FAILED" "$SKIPPED"
if [ "$FAILED" -ne 0 ]; then
    printf 'Провалились:\n'
    for name in "${FAILED_NAMES[@]}"; do
        printf '  - %s\n' "$name"
    done
    exit 1
fi
printf 'Гейт целостности ведёт себя как задумано.\n'
exit 0
