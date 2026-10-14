using System.Text.RegularExpressions;
using Domovoy.Core.Configuration;
using Domovoy.Core.Models;
using Domovoy.Ha;
using Domovoy.Ha.Registry;
using FluentAssertions;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Options;
using NSubstitute;

namespace Domovoy.Tests.Ha;

/// <summary>
/// Реестр сущностей (#10): файл YAML → <see cref="EntityRegistryOptions"/> →
/// проверка → allow-list. Испорченные реестры строятся из примера
/// <c>config/entities.example.yaml</c> вставкой одной записи: остальное
/// заведомо проходит проверку, и отказ относится ровно к вставке.
/// </summary>
public sealed partial class EntityRegistryTests : IDisposable
{
    private static readonly string ExamplePath = RepositoryLayout.Path("config", "entities.example.yaml");

    private readonly DirectoryInfo _workDirectory =
        Directory.CreateTempSubdirectory("domovoy-registry-");

    public void Dispose() => _workDirectory.Delete(recursive: true);

    [Fact(DisplayName = "Пример реестра проходит проверку, у каждой сущности заданы все поля")]
    public void ExampleRegistryLoadsEveryEntityWithAllFields()
    {
        EntityRegistryOptions registry = Load(ExamplePath);

        ValidateOptionsResult result = new EntityRegistryValidator().Validate(Options.DefaultName, registry);
        result.Succeeded.Should().BeTrue(result.FailureMessage);

        var allowList = new ConfiguredEntityAllowList(Options.Create(registry));

        // Число записей считается по тексту файла, а не по разбору:
        // иначе тест сверял бы разбор с самим собой.
        int entitiesInFile = EntityIdLine().Matches(File.ReadAllText(ExamplePath)).Count;
        entitiesInFile.Should().BePositive();
        allowList.All.Should().HaveCount(entitiesInFile);

        allowList.All.Should().AllSatisfy(entity =>
        {
            entity.EntityId.Should().NotBeNullOrWhiteSpace();
            entity.FriendlyName.Should().NotBeNullOrWhiteSpace(entity.EntityId);
            entity.Area.Should().NotBeNullOrWhiteSpace(entity.EntityId);
            entity.Domain.Should().NotBeNullOrWhiteSpace(entity.EntityId);
            entity.AllowedActions.Should().NotBeEmpty(entity.EntityId);
            entity.EntityId.Should().StartWith(entity.Domain + ".");

            HaAreaDescriptor? area = allowList.FindArea(entity.Area);
            area.Should().NotBeNull(entity.EntityId);
            area!.Prepositional.Should().NotBeNullOrWhiteSpace(entity.EntityId);
        });

        allowList.Areas.Should().HaveCount(AreaIdLine().Matches(File.ReadAllText(ExamplePath)).Count);
        allowList.Find("lock.example_front_door")!.RequiresConfirmation.Should().BeTrue();
        allowList.FindArea("kitchen").Should().BeEquivalentTo(new HaAreaDescriptor
        {
            Id = "kitchen",
            Name = "Кухня",
            Prepositional = "на кухне",
            Genitive = "кухни",
        });
    }

    [Fact(DisplayName = "Относительный путь к реестру считается от корня содержимого хоста")]
    public void RelativePathIsResolvedFromContentRoot()
    {
        EntityRegistryOptions registry = Load(
            Path.Combine("config", "entities.example.yaml"),
            contentRoot: RepositoryLayout.Root.FullName);

        registry.LoadError.Should().BeNull();
        registry.Entities.Should().NotBeEmpty();
    }

