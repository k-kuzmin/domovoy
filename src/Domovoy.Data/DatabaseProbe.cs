using Domovoy.Core.Abstractions;
using Domovoy.Core.Configuration;
using Domovoy.Core.Models;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Logging;

namespace Domovoy.Data;

/// <summary>
/// Проверка доступности базы для <c>/health</c> (NFR-OBS-3).
/// Реализована по-настоящему уже на этапе каркаса.
/// </summary>
internal sealed class DatabaseProbe : IComponentProbe
{
    private readonly DomovoyDbContext _db;
    private readonly ILogger<DatabaseProbe> _logger;

    public DatabaseProbe(DomovoyDbContext db, ILogger<DatabaseProbe> logger)
    {
        _db = db;
        _logger = logger;
    }

    public string ComponentName => "db";

    public async Task<ComponentHealth> CheckAsync(CancellationToken cancellationToken)
    {
        string? connectionString = _db.Database.GetConnectionString();

        if (PlaceholderValues.IsUnset(connectionString))
        {
            return ComponentHealth.NotConfigured("строка подключения не задана");
        }

        try
        {
            bool reachable = await _db.Database.CanConnectAsync(cancellationToken).ConfigureAwait(false);

            return reachable
                ? ComponentHealth.Ok("соединение установлено")
                : ComponentHealth.Unreachable("база не отвечает");
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            // Текст исключения содержит хост и параметры подключения —
            // наружу не отдаём, в лог пишем на уровне отладки.
            _logger.LogDebug(ex, "Проверка базы данных завершилась ошибкой.");
            return ComponentHealth.Unreachable("ошибка подключения");
        }
    }
}
