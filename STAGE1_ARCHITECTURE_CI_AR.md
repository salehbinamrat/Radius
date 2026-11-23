# المرحلة 1 — تنظيم البنية واختبارات البناء

- المرجع: `main` عند `e629bc72dd704bac3034754fe964de45b66a58f6`.
- النطاق: مختبر محلي فقط؛ لم تُغير قاعدة PostgreSQL أو إعدادات RouterOS أو FreeRADIUS أو Docker Compose.
- حالة النظام: **مختبر غير صالح بعد لفوترة أو تفعيل أرصدة إنتاجية**.

## الأعمال المنفذة في طلب الدمج
1. نقل مسارات الباقات إلى `PlanEndpoints.cs` مع الاحتفاظ بنفس HTTP routes والاستعلامات وAtomic PostgreSQL transactions.
2. إضافة اختبارات C# لعقد الباقة وثبات صيغة `Mikrotik-Rate-Limit`، واختبارات Python لتركيب CI.
3. استبدال القائمة اليدوية لفحوصات واجهة NOC بأمر `scripts/ci-config-checks.sh` الذي ينفذ كل اختبارات Python `*checks.py` ويتحقق من صياغة كل `*.mjs` محليا.
4. بناء API بعد نجاح اختبارات .NET، بينما تعمل اختبارات JavaScript/Python/Shell بالتوازي. لا تعمل اختبارات Docker إلا بعد نجاح هذين المسارين.
5. إضافة اختبارات HTTP لحماية العمليات من الطلبات غير المصرح بها أو Cross-Origin وللتعامل مع JSON الخاطئ. اختبارات HTTP السلبية لا تنشئ سجلات.
6. إزالة بيانات الاختبار العارضة عند النجاح أو الفشل في فحوصات الكروت والمحاسبة، وإنشاء أسماء باقات تجريبية فريدة.
7. تحديد الحد الأدنى لعائلة SDK داخل `global.json` إلى .NET 10 مع السماح بتحديث feature band داخل نفس العائلة.

## خطوات الفحص على نسخة مختبرية نظيفة
```bash
git clone https://github.com/salehbinamrat/Radius.git
cd Radius
bash scripts/ci-config-checks.sh
dotnet restore tests/RadiusManager.Tests/RadiusManager.Tests.csproj
dotnet test tests/RadiusManager.Tests/RadiusManager.Tests.csproj --no-restore -c Release
dotnet publish src/RadiusManager.Api/RadiusManager.Api.csproj --no-restore --no-self-contained -c Release -o /tmp/radius-api-publish
bash scripts/setup.sh
docker compose config --quiet
docker compose up -d --build
bash scripts/api-contract-smoke.sh
```

الأدوات المطلوبة: Linux أو WSL للاختبارات المتكاملة، Docker Engine وCompose، .NET SDK 10، Node.js 22، Python 3. لا ترسل ملف `.env` أو كلمات مرور المختبر إلى GitHub.

## ما لم تنجزه هذه المرحلة
- `global.json` يقيد SDK الرئيسي، لكنه **لا يثبت الاعتماديات العابرة**. ملفات `packages.lock.json` غير موجودة؛ الإنشاء والمراجعة والتثبيت على حالة مقفلة مهمة مستقلة قبل الإنتاج.
- صور Docker ما زالت تستخدم وسوما متغيرة ولم تُثبت بإشارات digest، ولا يوجد SBOM أو فحص CVE شامل. معالجة ذلك مطلوبة ضمن مراحل التقوية الأمنية.
- لا يزال Basic Auth مختبريا مع وصول loopback/SSH، دون RBAC أو جلسات HTTPS للإنتاج.
- لا توجد سياسة نسخ احتياطي واستعادة مجربة للبيانات الحقيقية أو ضبط تلقائي للراوتر.
- لا يعني نجاح CI سلامة نظام الرصيد أو قابلية التشغيل الإنتاجي.

## قاعدة الدمج
يجب نجاح `dotnet-tests` و`config-tests` و`compose-integration` على PR، ثم التحقق من رأس الفرع ومطابقته مع `main`. بعد الدمج يفحص نجاح المسارات الثلاثة على `main` مرة أخرى.
