using System.Threading.RateLimiting;
using Microsoft.AspNetCore.Http.Connections;
using System.Security.Claims;
using System.Security.Cryptography.X509Certificates;
using Microsoft.AspNetCore.DataProtection;
using Microsoft.AspNetCore.Identity;
using Microsoft.AspNetCore.Antiforgery;
using Microsoft.EntityFrameworkCore;
using Npgsql;
using RadiusManager.Api;

var builder = WebApplication.CreateBuilder(args);
var adminAuthMode = Environment.GetEnvironmentVariable("RADIUS_ADMIN_AUTH_MODE") ?? "basic";
if (adminAuthMode is not ("basic" or "session"))
    throw new InvalidOperationException("RADIUS_ADMIN_AUTH_MODE must be basic or session");
var sessionMode = adminAuthMode == "session";
// Session mode will not be silently activated on the current plain-HTTP container.
// A separate, tested HTTPS deployment must explicitly configure Kestrel TLS.
if (sessionMode && !(builder.Configuration["ASPNETCORE_URLS"] ?? "").Split(';')
    .Any(x => x.StartsWith("https://", StringComparison.OrdinalIgnoreCase)))
    throw new InvalidOperationException("Session mode requires a verified HTTPS Kestrel endpoint");
var adminUser = Environment.GetEnvironmentVariable("RADIUS_ADMIN_USER") ?? "admin";
var adminPassword = sessionMode ? "" : SecretInput.Resolve("RADIUS_ADMIN_PASSWORD",
    Environment.GetEnvironmentVariable("RADIUS_ADMIN_PASSWORD"),
    Environment.GetEnvironmentVariable("RADIUS_ADMIN_PASSWORD_FILE")) ?? "";
var connectionString = SecretInput.DatabaseConnection(
    builder.Configuration.GetConnectionString("RadiusDb"),
    Environment.GetEnvironmentVariable("RADIUS_DB_PASSWORD_FILE"));
if (!sessionMode && (adminUser.Length < 3 || adminPassword.Length < 24))
    throw new InvalidOperationException("Provide strong Basic lab administrator credentials.");

// Session mode cannot start with ephemeral (restart-invalidating) cookie keys.
// Protect the persistent key ring using a certificate with its private key,
// supplied exclusively through a locally mounted secure file.
if (sessionMode)
{
    var certificatePath = Environment.GetEnvironmentVariable("ASPNETCORE_Kestrel__Certificates__Default__Path");
    var certificatePassword = SecretInput.Resolve("TLS certificate password",
        builder.Configuration["Kestrel:Certificates:Default:Password"],
        Environment.GetEnvironmentVariable("RADIUS_TLS_PASSWORD_FILE"));
    // Configure Kestrel with the resolved value in memory, not an environment variable.
    builder.Configuration["Kestrel:Certificates:Default:Password"] = certificatePassword;
    var keysPath = Environment.GetEnvironmentVariable("RADIUS_ADMIN_DATA_PROTECTION_PATH");
    if (string.IsNullOrWhiteSpace(certificatePath) || string.IsNullOrEmpty(certificatePassword)
        || string.IsNullOrWhiteSpace(keysPath) || !Path.IsPathFullyQualified(keysPath)
        || !File.Exists(certificatePath) || !Directory.Exists(keysPath))
        throw new InvalidOperationException("Session mode requires mounted TLS certificate and persistent key directory");
    var certificate = X509CertificateLoader.LoadPkcs12FromFile(certificatePath, certificatePassword);
    if (!certificate.HasPrivateKey)
        throw new InvalidOperationException("Session key encryption certificate must have a private key");
    builder.Services.AddDataProtection()
        .SetApplicationName("RadiusNocAdminSessions")
        .PersistKeysToFileSystem(new DirectoryInfo(keysPath))
        .ProtectKeysWithCertificate(certificate);
}

builder.Services.AddSingleton(NpgsqlDataSource.Create(connectionString));
builder.Services.AddSingleton(_ =>
    Environment.GetEnvironmentVariable("RADIUS_SERVICE_HISTORY_PERSIST") == "1"
        ? new ServiceObservationHistory(new ServiceHistoryStore("/var/lib/radius-service-history"))
        : new ServiceObservationHistory());
builder.Services.AddSingleton(_ =>
    Environment.GetEnvironmentVariable("RADIUS_SERVICE_HISTORY_PERSIST") == "1"
        ? new ServiceIncidentArchive(new ServiceIncidentStore("/var/lib/radius-service-history"))
        : new ServiceIncidentArchive());
