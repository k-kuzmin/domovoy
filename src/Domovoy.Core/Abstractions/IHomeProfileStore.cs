namespace Domovoy.Core.Abstractions;

/// <summary>
/// Профиль дома: статическое описание — комнаты, устройства, кто живёт,
/// типичный распорядок (FR-MEM-2). Подмешивается в системный промпт.
///
/// Содержимое профиля приватнее токенов: вместе с реестром сущностей
/// оно даёт планировку, состав жильцов и расписание отсутствия. В
/// репозитории лежит только вымышленный пример (ТЗ 5.1.3).
/// </summary>
public interface IHomeProfileStore
{
    Task<string> GetAsync(CancellationToken cancellationToken);

    /// <summary>Заменить профиль. Доступно только через админ-эндпоинт.</summary>
    Task SetAsync(string profile, CancellationToken cancellationToken);
}
