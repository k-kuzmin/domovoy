using Domovoy.Core.Abstractions;
using Domovoy.Core.DependencyInjection;
using Domovoy.Core.Models;
using Domovoy.Core.Orchestration;
using Domovoy.Ha;
using Domovoy.Tests.Auth;
using FluentAssertions;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using NSubstitute;

namespace Domovoy.Tests.Routing;

/// <summary>
/// Оркестратор поверх быстрого пути (#14): итог <see cref="IFastPath"/>
/// превращается в поток событий. Быстрый путь — подстановка, allow-list —
/// вымышленная квартира, часы — ручные.
/// </summary>
public sealed class FastPathOrchestratorTests
{
    private const string KitchenLight = "light.example_kitchen_ceiling";
    private const string BedroomHumidity = "sensor.example_bedroom_humidity";
    private const string BoilerThermostat = "climate.example_kitchen_boiler_thermostat";

    private readonly IFastPath _fastPath = Substitute.For<IFastPath>();
    private readonly ManualTimeProvider _time = new();

    [Fact(DisplayName = "Успешная команда: action, token «Готово: <имя из реестра>.», done быстрого пути")]
    public async Task OrchestratorEmitsActionTokenDoneForSuccessfulCommand()
    {
        // Payload HA намеренно другой: имя в ответе — из allow-list, а не из ответа HA.
        Returns(Matched(KitchenLight, "turn_on", new ToolResult
        {
            ToolCallId = ToolResult.DirectCallId,
            Success = true,
            Payload = "Ceiling Light HA",
        }));

        List<AgentEvent> events = await HandleAsync("включи свет на кухне", "req-1");

        events.Should().HaveCount(3);
        events[0].Should().Be(new ActionEvent(KitchenLight, "turn_on", true));
        events[1].Should().Be(new TokenEvent("Готово: Свет на кухне."));
        ResponseMetadata metadata = events[2].Should().BeOfType<DoneEvent>().Subject.Metadata;
        metadata.RequestId.Should().Be("req-1");
        metadata.Path.Should().Be(ResponsePath.FastRouter);
        metadata.Elapsed.Should().Be(TimeSpan.FromMilliseconds(40));
        metadata.ToolCallCount.Should().Be(0);
        metadata.Usage.Should().BeNull();
    }

    [Fact(DisplayName = "Чтение: token «<имя>: <значение>.» и done, без action")]
    public async Task OrchestratorEmitsTokenDoneForRead()
    {
        Returns(Matched(BedroomHumidity, "read", new ToolResult
        {
            ToolCallId = ToolResult.DirectCallId,
            Success = true,
            Payload = "45 %",
        }));

        List<AgentEvent> events = await HandleAsync("какая влажность в спальне", "req-2");

        events.Should().HaveCount(2);
        events[0].Should().Be(new TokenEvent("Влажность в спальне: 45 %."));
        events[1].Should().BeOfType<DoneEvent>().Which.Metadata.RequestId.Should().Be("req-2");
        events.OfType<ActionEvent>().Should().BeEmpty();
    }

    [Fact(DisplayName = "Фраза не подошла: token NotUnderstoodReply и done, действий нет")]
    public async Task OrchestratorAnswersNotYetSupportedForUnmatchedPhrase()
    {
        _fastPath.TryHandleAsync(Arg.Any<string>(), Arg.Any<CancellationToken>())
            .Returns(FastPathOutcome.NotMatched);

        List<AgentEvent> events = await HandleAsync("расскажи анекдот", "req-3");

        events.Should().HaveCount(2);
        events[0].Should().Be(new TokenEvent(FastPathOrchestrator.NotUnderstoodReply));
        DoneEvent done = events[1].Should().BeOfType<DoneEvent>().Subject;
        done.Metadata.Path.Should().Be(ResponsePath.FastRouter);
        done.Metadata.RequestId.Should().Be("req-3");
        events.OfType<ActionEvent>().Should().BeEmpty();
    }

