#!/usr/bin/env bash
#
# Домовой — проверочные сценарии для scripts/guard-lite.sh.
#
# Каждый сценарий строит временный git-репозиторий (mktemp), коммитит базу и
# одну правку и запускает гейт на диапазоне base..HEAD. Фикстуры живут
# здесь же, инлайн: отдельный .cs с подавлением в дереве гейт видел бы как
# настоящее подавление.
#
# Красный сценарий проверяет код 1 и строку «файл:строка: правило» — иначе
# он зеленел бы от постороннего срабатывания. Зелёные сценарии доказывают
# фильтры: только добавленные строки, только файлы кода, граница Down().
#
#   bash scripts/guard-lite.test.sh
#
# Код возврата: 0 — все сценарии прошли, 1 — есть провалившиеся.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GUARD="$SCRIPT_DIR/guard-lite.sh"
[ -f "$GUARD" ] || { printf 'Не найден %s\n' "$GUARD" >&2; exit 2; }

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/no-hooks"

PASSED=0
FAILED=0
FAILED_NAMES=()
CASE_NAME=''
CASE_OK=1
OUTPUT=''
STATUS=0
SEQ=0
repo=''

begin_case() {
    CASE_NAME="$1"; CASE_OK=1; OUTPUT=''; STATUS=0
    printf '\n[ ... ] %s\n' "$CASE_NAME"
    new_fixture
}

fail_case() { CASE_OK=0; printf '        ! %s\n' "$1"; }

end_case() {
    if [ "$CASE_OK" -eq 1 ]; then
        PASSED=$((PASSED + 1)); printf '[ ok  ] %s\n' "$CASE_NAME"
    else
        FAILED=$((FAILED + 1)); FAILED_NAMES+=("$CASE_NAME")
        printf '[ FAIL] %s\n' "$CASE_NAME"
        printf '%s\n' "$OUTPUT" | sed 's/^/        | /'
    fi
}

# Репозиторий с базой: конфигурация сборки, .editorconfig с уже стоящим
# severity = none, workflow с уже стоящим continue-on-error, файл тестов,
# сценарий оболочки и документ. Ветка base — точка сравнения.
new_fixture() {
    SEQ=$((SEQ + 1))
    repo="$SANDBOX/repo-$SEQ"
    mkdir -p "$repo"
    git init -q -b main "$repo"
    git -C "$repo" config user.email 'guard-lite@example.invalid'
    git -C "$repo" config user.name 'Guard Lite'
    git -C "$repo" config commit.gpgsign false
    git -C "$repo" config core.autocrlf false
    git -C "$repo" config core.hooksPath "$SANDBOX/no-hooks"
    mkdir -p "$repo/src/Domovoy.Data/Migrations" "$repo/tests/Domovoy.Tests" \
        "$repo/.github/workflows" "$repo/scripts" "$repo/docs"

    cat > "$repo/Directory.Build.props" <<'EOF'
<Project>
  <PropertyGroup>
    <TreatWarningsAsErrors>true</TreatWarningsAsErrors>
    <AnalysisLevel>latest</AnalysisLevel>
  </PropertyGroup>
</Project>
EOF
    cat > "$repo/.editorconfig" <<'EOF'
root = true

[*.cs]
indent_size = 4
dotnet_diagnostic.CA1848.severity = none
EOF
    cat > "$repo/.github/workflows/old.yml" <<'EOF'
name: old
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    continue-on-error: true
    steps:
      - run: dotnet test --filter "Category!=Slow"
EOF
    cat > "$repo/tests/Domovoy.Tests/HealthTests.cs" <<'EOF'
namespace Domovoy.Tests;

public sealed class HealthTests
{
    [Fact(DisplayName = "Анонимный /health отвечает")]
    public void Answers()
    {
    }

    [Theory(DisplayName = "Пустой секрет — не сконфигурировано")]
    [InlineData("")]
    public void NotConfigured(string value)
    {
    }
}
EOF
    printf '#!/usr/bin/env bash\necho ok\n' > "$repo/scripts/old.test.sh"
    printf '# Правила\n\nПодавление Skip = "…" запрещено.\n' > "$repo/docs/rules.md"
    git -C "$repo" add -A
    git -C "$repo" commit -qm 'chore: база'
    git -C "$repo" branch -q base
}

commit_all() {
    git -C "$repo" add -A
    git -C "$repo" commit -qm 'change' --allow-empty
}

run_guard() {
    commit_all
    OUTPUT="$(cd "$repo" && bash "$GUARD" base HEAD 2>&1)"
    STATUS=$?
}

expect_status() { [ "$STATUS" -eq "$1" ] || fail_case "код возврата $STATUS, ожидался $1"; }
expect_output() { printf '%s' "$OUTPUT" | grep -qF -- "$1" || fail_case "в выводе нет: $1"; }
expect_no_output() { ! printf '%s' "$OUTPUT" | grep -qF -- "$1" || fail_case "в выводе лишнее: $1"; }

# Красный сценарий: код 1 и строка нарушения.
expect_red() { expect_status 1; expect_output "$1"; }
expect_green() { expect_status 0; expect_output 'нарушений нет'; }