    [Fact(DisplayName = "Allow-list сравнивает entity_id и действие без поправок на регистр")]
    public void AllowListMatchesOrdinally()
    {
        var allowList = new ConfiguredEntityAllowList(Options.Create(Load(ExamplePath)));

        allowList.Find("light.example_kitchen_ceiling").Should().NotBeNull();
        allowList.Find("Light.Example_Kitchen_Ceiling").Should().BeNull();
        allowList.Find("light.unknown").Should().BeNull();

        allowList.IsActionAllowed("light.example_kitchen_ceiling", "turn_on").Should().BeTrue();
        allowList.IsActionAllowed("light.example_kitchen_ceiling", "TURN_ON").Should().BeFalse();
        allowList.IsActionAllowed("sensor.example_bedroom_temperature", "turn_on").Should().BeFalse();
        allowList.IsActionAllowed("light.unknown", "turn_on").Should().BeFalse();

        allowList.FindArea("attic").Should().BeNull();
    }

    public static TheoryData<string, string, string, string> InvalidRegistries => new()
    {
        {
            "entities",
            Entity("cover.example_hall_blinds", "Шторы", "living_room", "cover", "[open_cover]"),
            "cover.example_hall_blinds",
            "domain"
        },
        {
            "entities",
            Entity("alarm_control_panel.example_home", "Сигнализация", "living_room", "alarm_control_panel", "[alarm_arm_away]"),
            "alarm_control_panel.example_home",
            "domain"
        },
        {
            "entities",
            Entity("light.example_hall", "Свет в прихожей", "living_room", "light", "[turn_on, unlock]"),
            "light.example_hall",
            "actions"
        },
        {
            "entities",
            Entity("light.example_hall", null, "living_room", "light", "[turn_on]"),
            "light.example_hall",
            "name"
        },
        {
            "entities",
            Entity("light.example_hall", "Свет в прихожей", null, "light", "[turn_on]"),
            "light.example_hall",
            "area"
        },
        {
            "entities",
            Entity("light.example_hall", "Свет в прихожей", "living_room", null, "[turn_on]"),
            "light.example_hall",
            "domain"
        },
        {
            "entities",
            Entity("light.example_hall", "Свет в прихожей", "living_room", "light", null),
            "light.example_hall",
            "actions"
        },
        {
            "entities",
            Entity("light.example_hall", "Свет в прихожей", "living_room", "light", "[]"),
            "light.example_hall",
            "actions"
        },
        {
            "entities",
            Entity("climate.example_hall_light", "Свет в прихожей", "living_room", "light", "[turn_on]"),
            "climate.example_hall_light",
            "entity_id"
        },
        {
            "entities",
            Entity("light.example_hall", "Свет в прихожей", "attic", "light", "[turn_on]"),
            "light.example_hall",
            "area"
        },
        {
            "entities",
            Entity("light.example_kitchen_ceiling", "Ещё один свет", "kitchen", "light", "[turn_on]"),
            "light.example_kitchen_ceiling",
            "entity_id"
        },
        {
            "entities",
            Entity(null, "Без идентификатора", "kitchen", "light", "[turn_on]"),
            "entities[",
            "entity_id"
        },
        {
            "areas",
            "  - id: hall\n    name: Прихожая\n    cases:\n      genitive: прихожей\n",
            "hall",
            "cases.prepositional"
        },
        {
            "areas",
            "  - id: hall\n    cases:\n      prepositional: в прихожей\n",
            "hall",
            "name"
        },
        {
            "scripts",
            "  - name: Без идентификатора\n",
            "scripts[",
            "script_id"
        },
    };

    [Theory(DisplayName = "Испорченный реестр не проходит проверку, сообщение называет запись и поле")]
    [MemberData(nameof(InvalidRegistries))]
    public void ValidatorRejectsInvalidRegistry(string section, string injected, string expectedRecord, string expectedField)
    {
        string path = WriteExampleWith(section, injected);

        ValidateOptionsResult result = new EntityRegistryValidator().Validate(Options.DefaultName, Load(path));

        result.Failed.Should().BeTrue();
        result.FailureMessage.Should().Contain(expectedRecord).And.Contain(expectedField);
    }