    [Fact(DisplayName = "Отказ с кодом: ровно одно событие error с тем же кодом и сообщением, без action и done")]
    public async Task OrchestratorEmitsSingleErrorEventForCodedRefusal()
    {
        Returns(Matched(KitchenLight, "turn_on", new ToolResult
        {
            ToolCallId = ToolResult.DirectCallId,
            Success = false,
            Error = "Home Assistant недоступен.",
            ErrorCode = HaErrorCodes.HaUnavailable,
        }));

        List<AgentEvent> events = await HandleAsync("включи свет на кухне", "req-4");

        events.Should().ContainSingle()
            .Which.Should().Be(new ErrorEvent(HaErrorCodes.HaUnavailable, "Home Assistant недоступен."));
    }

    [Fact(DisplayName = "Отказ без кода (climate без current_temperature): token с текстом отказа и done, не error")]
    public async Task OrchestratorAnswersUncodedRefusalAsText()
    {
        const string refusal = "У терморегулятора нет текущей температуры.";
        Returns(Matched(BoilerThermostat, "read", new ToolResult
        {
            ToolCallId = ToolResult.DirectCallId,
            Success = false,
            Error = refusal,
        }));

        List<AgentEvent> events = await HandleAsync("какая температура у котла", "req-5");

        events.Should().HaveCount(2);
        events[0].Should().Be(new TokenEvent(refusal));
        events[1].Should().BeOfType<DoneEvent>();
        events.OfType<ErrorEvent>().Should().BeEmpty();
    }

    [Fact(DisplayName = "AddDomovoyCore + AddHomeAssistant регистрируют IOrchestrator как transient FastPathOrchestrator")]
    public void OrchestratorResolvesOverRegisteredFastPath()
    {
        HostApplicationBuilder builder = Host.CreateEmptyApplicationBuilder(new HostApplicationBuilderSettings
        {
            EnvironmentName = Environments.Development,
            ContentRootPath = Path.GetTempPath(),
        });

        builder.Configuration
            .AddJsonFile(RepositoryLayout.Path("src", "Domovoy.Api", "appsettings.json"))
            .AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["Ha:EntityRegistryPath"] = RepositoryLayout.Path("config", "entities.example.yaml"),
                ["Ha:BaseUrl"] = DomovoyApiFactory.UnreachableHaBaseUrl,
                ["Ha:Token"] = "orchestrator-test-token",
            });

        builder.Services.AddLogging();
        builder.Services.AddDomovoyCore(builder.Configuration);
        builder.Services.AddHomeAssistant();

        using IHost host = builder.Build();

        IOrchestrator first = host.Services.GetRequiredService<IOrchestrator>();
        IOrchestrator second = host.Services.GetRequiredService<IOrchestrator>();

        first.Should().BeOfType<FastPathOrchestrator>();
        second.Should().BeOfType<FastPathOrchestrator>();
        first.Should().NotBeSameAs(second, "оркестратор держит transient IFastPath и сам transient");
    }

    private static FastPathOutcome Matched(string entityId, string action, ToolResult result) => new()
    {
        Matched = true,
        Match = new FastRouteMatch { TemplateName = "test", EntityId = entityId, Action = action },
        Result = result,
    };

    private void Returns(FastPathOutcome outcome) =>
        _fastPath.TryHandleAsync(Arg.Any<string>(), Arg.Any<CancellationToken>())
            .Returns(_ =>
            {
                _time.Advance(TimeSpan.FromMilliseconds(40));
                return outcome;
            });

    private async Task<List<AgentEvent>> HandleAsync(string text, string requestId)
    {
        var orchestrator = new FastPathOrchestrator(_fastPath, new ExampleApartment(), _time);
        var request = new AgentRequest
        {
            RequestId = requestId,
            DeviceId = "device-1",
            Text = text,
            Source = AgentRequestSource.Text,
        };

        var events = new List<AgentEvent>();
        await foreach (AgentEvent item in orchestrator.HandleAsync(request, CancellationToken.None))
        {
            events.Add(item);
        }

        _ = _fastPath.Received(1).TryHandleAsync(text, Arg.Any<CancellationToken>());
        return events;
    }
}