# Миграция: строка 9 — тело Up(), строка 14 — тело Down().
migration() { migration_at "src/Domovoy.Data/Migrations/${3:-20260101000000_Step}.cs" "$1" "$2"; }
migration_at() {
    local path="$1"; shift
    mkdir -p "$repo/$(dirname "$path")"
    cat > "$repo/$path" <<EOF
using Microsoft.EntityFrameworkCore.Migrations;

namespace Domovoy.Data.Migrations;

public partial class Step : Migration
{
    protected override void Up(MigrationBuilder migrationBuilder)
    {
        $1
    }

    protected override void Down(MigrationBuilder migrationBuilder)
    {
        $2
    }
}
EOF
}
MIG='src/Domovoy.Data/Migrations/20260101000000_Step.cs'

# Добавленная строка в новом файле кода: строка 2 файла.
add_line() {
    mkdir -p "$repo/$(dirname "$1")"
    printf '// шапка\n%s\n' "$2" > "$repo/$1"
}

# ------------------------------------------------------------------
# Красные: обязательные из критерия приёмки
# ------------------------------------------------------------------
begin_case 'Skip = в тесте краснеет'
sed -i 's/\[Fact(DisplayName = "Анонимный \/health отвечает")\]/[Fact(DisplayName = "Анонимный \/health отвечает", Skip = "мешает")]/' \
    "$repo/tests/Domovoy.Tests/HealthTests.cs"
run_guard
expect_red 'tests/Domovoy.Tests/HealthTests.cs:5: подавление: Skip ='
end_case

begin_case 'severity = none в .editorconfig краснеет'
printf 'dotnet_diagnostic.CA2007.severity = none\n' >> "$repo/.editorconfig"
run_guard
expect_red '.editorconfig:6: подавление: severity = none'
expect_no_output '.editorconfig:5:'
end_case

begin_case 'DropColumn в Up() краснеет'
migration 'migrationBuilder.DropColumn(name: "Name", table: "Rooms");' ''
run_guard
expect_red "$MIG:9: разрушительная миграция: DropColumn"
end_case

begin_case 'migrationBuilder.Sql("DELETE …") краснеет'
migration 'migrationBuilder.Sql("DELETE FROM rooms WHERE 1 = 1;");' ''
run_guard
expect_red "$MIG:9: сырой SQL в миграции: DELETE или TRUNCATE"
end_case

begin_case 'migrationBuilder.Sql("CREATE TABLE …") без IF NOT EXISTS краснеет'
migration 'migrationBuilder.Sql("CREATE TABLE rooms (id int);");' ''
run_guard
expect_red "$MIG:9: сырой SQL в миграции: CREATE TABLE или ADD COLUMN без IF NOT EXISTS"
end_case

begin_case '*.trx в любом каталоге краснеет'
mkdir -p "$repo/deep/nested"; printf '<TestRun/>\n' > "$repo/deep/nested/run.trx"
run_guard
expect_red 'deep/nested/run.trx:1: мусор прогона'
end_case

begin_case '*.keystore в любом каталоге краснеет'
mkdir -p "$repo/any/where"; printf 'key\n' > "$repo/any/where/release.keystore"
run_guard
expect_red 'any/where/release.keystore:1: подпись или ключ платформы'
end_case

# ------------------------------------------------------------------
# Красные: остальные пункты списка, по одному
# ------------------------------------------------------------------
check_suppression() {
    begin_case "$3 краснеет${4:+ в $4}"
    add_line "$1" "$2"
    run_guard
    expect_red "$1:2: подавление: $3"
    end_case
}
check_suppression 'src/Domovoy.Api/A.cs' '#pragma warning disable CA2000' '#pragma warning disable'
check_suppression 'tests/Domovoy.Tests/B.cs' '[Ignore("мешает")]' '[Ignore]'
check_suppression 'src/Domovoy.Api/C.cs' '[ExcludeFromCodeCoverage]' '[ExcludeFromCodeCoverage]'
check_suppression 'src/Domovoy.Api/D.cs' '[SuppressMessage("Design", "CA1031")]' '[SuppressMessage]'
check_suppression 'src/Domovoy.Api/Api.csproj' '<NoWarn>$(NoWarn);CA2000</NoWarn>' 'NoWarn'
check_suppression 'build/x.props' '<WarningsNotAsErrors>CA2000</WarningsNotAsErrors>' 'WarningsNotAsErrors'
check_suppression 'build/y.targets' '<TreatWarningsAsErrors>false</TreatWarningsAsErrors>' 'TreatWarningsAsErrors=false'
check_suppression 'build/z.props' '<EnforceCodeStyleInBuild>false</EnforceCodeStyleInBuild>' 'EnforceCodeStyleInBuild=false'
check_suppression '.github/workflows/new.yml' '    continue-on-error: true' 'continue-on-error'
check_suppression '.github/workflows/f.yml' '      - run: dotnet test --filter "FullyQualifiedName!~Slow"' '--filter с отрицанием'

# Типы файлов из п.10 #133.
check_suppression '.github/workflows/new.yaml' '    continue-on-error: true' 'continue-on-error' '*.yaml'
check_suppression 'Directory.Build.rsp' '-p:TreatWarningsAsErrors=false' 'TreatWarningsAsErrors=false' '*.rsp'
check_suppression 'tests/ci.runsettings' '    <TestCaseFilter>Category!=Slow</TestCaseFilter>' 'TestCaseFilter с отрицанием' '*.runsettings'

