# 04B3A-S — أمن البنية وسلامة الإصدار (الجزء الأول، غير معتمد)
 
التاريخ: 2026-11-24. الأساس: ab3a506dabac5911349eec033939dfa7bbb630f2.
مرجع الاختبارات الناجحة قبل التعديل: https://github.com/salehbinamrat/Radius/actions/runs/45445309189
مرجع الإصدارات المرصودة: https://github.com/salehbinamrat/Radius/actions/runs/45443854685

## المنجز في هذا الفرع
- تثبيت checkout وsetup-node وsetup-dotnet على SHA المرصودة في سجل CI الناجح، لا ادعاء بأنها أحدث إصدارات أو خالية من الثغرات. تعطيل حفظ اعتماد checkout وفحص SHA لكل وظيفة؛ في PR يكون GITHUB_SHA إصدار الدمج التجريبي.
- فحص محدود لأسماء ملفات الأسرار وأنماط المفاتيح والتوكنات في الملفات المتتبعة دون طباعة القيمة. لا يفحص تاريخ Git أو كل أنواع الأسرار، ولا يغني عن ماسح أوسع.
- اختبارات قبل التعديل؛ الحفاظ على مساري config/dotnet المتوازيين ثم Compose. لا تغيير لصلاحيات المستودع أو قاعدة البيانات.

## جرد الفجوات
- لا توجد ملفات package-lock.json أو packages.lock.json في الشجرة الأساسية؛ npm install وdotnet restore الحاليان لا يثبتان الاعتماديات العابرة. يلزم توليد القفل من سجلات الحزم الفعلية والتحقق من npm ci وdotnet restore --locked-mode، وفحص CVE/SBOM. لا يُنشأ قفل تخميني.
- صور node:24-bookworm-slim وdotnet sdk/aspnet:10.0 وpostgres:16-bookworm وdebian:bookworm-slim تستخدم وسوما متغيرة. يلزم تثبيت صور مدعومة بعد تدقيق CVE، وتسجيل حزم النظام الفعلية وخطة تحديث/تراجع. لا تثبيت للصورة الضعيفة باعتبارها آمنة.
- سجلات البناء تثبت FreeRADIUS 3.2.1+dfsg-4+deb12u1؛ Debian يصنف bookworm متأثرا بـ CVE-2024-3596: https://security-tracker.debian.org/tracker/CVE-2024-3596 . يلزم ترقية قاعدة الحاوية/حزمة FreeRADIUS إلى مصدر مدعوم مصحح مع اختبارات schema وPAP/CHAP/accounting. لا تعرض RADIUS للعامة ولا تسمح بإضافة NAS إنتاجي.
- مرجع التخفيف: https://www.freeradius.org/vul_notifications/2024/07/09/blastradius.html . يجب تقييم require_message_authenticator وlimit_proxy_state لكل NAS/إصدار بعد تحديث الخادم؛ لا تعطيل شامل للتحقق. مرجع MikroTik: https://manual.mikrotik.com/docs/authentication-authorization-accounting/radius/ . توافق v6.49.x وv7 مع Hotspot وPPPoE غير مؤكد دون CHR أو أجهزة معزولة مصرح بها.
- compose.yaml المختبري يستخدم حساب radius المالك وأسرارا بيئية وBasic على loopback، بينما tests/admin-https.compose.yaml يفصل radius_api وradius_bootstrap وradius_runtime ويستخدم ملفات أسرار وTLS. اختبارات الأدوار والاستعادة السابقة ناجحة، ولكن فصل مالك المخطط والمهاجر وتعميم التشغيل المقيد ما زال مطلوبا.
- GET لحماية main أعاد 403؛ قائمة rulesets المرئية فارغة. لا يعني ذلك أن main غير محمي. المقترح، بعد موافقة منفصلة: فرض PR، منع force push/delete، طلب الفحوص الثلاثة المطلوبة، تقييد تجاوزها وإلزام التحديث مع main حسب سياسة الفريق. لم تتغير إعدادات المستودع.

## شروط القبول المتبقية
الاختبارات الحالية لهذا الفرع معلقة حتى ظهور نتائج push وPR. لا اعتماد للمرحلة 01 حتى إن نجح هذا الجزء: يلزم قفل الاعتماديات وفحصها، تدقيق الصور، معالجة BlastRADIUS، اختبارات فصل الصلاحيات وتدوير الشهادات والاستعادة وتوافق النسخ. لا اتصال إنتاجي أو تغيير لبيانات المشتركين. تراجع هذا الجزء بإلغاء PR أو revert لتعديل CI بعد التحقق؛ لا migrations جديدة.
