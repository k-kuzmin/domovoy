using System.Text.RegularExpressions;
using FluentAssertions;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.Routing;
using Microsoft.Extensions.DependencyInjection;

namespace Domovoy.Tests;

/// <summary>
/// Правило 7 раздела «Безопасность» в <c>.claude/CLAUDE.md</c>: каждый
/// анонимный эндпоинт записан в таблице правила, и каждая строка таблицы
/// соответствует анонимному эндпоинту.
///
/// Источников два, и ни один не копия: с одной стороны — живая
/// маршрутизация приложения, с другой — сам документ, разобранный из
/// файла. Список анонимных эндпоинтов в тесте проверял бы сам себя.
/// </summary>
public sealed class AnonymousEndpointsRuleTests : IClassFixture<WebApplicationFactory<Program>>
{
    private readonly WebApplicationFactory<Program> _factory;

    public AnonymousEndpointsRuleTests(WebApplicationFactory<Program> factory) => _factory = factory;

    [Fact(DisplayName = "Анонимные эндпоинты приложения совпадают с таблицей правила 7")]
    public void AnonymousEndpointsMatchRuleSevenTable()
    {
        EndpointDataSource dataSource = _factory.Services.GetRequiredService<EndpointDataSource>();

        IReadOnlyList<AnonymousEndpoint> endpoints = AnonymousEndpointsRule.Extract(dataSource.Endpoints);
        IReadOnlyList<DocumentedEndpoint> documented =
            AnonymousEndpointsRule.ParseTable(File.ReadAllText(RepositoryLayout.Path(".claude", "CLAUDE.md")));

        IReadOnlyList<string> discrepancies = AnonymousEndpointsRule.Reconcile(endpoints, documented);

        discrepancies.Should().BeEmpty(
            "правило 7 в .claude/CLAUDE.md: анонимный эндпоинт появляется только вместе со строкой таблицы и записью решения");
    }

    [Fact(DisplayName = "Анонимный эндпоинт без строки таблицы сообщается лишним")]
    public void UndocumentedAnonymousEndpointIsReported()
    {
        IReadOnlyList<string> discrepancies = AnonymousEndpointsRule.Reconcile(
            [new AnonymousEndpoint(["POST"], "/api/v1/chat")],
            []);

        discrepancies.Should().ContainSingle()
            .Which.Should().Contain("POST /api/v1/chat")
            .And.Contain("не записан в правиле 7")
            .And.Contain(".claude/CLAUDE.md")
            .And.Contain("docs/decisions/")
            .And.Contain("снять AllowAnonymous");
    }

    [Fact(DisplayName = "Строка таблицы без анонимного эндпоинта сообщается недостающей")]
    public void DocumentedButMissingEndpointIsReported()
    {
        IReadOnlyList<string> discrepancies = AnonymousEndpointsRule.Reconcile(
            [],
            [new DocumentedEndpoint("POST", "/api/v1/auth/device")]);

        discrepancies.Should().ContainSingle()
            .Which.Should().Contain("POST /api/v1/auth/device")
            .And.Contain("не соответствует ни одному анонимному эндпоинту")
            .And.Contain("убрать строку и запись решения")
            .And.Contain("вернуть эндпоинт");
    }

    [Fact(DisplayName = "Эндпоинт без метода сопоставляется со строкой таблицы по пути")]
    public void MethodlessEndpointMatchesRowByPath()
    {
        IReadOnlyList<string> discrepancies = AnonymousEndpointsRule.Reconcile(
            [new AnonymousEndpoint([], "/health")],
            [new DocumentedEndpoint("GET", "/health")]);

        discrepancies.Should().BeEmpty();
    }

    [Fact(DisplayName = "Эндпоинт без метода и без строки таблицы сообщается лишним")]
    public void MethodlessUndocumentedEndpointIsReported()
    {
        IReadOnlyList<string> discrepancies = AnonymousEndpointsRule.Reconcile(
            [new AnonymousEndpoint([], "/metrics")],
            [new DocumentedEndpoint("GET", "/health")]);

        discrepancies.Should().HaveCount(2);
        discrepancies.Should().ContainSingle(message => message.Contains("* /metrics", StringComparison.Ordinal)
            && message.Contains("не записан в правиле 7", StringComparison.Ordinal));
        discrepancies.Should().ContainSingle(message => message.Contains("GET /health", StringComparison.Ordinal)
            && message.Contains("не соответствует ни одному анонимному эндпоинту", StringComparison.Ordinal));
    }