begin_case 'severity = none в .globalconfig краснеет'
add_line '.globalconfig' 'dotnet_diagnostic.CA2000.severity = none'
run_guard
expect_red '.globalconfig:2: подавление: severity = none'
end_case

begin_case 'Понижение AnalysisLevel краснеет'
sed -i 's|<AnalysisLevel>latest</AnalysisLevel>|<AnalysisLevel>5.0</AnalysisLevel>|' "$repo/Directory.Build.props"
run_guard
expect_red 'Directory.Build.props:4: подавление: понижение AnalysisLevel до «5.0»'
end_case

begin_case 'AnalysisLevelSecurity = 5.0 краснеет'
add_line 'build/a.props' '<AnalysisLevelSecurity>5.0</AnalysisLevelSecurity>'
run_guard
expect_red 'build/a.props:2: подавление: понижение AnalysisLevelSecurity до «5.0»'
end_case

begin_case 'AnalysisLevel с атрибутом Condition = 5.0 краснеет'
add_line 'build/b.props' '<AnalysisLevel Condition="true">5.0</AnalysisLevel>'
run_guard
expect_red 'build/b.props:2: подавление: понижение AnalysisLevel до «5.0»'
end_case

begin_case 'Skip = с причиной-константой в многострочном атрибуте краснеет'
add_line 'tests/Domovoy.Tests/C.cs' '    Skip = Reasons.Slow)]'
run_guard
expect_red 'tests/Domovoy.Tests/C.cs:2: подавление: Skip ='
end_case

begin_case 'Skip = в продуктовом коде краснеет — названный предел шапки'
add_line 'src/Domovoy.Api/Page.cs' '    var page = new Page { Skip = offset };'
run_guard
expect_red 'src/Domovoy.Api/Page.cs:2: подавление: Skip ='
end_case

begin_case 'Правка *.ruleset краснеет'
add_line 'build/rules.ruleset' '<RuleSet Name="r" />'
run_guard
expect_red 'build/rules.ruleset:1: подавление: правка *.ruleset'
end_case

begin_case 'Удалённый тестовый метод краснеет'
sed -i '5,8d' "$repo/tests/Domovoy.Tests/HealthTests.cs"
run_guard
expect_red 'tests/Domovoy.Tests/HealthTests.cs:5: удалён тестовый метод'
end_case

begin_case 'Тестовый файл, переименованный в не-код, — удалённые тесты'
git -C "$repo" mv tests/Domovoy.Tests/HealthTests.cs tests/Domovoy.Tests/HealthTests.cs.txt
run_guard
expect_red 'tests/Domovoy.Tests/HealthTests.cs:10: удалён тестовый метод'
end_case

# Удалённый или вынесенный из tests/ файл *.cs (п.6 #133) — нарушение сам по
# себе, без баланса атрибутов. Добавленный файл непохож на удалённый, чтобы
# git не свёл их в переименование.
other_tests() {
    mkdir -p "$repo/$(dirname "$1")"
    cat > "$repo/$1" <<'EOF'
using System.Globalization;

namespace Domovoy.Tests.Formatting;

internal static class NumberFormatChecks
{
    [Fact]
    internal static void InvariantDecimalSeparator() =>
        Assert.Equal("1.5", 1.5m.ToString(CultureInfo.InvariantCulture));

    [Theory]
    [InlineData(42)]
    internal static void RoundTrip(int value) =>
        Assert.Equal(value, int.Parse(value.ToString(CultureInfo.InvariantCulture), CultureInfo.InvariantCulture));
}
EOF
}
REMOVED_RULE='удалён или вынесен из tests/'

begin_case 'Удалённый *.cs под tests/ краснеет при равном балансе атрибутов'
git -C "$repo" rm -q tests/Domovoy.Tests/HealthTests.cs
other_tests 'tests/Domovoy.Tests/NumberFormatChecks.cs'
run_guard
expect_red "tests/Domovoy.Tests/HealthTests.cs:1: $REMOVED_RULE"
expect_no_output 'NumberFormatChecks.cs:1:'
end_case

begin_case 'Тестовый файл, вынесенный из tests/ в другой каталог кода, краснеет'
mkdir -p "$repo/src/Domovoy.Api"
git -C "$repo" mv tests/Domovoy.Tests/HealthTests.cs src/Domovoy.Api/HealthTests.cs
run_guard
expect_red "tests/Domovoy.Tests/HealthTests.cs:1: $REMOVED_RULE"
expect_output 'src/Domovoy.Api/HealthTests.cs'
end_case

begin_case 'Переименование тестового файла внутри tests/ зеленеет'
mkdir -p "$repo/tests/Domovoy.Api.Tests"
git -C "$repo" mv tests/Domovoy.Tests/HealthTests.cs tests/Domovoy.Api.Tests/HealthEndpointTests.cs
run_guard
expect_green
end_case

