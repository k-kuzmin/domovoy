using ArchUnitNET.Domain;
using ArchUnitNET.Fluent;
using ArchUnitNET.Loader;
using ArchUnitNET.xUnit;
using Domovoy.Core.Abstractions;
using Domovoy.Data;
using Domovoy.Ha;
using Domovoy.Llm;
using Domovoy.Notifications;
using Domovoy.Voice;
using static ArchUnitNET.Fluent.ArchRuleDefinition;

namespace Domovoy.Tests;

/// <summary>
/// Направление зависимостей проверяется тестом, а не соглашением.
/// Соглашение держится до первого «сейчас быстрее сослаться напрямую».
///
/// Правила описаны через сборки, а не через шаблоны пространств имён:
/// сборка — это и есть граница слоя, а пространство имён можно
/// переименовать и обойти правило, ничего не сломав.
/// </summary>
public sealed class ArchitectureTests
{
    private static readonly System.Reflection.Assembly CoreAssembly = typeof(IAgentTool).Assembly;
    private static readonly System.Reflection.Assembly HaAssembly = typeof(HaServiceCollectionExtensions).Assembly;
    private static readonly System.Reflection.Assembly LlmAssembly = typeof(LlmServiceCollectionExtensions).Assembly;
    private static readonly System.Reflection.Assembly VoiceAssembly = typeof(VoiceServiceCollectionExtensions).Assembly;
    private static readonly System.Reflection.Assembly DataAssembly = typeof(DataServiceCollectionExtensions).Assembly;
    private static readonly System.Reflection.Assembly ApiAssembly = typeof(Program).Assembly;

    private static readonly System.Reflection.Assembly NotificationsAssembly =
        typeof(NotificationsServiceCollectionExtensions).Assembly;

    private static readonly Architecture Architecture = new ArchLoader()
        .LoadAssemblies(
            CoreAssembly,
            HaAssembly,
            LlmAssembly,
            VoiceAssembly,
            NotificationsAssembly,
            DataAssembly,
            ApiAssembly)
        .Build();

    [Fact(DisplayName = "Ядро не зависит от транспорта, БД и провайдеров")]
    public void CoreDoesNotDependOnPeriphery()
    {
        IArchRule rule = Types().That().ResideInAssembly(CoreAssembly).As("ядро")
            .Should().NotDependOnAny(
                Types().That().ResideInAssembly(
                    ApiAssembly,
                    HaAssembly,
                    LlmAssembly,
                    VoiceAssembly,
                    NotificationsAssembly,
                    DataAssembly).As("периферия"))
            .Because("Core содержит только порты и модели: направление зависимостей — внутрь.");

        rule.Check(Architecture);
    }

    [Fact(DisplayName = "Адаптер Home Assistant не знает о провайдере LLM и о БД")]
    public void HaLayerIsIsolated()
    {
        IArchRule rule = Types().That().ResideInAssembly(HaAssembly).As("слой Home Assistant")
            .Should().NotDependOnAny(
                Types().That().ResideInAssembly(LlmAssembly, DataAssembly, ApiAssembly).As("другие слои"))
            .Because("связь между адаптерами идёт через порты в Core, а не напрямую.");

        rule.Check(Architecture);
    }

    [Fact(DisplayName = "Адаптер провайдера LLM не знает о Home Assistant и о БД")]
    public void LlmLayerIsIsolated()
    {
        IArchRule rule = Types().That().ResideInAssembly(LlmAssembly).As("слой LLM")
            .Should().NotDependOnAny(
                Types().That().ResideInAssembly(HaAssembly, DataAssembly, ApiAssembly).As("другие слои"))
            .Because("провайдер-специфичный код не должен видеть ни дом, ни хранилище.");

        rule.Check(Architecture);
    }

    [Fact(DisplayName = "Слой данных не зависит от транспорта и внешних адаптеров")]
    public void DataLayerIsIsolated()
    {
        IArchRule rule = Types().That().ResideInAssembly(DataAssembly).As("слой данных")
            .Should().NotDependOnAny(
                Types().That().ResideInAssembly(ApiAssembly, HaAssembly, LlmAssembly, VoiceAssembly).As("другие слои"))
            .Because("хранилище реализует порты Core и ничего не знает о том, кто его вызывает.");

        rule.Check(Architecture);
    }

    [Fact(DisplayName = "Порты ядра публичны: их реализуют другие сборки")]
    public void CorePortsArePublic()
    {
        IArchRule rule = Interfaces().That().ResideInAssembly(CoreAssembly).As("порты ядра")
            .Should().BePublic()
            .Because("порт реализуется другой сборкой — внутренний интерфейс реализовать снаружи нельзя.");

        rule.Check(Architecture);
    }

    [Fact(DisplayName = "Адаптеры не заводят публичных интерфейсов")]
    public void AdaptersDoNotDeclarePublicPorts()
    {
        // Интерфейс, объявленный в адаптере, известен только этому
        // адаптеру — подменить реализацию через него уже нельзя.
        //
        // Сейчас таких интерфейсов нет, и правило проверяет отсутствие
        // нарушений, а не наличие совпадений: WithoutRequiringPositiveResults
        // нужен именно для этого. Правило начнёт работать в тот момент,
        // когда кто-нибудь объявит порт не там, а не когда об этом
        // вспомнят.
        IArchRule rule = Interfaces().That()
            .ResideInAssembly(HaAssembly, LlmAssembly, VoiceAssembly, NotificationsAssembly, DataAssembly)
            .As("интерфейсы адаптеров")
            .Should().NotBePublic()
            .Because("место порта — в ядре, рядом с остальными абстракциями.")
            .WithoutRequiringPositiveResults();

        rule.Check(Architecture);
    }
}