    [Fact(DisplayName = "Анонимность, унаследованная от группы маршрутов, видна так же, как на эндпоинте")]
    public async Task GroupInheritedAnonymityIsDetected()
    {
        WebApplicationBuilder builder = WebApplication.CreateBuilder();
        await using WebApplication app = builder.Build();

        app.MapGroup("/g").AllowAnonymous().MapGet("/x", () => "x");
        app.MapGroup("/h").MapGet("/y", () => "y");
        app.MapGet("/z", () => "z");

        IEnumerable<Endpoint> all = ((IEndpointRouteBuilder)app).DataSources.SelectMany(source => source.Endpoints);

        IReadOnlyList<AnonymousEndpoint> endpoints = AnonymousEndpointsRule.Extract(all);

        endpoints.Should().ContainSingle();
        endpoints[0].Path.Should().Be("/g/x");
        endpoints[0].Methods.Should().Equal("GET");
    }

    [Fact(DisplayName = "Таблица правила 7 разбирается с отступом пункта списка")]
    public void RuleSevenTableIsParsed()
    {
        const string document = """
            7. **Новый публичный эндпоинт по умолчанию требует аутентификации.**
               Анонимные эндпоинты сейчас — каждый со своей записью:

               | Эндпоинт | Зачем | Запись |
               |---|---|---|
               | `GET /health` | пригодность к работе | [0002](../docs/decisions/0002.md) |
               | `POST /api/v1/auth/device` | обмен кода привязки | [0025](../docs/decisions/0025.md) |

               Новый анонимный эндпоинт добавляется в эту таблицу.

            | Другая | таблица |
            |---|---|
            | `DELETE /other` | не из правила 7 |
            """;

        IReadOnlyList<DocumentedEndpoint> documented = AnonymousEndpointsRule.ParseTable(document);

        documented.Should().Equal(
            new DocumentedEndpoint("GET", "/health"),
            new DocumentedEndpoint("POST", "/api/v1/auth/device"));
    }

    [Theory(DisplayName = "Потерянная таблица правила 7 — отдельная ошибка, а не пустой набор")]
    [InlineData("""
        Анонимные эндпоинты сейчас — каждый со своей записью:

        | Путь | Зачем |
        |---|---|
        | `GET /health` | пригодность |
        """)]
    [InlineData("""
           | Эндпоинт | Зачем | Запись |
           |---|---|---|

           Новый анонимный эндпоинт добавляется в эту таблицу.
        """)]
    public void MissingRuleSevenTableIsReported(string document)
    {
        Action parse = () => AnonymousEndpointsRule.ParseTable(document);

        parse.Should().Throw<InvalidOperationException>()
            .WithMessage("*таблица правила 7 не найдена*")
            .WithMessage($"*{AnonymousEndpointsRule.TableHeader}*");
    }

    [Theory(DisplayName = "Строка за заголовком таблицы правила 7 без разделителя — ошибка, а не пропущенная строка данных")]
    [InlineData("""
           | Эндпоинт | Зачем | Запись |
           | `GET /health` | пригодность к работе | [0002](../docs/decisions/0002.md) |
           | `POST /api/v1/auth/device` | обмен кода привязки | [0025](../docs/decisions/0025.md) |
        """)]
    [InlineData("""
           | Эндпоинт | Зачем | Запись |
           |---|-x-|---|
           | `GET /health` | пригодность к работе | [0002](../docs/decisions/0002.md) |
        """)]
    [InlineData("""
           | Эндпоинт | Зачем | Запись |
        """)]
    public void MissingSeparatorIsReported(string document)
    {
        Action parse = () => AnonymousEndpointsRule.ParseTable(document);

        parse.Should().Throw<InvalidOperationException>()
            .WithMessage("*нет строки-разделителя*")
            .WithMessage($"*{AnonymousEndpointsRule.TableHeader}*");
    }

