using ArchUnitNET.Domain;
using ArchUnitNET.Fluent;
using ArchUnitNET.Loader;
using ArchUnitNET.xUnit;
using Domovoy.Core.Abstractions;
using Domovoy.Core.DependencyInjection;
using Domovoy.Core.Models;
using Domovoy.Core.Routing;
using FluentAssertions;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using NSubstitute;
using NSubstitute.ExceptionExtensions;
using static ArchUnitNET.Fluent.ArchRuleDefinition;

namespace Domovoy.Tests.Routing;

/// <summary>
/// Роутер быстрого пути (#11): шаблоны, расширяемость через DI и исполнение
/// совпадения напрямую через <see cref="IHaClient"/>, без LLM.
/// Роутер и шаблоны берутся из DI: шаблоны — внутренние типы ядра.
/// </summary>
public sealed class FastRouterTests
{
    private const string KitchenLight = "light.example_kitchen_ceiling";
    private const string LivingRoomLight = "light.example_living_room_ceiling";
    private const string BedroomAc = "climate.example_bedroom_ac";

    private static readonly Architecture CoreArchitecture = new ArchLoader()
        .LoadAssemblies(typeof(IFastRouter).Assembly)
        .Build();

    /// <summary>
    /// Два шаблона, названных в критерии #11, и 13 формулировок вне них:
    /// другой глагол или другая конструкция, а не подстановка устройства
    /// или комнаты.
    /// </summary>
    public static TheoryData<string, string, string, string, string?> TemplatePhrases => new()
    {
        // Названные в критерии.
        { "Включи свет на кухне", "switch", KitchenLight, "turn_on", null },
        { "Какая температура в спальне?", "read_value", "sensor.example_bedroom_temperature", "read", null },

        // Формулировки вне названных.
        { "Переключи свет на кухне", "switch", KitchenLight, "toggle", null },
        { "Зажги свет на кухне", "switch", KitchenLight, "turn_on", null },
        { "Погаси свет в гостиной", "switch", LivingRoomLight, "turn_off", null },
        { "Отключи свет на кухне", "switch", KitchenLight, "turn_off", null },
        { "Вруби свет в гостиной", "switch", LivingRoomLight, "turn_on", null },
        { "Выруби кондиционер в спальне", "switch", BedroomAc, "turn_off", null },
        { "Какая влажность в спальне", "read_value", "sensor.example_bedroom_humidity", "read", null },
        { "Сколько градусов в спальне", "read_value", "sensor.example_bedroom_temperature", "read", null },
        { "Открыто ли окно на кухне", "read_value", "binary_sensor.example_kitchen_window", "read", null },
        { "Есть ли протечка на кухне", "read_value", "binary_sensor.example_kitchen_leak", "read", null },
        { "Поставь 22 градуса в спальне", "set_value", BedroomAc, "set_temperature", "22" },
        { "Сделай свет на кухне на 40 процентов", "set_value", KitchenLight, "set_brightness", "40" },
        { "Убавь свет в гостиной до 30 процентов", "set_value", LivingRoomLight, "set_brightness", "30" },

        // Комната решает, какая сущность: тот же глагол, другая комната.
        { "Выключи свет в гостиной", "switch", LivingRoomLight, "turn_off", null },

        // Комната родительным падежом реестра.
        { "Какая температура спальни", "read_value", "sensor.example_bedroom_temperature", "read", null },

        // Границы значения проверяет слой Ha, а не роутер: число уходит как есть.
        { "Поставь 400 градусов в спальне", "set_value", BedroomAc, "set_temperature", "400" },
    };

    [Theory(DisplayName = "Фраза шаблона даёт ожидаемые шаблон, сущность, действие и значение")]
    [MemberData(nameof(TemplatePhrases))]
    public void TemplatePhrasesRouteToExpectedEntityAndAction(
        string phrase,
        string templateName,
        string entityId,
        string action,
        string? value)
    {
        FastRouteMatch? match = BuildServices().GetRequiredService<IFastRouter>().TryMatch(phrase);

        match.Should().BeEquivalentTo(new FastRouteMatch
        {
            TemplateName = templateName,
            EntityId = entityId,
            Action = action,
            Value = value,
        });
    }

