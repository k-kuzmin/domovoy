using System.Diagnostics;
using Domovoy.Core.Abstractions;
using Domovoy.Core.DependencyInjection;
using Domovoy.Core.Models;
using Domovoy.Ha;
using Domovoy.Llm;
using Domovoy.Tests.Ha;
using FluentAssertions;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using NSubstitute;

namespace Domovoy.Tests.Routing;

/// <summary>
/// Быстрый путь целиком на настоящей регистрации DI (#11): роутер →
/// allow-list → REST Home Assistant, без LLM. HA — фейк на loopback.
///
/// Хост собирается, но не запускается: воркер WebSocket не стартует,
/// статус соединения остаётся «подключается», и чтение идёт в REST фейка.
/// Построитель — без источников по умолчанию: переменные окружения машины
/// до теста не доходят.
/// </summary>
public sealed class FastPathEndToEndTests : IAsyncLifetime
{
    private const string Token = "fast-path-test-token";
    private const string KitchenLight = "light.example_kitchen_ceiling";
    private const string OffListEntity = "light.example_hall_off_list";
    private const string OffListPhrase = "открой портал в прихожей";

    private FakeHomeAssistant _fake = null!;
    private IHost _host = null!;
    private ILlmProvider _llm = null!;

    public async Task InitializeAsync()
    {
        _fake = await FakeHomeAssistant.StartAsync(Token);
        _fake.SetState(KitchenLight, "off");
        _fake.SetState("sensor.example_bedroom_humidity", "45");

        _llm = Substitute.For<ILlmProvider>();
        _host = BuildHost(_fake.BaseUrl, _llm);
    }

    public async Task DisposeAsync()
    {
        _host.Dispose();
        await _fake.DisposeAsync();
    }

    [Fact(DisplayName = "«Включи свет на кухне» уходит POST в light/turn_on, LLM не вызывается")]
    public async Task FastPathCallsHaRestWithoutLlm()
    {
        FastPathOutcome outcome = await FastPath().TryHandleAsync("включи свет на кухне", CancellationToken.None);

        outcome.Matched.Should().BeTrue();
        outcome.Result!.Success.Should().BeTrue();

        FakeRestRequest request = _fake.RestRequests.Should().ContainSingle().Subject;
        request.Method.Should().Be("POST");
        request.Path.Should().Be("/api/services/light/turn_on");
        request.Body.Should().Contain(KitchenLight);
        request.AuthorizedWithExpectedToken.Should().BeTrue();

        _llm.ReceivedCalls().Should().BeEmpty("быстрый путь не обращается к LLM");
    }

    [Fact(DisplayName = "Сущность вне allow-list из шаблона отклоняется до запроса к HA")]
    public async Task FastPathRejectsOffListEntityBeforeHaCall()
    {
        FastPathOutcome outcome = await FastPath().TryHandleAsync(OffListPhrase, CancellationToken.None);

        outcome.Matched.Should().BeTrue("тестовый шаблон, зарегистрированный в DI, разобрал фразу");
        outcome.Match!.EntityId.Should().Be(OffListEntity);
        outcome.Result!.Success.Should().BeFalse();
        outcome.Result.ErrorCode.Should().Be(HaErrorCodes.EntityNotAllowed);
        outcome.Result.ToolCallId.Should().Be(ToolResult.DirectCallId);

        _fake.RestRequests.Should().BeEmpty("проверка allow-list идёт до HTTP");
        _fake.WebSocketRequestCount.Should().Be(0);
    }

    [Fact(DisplayName = "Отказы быстрого пути — коды ошибок: invalid_value и ha_unavailable, без исключений")]
    public async Task FastPathReportsRefusalsAsErrorCodes()
    {
        FastPathOutcome invalid = await FastPath().TryHandleAsync("поставь 400 градусов в спальне", CancellationToken.None);

        invalid.Matched.Should().BeTrue();
        invalid.Result!.ErrorCode.Should().Be(HaErrorCodes.InvalidValue);
        invalid.Result.ToolCallId.Should().Be(ToolResult.DirectCallId);
        _fake.RestRequests.Should().BeEmpty("значение вне границ отклоняется до HTTP");

        _fake.RestAvailable = false;

        FastPathOutcome unavailable = await FastPath().TryHandleAsync("какая влажность в спальне", CancellationToken.None);

        unavailable.Matched.Should().BeTrue();
        unavailable.Result!.Success.Should().BeFalse();
        unavailable.Result.ErrorCode.Should().Be(HaErrorCodes.HaUnavailable);
        unavailable.Result.ToolCallId.Should().Be(ToolResult.DirectCallId);
    }

    [Fact(DisplayName = "p95 быстрого пути против HA на loopback меньше 500 мс")]
    public async Task FastPathP95OnLoopbackIsUnder500Ms()
    {
        const int warmup = 20;
        const int runs = 200;

        IFastPath fastPath = FastPath();
        for (int index = 0; index < warmup; index++)
        {
            await fastPath.TryHandleAsync("включи свет на кухне", CancellationToken.None);
        }

        var samples = new double[runs];
        for (int index = 0; index < runs; index++)
        {
            long started = Stopwatch.GetTimestamp();
            FastPathOutcome outcome = await FastPath().TryHandleAsync("включи свет на кухне", CancellationToken.None);
            samples[index] = Stopwatch.GetElapsedTime(started).TotalMilliseconds;

            outcome.Result!.Success.Should().BeTrue();
        }

        Array.Sort(samples);
        double p95 = samples[(int)Math.Ceiling(runs * 0.95) - 1];

        p95.Should().BeLessThan(500, "санитарная граница собственной стоимости роутера и клиента");
    }

    private IFastPath FastPath() => _host.Services.GetRequiredService<IFastPath>();

    private static IHost BuildHost(string haBaseUrl, ILlmProvider llm)
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
                ["Ha:BaseUrl"] = haBaseUrl,
                ["Ha:Token"] = Token,
            });

        builder.Services.AddLogging();
        builder.Services.AddDomovoyCore(builder.Configuration);
        builder.Services.AddHomeAssistant();
        builder.Services.AddLlm();
        builder.Services.AddSingleton(llm);

        // Шаблон, известный только DI: роутер его не знает по имени.
        builder.Services.AddSingleton<IFastRouteTemplate, OffListTemplate>();

        return builder.Build();
    }

    /// <summary>Шаблон, который отдаёт сущность вне allow-list.</summary>
    private sealed class OffListTemplate : IFastRouteTemplate
    {
        public string Name => "off_list";

        public FastRouteMatch? TryMatch(string normalizedText, IEntityAllowList allowList) =>
            normalizedText == OffListPhrase
                ? new FastRouteMatch { TemplateName = Name, EntityId = OffListEntity, Action = "turn_on" }
                : null;
    }
}
