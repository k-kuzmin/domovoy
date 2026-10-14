using Domovoy.Core.Configuration;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Options;
using YamlDotNet.Core;
using YamlDotNet.Serialization;
using YamlDotNet.Serialization.NamingConventions;

namespace Domovoy.Ha.Registry;

/// <summary>
/// Читает файл реестра сущностей по <see cref="HaOptions.EntityRegistryPath"/>;
/// относительный путь считается от корня содержимого хоста.
///
/// Файл не найден или не разобран — <see cref="EntityRegistryOptions.LoadError"/>
/// с путём и причиной, и проверка реестра отказывает старту. Содержимое
/// файла в сообщение не попадает: текст ошибки разборщика может повторять
/// значения из файла, поэтому причина — место ошибки, а не его текст.
/// </summary>
internal sealed class EntityRegistryFileLoader : IConfigureOptions<EntityRegistryOptions>
{
    private readonly IOptions<HaOptions> _haOptions;
    private readonly IHostEnvironment _environment;

    public EntityRegistryFileLoader(IOptions<HaOptions> haOptions, IHostEnvironment environment)
    {
        _haOptions = haOptions;
        _environment = environment;
    }

    public void Configure(EntityRegistryOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);

        string path = Path.GetFullPath(_haOptions.Value.EntityRegistryPath, _environment.ContentRootPath);

        if (!File.Exists(path))
        {
            options.LoadError = $"Файл реестра сущностей не найден: {path}.";
            return;
        }

        EntityRegistryOptions? parsed;

        try
        {
            using StreamReader reader = File.OpenText(path);
            parsed = CreateDeserializer().Deserialize<EntityRegistryOptions?>(reader);
        }
        catch (YamlException exception)
        {
            options.LoadError =
                $"Файл реестра сущностей {path} не разобран: строка {exception.Start.Line}, " +
                $"столбец {exception.Start.Column} — незнакомый ключ, неверный тип значения или нарушен синтаксис YAML.";
            return;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            options.LoadError = $"Файл реестра сущностей {path} не прочитан: {exception.GetType().Name}.";
            return;
        }

        // Пустой файл или пустой раздел — пустой список: пустой allow-list
        // запрещает всё, а не разрешает.
        options.Areas = parsed?.Areas ?? [];
        options.Entities = parsed?.Entities ?? [];
        options.Scripts = parsed?.Scripts ?? [];
    }

    // Незнакомый ключ — исключение: IgnoreUnmatchedProperties не включается
    // намеренно, опечатка в ключе не должна молча выключать поле.
    private static IDeserializer CreateDeserializer() =>
        new DeserializerBuilder()
            .WithNamingConvention(UnderscoredNamingConvention.Instance)
            .Build();
}
