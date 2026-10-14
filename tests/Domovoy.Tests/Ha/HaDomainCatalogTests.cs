using System.Text.Json.Nodes;
using Domovoy.Ha.Registry;
using FluentAssertions;

namespace Domovoy.Tests.Ha;

/// <summary>
/// Закрытый каталог доменов слоя Home Assistant — белый список сервисов
/// раздела 4.3 ТЗ. Тесты читают сам каталог, а не его копию: новое
/// действие проверяется в момент добавления.
/// </summary>
public sealed class HaDomainCatalogTests
{
    [Theory(DisplayName = "Чувствительный домен либо вне каталога, либо каждое его изменяющее действие требует подтверждения")]
    [InlineData("lock")]
    [InlineData("alarm_control_panel")]
    [InlineData("valve")]
    [InlineData("cover")]
    public void SensitiveDomainActionsRequireConfirmation(string domain)
    {
        if (!HaDomainCatalog.IsKnownDomain(domain))
        {
            HaDomainCatalog.Actions.Should().NotContainKey(domain);
            return;
        }

        IReadOnlyDictionary<string, HaActionSpec> actions = HaDomainCatalog.Actions[domain];

        actions.Should().NotBeEmpty("известный чувствительный домен без действий проверять нечего — это ошибка каталога");
        actions.Should().AllSatisfy(pair =>
            pair.Value.RequiresConfirmation.Should().BeTrue(
                $"{domain}.{pair.Key} меняет замок, сигнализацию, ворота или газ — правило 6 раздела «Безопасность»"));
    }

    [Fact(DisplayName = "Замок управляется только с подтверждением: lock и unlock помечены")]
    public void LockActionsAreMarkedForConfirmation()
    {
        HaDomainCatalog.Resolve("lock", "lock")!.RequiresConfirmation.Should().BeTrue();
        HaDomainCatalog.Resolve("lock", "unlock")!.RequiresConfirmation.Should().BeTrue();
    }

    [Fact(DisplayName = "Каталог — закрытый перечень доменов этого этапа")]
    public void CatalogContainsOnlyKnownDomains()
    {
        HaDomainCatalog.Actions.Keys.Should().BeEquivalentTo(
            "light", "media_player", "vacuum", "climate", "lock", "sensor", "binary_sensor");

        HaDomainCatalog.IsKnownDomain("switch").Should().BeFalse();
        HaDomainCatalog.IsKnownDomain("cover").Should().BeFalse();
    }

    [Fact(DisplayName = "Каждое действие со значением описано типом и границами, без значения — без них")]
    public void CatalogValueActionsAreFullyDescribed()
    {
        List<(string Domain, string Action, HaActionSpec Spec)> all = HaDomainCatalog.Actions
            .SelectMany(domain => domain.Value.Select(action => (domain.Key, action.Key, action.Value)))
            .ToList();

        all.Should().NotBeEmpty();

        foreach ((string domain, string action, HaActionSpec spec) in all)
        {
            string because = $"{domain}.{action}";

            spec.Service.Should().NotBeNullOrWhiteSpace(because);

            if (spec.ValueField is null)
            {
                spec.Kind.Should().Be(HaValueKind.None, because);
                spec.Min.Should().BeNull(because);
                spec.Max.Should().BeNull(because);
                spec.MaxLength.Should().BeNull(because);
                continue;
            }

            spec.ValueField.Should().NotBeEmpty(because);
            spec.Kind.Should().NotBe(HaValueKind.None, because);

            switch (spec.Kind)
            {
                case HaValueKind.Integer:
                case HaValueKind.Number:
                case HaValueKind.PercentAsFraction:
                    spec.Min.Should().NotBeNull(because);
                    spec.Max.Should().NotBeNull(because);
                    spec.Min.Should().BeLessThanOrEqualTo(spec.Max!.Value, because);
                    spec.MaxLength.Should().BeNull(because);
                    break;
                case HaValueKind.String:
                    spec.MaxLength.Should().BePositive(because);
                    spec.Min.Should().BeNull(because);
                    spec.Max.Should().BeNull(because);
                    break;
                case HaValueKind.Boolean:
                    spec.Min.Should().BeNull(because);
                    spec.Max.Should().BeNull(because);
                    spec.MaxLength.Should().BeNull(because);
                    break;
                default:
                    throw new InvalidOperationException($"{because}: тип значения {spec.Kind} не описан в тесте.");
            }
        }
    }

    [Fact(DisplayName = "read есть в каждом домене каталога и не вызывает сервис")]
    public void ReadIsAllowedEverywhereAndResolvesToNothing()
    {
        foreach (string domain in HaDomainCatalog.Actions.Keys)
        {
            HaDomainCatalog.IsActionAllowed(domain, HaDomainCatalog.ReadAction).Should().BeTrue(domain);
            HaDomainCatalog.Resolve(domain, HaDomainCatalog.ReadAction).Should().BeNull(domain);
        }
    }