    [Fact(DisplayName = "Разделитель с выравниванием и пробелами принимается")]
    public void AlignedSeparatorIsAccepted()
    {
        const string document = """
               | Эндпоинт | Зачем | Запись |
               | :--- | :---: | ---: |
               | `GET /health` | пригодность к работе | [0002](../docs/decisions/0002.md) |
            """;

        AnonymousEndpointsRule.ParseTable(document).Should().Equal(new DocumentedEndpoint("GET", "/health"));
    }
}

/// <summary>Анонимный эндпоинт живой маршрутизации. Пустой набор методов — эндпоинт отвечает на любой метод.</summary>
internal sealed record AnonymousEndpoint(IReadOnlyList<string> Methods, string Path);

/// <summary>Строка таблицы правила 7: метод и путь из первой ячейки.</summary>
internal sealed record DocumentedEndpoint(string Method, string Path);

/// <summary>
/// Извлечение, разбор и сверка для правила 7. Три части разведены, чтобы
/// сверку можно было проверить на заведомых наборах, а извлечение — на
/// голом приложении с группой маршрутов.
/// </summary>
internal static partial class AnonymousEndpointsRule
{
    /// <summary>
    /// Якорь таблицы — её строка заголовка, а не фраза абзаца над ней:
    /// абзац перенесён по ширине, и переформулировка разорвала бы фразу.
    /// Строка заголовка в документе одна.
    /// </summary>
    public const string TableHeader = "| Эндпоинт | Зачем | Запись |";

    private const string SourceFile = ".claude/CLAUDE.md";

    /// <summary>
    /// Анонимные эндпоинты — те, у кого есть метаданные
    /// <see cref="IAllowAnonymous"/>: тот же признак, по которому
    /// AuthorizationMiddleware пропускает запрос мимо FallbackPolicy.
    /// Метаданные группы маршрутов попадают в метаданные конечного
    /// эндпоинта, поэтому анонимность группы видна здесь так же, как
    /// вызов AllowAnonymous на самом эндпоинте.
    /// </summary>
    public static IReadOnlyList<AnonymousEndpoint> Extract(IEnumerable<Endpoint> endpoints) =>
        endpoints
            .OfType<RouteEndpoint>()
            .Where(endpoint => endpoint.Metadata.GetMetadata<IAllowAnonymous>() is not null)
            .Select(endpoint => new AnonymousEndpoint(
                endpoint.Metadata.GetMetadata<IHttpMethodMetadata>()?.HttpMethods
                    .Select(method => method.ToUpperInvariant())
                    .Order(StringComparer.Ordinal)
                    .ToList() ?? [],
                NormalizePath(endpoint.RoutePattern.RawText ?? string.Empty)))
            .OrderBy(endpoint => endpoint.Path, StringComparer.Ordinal)
            .ToList();

    /// <summary>
    /// Первая markdown-таблица, начинающаяся строкой <see cref="TableHeader"/>.
    /// Ведущий отступ строк отбрасывается: таблица стоит внутри пункта
    /// списка и начинается с трёх пробелов.
    /// </summary>
    public static IReadOnlyList<DocumentedEndpoint> ParseTable(string document)
    {
        string[] lines = document.ReplaceLineEndings("\n").Split('\n');

        int header = Array.FindIndex(lines, line => string.Equals(line.Trim(), TableHeader, StringComparison.Ordinal));

        var rows = new List<DocumentedEndpoint>();

        if (header >= 0)
        {
            // Строка сразу за заголовком обязана быть разделителем |---|: без
            // проверки первая строка данных пропускалась бы молча, и сверка
            // осталась бы зелёной без неё.
            if (header + 1 >= lines.Length || !SeparatorPattern().IsMatch(lines[header + 1].Trim()))
            {
                throw new InvalidOperationException(
                    $"В {SourceFile} под строкой заголовка таблицы правила 7 «{TableHeader}» нет строки-разделителя " +
                    "вида `|---|---|---|`: без неё таблица не читается как таблица, а первая строка данных " +
                    "была бы пропущена. Вернуть разделитель сразу под заголовком.");
            }

            for (int index = header + 2; index < lines.Length; index++)
            {
                string line = lines[index].Trim();

                if (!line.StartsWith('|'))
                {
                    break;
                }

                string firstCell = line.Split('|', StringSplitOptions.TrimEntries)[1];
                Match match = FirstCellPattern().Match(firstCell);

                if (!match.Success)
                {
                    throw new InvalidOperationException(
                        $"Строка таблицы правила 7 в {SourceFile} не разобрана: первая ячейка «{firstCell}» " +
                        "должна быть вида `МЕТОД /путь` в обратных кавычках.");
                }

                rows.Add(new DocumentedEndpoint(match.Groups["method"].Value, match.Groups["path"].Value));
            }
        }

        if (rows.Count == 0)
        {
            throw new InvalidOperationException(
                $"В {SourceFile} таблица правила 7 не найдена: нет строки заголовка «{TableHeader}» " +
                "или под ней нет ни одной строки данных. Сверять анонимные эндпоинты не с чем — " +
                "таблицу перенесли или переименовали, и тест надо привести к документу.");
        }

        return rows;
    }

