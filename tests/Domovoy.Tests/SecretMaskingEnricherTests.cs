using Domovoy.Api.Logging;
using FluentAssertions;
using Serilog;
using Serilog.Core;
using Serilog.Events;

namespace Domovoy.Tests;

/// <summary>
/// Токены и ключи не логируются никогда, даже на уровне Debug.
/// Правило проверяется тестом, потому что нарушить его можно одной
/// строкой, а обнаружить — только читая файл логов.
/// </summary>
public sealed class SecretMaskingEnricherTests
{
    [Theory(DisplayName = "Имя свойства распознаётся как чувствительное")]
    [InlineData("Token")]
    [InlineData("HaToken")]
    [InlineData("ApiKey")]
    [InlineData("api_key")]
    [InlineData("Password")]
    [InlineData("Authorization")]
    [InlineData("NtfyTopic")]
    [InlineData("ConnectionString")]
    [InlineData("ClientSecret")]
    public void SensitiveNamesAreRecognized(string name) =>
        SecretMaskingEnricher.IsSensitive(name).Should().BeTrue();

    [Theory(DisplayName = "Обычные имена свойств не затрагиваются")]
    [InlineData("RequestId")]
    [InlineData("EntityId")]
    [InlineData("Area")]
    [InlineData("Elapsed")]
    [InlineData("ComponentName")]
    public void OrdinaryNamesAreNotTouched(string name) =>
        SecretMaskingEnricher.IsSensitive(name).Should().BeFalse();

    [Fact(DisplayName = "Значение чувствительного свойства заменяется в событии лога")]
    public void SensitiveValueIsMaskedInLogEvent()
    {
        var sink = new CollectingSink();

        using Logger logger = new LoggerConfiguration()
            .MinimumLevel.Verbose()
            .Enrich.With<SecretMaskingEnricher>()
            .WriteTo.Sink(sink)
            .CreateLogger();

        // Значение намеренно не похоже на настоящий секрет: строка,
        // выглядящая как токен, срабатывает на правиле gitleaks — в
        // тестах секретоподобных литералов быть не должно.
        const string tokenValue = "значение-которого-не-должно-быть-в-логе";

        logger.Debug("Подключение к {Component} с {Token}", "ha", tokenValue);

        LogEvent captured = sink.Events.Should().ContainSingle().Subject;

        captured.Properties["Token"].ToString().Should().NotContain(tokenValue);
        captured.Properties["Token"].ToString().Should().Contain(SecretMaskingEnricher.Mask);
        captured.Properties["Component"].ToString().Should().Contain("ha");
    }

    private sealed class CollectingSink : ILogEventSink
    {
        public List<LogEvent> Events { get; } = [];

        public void Emit(LogEvent logEvent) => Events.Add(logEvent);
    }
}
