using YamlDotNet.Serialization;

namespace Domovoy.Ha.Registry;

/// <summary>
/// Реестр сущностей — allow-list (FR-HA-4, FR-HA-5) в том виде, в каком он
/// лежит в файле <c>config/entities.yaml</c>. Поля один к одному с ключами
/// файла (snake_case); незнакомый ключ — ошибка разбора, а не пропущенное
/// поле.
///
/// Заполняет <see cref="EntityRegistryFileLoader"/>, проверяет
/// <see cref="EntityRegistryValidator"/>. Обязательные поля объявлены
/// допускающими <c>null</c>: отсутствие ключа должно дойти до проверки, а
/// не подмениться значением по умолчанию.
/// </summary>
internal sealed class EntityRegistryOptions
{
    public List<AreaEntry?> Areas { get; set; } = [];

    public List<EntityEntry?> Entities { get; set; } = [];

    public List<ScriptEntry?> Scripts { get; set; } = [];

    /// <summary>
    /// Файл не найден или не разобран: путь и причина, без содержимого
    /// файла. Задан — проверка реестра отказывает. Ключом файла не является.
    /// </summary>
    [YamlIgnore]
    public string? LoadError { get; set; }
}

/// <summary>Комната.</summary>
internal sealed class AreaEntry
{
    public string? Id { get; set; }

    public string? Name { get; set; }

    public AreaCases? Cases { get; set; }
}

/// <summary>Падежи имени комнаты для шаблонов ответа и разбора фраз.</summary>
internal sealed class AreaCases
{
    /// <summary>Предложный падеж с предлогом: «на кухне». Обязателен.</summary>
    public string? Prepositional { get; set; }

    /// <summary>Родительный падеж: «кухни».</summary>
    public string? Genitive { get; set; }
}

/// <summary>Сущность Home Assistant, видимая агенту.</summary>
internal sealed class EntityEntry
{
    public string? EntityId { get; set; }

    public string? Name { get; set; }

    public string? Area { get; set; }

    public string? Domain { get; set; }

    public List<string?>? Actions { get; set; }

    public bool RequiresConfirmation { get; set; }
}

/// <summary>Сценарий Home Assistant.</summary>
internal sealed class ScriptEntry
{
    public string? ScriptId { get; set; }

    public string? Name { get; set; }

    public string? Description { get; set; }
}
