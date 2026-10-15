using System.Collections.Concurrent;
using System.Globalization;
using System.Net;
using System.Text.Json;
using FluentAssertions;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.DependencyInjection;
using Serilog.Core;
using Serilog.Events;

namespace Domovoy.Tests.Auth;

/// <summary>
/// Токен устройства, код привязки и админ-секрет не попадают в лог ни на
/// каком уровне (#12, правило 3 раздела «Безопасность»).
///
/// Код привязки маскирующий enricher не распознаёт — слов code и pairing в
/// его списке нет, — поэтому защита держится на том, что его не логируют, и
/// проверяется сценарием целиком. Коллекция непараллельная по той же
/// причине, что у <see cref="OutboundHttpLoggingTests"/>: логгер Serilog
/// статический и общий для хостов процесса.
/// </summary>
[Collection(OutboundHttpLoggingSerialGroup.Name)]
public sealed class DeviceTokenLoggingTests : IClassFixture<DomovoyApiFactory>
{
    private readonly DomovoyApiFactory _factory;

    public DeviceTokenLoggingTests(DomovoyApiFactory factory) => _factory = factory;

    [Fact(DisplayName = "Код привязки, токен устройства и админ-секрет не попадают в лог даже на уровне Verbose")]
    public async Task PairingSecretsNeverReachLogs()
    {
        var sink = new CollectingSink();
        using WebApplicationFactory<Program> host = AuthTestApi.WithAdmin(
            _factory,
            services => services.AddSingleton<ILogEventSink>(sink),
            new Dictionary<string, string?>
            {
                ["Serilog:MinimumLevel:Default"] = "Verbose",
                // Обработчики аутентификации и маршрутизация пишут в
                // категориях Microsoft.AspNetCore — их тоже до Verbose.
                ["Serilog:MinimumLevel:Override:Microsoft.AspNetCore"] = "Verbose",
            });
        using HttpClient client = host.CreateClient();

        string code = await AuthTestApi.IssueCodeAsync(client);
        string token;
        using (HttpResponseMessage redeemed = await AuthTestApi.RedeemAsync(client, code, "logged-device"))
        {
            redeemed.StatusCode.Should().Be(HttpStatusCode.OK);
            using JsonDocument body = JsonDocument.Parse(await redeemed.Content.ReadAsStringAsync());
            token = body.RootElement.GetProperty("token").GetString()!;
        }

        using (HttpResponseMessage state = await AuthTestApi.SendAsync(client, HttpMethod.Get, "/api/v1/state", token))
        {
            state.StatusCode.Should().Be(HttpStatusCode.NotImplemented);
        }

        Guid id = await AuthTestApi.DeviceIdAsync(client, "logged-device");
        using (HttpResponseMessage revoked = await AuthTestApi.SendAsync(
                   client, HttpMethod.Delete, AuthTestApi.DevicePath(id), AuthTestApi.AdminToken))
        {
            revoked.StatusCode.Should().Be(HttpStatusCode.NoContent);
        }

        using (HttpResponseMessage rejected = await AuthTestApi.SendAsync(client, HttpMethod.Get, "/api/v1/state", token))
        {
            rejected.StatusCode.Should().Be(HttpStatusCode.Unauthorized);
        }

        List<LogEvent> events = sink.Events.ToList();

        // Положительный контроль: без событий своих запросов отсутствие
        // секретов ничего не доказывает — уровень или sink не применились.
        string[] paths = [AuthTestApi.PairingCodesPath, AuthTestApi.PairingPath, "/api/v1/state", AuthTestApi.DevicePath(id)];
        foreach (string path in paths)
        {
            events.Should().Contain(
                logEvent => Flatten(logEvent).Contains(path, StringComparison.Ordinal),
                $"на уровне Verbose запрос к {path} оставляет события в логе");
        }

        events.Should().Contain(logEvent => logEvent.Level == LogEventLevel.Verbose, "уровень Verbose применился");

        foreach ((string name, string secret) in new[]
                 {
                     ("код привязки", code),
                     ("токен устройства", token),
                     ("админ-секрет", AuthTestApi.AdminToken),
                 })
        {
            events.Count(logEvent => Flatten(logEvent).Contains(secret, StringComparison.Ordinal))
                .Should().Be(0, $"{name} не встречается ни в тексте, ни в свойствах, ни в исключениях событий");
        }
    }

    private static string Flatten(LogEvent logEvent) =>
        string.Join(
            '\n',
            new[] { logEvent.RenderMessage(CultureInfo.InvariantCulture), logEvent.Exception?.ToString() ?? "" }
                .Concat(logEvent.Properties.Values.Select(value => value.ToString())));

    private sealed class CollectingSink : ILogEventSink
    {
        private readonly ConcurrentQueue<LogEvent> _events = new();

        public IEnumerable<LogEvent> Events => _events;

        public void Emit(LogEvent logEvent) => _events.Enqueue(logEvent);
    }
}
