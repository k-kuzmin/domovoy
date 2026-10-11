using FluentAssertions;
using Microsoft.AspNetCore.Builder;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Configuration.Json;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;

namespace Domovoy.Tests;

/// <summary>
/// Тесты, поднимающие приложение, не зависят от машины, на которой их
/// запускают: ни user-secrets, ни переменные окружения разработчика до
/// тестового хоста не доходят (<see cref="DomovoyApiFactory"/>).
///
/// Каждая проверка идёт парой с положительным контролем: построитель
/// приложения в Development тот же источник видит — иначе отсутствие
/// источника у фабрики ничего бы не доказывало. Контроль собирается на
/// уровне построителя, без сборки и старта хоста: поднятый на машинной
/// конфигурации хост сам ходил бы в сеть с учётными данными разработчика.
/// Содержимое user-secrets не читается: проверяется наличие источника,
/// а не его значения.
/// </summary>
public sealed class TestHostConfigurationTests
{
    private const string UserSecretsFileName = "secrets.json";

    [Fact(DisplayName = "Тестовый хост не читает user-secrets разработчика и остаётся в Development")]
    public void UserSecretsAreNotLoaded()
    {
        WebApplicationBuilder control = CreateDevelopmentBuilder();

        control.Configuration.Sources.OfType<JsonConfigurationSource>()
            .Should().Contain(
                source => IsUserSecrets(source) && DomovoyApiFactory.IsMachineSource(source),
                "Development-построитель подключает user-secrets — на этом и держалась зависимость от машины");

        using var factory = new DomovoyApiFactory();

        ((IConfigurationRoot)factory.Services.GetRequiredService<IConfiguration>()).Providers
            .OfType<JsonConfigurationProvider>()
            .Should().NotContain(
                provider => IsUserSecrets(provider.Source),
                "тестовый хост не должен видеть секреты того, кто запускает тесты");

        // Окружение не меняется: в Development хост проверяет DI-граф
        // при сборке, и эта проверка нужна всем тестам приложения.
        factory.Services.GetRequiredService<IHostEnvironment>().IsDevelopment().Should().BeTrue();
    }

    [Fact(DisplayName = "Тестовый хост не читает переменные окружения машины")]
    public void MachineEnvironmentVariablesAreNotLoaded()
    {
        // Ключ, которого приложение не знает: переменная процесса не
        // влияет ни на один соседний тест.
        const string variable = "DomovoyTestHostProbe__Marker";
        const string key = "DomovoyTestHostProbe:Marker";

        Environment.SetEnvironmentVariable(variable, "machine");

        try
        {
            CreateDevelopmentBuilder().Configuration[key].Should().Be(
                "machine",
                "построитель приложения читает переменные окружения машины");

            using var factory = new DomovoyApiFactory();

            factory.Services.GetRequiredService<IConfiguration>()[key].Should().BeNull(
                "переменные окружения машины не должны доходить до тестового хоста");
        }
        finally
        {
            Environment.SetEnvironmentVariable(variable, null);
        }
    }

    /// <summary>
    /// Тот же построитель, что у приложения: имя сборки Api даёт
    /// UserSecretsId, окружение — то, в котором запускает фабрика.
    /// </summary>
    private static WebApplicationBuilder CreateDevelopmentBuilder() =>
        WebApplication.CreateBuilder(new WebApplicationOptions
        {
            ApplicationName = typeof(Program).Assembly.GetName().Name,
            EnvironmentName = Environments.Development,
        });

    private static bool IsUserSecrets(FileConfigurationSource source) =>
        string.Equals(source.Path, UserSecretsFileName, StringComparison.OrdinalIgnoreCase);
}
