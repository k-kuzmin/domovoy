using Domovoy.Core.Abstractions;
using Domovoy.Core.Configuration;
using Domovoy.Core.Routing;
using Domovoy.Core.Routing.Templates;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;

namespace Domovoy.Core.DependencyInjection;

/// <summary>
/// Регистрация настроек и служб ядра.
///
/// Валидация выполняется на старте (<c>ValidateOnStart</c>), но
/// проверяет форму, а не наличие секретов: пустой или плейсхолдерный
/// секрет — это состояние «не сконфигурировано» в <c>/health</c>, а не
/// отказ запуска. Иначе <c>docker compose up</c> на
/// <c>.example</c>-конфигурации не поднялся бы (ТЗ 5.1.3).
/// </summary>
public static class CoreServiceCollectionExtensions
{
    public static IServiceCollection AddDomovoyCore(
        this IServiceCollection services,
        IConfiguration configuration)
    {
        ArgumentNullException.ThrowIfNull(services);
        ArgumentNullException.ThrowIfNull(configuration);

        services.AddValidatedOptions<HaOptions>(configuration, HaOptions.SectionName);
        services.AddValidatedOptions<LlmOptions>(configuration, LlmOptions.SectionName);
        services.AddValidatedOptions<NtfyOptions>(configuration, NtfyOptions.SectionName);
        services.AddValidatedOptions<VoiceOptions>(configuration, VoiceOptions.SectionName);
        services.AddValidatedOptions<ProactivityOptions>(configuration, ProactivityOptions.SectionName);
        services.AddValidatedOptions<HomeProfileOptions>(configuration, HomeProfileOptions.SectionName);
        services.AddValidatedOptions<ResponseTemplateOptions>(configuration, ResponseTemplateOptions.SectionName);

        // Быстрый путь (FR-CORE-2). Шаблоны перебираются в порядке
        // регистрации; новый шаблон — одна строка здесь, роутер не меняется.
        services.AddSingleton<IFastRouteTemplate, SwitchTemplate>();
        services.AddSingleton<IFastRouteTemplate, ReadValueTemplate>();
        services.AddSingleton<IFastRouteTemplate, SetValueTemplate>();
        services.AddSingleton<IFastRouter, FastRouter>();
        // Transient, не singleton: ранер держит IHaClient — типизированный
        // HttpClient, а долгоживущая ссылка на него не переживает смену DNS.
        services.AddTransient<IFastPath, FastPathRunner>();

        return services;
    }

    private static IServiceCollection AddValidatedOptions<TOptions>(
        this IServiceCollection services,
        IConfiguration configuration,
        string sectionName)
        where TOptions : class
    {
        services.AddOptions<TOptions>()
            .Bind(configuration.GetSection(sectionName))
            .ValidateDataAnnotations()
            .ValidateOnStart();

        return services;
    }
}
