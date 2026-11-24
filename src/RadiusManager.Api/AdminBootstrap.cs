using System.Text;
using System.Text.RegularExpressions;
using Microsoft.AspNetCore.Identity;
using Microsoft.EntityFrameworkCore;
using Npgsql;

namespace RadiusManager.Api;

/// <summary>One-time, interactive, server-console-only first administrator enrollment.</summary>
public static class AdminBootstrap
{
    public static async Task<int> RunAsync(IServiceProvider services)
    {
        if (Console.IsInputRedirected || Console.IsOutputRedirected)
        {
            Console.Error.WriteLine("Bootstrap requires an interactive local operator terminal.");
            return 2;
        }
        await using var scope = services.CreateAsyncScope();
        var users = scope.ServiceProvider.GetRequiredService<UserManager<IdentityUser>>();
        var roles = scope.ServiceProvider.GetRequiredService<RoleManager<IdentityRole>>();
        if (!await roles.RoleExistsAsync("super-admin"))
        {
            Console.Error.WriteLine("Migration 005 must be applied first.");
            return 2;
        }
        if ((await users.GetUsersInRoleAsync("super-admin")).Count != 0)
        {
            Console.Error.WriteLine("A super-admin already exists. Bootstrap refused.");
            return 2;
        }
        Console.Write("First administrator username (Latin letters/digits/.-_): ");
        string? name = Console.ReadLine()?.Trim();
        if (name is null || !Regex.IsMatch(name, @"^[A-Za-z0-9._-]{3,40}$"))
        {
            Console.Error.WriteLine("Invalid administrator username.");
            return 2;
        }
        Console.Write("Strong password (hidden, minimum 14 characters): ");
        var chars = new StringBuilder();
        while (true)
        {
            var key = Console.ReadKey(intercept: true);
            if (key.Key == ConsoleKey.Enter) break;
            if (key.Key == ConsoleKey.Backspace)
            {
                if (chars.Length > 0) chars.Length--;
                continue;
            }
            if (!char.IsControl(key.KeyChar) && chars.Length < 256) chars.Append(key.KeyChar);
        }
        Console.WriteLine();
        var password = chars.ToString();
        chars.Clear();
        var db = scope.ServiceProvider.GetRequiredService<AdminIdentityDbContext>();
        try
        {
            // Never hold the database lock while waiting for human input.
            // All bootstrap processes use the same transaction-scoped lock.
            await using var transaction = await db.Database.BeginTransactionAsync(System.Data.IsolationLevel.ReadCommitted);
            await db.Database.ExecuteSqlRawAsync("SET LOCAL lock_timeout = '10s'");
            await db.Database.ExecuteSqlRawAsync("SELECT pg_advisory_xact_lock(470174, 1)");
            // Recheck AFTER the lock, even if the earlier interactive check passed.
            if ((await users.GetUsersInRoleAsync("super-admin")).Count != 0)
            {
                Console.Error.WriteLine("A super-admin already exists. Bootstrap refused.");
                return 2;
            }
            var user = new IdentityUser { UserName = name, LockoutEnabled = true };
            var created = await users.CreateAsync(user, password);
            if (!created.Succeeded)
            {
                Console.Error.WriteLine("Password/user policy rejected bootstrap request.");
                return 2;
            }
            var assigned = await users.AddToRoleAsync(user, "super-admin");
            if (!assigned.Succeeded)
            {
                Console.Error.WriteLine("Role assignment failed; bootstrap transaction rolled back.");
                return 2;
            }
            db.AdminAuditEvents.Add(new AdminAuditEvent
            {
                ActorUserId = user.Id, Action = "bootstrap_admin", SubjectKind = "admin",
                SubjectId = user.Id, Outcome = "success", OccurredAt = DateTime.UtcNow,
                CorrelationId = Guid.NewGuid()
            });
            await db.SaveChangesAsync();
            await transaction.CommitAsync();
            Console.WriteLine("Initial super-admin created without printing password. Enable HTTPS before session mode.");
            return 0;
        }
        catch (Exception ex) when (ex is NpgsqlException or DbUpdateException or TimeoutException)
        {
            // Disposal rolls back any uncommitted account, role or audit entry.
            // Do not print connection details, Identity fields, or credentials.
            Console.Error.WriteLine("Bootstrap database operation failed; check database availability before retrying.");
            return 2;
        }
    }
}