begin_case 'Переименование *.cs внутри tests/ с переписыванием большей части краснеет — осознанно'
git -C "$repo" mv tests/Domovoy.Tests/HealthTests.cs tests/Domovoy.Tests/NumberFormatChecks.cs
other_tests 'tests/Domovoy.Tests/NumberFormatChecks.cs'
run_guard
expect_red "tests/Domovoy.Tests/HealthTests.cs:1: $REMOVED_RULE"
end_case

begin_case 'Файл тестов, переименованный в tests/ в не-*.cs, — вынесен из тестового кода'
git -C "$repo" mv tests/Domovoy.Tests/HealthTests.cs tests/Domovoy.Tests/HealthTests.cs.txt
run_guard
expect_red "tests/Domovoy.Tests/HealthTests.cs:1: $REMOVED_RULE файл тестов (перенесён в tests/Domovoy.Tests/HealthTests.cs.txt)"
end_case

begin_case 'Удаление нетестового файла под tests/ зеленеет'
printf '{ "rooms": [] }\n' > "$repo/tests/Domovoy.Tests/rooms.json"
commit_all; git -C "$repo" branch -qf base HEAD
git -C "$repo" rm -q tests/Domovoy.Tests/rooms.json
run_guard
expect_green
end_case

for api in DropTable RenameColumn RenameTable AlterColumn DropIndex DropForeignKey \
    DropPrimaryKey DropUniqueConstraint AddPrimaryKey; do
    begin_case "$api в Up() краснеет"
    migration "migrationBuilder.$api(name: \"X\", table: \"Rooms\");" ''
    run_guard
    expect_red "$MIG:9: разрушительная миграция: $api"
    end_case
done

check_sql() {
    begin_case "SQL «$2» краснеет"
    migration "migrationBuilder.Sql(\"$1\");" ''
    run_guard
    expect_red "$MIG:9: сырой SQL в миграции: $2"
    end_case
}
check_sql 'TRUNCATE rooms;' 'DELETE или TRUNCATE'
check_sql 'DROP TABLE rooms;' 'DROP без IF EXISTS'
check_sql 'DROP TABLE a; DROP TABLE IF EXISTS b;' 'DROP без IF EXISTS'
check_sql 'LOCK TABLE rooms IN ACCESS EXCLUSIVE MODE;' 'ACCESS EXCLUSIVE'
check_sql 'ALTER TABLE rooms ADD CONSTRAINT pk PRIMARY KEY (id);' 'ADD CONSTRAINT … PRIMARY KEY'
check_sql 'ALTER TABLE rooms ADD COLUMN floor int;' 'CREATE TABLE или ADD COLUMN без IF NOT EXISTS'

begin_case 'DropColumn во вложенном каталоге Migrations краснеет'
NESTED='src/Domovoy.Data/Migrations/2026/20260101000000_Step.cs'
migration_at "$NESTED" 'migrationBuilder.DropColumn(name: "Name", table: "Rooms");' ''
run_guard
expect_red "$NESTED:9: разрушительная миграция: DropColumn"
end_case

begin_case 'DROP TABLE в SQL-файле миграции краснеет'
add_line 'src/Domovoy.Data/Migrations/Sql/001_drop.sql' 'DROP TABLE rooms;'
run_guard
expect_red 'src/Domovoy.Data/Migrations/Sql/001_drop.sql:2: сырой SQL в миграции: DROP без IF EXISTS'
end_case

begin_case 'DROP TABLE IF EXISTS в SQL-файле миграции зеленеет'
add_line 'src/Domovoy.Data/Migrations/Sql/001_drop.sql' 'DROP TABLE IF EXISTS rooms;'
run_guard
expect_green
end_case

begin_case 'SQL-файл миграции проверяется только правилами миграций'
add_line 'src/Domovoy.Data/Migrations/Sql/002_note.sql' '-- NoWarn и Skip = в комментарии SQL — не подавление сборки'
run_guard
expect_green
end_case

check_junk() {
    begin_case "$1 краснеет"
    mkdir -p "$repo/$(dirname "$1")"; printf 'x\n' > "$repo/$1"
    run_guard
    expect_red "$1:1: $2"
    end_case
}
check_junk 'tests/Domovoy.Tests/TestResults/abc/coverage.cobertura.xml' 'мусор прогона'
check_junk 'out/coverage.json' 'мусор прогона'
check_junk 'coverage.cobertura.xml' 'мусор прогона'
check_junk 'out/coverage.info' 'мусор прогона'
check_junk 'out/Coverage-report.XML' 'мусор прогона'
check_junk 'out/run.coverage' 'мусор прогона'
check_junk 'out/run.coveragexml' 'мусор прогона'
check_junk 'coverage/lcov-report/index.html' 'мусор прогона'
check_junk 'tests/Domovoy.Tests/Coverage/a/b/report.html' 'мусор прогона'
check_junk 'out/CoverageReport/index.htm' 'мусор прогона'
check_junk 'certs/dev.p12' 'подпись или ключ платформы'
check_junk 'ios/App.mobileprovision' 'подпись или ключ платформы'
check_junk 'android/app/google-services.json' 'подпись или ключ платформы'
check_junk 'src/Domovoy.Mobile.App/Platforms/iOS/GoogleService-Info.plist' 'подпись или ключ платформы'
check_junk 'отчёты/прогон.trx' 'мусор прогона'

