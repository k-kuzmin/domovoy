using System.Runtime.CompilerServices;
using Domovoy.Core.Abstractions;
using Domovoy.Core.Models;

namespace Domovoy.Core.Orchestration;

/// <summary>
/// Оркестратор без LLM: только быстрый путь (FR-CORE-2). Итог
/// <see cref="IFastPath"/> превращается в поток событий (FR-CORE-8).
///
/// Фраза, не подошедшая ни к одному шаблону, получает фиксированный
/// ответ <see cref="NotUnderstoodReply"/>: пути через LLM ещё нет.
///
/// Имя сущности в ответе берётся из allow-list, а не из ответа Home
/// Assistant: ответ HA — данные, а не текст для пользователя (NFR-SEC-6).
///
/// Исключения <see cref="IFastPath"/>, включая отмену, не перехватываются —
/// их переводит в ответ эндпоинт.
/// </summary>
public sealed class FastPathOrchestrator : IOrchestrator
{
    /// <summary>Ответ на фразу, не подошедшую ни к одному шаблону.</summary>
    public const string NotUnderstoodReply = "Пока не умею выполнять такие запросы.";

    private const string ReadAction = "read";

    private readonly IFastPath _fastPath;
    private readonly IEntityAllowList _allowList;
    private readonly TimeProvider _timeProvider;

    public FastPathOrchestrator(IFastPath fastPath, IEntityAllowList allowList, TimeProvider timeProvider)
    {
        ArgumentNullException.ThrowIfNull(fastPath);
        ArgumentNullException.ThrowIfNull(allowList);
        ArgumentNullException.ThrowIfNull(timeProvider);

        _fastPath = fastPath;
        _allowList = allowList;
        _timeProvider = timeProvider;
    }

    public async IAsyncEnumerable<AgentEvent> HandleAsync(
        AgentRequest request,
        [EnumeratorCancellation] CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);

        DateTimeOffset started = _timeProvider.GetUtcNow();
        FastPathOutcome outcome = await _fastPath.TryHandleAsync(request.Text, cancellationToken).ConfigureAwait(false);

        if (!outcome.Matched)
        {
            yield return new TokenEvent(NotUnderstoodReply);
            yield return Done(request, started);
            yield break;
        }

        FastRouteMatch match = outcome.Match
            ?? throw new InvalidOperationException("Быстрый путь сообщил о совпадении без шаблона.");
        ToolResult result = outcome.Result
            ?? throw new InvalidOperationException("Быстрый путь сообщил о совпадении без результата.");

        if (!result.Success)
        {
            if (result.ErrorCode is not null)
            {
                // Отказ с кодом прерывает поток: done после error не отдаётся.
                yield return new ErrorEvent(result.ErrorCode, result.Error ?? string.Empty);
                yield break;
            }

            yield return new TokenEvent(result.Error ?? string.Empty);
            yield return Done(request, started);
            yield break;
        }

        string? friendlyName = _allowList.Find(match.EntityId)?.FriendlyName;
        string payload = result.Payload ?? string.Empty;

        if (string.Equals(match.Action, ReadAction, StringComparison.Ordinal))
        {
            yield return new TokenEvent(friendlyName is null ? payload : $"{friendlyName}: {payload}.");
        }
        else
        {
            yield return new ActionEvent(match.EntityId, match.Action, true);
            yield return new TokenEvent(friendlyName is null ? "Готово." : $"Готово: {friendlyName}.");
        }

        yield return Done(request, started);
    }

    private DoneEvent Done(AgentRequest request, DateTimeOffset started) => new(new ResponseMetadata
    {
        RequestId = request.RequestId,
        Path = ResponsePath.FastRouter,
        Elapsed = _timeProvider.GetUtcNow() - started,
        ToolCallCount = 0,
        Usage = null,
    });
}