    /// <summary>
    /// Сверка двух множеств. Эндпоинт с объявленными методами
    /// раскладывается в пары «метод + путь». Эндпоинт без метода
    /// (MapHealthChecks) отвечает на любой метод и сопоставляется со
    /// строкой таблицы по пути при любом её методе; то, что таблица
    /// называет у него один метод, эта сверка не проверяет. Без строки с
    /// таким путём он лишний и печатается как <c>* /путь</c>.
    /// </summary>
    public static IReadOnlyList<string> Reconcile(
        IReadOnlyList<AnonymousEndpoint> endpoints,
        IReadOnlyList<DocumentedEndpoint> documented)
    {
        var discrepancies = new List<string>();

        foreach (AnonymousEndpoint endpoint in endpoints)
        {
            if (endpoint.Methods.Count == 0)
            {
                if (!documented.Any(row => string.Equals(row.Path, endpoint.Path, StringComparison.Ordinal)))
                {
                    discrepancies.Add(Undocumented($"* {endpoint.Path}"));
                }

                continue;
            }

            foreach (string method in endpoint.Methods)
            {
                if (!documented.Any(row => Matches(row, method, endpoint.Path)))
                {
                    discrepancies.Add(Undocumented($"{method} {endpoint.Path}"));
                }
            }
        }

        foreach (DocumentedEndpoint row in documented)
        {
            bool covered = endpoints.Any(endpoint =>
                string.Equals(endpoint.Path, row.Path, StringComparison.Ordinal)
                && (endpoint.Methods.Count == 0
                    || endpoint.Methods.Any(method => Matches(row, method, endpoint.Path))));

            if (!covered)
            {
                discrepancies.Add(
                    $"строка таблицы `{row.Method} {row.Path}` не соответствует ни одному анонимному эндпоинту — " +
                    "убрать строку и запись решения в docs/decisions/ или вернуть эндпоинт с AllowAnonymous");
            }
        }

        return discrepancies;
    }

    private static bool Matches(DocumentedEndpoint row, string method, string path) =>
        string.Equals(row.Method, method, StringComparison.OrdinalIgnoreCase)
        && string.Equals(row.Path, path, StringComparison.Ordinal);

    private static string Undocumented(string endpoint) =>
        $"анонимный эндпоинт `{endpoint}` не записан в правиле 7 — добавить строку в таблицу {SourceFile} " +
        "и запись решения в docs/decisions/, либо снять AllowAnonymous";

    private static string NormalizePath(string raw) =>
        "/" + RepeatedSlashes().Replace(raw, "/").Trim('/');

    [GeneratedRegex(@"^`(?<method>[A-Z]+) (?<path>/\S*)`$")]
    private static partial Regex FirstCellPattern();

    [GeneratedRegex(@"^\|(?:[ \t]*:?-+:?[ \t]*\|)+$")]
    private static partial Regex SeparatorPattern();

    [GeneratedRegex("/{2,}")]
    private static partial Regex RepeatedSlashes();
}
