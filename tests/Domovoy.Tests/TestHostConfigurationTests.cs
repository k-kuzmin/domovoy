using FluentAssertions;
using Microsoft.AspNetCore.Mvc.Testing;
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
/// Каждая проверка идёт парой: голая <c>WebApplicationFactory</c> тот же
/// источник видит — иначе отсутствие источника у фабрики ничего бы не
/// доказывало. Содержимое user-secrets при этом не читается: проверяется
/// наличие источника, а не его значения.
/// </summary>
public sealed class TestHostConfigurationTests
{
    private const string UserSecretsFileName = "secrets.json";

    [Fact(DisplayName = "Тестовый хост не читает user-secrets разработчика и остаётся в Development")]
    public void UserSecretsAreNotLoaded()
    {
        using var bare = new WebApplicationFactory<Program>();
        using var factory = new DomovoyApiFactory();

        HasUserSecretsSource(bare.Services).Should().BeTrue(
            "без фабрики Development-хост подключает user-secrets — на этом и держалась зависимость от машины");
        HasUserSecretsSource(factory.Services).Should().BeFalse(
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
            using var bare = new WebApplicationFactory<Program>();
            using var factory = new DomovoyApiFactory();

            bare.Services.GetRequiredService<IConfiguration>()[key].Should().Be(
                "machine",
                "без фабрики переменные окружения машины попадают в конфигурацию приложения");
            factory.Services.GetRequiredService<IConfiguration>()[key].Should().BeNull(
                "переменные окружения машины не должны доходить до тестового хоста");
        }
        finally
        {
            Environment.SetEnvironmentVariable(variable, null);
        }
    }

    private static bool HasUserSecretsSource(IServiceProvider services) =>
        ((IConfigurationRoot)services.GetRequiredService<IConfiguration>()).Providers
            .OfType<JsonConfigurationProvider>()
            .Any(provider => string.Equals(
                provider.Source.Path,
                UserSecretsFileName,
                StringComparison.OrdinalIgnoreCase));
}