    [Theory(DisplayName = "Неверная комната, двусмысленность или чужое действие — нет совпадения")]
    [InlineData("Включи свет в спальне")]
    [InlineData("Включи свет на кухню")]
    [InlineData("Какая температура на кухне")]
    [InlineData("Какая влажность в гостиной")]
    [InlineData("Выключи свет")]
    [InlineData("Включи телевизор")]
    [InlineData("Убавь свет в гостиной на 10 процентов")]
    [InlineData("Поставь 22 градуса на кухне")]
    public void PhraseWithoutUniqueAllowedEntityIsNotMatched(string phrase)
    {
        BuildServices().GetRequiredService<IFastRouter>().TryMatch(phrase).Should().BeNull();
    }

    [Fact(DisplayName = "Неразобранная фраза уходит в LLM-путь без обращения к HA")]
    public async Task UnmatchedPhraseFallsThroughWithoutHaCall()
    {
        IHaClient haClient = Substitute.For<IHaClient>();
        IFastPath fastPath = BuildServices(haClient).GetRequiredService<IFastPath>();

        FastPathOutcome outcome = await fastPath.TryHandleAsync("Какая погода завтра", CancellationToken.None);

        outcome.Should().BeSameAs(FastPathOutcome.NotMatched);
        haClient.ReceivedCalls().Should().BeEmpty();
    }

    [Fact(DisplayName = "Шаблон, зарегистрированный только в DI, срабатывает без правки роутера")]
    public void TemplateAddedViaDiIsMatchedWithoutRouterChanges()
    {
        ServiceProvider services = BuildServices(
            configure: collection => collection.AddSingleton<IFastRouteTemplate, ProbeTemplate>());

        FastRouteMatch? match = services.GetRequiredService<IFastRouter>().TryMatch("Проверка, шаблона!");

        match.Should().NotBeNull();
        match!.TemplateName.Should().Be(ProbeTemplate.TemplateName);
        match.EntityId.Should().Be(KitchenLight);
    }

    [Fact(DisplayName = "Роутер не зависит ни от одного конкретного шаблона")]
    public void RouterDoesNotReferenceConcreteTemplates()
    {
        var concreteTemplates = Classes()
            .That().AreAssignableTo(typeof(IFastRouteTemplate))
            .As("конкретные шаблоны");

        // Правило не вхолостую: шаблоны в ядре есть.
        concreteTemplates.GetObjects(CoreArchitecture).Should().NotBeEmpty();

        IArchRule rule = Types().That().HaveFullName(typeof(FastRouter).FullName!).As("FastRouter")
            .Should().NotDependOnAny(concreteTemplates)
            .Because("шаблоны приходят через IEnumerable<IFastRouteTemplate>, ветвления по шаблону в роутере нет.");

        rule.Check(CoreArchitecture);
    }

    [Fact(DisplayName = "Действие уходит в CallServiceAsync с доменом сущности, результат — как есть")]
    public async Task RunnerCallsServiceWithEntityDomainAndPassesResultThrough()
    {
        var match = new FastRouteMatch { TemplateName = "set_value", EntityId = KitchenLight, Action = "set_brightness", Value = "40" };
        var result = new ToolResult { ToolCallId = ToolResult.DirectCallId, Success = true };
        IFastRouter router = Substitute.For<IFastRouter>();
        router.TryMatch("фраза").Returns(match);
        IHaClient haClient = Substitute.For<IHaClient>();
        haClient.CallServiceAsync("light", "set_brightness", KitchenLight, "40", Arg.Any<CancellationToken>())
            .Returns(result);

        FastPathOutcome outcome = await new FastPathRunner(router, haClient).TryHandleAsync("фраза", CancellationToken.None);

        outcome.Matched.Should().BeTrue();
        outcome.Match.Should().BeSameAs(match);
        outcome.Result.Should().BeSameAs(result);
        await haClient.DidNotReceiveWithAnyArgs().GetStatesAsync(default, default, default);
    }

