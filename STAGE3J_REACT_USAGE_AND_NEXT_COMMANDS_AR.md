# المرحلة 03J — تقرير استهلاك المختبر في React 19 / TypeScript

**التاريخ:** 2026-11-24
**النطاق:** واجهة مختبر FreeRADIUS/NOC في مشروع \`salehbinamrat/Radius\`، دون تعديل مخطط قاعدة البيانات أو سلوك حسابات الإنتاج.

## التنفيذ الحقيقي

- \`frontend/src/UsageReport.tsx\`: مكون React 19 يعرض إجمالي البيانات، الرفع، التنزيل، عدد الجلسات، السجلات المفتوحة والقديمة وغير السليمة، عدد عناوين NAS المرصودة، حالة السجل، وتحذير عدم نهائية التقرير.
- \`wwwroot/usage-view-model.mjs\`: إسقاط محدود للحقول التي يجوز عرضها. لا تنقل كلمة مرور الكرت، أو بيانات RADIUS السرية، أو استجابة API الكاملة إلى React. تكون الأرقام المفقودة «—»، وليست صفرا مفترضا. الحالة \`reportIsFinal=true\` توصف «مغلق شكليا»، لا «رصيد نهائي».
- يبقى اختيار الكرت وزر الاستعلام وباقي API في \`app.mjs\`، مع المحافظة على \`GET /api/lab-accounts/{username}/usage\` والمصادقة المطبقة فيه (Basic في المختبر أو جلسة HTTPS).
- رقم \`usageGeneration\` يبطل أي رد متأخر بعد تغيير الكرت، أو مغادرة صفحة المحاسبة، أو تسجيل الخروج، أو إعادة إرسال الطلب. لا تقبل React إلا لقطات خضعت للفحص من \`usage-view-model.mjs\`.
- \`index.html\` يحتفظ بالتصميم RTL وCSS الأصلي وشاشة المحاسبة، ولا يكرر إخراجا آخر داخل \`usageEmpty/usageReport\`.

## الاختبارات

1. \`tests/js/usage-view-model.test.mjs\`: أرقام صحيحة/مفقودة، حالة السجل، التحذيرات، عدم نسخ بيانات سرية.
2. \`tests/react_usage_report_checks.py\`: التوافق مع HTML، منع جلب البيانات مباشرة من React، إبطال الطلبات القديمة، ومسح البيانات عند مغادرة الصفحة.
3. \`scripts/ui-smoke.sh\`: توفر ملفات React/ESM من خدمة ASP.NET Core المعبأة.
4. المسارات المتوازية \`dotnet-tests\` و\`config-tests\` قبل \`compose-integration\`: FreeRADIUS/PostgreSQL والمخططات ذات الترحيلات والمراجعة/الاستعادة المشفرة واختبارات جلسات HTTPS.

## أوامر التحقق المحلية (بيئة Ubuntu Mini PC مختبرية فقط)

\`\`\`bash
# من جذر المستودع، لا تشغّل هذه الأوامر على خادم MikroTik للإنتاج.
bash scripts/ci-config-checks.sh
dotnet restore tests/RadiusManager.Tests/RadiusManager.Tests.csproj
dotnet test tests/RadiusManager.Tests/RadiusManager.Tests.csproj --no-restore -c Release
cd src/RadiusManager.Api/frontend
npm install --no-audit --no-fund --ignore-scripts
npm run check
npm run build
cd ../../..
\`\`\`

**لا تشغّل** \`docker compose up\` على نظام يستخدم قاعدة بيانات مشتركين قائمة دون إعادة فحص \`compose.yaml\` وعزل المنافذ، لأن بيئة Docker الافتراضية مخصصة لمختبر تطوير وليست خطة نشر معتمدة.

## أوامر المراحل التالية — للتنفيذ المنفصل بعد نجاح 03J

**COMMAND 03K — MODERN FRONTEND DEPENDENCIES:**

> Upgrade React and React DOM together to the verified latest stable React 19 maintenance release. Update compatible type declarations and evaluate stable Vite/toolchain versions separately. Preserve the self-hosted CSP-safe single ESM bundle, run TypeScript strict checks and all E2E session, voucher, usage, migration and RADIUS regression tests. Never turn off security checks to make a dependency upgrade pass. Pin resolved dependencies and use a lockfile with \`npm ci\` when the lockfile has been generated and verified. Do not merge until all CI jobs pass.

**COMMAND 03L — REAL BROWSER ACCEPTANCE:**

> Add an isolated Playwright smoke suite covering login/cookie/CSRF, RTL navigation, voucher secret reveal and clearing, stale and out-of-order usage responses, plan creation and filter compatibility, and logout revocation. Use an ephemeral trusted-local HTTPS test certificate; do not introduce production admin credentials or broaden service exposure.

**COMMAND 04A — READ-ONLY REAL-TIME FEED:**

> Add an authenticated SignalR hub for explicitly read-only status/notification events from trusted, server-verified sources. Enforce current role authorization, same-origin and anti-leak protections. Introduce no new database schema or live MikroTik/NAS actions without separately approved designs. Test reconnect, replay, throttling and cleanup.

**COMMAND 04B — PRODUCTION READINESS:**

> Add scoped tenant authorization, comprehensive immutable admin audit coverage, first-admin recovery with concurrency safety, browser end-to-end security tests, protected persistent secrets, TLS certificate rotation and full isolated backup/restore/rollback acceptance. Do not enable production RADIUS/NAS or migrate existing User Manager v6 subscribers without a separately approved deployment procedure.

التقنيات **التي لم تُفعّل إنتاجيا** (مثل SignalR أو فاتورة الرصيد النهائي) لا تُقدّم بوصفها منجزة.