builder.Services.AddHostedService<ServiceObservationWorker>();
builder.Services.AddDbContext<AdminIdentityDbContext>(o => o.UseNpgsql(connectionString));
builder.Services.AddIdentity<IdentityUser, IdentityRole>(options =>
{
    options.Password.RequiredLength = 14;
    options.Password.RequireDigit = true;
    options.Password.RequireUppercase = true;
    options.Password.RequireLowercase = true;
    options.Password.RequireNonAlphanumeric = true;
    options.Lockout.MaxFailedAccessAttempts = 5;
    options.Lockout.DefaultLockoutTimeSpan = TimeSpan.FromMinutes(20);
    options.Lockout.AllowedForNewUsers = true;
    options.User.RequireUniqueEmail = false;
}).AddEntityFrameworkStores<AdminIdentityDbContext>().AddDefaultTokenProviders();
builder.Services.ConfigureApplicationCookie(options =>
{
    options.Cookie.Name = "__Host-RadiusAdmin";
    options.Cookie.HttpOnly = true;
    options.Cookie.SecurePolicy = CookieSecurePolicy.Always;
    options.Cookie.SameSite = SameSiteMode.Strict;
    options.Cookie.Path = "/";
    options.SlidingExpiration = false;
    options.ExpireTimeSpan = TimeSpan.FromHours(8);
    options.Events.OnValidatePrincipal = AdminSessionSecurity.ValidateAsync;
    options.Events.OnRedirectToLogin = ctx => { ctx.Response.StatusCode = 401; return Task.CompletedTask; };
    options.Events.OnRedirectToAccessDenied = ctx => { ctx.Response.StatusCode = 403; return Task.CompletedTask; };
});
builder.Services.AddAntiforgery(options =>
{
    options.HeaderName = "X-CSRF-TOKEN";
    options.Cookie.Name = "__Host-RadiusCsrf";
    options.Cookie.HttpOnly = true;
    options.Cookie.SecurePolicy = CookieSecurePolicy.Always;
    options.Cookie.SameSite = SameSiteMode.Strict;
    options.Cookie.Path = "/";
});
builder.Services.AddAuthorization(options => options.AddPolicy(LabStatusHubRules.Policy,
    policy => policy.RequireAuthenticatedUser().RequireRole("super-admin", "noc-operator", "auditor")
        .RequireAssertion(context => LabStatusHubRules.CanRead(context.User))));
if (sessionMode)
{
    builder.Services.AddSignalR(options =>
    {
        options.EnableDetailedErrors = false;
        options.MaximumReceiveMessageSize = 4096;
        options.MaximumParallelInvocationsPerClient = 1;
    });
}
builder.Services.AddRateLimiter(o =>
{
    o.RejectionStatusCode = StatusCodes.Status429TooManyRequests;
    o.AddPolicy("admin", context => RateLimitPartition.GetFixedWindowLimiter(
        partitionKey: context.Connection.RemoteIpAddress?.ToString() ?? "unknown",
        factory: _ => new FixedWindowRateLimiterOptions
        {
            PermitLimit = 120, Window = TimeSpan.FromMinutes(1), QueueLimit = 0,
            AutoReplenishment = true
        }));
});

var app = builder.Build();
if (args.Length == 1 && args[0] == "--bootstrap-admin")
{
    Environment.ExitCode = await AdminBootstrap.RunAsync(app.Services);
    return;
}
app.Use(async (context, next) =>
{
    context.Response.Headers["X-Content-Type-Options"] = "nosniff";
    context.Response.Headers["X-Frame-Options"] = "DENY";
    context.Response.Headers["Cache-Control"] = "no-store";
    context.Response.Headers["Content-Security-Policy"] = "default-src 'self'; connect-src 'self'; img-src 'self' data:; script-src 'self'; style-src 'self'; base-uri 'none'; frame-ancestors 'none'";
    await next();
});
app.UseDefaultFiles();
app.UseStaticFiles();
app.UseRateLimiter();
app.UseAuthentication();
app.UseAuthorization();
if (sessionMode)
{
    app.Use(async (ctx, next) =>
    {
        if (ctx.Request.Path.StartsWithSegments("/hubs/lab-status")
            && !LabStatusHubRules.IsTrustedTransport(ctx.Request.IsHttps,
                ctx.Request.Headers["Origin"].ToString(),
                ctx.Request.Headers["Sec-Fetch-Site"].ToString(),
                ctx.Request.Host.Value))
        {
            ctx.Response.StatusCode = StatusCodes.Status403Forbidden;
            return;
        }
        await next();
    });
}
// Protect authenticated, state-changing browser requests against cross-site
// form submission. The API remains usable by existing local CLI clients.
app.Use(async (ctx, next) =>
{
    if (ctx.Request.Path.StartsWithSegments("/api")
        && !RequestOriginRules.IsAllowed(
            ctx.Request.Method,
            ctx.Request.Headers["Origin"].ToString(),
            ctx.Request.Headers["Sec-Fetch-Site"].ToString(),
            ctx.Request.Scheme,
            ctx.Request.Host.Value))
    {
        ctx.Response.StatusCode = StatusCodes.Status403Forbidden;
        await ctx.Response.WriteAsJsonAsync(new { error = "طلب من مصدر غير موثوق" });
        return;
    }
    await next();
});

