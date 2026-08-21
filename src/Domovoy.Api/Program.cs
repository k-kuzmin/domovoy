using Domovoy.Api.Endpoints;
using Domovoy.Api.Health;
using Domovoy.Api.Logging;
using Domovoy.Api.Security;
using Domovoy.Core.DependencyInjection;
using Domovoy.Data;
using Domovoy.Ha;
using Domovoy.Llm;
using Domovoy.Notifications;
using Domovoy.Voice;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authorization;
using Serilog;

WebApplicationBuilder builder = WebApplication.CreateBuilder(args);

// Структурные логи с корреляцией по request_id через весь путь
// (NFR-OBS-1). Маскирование чувствительных полей — enricher: правило
// «токены не логируются никогда» должно выполняться механически, а не
// вниманием того, кто пишет вызов.
builder.Host.UseSerilog((context, services, configuration) => configuration
    .ReadFrom.Configuration(context.Configuration)
    .ReadFrom.Services(services)
    .Enrich.FromLogContext()
    .Enrich.With<SecretMaskingEnricher>());

builder.Services.AddDomovoyCore(builder.Configuration);
builder.Services.AddDomovoyData(builder.Configuration);
builder.Services.AddHomeAssistant();
builder.Services.AddLlm();
builder.Services.AddVoice();
builder.Services.AddNotifications();

// Аутентификация устройств по Bearer-токену.
builder.Services
    .AddAuthentication(DeviceTokenDefaults.SchemeName)
    .AddScheme<AuthenticationSchemeOptions, DeviceTokenAuthenticationHandler>(
        DeviceTokenDefaults.SchemeName,
        configureOptions: null);

// Новый эндпоинт по умолчанию требует аутентификации. Анонимный доступ
// возможен только явным AllowAnonymous — так решение видно в коде, а не
// возникает из-за забытого атрибута.
builder.Services.AddAuthorization(options =>
    options.FallbackPolicy = new AuthorizationPolicyBuilder()
        .RequireAuthenticatedUser()
        .Build());

builder.Services.AddHealthChecks()
    .AddCheck<ComponentsHealthCheck>("components", tags: ["components"]);

builder.Services.AddProblemDetails();

WebApplication app = builder.Build();

app.UseSerilogRequestLogging();
app.UseAuthentication();
app.UseAuthorization();

app.MapHealthEndpoints();
app.MapApiV1Endpoints();

await app.RunAsync().ConfigureAwait(false);

/// <summary>
/// Точка входа. Объявлена явно, чтобы тесты могли поднять приложение
/// через <c>WebApplicationFactory&lt;Program&gt;</c>.
/// </summary>
public partial class Program;
