using Domovoy.Core.Abstractions;
using Domovoy.Core.Configuration;
using Domovoy.Core.Models;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Domovoy.Ha;

/// <summary>
/// Allow-list сущностей, загружаемый из файла реестра (FR-HA-4).
///
/// Каркас: до реализации список пуст, то есть агенту не видна ни одна
/// сущность. Это безопасное значение по умолчанию — пустой allow-list
/// запрещает всё, а не разрешает.
/// </summary>
internal sealed class ConfiguredEntityAllowList : IEntityAllowList
{
    private readonly HaOptions _options;
    private readonly ILogger<ConfiguredEntityAllowList> _logger;

    public ConfiguredEntityAllowList(IOptions<HaOptions> options, ILogger<ConfiguredEntityAllowList> logger)
    {
        ArgumentNullException.ThrowIfNull(options);

        _options = options.Value;
        _logger = logger;
    }

    public IReadOnlyList<HaEntityDescriptor> All { get; } = [];

    public bool IsActionAllowed(string entityId, string action) => false;

    public HaEntityDescriptor? Find(string entityId) => null;
}