app.MapGet("/api/health/live", () => Results.Ok(new { status = "running", phase = 1 }));
app.MapGet("/api/health/ready", async (NpgsqlDataSource dataSource, CancellationToken ct) =>
{
    try
    {
        await using var cmd = dataSource.CreateCommand("SELECT 1 FROM app_plans LIMIT 1");
        await cmd.ExecuteScalarAsync(ct);
        return Results.Ok(new { status = "ready" });
    }
    catch (NpgsqlException) { return Results.StatusCode(StatusCodes.Status503ServiceUnavailable); }
});

app.Use(async (ctx, next) =>
{
    if (ctx.Request.Path.StartsWithSegments("/api")
        && !ctx.Request.Path.StartsWithSegments("/api/health")
        && !ctx.Request.Path.StartsWithSegments("/api/admin/auth"))
    {
        if (sessionMode)
        {
            if (!ctx.Request.IsHttps)
            {
                ctx.Response.StatusCode = StatusCodes.Status403Forbidden;
                return;
            }
            if (ctx.User.Identity?.IsAuthenticated != true)
            {
                ctx.Response.StatusCode = StatusCodes.Status401Unauthorized;
                return;
            }
            if (!AdminAuthorizationRules.IsAllowed(ctx.User, ctx.Request.Method, ctx.Request.Path.Value))
            {
                await DeniedMutationAudit.RecordAsync(ctx, DenialReason.Role);
                ctx.Response.StatusCode = StatusCodes.Status403Forbidden;
                return;
            }
            if (HttpMethods.IsPost(ctx.Request.Method) || HttpMethods.IsPut(ctx.Request.Method)
                || HttpMethods.IsPatch(ctx.Request.Method) || HttpMethods.IsDelete(ctx.Request.Method))
            {
                var csrf = ctx.RequestServices.GetRequiredService<IAntiforgery>();
                if (!await csrf.IsRequestValidAsync(ctx))
                {
                    await DeniedMutationAudit.RecordAsync(ctx, DenialReason.Csrf);
                    ctx.Response.StatusCode = StatusCodes.Status403Forbidden;
                    return;
                }
            }
        }
        else if (!AdminBasicAuth.Matches(ctx.Request.Headers.Authorization.ToString(), adminUser, adminPassword))
        {
            ctx.Response.StatusCode = StatusCodes.Status401Unauthorized;
            ctx.Response.Headers.WWWAuthenticate = "Basic realm=\"Local-RADIUS-Lab\"";
            await ctx.Response.WriteAsJsonAsync(new { error = "غير مصرح" });
            return;
        }
    }
    await next();
});

var api = app.MapGroup("/api").RequireRateLimiting("admin");

api.MapGet("/summary", async (NpgsqlDataSource dataSource, CancellationToken ct) =>
{
    await using var cmd = dataSource.CreateCommand("SELECT (SELECT count(*) FROM app_plans), (SELECT count(*) FROM app_lab_accounts)");
    await using var reader = await cmd.ExecuteReaderAsync(ct);
    await reader.ReadAsync(ct);
    return Results.Ok(new { plans = reader.GetInt64(0), labAccounts = reader.GetInt64(1), phase = 1, accountingEnforced = false });
});

api.MapGet("/service-status/radius", () => Results.Ok(RadiusHealthEvidence.Read()));
api.MapGet("/service-status/history", (ServiceObservationHistory history) => Results.Ok(history.Snapshot()));
api.MapGet("/service-status/alerts", (ServiceObservationHistory history) =>
    Results.Ok(ServiceAlertProjection.Build(history.Snapshot().Samples, DateTimeOffset.UtcNow)));
api.MapGet("/service-status/incidents", (ServiceIncidentArchive archive) => Results.Ok(archive.Snapshot(DateTimeOffset.UtcNow)));

api.MapPlanEndpoints(sessionMode);

// Independent laboratory voucher routes; protected by the same /api auth middleware.
app.MapLabAccountEndpoints(sessionMode);
app.MapLabUsageEndpoints();
app.MapLabSessionEndpoints();
// Phase 7A: metadata-only NAS drafts; no actual RADIUS client registration.
app.MapNasDraftEndpoints(sessionMode);
app.MapAdminIdentityEndpoints(sessionMode);
app.MapResellerEndpoints(sessionMode);
app.MapOwnershipEndpoints(sessionMode);
app.MapAuditReadEndpoints(sessionMode);
if (sessionMode)
{
    app.MapHub<LabStatusHub>("/hubs/lab-status", options =>
    {
        options.Transports = HttpTransportType.WebSockets;
        options.CloseOnAuthenticationExpiration = true;
    }).RequireAuthorization(LabStatusHubRules.Policy).RequireRateLimiting("admin");
}
app.Run();