# ------------------------------------------------------------------
# Зелёные: фильтры
# ------------------------------------------------------------------
begin_case 'Чистый дифф зеленеет'
add_line 'src/Domovoy.Api/Formatter.cs' 'public static class Formatter { }'
run_guard
expect_green
end_case

begin_case 'Файл кода Coverage*.cs зеленеет'
add_line 'tests/Domovoy.Tests/CoverageGateTests.cs' 'public sealed class CoverageGateTests { }'
run_guard
expect_green
end_case

begin_case 'Каталог Coverage.Tests/ — не каталог отчётов, зеленеет'
add_line 'tests/Coverage.Tests/CoverageGateTests.cs' 'public sealed class CoverageGateTests { }'
run_guard
expect_green
end_case

begin_case 'DropTable в Down() зеленеет'
migration 'migrationBuilder.CreateTable(name: "Rooms", columns: t => new { Id = t.Column<int>() });' \
    'migrationBuilder.DropTable(name: "Rooms");'
run_guard
expect_green
end_case

begin_case 'DropTable и в Up(), и в Down(): в выводе только Up()'
migration 'migrationBuilder.DropTable(name: "Old");' 'migrationBuilder.DropTable(name: "Rooms");'
run_guard
expect_red "$MIG:9: разрушительная миграция: DropTable"
expect_no_output "$MIG:14:"
end_case

# ------------------------------------------------------------------
# Граница Down() (п.9 #133): комментарии и литералы не сдвигают её, а форма,
# которую разметка не разбирает, — красный «граница не определена», а не
# молчаливый пропуск. Файл миграции целиком — из stdin, номера строк явные.
# ------------------------------------------------------------------
mig_file() { cat > "$repo/$MIG"; }
BOUNDARY='граница Down() не определена'

begin_case 'Down(): комментарий не сдвигает границу'
mig_file <<'EOF'
using Microsoft.EntityFrameworkCore.Migrations;

namespace Domovoy.Data.Migrations;

public partial class Step : Migration
{
    protected override void Up(MigrationBuilder migrationBuilder)
    {
        // откат — в void Down(MigrationBuilder migrationBuilder)
        migrationBuilder.DropColumn(name: "Name", table: "Rooms");
    }

    protected override void Down(MigrationBuilder migrationBuilder)
    {
    }
}
EOF
run_guard
expect_red "$MIG:10: разрушительная миграция: DropColumn"
end_case

begin_case 'Down(): блочный комментарий со скобкой не сдвигает границу'
mig_file <<'EOF'
using Microsoft.EntityFrameworkCore.Migrations;

namespace Domovoy.Data.Migrations;

public partial class Step : Migration
{
    protected override void Down(MigrationBuilder migrationBuilder)
    {
        /* прежняя схема:
           { "rooms": [ */
    }

    protected override void Up(MigrationBuilder migrationBuilder)
    {
        migrationBuilder.DropColumn(name: "Name", table: "Rooms");
    }
}
EOF
run_guard
expect_red "$MIG:15: разрушительная миграция: DropColumn"
end_case

# Down() перед Up(); строка 9 — тело Down(), строка 14 — тело Up().
down_first() {
    mig_file <<EOF
using Microsoft.EntityFrameworkCore.Migrations;

namespace Domovoy.Data.Migrations;

public partial class Step : Migration
{
    protected override void Down(MigrationBuilder migrationBuilder)
    {
        $1
    }

    protected override void Up(MigrationBuilder migrationBuilder)
    {
        migrationBuilder.DropColumn(name: "Name", table: "Rooms");
    }
}
EOF
}

begin_case 'Down(): строковый литерал не сдвигает границу'
down_first 'migrationBuilder.Sql("UPDATE rooms SET meta = '"'"'{'"'"', note = \"}{\";");'
run_guard
expect_red "$MIG:14: разрушительная миграция: DropColumn"
expect_no_output "$BOUNDARY"
end_case

begin_case 'Down(): символьный литерал со скобкой не сдвигает границу'
down_first "var open = '{'; var quote = '\\''; var slash = '\\\\'; var brace = '{';"
run_guard
expect_red "$MIG:14: разрушительная миграция: DropColumn"
expect_no_output "$BOUNDARY"
end_case

begin_case 'Down(): verbatim с обратной косой в конце не сдвигает границу'
down_first 'migrationBuilder.Sql(@"C:\"); migrationBuilder.Sql("{");'
run_guard
expect_red "$MIG:14: разрушительная миграция: DropColumn"
expect_no_output "$BOUNDARY"
end_case

begin_case 'Down(): тело-выражение размечается'
mig_file <<'EOF'
using Microsoft.EntityFrameworkCore.Migrations;

namespace Domovoy.Data.Migrations;

public partial class Step : Migration
{
    protected override void Up(MigrationBuilder migrationBuilder) =>
        migrationBuilder.CreateTable(name: "Rooms", columns: t => new { Id = t.Column<int>() });

    protected override void Down(MigrationBuilder migrationBuilder) =>
        migrationBuilder.DropTable(name: "Rooms");
}
EOF
run_guard
expect_green
end_case

begin_case 'Незакрытый Down() краснеет: граница не определена'
mig_file <<'EOF'
using Microsoft.EntityFrameworkCore.Migrations;

