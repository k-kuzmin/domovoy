using Domovoy.Core.Abstractions;
using Domovoy.Core.Configuration;
using Microsoft.Extensions.Options;

namespace Domovoy.Data;

/// <summary>
/// Профиль дома в файле (FR-MEM-2).
///
/// Файл, а не таблица: профиль правится вручную и читается человеком,
/// текстовый файл под рукой удобнее строки в базе. Реальный файл закрыт
/// .gitignore, в репозитории лежит только вымышленный пример.
///
/// Каркас: реализация появляется на этапе 6.
/// </summary>
internal sealed class FileHomeProfileStore : IHomeProfileStore
{
    private readonly HomeProfileOptions _options;

    public FileHomeProfileStore(IOptions<HomeProfileOptions> options)
    {
        ArgumentNullException.ThrowIfNull(options);

        _options = options.Value;
    }

    public Task<string> GetAsync(CancellationToken cancellationToken) =>
        throw new NotImplementedException("Этап 6: чтение профиля дома.");

    public Task SetAsync(string profile, CancellationToken cancellationToken) =>
        throw new NotImplementedException("Этап 6: запись профиля через админ-эндпоинт.");
}