    [Theory(DisplayName = "Действие вне домена или неизвестный домен не разрешены")]
    [InlineData("light", "unlock")]
    [InlineData("sensor", "turn_on")]
    [InlineData("cover", "open_cover")]
    [InlineData("switch", "turn_on")]
    [InlineData("lock", "open")]
    public void ForeignActionIsNotAllowed(string domain, string action)
    {
        HaDomainCatalog.IsActionAllowed(domain, action).Should().BeFalse();
        HaDomainCatalog.Resolve(domain, action).Should().BeNull();
    }

    [Theory(DisplayName = "Действие выводит сервис HA по каталогу")]
    [InlineData("light", "set_brightness", "turn_on")]
    [InlineData("light", "toggle", "toggle")]
    [InlineData("media_player", "volume_set", "volume_set")]
    [InlineData("climate", "set_temperature", "set_temperature")]
    [InlineData("vacuum", "return_to_base", "return_to_base")]
    public void ActionResolvesToService(string domain, string action, string service)
    {
        HaDomainCatalog.Resolve(domain, action)!.Service.Should().Be(service);
    }

    [Theory(DisplayName = "Тело вызова типизировано: число — числом, флаг — булевым")]
    [InlineData("light", "set_brightness", "40", """{"entity_id":"light.example","brightness_pct":40}""")]
    [InlineData("light", "set_brightness", "0", """{"entity_id":"light.example","brightness_pct":0}""")]
    [InlineData("light", "turn_on", null, """{"entity_id":"light.example"}""")]
    [InlineData("media_player", "volume_set", "30", """{"entity_id":"light.example","volume_level":0.3}""")]
    [InlineData("media_player", "volume_set", "100", """{"entity_id":"light.example","volume_level":1}""")]
    [InlineData("media_player", "volume_mute", "true", """{"entity_id":"light.example","is_volume_muted":true}""")]
    [InlineData("media_player", "volume_mute", "false", """{"entity_id":"light.example","is_volume_muted":false}""")]
    [InlineData("media_player", "select_source", "HDMI 1", """{"entity_id":"light.example","source":"HDMI 1"}""")]
    [InlineData("climate", "set_temperature", "22.5", """{"entity_id":"light.example","temperature":22.5}""")]
    [InlineData("climate", "set_temperature", "22,5", """{"entity_id":"light.example","temperature":22.5}""")]
    [InlineData("climate", "set_temperature", "7", """{"entity_id":"light.example","temperature":7}""")]
    [InlineData("climate", "set_temperature", "35", """{"entity_id":"light.example","temperature":35}""")]
    public void PayloadIsTyped(string domain, string action, string? value, string expectedJson)
    {
        HaActionSpec spec = HaDomainCatalog.Resolve(domain, action)!;

        bool built = HaDomainCatalog.TryBuildPayload(spec, "light.example", value, out JsonObject payload);

        built.Should().BeTrue();
        payload.ToJsonString().Should().Be(expectedJson);
    }

    [Theory(DisplayName = "Значение не того типа, вне границ, лишнее или пропущенное — отказ")]
    [InlineData("light", "set_brightness", "101")]
    [InlineData("light", "set_brightness", "-1")]
    [InlineData("light", "set_brightness", "40.5")]
    [InlineData("light", "set_brightness", "сорок")]
    [InlineData("light", "set_brightness", null)]
    [InlineData("light", "set_brightness", "")]
    [InlineData("light", "turn_on", "1")]
    [InlineData("media_player", "volume_set", "0.3")]
    [InlineData("media_player", "volume_set", "150")]
    [InlineData("media_player", "volume_mute", "1")]
    [InlineData("media_player", "volume_mute", "да")]
    [InlineData("media_player", "select_source", "   ")]
    [InlineData("climate", "set_temperature", "6.9")]
    [InlineData("climate", "set_temperature", "35.5")]
    [InlineData("climate", "set_temperature", "1e2")]
    [InlineData("climate", "set_temperature", "1,000.5")]
    public void InvalidValueIsRejected(string domain, string action, string? value)
    {
        HaActionSpec spec = HaDomainCatalog.Resolve(domain, action)!;

        HaDomainCatalog.TryBuildPayload(spec, "light.example", value, out _).Should().BeFalse();
    }

    [Fact(DisplayName = "Строка длиннее предела — отказ, на пределе — как есть")]
    public void StringValueIsLimitedByMaxLength()
    {
        HaActionSpec spec = HaDomainCatalog.Resolve("media_player", "select_source")!;
        int limit = spec.MaxLength!.Value;

        HaDomainCatalog.TryBuildPayload(spec, "media_player.example", new string('a', limit), out JsonObject payload)
            .Should().BeTrue();
        payload["source"]!.GetValue<string>().Should().HaveLength(limit);

        HaDomainCatalog.TryBuildPayload(spec, "media_player.example", new string('a', limit + 1), out _)
            .Should().BeFalse();
    }
}
