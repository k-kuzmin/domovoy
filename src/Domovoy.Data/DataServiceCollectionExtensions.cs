using Domovoy.Core.Abstractions;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;

namespace Domovoy.Data;

/// <summary>Регистрация слоя данных.</summary>
public static class DataServiceCollectionExtensions
{
    /// <summary>Имя строки подключения в конфигурации.</summary>
    public const string ConnectionStringName = "Domovoy";

    public static IServiceCollection AddDomovoyData(
        this IServiceCollection services,
        IConfiguration configuration)
    {
        ArgumentNullException.ThrowIfNull(services);
        ArgumentNullException.ThrowIfNull(configuration);

        string? connectionString = configuration.GetConnectionString(ConnectionStringName);

        services.AddDbContext<DomovoyDbContext>(options => options.UseNpgsql(connectionString));

        services.AddScoped<IConversationStore, EfConversationStore>();
        services.AddScoped<IMemoryStore, EfMemoryStore>();
        services.AddScoped<IAuditLog, EfAuditLog>();
        services.AddScoped<ITokenLedger, EfTokenLedger>();
        services.AddScoped<IHomeProfileStore, FileHomeProfileStore>();
        services.AddScoped<IComponentProbe, DatabaseProbe>();

        return services;
    }
}