    [Fact(DisplayName = "Отсутствующий файл реестра не проходит проверку, сообщение называет путь")]
    public void ValidatorRejectsInvalidRegistryWhenFileIsMissing()
    {
        string path = Path.Combine(_workDirectory.FullName, "missing.yaml");

        EntityRegistryOptions registry = Load(path);
        ValidateOptionsResult result = new EntityRegistryValidator().Validate(Options.DefaultName, registry);

        registry.LoadError.Should().NotBeNull();
        result.Failed.Should().BeTrue();
        result.FailureMessage.Should().Contain(path);
    }

    [Fact(DisplayName = "Незнакомый ключ — ошибка разбора; сообщение без содержимого файла")]
    public void ValidatorRejectsInvalidRegistryWithUnknownKey()
    {
        string path = WriteExampleWith(
            "entities",
            Entity("light.example_hall", "Свет в прихожей", "living_room", "light", "[turn_on]")
            + "    secret_note: do-not-echo-this-value\n");

        EntityRegistryOptions registry = Load(path);
        ValidateOptionsResult result = new EntityRegistryValidator().Validate(Options.DefaultName, registry);

        result.Failed.Should().BeTrue();
        result.FailureMessage.Should().Contain(path);
        result.FailureMessage.Should().NotContain("do-not-echo-this-value");
    }

    [Fact(DisplayName = "Ключ load_error в файле не заполняет ошибку загрузки")]
    public void LoadErrorIsNotAFileKey()
    {
        string example = File.ReadAllText(ExamplePath);
        string path = Path.Combine(_workDirectory.FullName, "entities.yaml");
        File.WriteAllText(path, "load_error: подложено\n" + example);

        EntityRegistryOptions registry = Load(path);

        registry.LoadError.Should().NotBe("подложено");
        registry.LoadError.Should().NotBeNull("load_error — незнакомый ключ файла");
    }

    private static EntityRegistryOptions Load(string path, string? contentRoot = null)
    {
        IHostEnvironment environment = Substitute.For<IHostEnvironment>();
        environment.ContentRootPath.Returns(contentRoot ?? Path.GetTempPath());

        var loader = new EntityRegistryFileLoader(
            Options.Create(new HaOptions { EntityRegistryPath = path }),
            environment);

        var registry = new EntityRegistryOptions();
        loader.Configure(registry);
        return registry;
    }

    private static string Entity(string? entityId, string? name, string? area, string? domain, string? actions)
    {
        var lines = new List<string>();

        void Add(string key, string? value)
        {
            if (value is not null)
            {
                lines.Add($"{(lines.Count == 0 ? "  - " : "    ")}{key}: {value}");
            }
        }

        Add("entity_id", entityId);
        Add("name", name);
        Add("area", area);
        Add("domain", domain);
        Add("actions", actions);

        return string.Join('\n', lines) + "\n";
    }

    /// <summary>Пример реестра со вставкой в конец раздела.</summary>
    private string WriteExampleWith(string section, string injected)
    {
        string example = File.ReadAllText(ExamplePath).ReplaceLineEndings("\n");

        string next = section switch
        {
            "areas" => "\nentities:",
            "entities" => "\nscripts:",
            "scripts" => null!,
            _ => throw new ArgumentOutOfRangeException(nameof(section), section, null),
        };

        string content = next is null
            ? example.TrimEnd('\n') + "\n" + injected
            : example.Replace(next, "\n" + injected + next, StringComparison.Ordinal);

        content.Should().NotBe(example, "вставка должна попасть в файл");

        string path = Path.Combine(_workDirectory.FullName, "entities.yaml");
        File.WriteAllText(path, content);
        return path;
    }

    [GeneratedRegex(@"^\s*-\s*entity_id:", RegexOptions.Multiline)]
    private static partial Regex EntityIdLine();

    [GeneratedRegex(@"^\s*-\s*id:", RegexOptions.Multiline)]
    private static partial Regex AreaIdLine();
}
