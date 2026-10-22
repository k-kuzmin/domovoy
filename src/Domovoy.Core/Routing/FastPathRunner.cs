using Domovoy.Core.Abstractions;
using Domovoy.Core.Models;

namespace Domovoy.Core.Routing;

/// <summary>
/// Быстрый путь целиком (FR-CORE-2, NFR-PERF-1): роутер и прямой вызов
/// Home Assistant, без LLM.
///
/// Нет совпадения — <see cref="FastPathOutcome.NotMatched"/> без обращения к
/// Home Assistant: это условие перехода на путь через LLM. Совпадение
/// исполняется через <see cref="IHaClient"/>: действие <c>read</c> —
/// <see cref="IHaClient.GetStatesAsync"/>, остальное —
/// <see cref="IHaClient.CallServiceAsync"/>.
///
/// Allow-list раннер не проверяет и сущность не отбрасывает: проверка — одна
/// точка на входе в слой Home Assistant. Домен берётся из префикса
/// <c>entity_id</c> (реестр требует совпадения префикса с доменом); чужой
/// домен или сущность вне списка отклоняет слой Home Assistant.
/// </summary>
public sealed class FastPathRunner : IFastPath
{
    private const string ReadAction = "read";
    private const string ClimateDomain = "climate";
    private const string CurrentTemperatureAttribute = "current_temperature";

    private readonly IFastRouter _router;
    private readonly IHaClient _haClient;

    public FastPathRunner(IFastRouter router, IHaClient haClient)
    {
        ArgumentNullException.ThrowIfNull(router);
        ArgumentNullException.ThrowIfNull(haClient);

        _router = router;
        _haClient = haClient;
    }

    public async Task<FastPathOutcome> TryHandleAsync(string text, CancellationToken cancellationToken)
    {
        FastRouteMatch? match = _router.TryMatch(text);
        if (match is null)
        {
            return FastPathOutcome.NotMatched;
        }

        string domain = DomainOf(match.EntityId);

        ToolResult result = string.Equals(match.Action, ReadAction, StringComparison.Ordinal)
            ? await ReadAsync(domain, match.EntityId, cancellationToken).ConfigureAwait(false)
            : await _haClient.CallServiceAsync(domain, match.Action, match.EntityId, match.Value, cancellationToken)
                .ConfigureAwait(false);

        return new FastPathOutcome { Matched = true, Match = match, Result = result };
    }

    private async Task<ToolResult> ReadAsync(string domain, string entityId, CancellationToken cancellationToken)
    {
        IReadOnlyList<HaEntityState> states;
        try
        {
            states = await _haClient.GetStatesAsync(area: null, domain: domain, cancellationToken).ConfigureAwait(false);
        }
        catch (HaUnavailableException)
        {
            return Refusal(HaErrorCodes.HaUnavailable, "Home Assistant недоступен.");
        }

        HaEntityState? state = states.FirstOrDefault(
            candidate => string.Equals(candidate.EntityId, entityId, StringComparison.Ordinal));

        // GetStatesAsync отдаёт только сущности из allow-list: отсутствие
        // в ответе — сущность вне списка или неизвестна Home Assistant.
        if (state is null)
        {
            return Refusal(HaErrorCodes.EntityNotAllowed, "Состояние сущности недоступно.");
        }

        return string.Equals(domain, ClimateDomain, StringComparison.Ordinal)
            ? ReadClimateTemperature(state)
            : Answer(state.State);
    }

    /// <summary>
    /// Состояние <c>climate</c> — режим работы (<c>off</c>, <c>heat</c>),
    /// а не температура: ответ на вопрос о ней — атрибут
    /// <c>current_temperature</c>. Единица — °C: проект исходит из
    /// Цельсия, границы <c>set_temperature</c> в каталоге доменов заданы в
    /// нём же. Атрибута нет — отказ без кода, режим вместо температуры не
    /// подставляется.
    /// </summary>
    private static ToolResult ReadClimateTemperature(HaEntityState state) =>
        state.Attributes.TryGetValue(CurrentTemperatureAttribute, out string? temperature)
            ? Answer($"{temperature} °C")
            : Refusal(errorCode: null, "Устройство не сообщает текущую температуру.");

    private static ToolResult Answer(string payload) => new()
    {
        ToolCallId = ToolResult.DirectCallId,
        Success = true,
        Payload = payload,
    };

    private static ToolResult Refusal(string? errorCode, string error) => new()
    {
        ToolCallId = ToolResult.DirectCallId,
        Success = false,
        Error = error,
        ErrorCode = errorCode,
    };

    private static string DomainOf(string entityId)
    {
        int dot = entityId.IndexOf('.', StringComparison.Ordinal);
        return dot > 0 ? entityId[..dot] : string.Empty;
    }
}
