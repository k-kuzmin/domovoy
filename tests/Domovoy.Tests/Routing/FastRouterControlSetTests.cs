using System.Text.Json;
using System.Text.Json.Serialization;
using Domovoy.Core.Abstractions;
using Domovoy.Core.Configuration;
using Domovoy.Core.DependencyInjection;
using Domovoy.Core.Models;
using Domovoy.Ha;
using Domovoy.Ha.Registry;
using FluentAssertions;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Options;
using NSubstitute;
using Xunit.Abstractions;

namespace Domovoy.Tests.Routing;

/// <summary>
/// Контрольный набор фраз быстрого пути (#11): доля покрытия измеряется на
/// вымышленной квартире примера, ожидания зафиксированы данными до прогона.
/// Порога доли в тесте нет — число публикуется как есть; тест ловит
/// расхождение исхода фразы с ожиданием в обе стороны.
/// </summary>
public sealed class FastRouterControlSetTests
{
    private static readonly string ControlSetPath =
        RepositoryLayout.Path("tests", "Domovoy.Tests", "Routing", "fast-router-control-set.json");

    private readonly ITestOutputHelper _output;

    public FastRouterControlSetTests(ITestOutputHelper output) => _output = output;

    [Fact(DisplayName = "Доля покрытия контрольного набора измерена, исход каждой фразы равен ожиданию")]
    public void ControlSetCoverageIsMeasured()
    {
        List<ControlPhrase> phrases = LoadControlSet();
        phrases.Should().HaveCountGreaterThanOrEqualTo(30);
        phrases.Count(phrase => phrase.Expected is null).Should().BeGreaterThanOrEqualTo(8);

        IFastRouter router = BuildRouter();
        var mismatches = new List<string>();
        int matched = 0;

        foreach (ControlPhrase phrase in phrases)
        {
            FastRouteMatch? match = router.TryMatch(phrase.Phrase);
            if (match is not null)
            {
                matched++;
            }

            ExpectedMatch? actual = match is null
                ? null
                : new ExpectedMatch { EntityId = match.EntityId, Action = match.Action, Value = match.Value };

            if (actual != phrase.Expected)
            {
                mismatches.Add($"«{phrase.Phrase}»: ожидалось {Describe(phrase.Expected)}, получено {Describe(actual)}");
            }
        }

        _output.WriteLine($"coverage: {matched}/{phrases.Count}");

        mismatches.Should().BeEmpty();
    }

    [Fact(DisplayName = "Тестовая квартира совпадает с config/entities.example.yaml")]
    public void ExampleApartmentMatchesExampleRegistry()
    {
        IHostEnvironment environment = Substitute.For<IHostEnvironment>();
        environment.ContentRootPath.Returns(Path.GetTempPath());
        var loader = new EntityRegistryFileLoader(
            Options.Create(new HaOptions { EntityRegistryPath = RepositoryLayout.Path("config", "entities.example.yaml") }),
            environment);
        var registry = new EntityRegistryOptions();
        loader.Configure(registry);
        var example = new ConfiguredEntityAllowList(Options.Create(registry));

        var apartment = new ExampleApartment();

        apartment.Areas.Should().BeEquivalentTo(example.Areas);
        apartment.All.Should().BeEquivalentTo(example.All);
    }

    private static IFastRouter BuildRouter()
    {
        var services = new ServiceCollection();
        services.AddDomovoyCore(new ConfigurationBuilder().Build());
        services.AddSingleton<IEntityAllowList, ExampleApartment>();
        services.AddSingleton(Substitute.For<IHaClient>());

        return services.BuildServiceProvider().GetRequiredService<IFastRouter>();
    }

    private static List<ControlPhrase> LoadControlSet() =>
        JsonSerializer.Deserialize<List<ControlPhrase>>(File.ReadAllText(ControlSetPath))
            ?? throw new InvalidOperationException("Контрольный набор пуст.");

    private static string Describe(ExpectedMatch? match) =>
        match is null ? "null" : $"{match.EntityId} {match.Action} {match.Value ?? "-"}";

    private sealed record ControlPhrase
    {
        [JsonPropertyName("phrase")]
        public required string Phrase { get; init; }

        [JsonPropertyName("expected")]
        public ExpectedMatch? Expected { get; init; }
    }

    private sealed record ExpectedMatch
    {
        [JsonPropertyName("entity_id")]
        public required string EntityId { get; init; }

        [JsonPropertyName("action")]
        public required string Action { get; init; }

        [JsonPropertyName("value")]
        public string? Value { get; init; }
    }
}