namespace Domovoy.Data.Migrations;

public partial class Step : Migration
{
    protected override void Up(MigrationBuilder migrationBuilder)
    {
    }

    protected override void Down(MigrationBuilder migrationBuilder)
    {
        migrationBuilder.DropTable(name: "Rooms");
EOF
run_guard
expect_red "$MIG:11: $BOUNDARY: Down() не закрыт до конца файла"
end_case

begin_case 'Два заголовка Down() в файле краснеют: граница не определена'
mig_file <<'EOF'
using Microsoft.EntityFrameworkCore.Migrations;

namespace Domovoy.Data.Migrations;

public partial class Step : Migration
{
    protected override void Down(MigrationBuilder migrationBuilder)
    {
    }

    protected override void Down(MigrationBuilder migrationBuilder)
    {
    }
}
EOF
run_guard
expect_red "$MIG:11: $BOUNDARY: заголовков Down() больше одного"
end_case

begin_case 'Заголовок Up() внутри Down() краснеет: граница не определена'
mig_file <<'EOF'
using Microsoft.EntityFrameworkCore.Migrations;

namespace Domovoy.Data.Migrations;

public partial class Step : Migration
{
    protected override void Down(MigrationBuilder migrationBuilder)
    {
        migrationBuilder.DropTable(name: "Rooms");

    protected override void Up(MigrationBuilder migrationBuilder)
    {
        migrationBuilder.DropColumn(name: "Name", table: "Rooms");
    }
}
EOF
run_guard
expect_red "$MIG:11: $BOUNDARY: заголовок Up() внутри Down()"
expect_output "$MIG:13: разрушительная миграция: DropColumn"
end_case

begin_case 'Лишняя закрывающая скобка краснеет: граница не определена'
mig_file <<'EOF'
using Microsoft.EntityFrameworkCore.Migrations;

namespace Domovoy.Data.Migrations;

public partial class Step : Migration
{
    protected override void Up(MigrationBuilder migrationBuilder)
    {
    }
}
}

    protected override void Down(MigrationBuilder migrationBuilder)
    {
    }
EOF
run_guard
expect_red "$MIG:11: $BOUNDARY: глубина скобок ушла в минус"
end_case

begin_case 'Многострочный литерал в Down() краснеет: граница не определена'
mig_file <<'EOF'
using Microsoft.EntityFrameworkCore.Migrations;

namespace Domovoy.Data.Migrations;

public partial class Step : Migration
{
    protected override void Up(MigrationBuilder migrationBuilder)
    {
    }

    protected override void Down(MigrationBuilder migrationBuilder)
    {
        migrationBuilder.Sql(@"
            UPDATE rooms SET floor = 0;
        ");
    }
}
EOF
run_guard
expect_red "$MIG:13: $BOUNDARY: многострочный литерал"
end_case

begin_case 'Down(): интерполированная строка — граница не определена'
mig_file <<'EOF'
using Microsoft.EntityFrameworkCore.Migrations;

namespace Domovoy.Data.Migrations;

public partial class Step : Migration
{
    protected override void Up(MigrationBuilder migrationBuilder)
    {
        var table = "rooms";
        migrationBuilder.Sql($"UPDATE \"{table}\" SET floor = 0;");
    }

    protected override void Down(MigrationBuilder migrationBuilder)
    {
    }
}
EOF
run_guard
expect_red "$MIG:10: $BOUNDARY: интерполированная строка"
end_case

begin_case 'Down(): raw string — граница не определена'
mig_file <<'EOF'
using Microsoft.EntityFrameworkCore.Migrations;

namespace Domovoy.Data.Migrations;

public partial class Step : Migration
{
    protected override void Up(MigrationBuilder migrationBuilder)
    {
        migrationBuilder.Sql("""UPDATE rooms SET floor = 0;""");
    }

    protected override void Down(MigrationBuilder migrationBuilder)
    {
    }
}
EOF
run_guard
expect_red "$MIG:9: $BOUNDARY: raw string"
end_case

begin_case 'Интерполированная строка в файле без Down() зеленеет'
add_line 'src/Domovoy.Data/Migrations/Helper.cs' '    var sql = $"UPDATE \"{table}\" SET floor = 0;";'
run_guard
expect_green
end_case

begin_case 'Сырой DELETE в Down() зеленеет'
migration 'migrationBuilder.Sql("INSERT INTO rooms VALUES (1);");' 'migrationBuilder.Sql("DELETE FROM rooms;");'
run_guard
expect_green
end_case

begin_case 'Идемпотентный SQL в Up() зеленеет'
migration 'migrationBuilder.Sql("CREATE TABLE IF NOT EXISTS rooms (id int); DROP TABLE IF EXISTS old;");' \
    'migrationBuilder.Sql("ALTER TABLE rooms ADD COLUMN IF NOT EXISTS floor int;");'
run_guard
expect_green
end_case

# ------------------------------------------------------------------
# Сгенерированная EF миграция (п.7 #133). Содержимое — вывод настоящего
# dotnet ef migrations add (dotnet-ef 8.0.26, Npgsql.EntityFrameworkCore.
# PostgreSQL и EF Core Design 8.0.11): Initial с одной строкой seed, затем
# SeedRooms с несколькими. Урезано до значимых строк; имя контекста приведено
# к проекту. EF пишет UTF-8 с BOM — BOM сохранён; переводы строк — LF, как
# *.cs лежит в репозитории по .gitattributes. Директиву ставят Designer,
# ModelSnapshot и, при seed из нескольких строк, сам файл миграции (CA1814).
# Аргумент — тело Down() файла Initial после DropTable.
# ------------------------------------------------------------------
EF_DIR='src/Domovoy.Data/Migrations'
ef_generated() {
    local dir="$repo/$EF_DIR"
    mkdir -p "$dir"
    printf '\xEF\xBB\xBF' > "$dir/20261007164442_Initial.cs"
    cat >> "$dir/20261007164442_Initial.cs" <<EOF
using Microsoft.EntityFrameworkCore.Migrations;
using Npgsql.EntityFrameworkCore.PostgreSQL.Metadata;

#nullable disable

namespace Domovoy.Data.Migrations
{
    /// <inheritdoc />
    public partial class Initial : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.CreateTable(
                name: "Rooms",
                columns: table => new
                {
                    Id = table.Column<int>(type: "integer", nullable: false)
                        .Annotation("Npgsql:ValueGenerationStrategy", NpgsqlValueGenerationStrategy.IdentityByDefaultColumn),
                    Name = table.Column<string>(type: "text", nullable: false)
                },
                constraints: table =>
                {
                    table.PrimaryKey("PK_Rooms", x => x.Id);
                });

            migrationBuilder.InsertData(
                table: "Rooms",
                columns: new[] { "Id", "Name" },
                values: new object[] { 1, "Kitchen" });
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {${1:+
            $1
}
            migrationBuilder.DropTable(
                name: "Rooms");
        }
    }
}
EOF
    printf '\xEF\xBB\xBF' > "$dir/20261007164442_Initial.Designer.cs"
    cat >> "$dir/20261007164442_Initial.Designer.cs" <<'EOF'
// <auto-generated />
using Domovoy.Data;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Migrations;
using Microsoft.EntityFrameworkCore.Storage.ValueConversion;
using Npgsql.EntityFrameworkCore.PostgreSQL.Metadata;

#nullable disable

namespace Domovoy.Data.Migrations
{
    [DbContext(typeof(DomovoyDbContext))]
    [Migration("20261007164442_Initial")]
    partial class Initial
    {
        /// <inheritdoc />
        protected override void BuildTargetModel(ModelBuilder modelBuilder)
        {
#pragma warning disable 612, 618
            modelBuilder
                .HasAnnotation("ProductVersion", "8.0.11")
                .HasAnnotation("Relational:MaxIdentifierLength", 63);

            NpgsqlModelBuilderExtensions.UseIdentityByDefaultColumns(modelBuilder);

            modelBuilder.Entity("Domovoy.Data.Room", b =>
                {
                    b.Property<int>("Id")
                        .ValueGeneratedOnAdd()
                        .HasColumnType("integer");

                    b.HasKey("Id");

                    b.ToTable("Rooms");

                    b.HasData(
                        new
                        {
                            Id = 1,
                            Name = "Kitchen"
                        });
                });
#pragma warning restore 612, 618
        }
    }
}
EOF
    printf '\xEF\xBB\xBF' > "$dir/DomovoyDbContextModelSnapshot.cs"
    cat >> "$dir/DomovoyDbContextModelSnapshot.cs" <<'EOF'
// <auto-generated />
using Domovoy.Data;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Storage.ValueConversion;
using Npgsql.EntityFrameworkCore.PostgreSQL.Metadata;

#nullable disable

namespace Domovoy.Data.Migrations
{
    [DbContext(typeof(DomovoyDbContext))]
    partial class DomovoyDbContextModelSnapshot : ModelSnapshot
    {
        protected override void BuildModel(ModelBuilder modelBuilder)
        {
#pragma warning disable 612, 618
            modelBuilder
                .HasAnnotation("ProductVersion", "8.0.11")
                .HasAnnotation("Relational:MaxIdentifierLength", 63);

            modelBuilder.Entity("Domovoy.Data.Room", b =>
                {
                    b.Property<int>("Id")
                        .ValueGeneratedOnAdd()
                        .HasColumnType("integer");

                    b.HasKey("Id");

                    b.ToTable("Rooms");
                });
#pragma warning restore 612, 618
        }
    }
}
EOF
    printf '\xEF\xBB\xBF' > "$dir/20261007164500_SeedRooms.cs"
    cat >> "$dir/20261007164500_SeedRooms.cs" <<'EOF'
using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

#pragma warning disable CA1814 // Prefer jagged arrays over multidimensional

namespace Domovoy.Data.Migrations
{
    /// <inheritdoc />
    public partial class SeedRooms : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.InsertData(
                table: "Rooms",
                columns: new[] { "Id", "Name" },
                values: new object[,]
                {
                    { 2, "Hall" },
                    { 3, "Bedroom" }
                });
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DeleteData(
                table: "Rooms",
                keyColumn: "Id",
                keyValue: 2);

            migrationBuilder.DeleteData(
                table: "Rooms",
                keyColumn: "Id",
                keyValue: 3);
        }
    }
}
EOF
}

