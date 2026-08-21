#!/usr/bin/env bash
#
# Домовой — проверочные сценарии для гейта целостности scripts/guard.sh.
#
# ЗАЧЕМ
#
# Гейт, который никто не проверял, — это не гейт, а надежда. Здесь для
# каждой из шести проверок собирается временный git-репозиторий, в нём
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
# Сценарий 7. Ошибка запуска: неизвестная база.
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