    [Fact(DisplayName = "Чтение идёт через GetStatesAsync по домену и выбирает состояние сущности")]
    public async Task RunnerReadsStateOfMatchedEntity()
    {
        const string temperature = "sensor.example_bedroom_temperature";
        IFastRouter router = Substitute.For<IFastRouter>();
        router.TryMatch("фраза").Returns(new FastRouteMatch { TemplateName = "read_value", EntityId = temperature, Action = "read" });
        IHaClient haClient = Substitute.For<IHaClient>();
        haClient.GetStatesAsync(null, "sensor", Arg.Any<CancellationToken>())
            .Returns([State("sensor.example_bedroom_humidity", "45"), State(temperature, "21.5")]);

        FastPathOutcome outcome = await new FastPathRunner(router, haClient).TryHandleAsync("фраза", CancellationToken.None);

        outcome.Matched.Should().BeTrue();
        outcome.Result.Should().BeEquivalentTo(new ToolResult
        {
            ToolCallId = ToolResult.DirectCallId,
            Success = true,
            Payload = "21.5",
        });
        await haClient.DidNotReceiveWithAnyArgs().CallServiceAsync(default!, default!, default!, default, default);
    }

    [Fact(DisplayName = "Недоступный HA при чтении — отказ ha_unavailable, без исключения наружу")]
    public async Task RunnerReportsHaUnavailableOnRead()
    {
        IFastRouter router = Substitute.For<IFastRouter>();
        router.TryMatch("фраза").Returns(new FastRouteMatch
        {
            TemplateName = "read_value",
            EntityId = "sensor.example_bedroom_humidity",
            Action = "read",
        });
        IHaClient haClient = Substitute.For<IHaClient>();
        haClient.GetStatesAsync(null, "sensor", Arg.Any<CancellationToken>())
            .ThrowsAsync(new HaUnavailableException());

        FastPathOutcome outcome = await new FastPathRunner(router, haClient).TryHandleAsync("фраза", CancellationToken.None);

        outcome.Matched.Should().BeTrue();
        outcome.Result!.ToolCallId.Should().Be(ToolResult.DirectCallId);
        outcome.Result.Success.Should().BeFalse();
        outcome.Result.ErrorCode.Should().Be(HaErrorCodes.HaUnavailable);
    }

    [Fact(DisplayName = "Сущности нет в ответе GetStatesAsync — отказ entity_not_allowed")]
    public async Task RunnerReportsMissingStateAsEntityNotAllowed()
    {
        IFastRouter router = Substitute.For<IFastRouter>();
        router.TryMatch("фраза").Returns(new FastRouteMatch
        {
            TemplateName = "read_value",
            EntityId = "sensor.example_off_list",
            Action = "read",
        });
        IHaClient haClient = Substitute.For<IHaClient>();
        haClient.GetStatesAsync(null, "sensor", Arg.Any<CancellationToken>())
            .Returns([State("sensor.example_bedroom_humidity", "45")]);

        FastPathOutcome outcome = await new FastPathRunner(router, haClient).TryHandleAsync("фраза", CancellationToken.None);

        outcome.Matched.Should().BeTrue();
        outcome.Result!.ToolCallId.Should().Be(ToolResult.DirectCallId);
        outcome.Result.Success.Should().BeFalse();
        outcome.Result.ErrorCode.Should().Be(HaErrorCodes.EntityNotAllowed);
    }

    private static ServiceProvider BuildServices(
        IHaClient? haClient = null,
        Action<IServiceCollection>? configure = null)
    {
        var services = new ServiceCollection();
        services.AddDomovoyCore(new ConfigurationBuilder().Build());
        services.AddSingleton<IEntityAllowList, ExampleApartment>();
        services.AddSingleton(haClient ?? Substitute.For<IHaClient>());
        configure?.Invoke(services);

        return services.BuildServiceProvider();
    }

    private static HaEntityState State(string entityId, string state) => new()
    {
        EntityId = entityId,
        State = state,
        Attributes = new Dictionary<string, string>(),
        LastChanged = DateTimeOffset.UnixEpoch,
        LastUpdated = DateTimeOffset.UnixEpoch,
    };

    /// <summary>Шаблон, о котором роутер ничего не знает: только регистрация в DI.</summary>
    private sealed class ProbeTemplate : IFastRouteTemplate
    {
        public const string TemplateName = "probe";

        public string Name => TemplateName;

        public FastRouteMatch? TryMatch(string normalizedText, IEntityAllowList allowList) =>
            normalizedText == "проверка шаблона"
                ? new FastRouteMatch { TemplateName = Name, EntityId = KitchenLight, Action = "toggle" }
                : null;
    }
}