begin_case 'Сгенерированная EF миграция (Initial, Designer, ModelSnapshot) зеленеет'
ef_generated ''
run_guard
expect_green
end_case

begin_case 'Сгенерированная EF миграция с однострочным SQL в Down() зеленеет'
ef_generated 'migrationBuilder.Sql("DELETE FROM \"Rooms\" WHERE \"Id\" = 1;");'
run_guard
expect_green
end_case

begin_case '#pragma warning disable в Migrations/ вне src/Domovoy.Data краснеет'
add_line 'src/Legacy/Migrations/20260101000000_Step.cs' '#pragma warning disable CA1814'
run_guard
expect_red 'src/Legacy/Migrations/20260101000000_Step.cs:2: подавление: #pragma warning disable'
end_case

begin_case 'Skip = в src/Domovoy.Data/Migrations/ краснеет'
add_line "$EF_DIR/Helper.cs" '    var page = new Page { Skip = offset };'
run_guard
expect_red "$EF_DIR/Helper.cs:2: подавление: Skip ="
end_case

begin_case 'Skip = в .md и в .sh зеленеет'
printf 'Пример: Skip = "причина"\n' >> "$repo/docs/rules.md"
printf '# Skip = "причина"\n#pragma warning disable\n' >> "$repo/scripts/old.test.sh"
run_guard
expect_green
end_case

