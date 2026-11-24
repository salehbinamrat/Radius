using System.Diagnostics;
using Npgsql;

namespace RadiusManager.Api;

/// <summary>One independent, bounded read-only probe per cycle, regardless of UI connections.</summary>
public sealed class ServiceObservationWorker(NpgsqlDataSource dataSource,
    ServiceObservationHistory history) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(ServiceObservationHistory.IntervalSeconds));
        do
        {
            var state = "unknown";
            double? duration = null;
            using (var deadline = CancellationTokenSource.CreateLinkedTokenSource(stoppingToken))
            {
                deadline.CancelAfter(TimeSpan.FromSeconds(5));
                var started = Stopwatch.GetTimestamp();
                try
                {
                    await using var command = dataSource.CreateCommand("SELECT 1");
                    command.CommandTimeout = 4;
                    var result = await command.ExecuteScalarAsync(deadline.Token);
                    if (!deadline.IsCancellationRequested && result is int value && value == 1)
                    {
                        state = "reachable";
                        duration = Math.Round(Stopwatch.GetElapsedTime(started).TotalMilliseconds, 2);
                    }
                }
                catch (OperationCanceledException) when (!stoppingToken.IsCancellationRequested)
                {
                    state = "no-response";
                }
                catch (NpgsqlException) when (!stoppingToken.IsCancellationRequested)
                {
                    state = "no-response";
                }
            }
            stoppingToken.ThrowIfCancellationRequested();
            var radius = RadiusHealthEvidence.Read();
            history.Add(new(DateTimeOffset.UtcNow, state, duration, radius.State, radius.CheckedAtUtc));
        } while (await timer.WaitForNextTickAsync(stoppingToken));
    }
}