begin_case 'Подавление в scripts/fixtures/ зеленеет'
add_line 'scripts/fixtures/x/Bad.cs' '[Fact(Skip = "фикстура")]'
run_guard
expect_green
end_case

begin_case 'Удаление .yml с continue-on-error и --filter зеленеет'
git -C "$repo" rm -q .github/workflows/old.yml
run_guard
expect_green
end_case

begin_case 'Удаление *.test.sh зеленеет'
git -C "$repo" rm -q scripts/old.test.sh
run_guard
expect_green
end_case

begin_case 'Соседняя правка в .editorconfig с уже стоящим severity = none зеленеет'
sed -i 's/indent_size = 4/indent_size = 2/' "$repo/.editorconfig"
run_guard
expect_green
end_case

begin_case 'Удаление закоммиченного .trx зеленеет'
printf 'x\n' > "$repo/run.trx"; commit_all; git -C "$repo" branch -qf base HEAD
git -C "$repo" rm -q run.trx
run_guard
expect_green
end_case

begin_case 'Перенос теста в другой файл зеленеет'
sed -n '1,4p;9,$p' "$repo/tests/Domovoy.Tests/HealthTests.cs" > "$repo/t.cs"
mv "$repo/t.cs" "$repo/tests/Domovoy.Tests/HealthTests.cs"
printf 'namespace Domovoy.Tests;\npublic sealed class Moved\n{\n    [Fact(DisplayName = "Анонимный /health отвечает")]\n    public void Answers() { }\n}\n' \
    > "$repo/tests/Domovoy.Tests/MovedTests.cs"
run_guard
expect_green
end_case

begin_case 'AnalysisLevel latest-recommended зеленеет'
sed -i 's|<AnalysisLevel>latest</AnalysisLevel>|<AnalysisLevel>latest-recommended</AnalysisLevel>|' "$repo/Directory.Build.props"
run_guard
expect_green
end_case

begin_case 'AnalysisLevel latest-Recommended зеленеет: регистр не важен'
sed -i 's|<AnalysisLevel>latest</AnalysisLevel>|<AnalysisLevel>latest-Recommended</AnalysisLevel>|' "$repo/Directory.Build.props"
run_guard
expect_green
end_case

begin_case 'AnalysisLevelSecurity = latest-all зеленеет'
add_line 'build/a.props' '<AnalysisLevelSecurity>latest-all</AnalysisLevelSecurity>'
run_guard
expect_green
expect_no_output '«Security»'
end_case

begin_case 'Ссылка $(AnalysisLevel) в условии зеленеет'
add_line 'build/c.props' '<Foo Condition="$(AnalysisLevel) == 5.0">x</Foo>'
run_guard
expect_green
end_case

begin_case 'continue-on-error: false зеленеет'
add_line '.github/workflows/ok.yml' '    continue-on-error: false'
run_guard
expect_green
end_case

# ------------------------------------------------------------------
begin_case 'Неизвестная ревизия — код 2'
OUTPUT="$(cd "$repo" && bash "$GUARD" no-such-ref HEAD 2>&1)"; STATUS=$?
expect_status 2
expect_output 'неизвестная ревизия'
end_case

begin_case 'Все нарушения печатаются за один прогон'
add_line 'src/Domovoy.Api/A.cs' '#pragma warning disable CA2000'
printf 'x\n' > "$repo/a.keystore"
run_guard
expect_red 'src/Domovoy.Api/A.cs:2:'
expect_output 'a.keystore:1:'
expect_output 'нарушений — 2'
end_case

printf '\n'
if [ "$FAILED" -gt 0 ]; then
    printf 'Провалившиеся сценарии:\n'
    printf '  - %s\n' "${FAILED_NAMES[@]}"
    printf '\n'
fi
printf 'Пройдено: %d, провалено: %d, пропущено: 0\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ] || exit 1
exit 0
