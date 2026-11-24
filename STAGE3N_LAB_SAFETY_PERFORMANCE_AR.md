# المرحلة 03N — فحص أمان نشر المختبر وقياس أساس زمن استجابة API

**24 نوفمبر 2026** — التغييرات محصورة في الأدوات والاختبارات. لا تعديل على الراوتر أو مخطط PostgreSQL أو الصلاحيات أو الاستهلاك.

## فحص منافذ نشر Linux
- `scripts/lab-deployment-preflight.sh` يستخرج وصف Docker Compose المحسوم بمتغيرات البيئة عبر `docker compose config --format json` دون طباعة الأسرار، ويرسله إلى `scripts/validate_lab_compose.py`.
- يفشل تلقائيا إن كانت منافذ API 8080 أو RADIUS UDP 1812/1813 غير مربوطة بـ`127.0.0.1` حصرا، أو كشف PostgreSQL منفذا، أو أضيف منفذ منشور غير متوقع. يمنع بذلك الخطأ الشائع في ضبط `0.0.0.0` أو حذف Host IP.
- هذا **فحص مختبر محلي وليس أداة إعداد نشر إنتاجي**؛ استخدامه يتطلب إقرارا صريحا `LAB_NETWORK_PREFLIGHT_ACK=isolated-lab`.

## أساس أداء قراءات ASP.NET/PostgreSQL
- `scripts/lab-read-performance.sh` يقيس طلبات GET فقط لـ`/api/summary` و`/api/plans` و`/api/lab-accounts` بواقع ثمانية طلبات لكل منها، ويعرض `p50` و`p95` زمن الاستجابة.
- بيانات المسؤول المستخدمة في الاختبار المحلي تؤخذ من `.env` وتوضع داخل ملف Netrc مؤقت بترخيص مالكه فقط ثم تُحذف، دون طباعتها في السجل أو تمرير كلمة المرور ضمن وسيطات `curl -u`.
- يفحص أيضا 401 دون تسجيل دخول، ووجود ترويسات `Content-Security-Policy` و`X-Frame-Options` و`X-Content-Type-Options` و`Cache-Control`.
- **لا يحدّد الاختبار SLO ولا يُعد اختبار ضغط أو قبول إنتاج**؛ الزمن يتأثر بعتاد runner والتشغيل البارد، ويجب جمع أساس الأداء على Mini PC المستهدف قبل ضبط حدود رقمية.
- يلزم `RADIUS_PERF_TEST_ACK=isolated-ci`. العنوان ثابت داخل السكربت `127.0.0.1:8080` ولا يمكن تحويله إلى شبكة فعلية.

## تشغيل على مختبر Linux المعزول
```bash
bash scripts/setup.sh
LAB_NETWORK_PREFLIGHT_ACK=isolated-lab bash scripts/lab-deployment-preflight.sh
docker compose up -d --build
RADIUS_PERF_TEST_ACK=isolated-ci bash scripts/lab-read-performance.sh
```

## بوابة الاختبار
- اختبارات Python خالصة لاختبار رفض منافذ علنية أو تعريف غير صحيح.
- Bash syntax and static security checks.
- `.github/workflows/ci.yml`: يعمل فحص المنافذ بعد إنشاء `.env` وقبل بدء الحاويات، ثم قياسات GET بعد جاهزية API، بجانب الاختبارات السابقة React/TypeScript/Playwright/.NET/PostgreSQL/FreeRADIUS/HTTPS.

## ما لا يتم ادعاؤه
- لا تشغيل لخادم Linux حقيقي أو فتح منافذ إنتاج، ولا تغيير لمستويات صلاحيات الإدارة أو الجداول أو الفهارس.
- لا SignalR فعلي قبل تحديد أحداث خادم موثوقة وحدود الأدوار؛ **عدم وجود مصدر متصل حي** لا يعطي الحق في عرض قياسات اتصال حية وهمية.
- اختبار 24 طلب GET لا يثبت تحمل 500 أو 2000 كرت متزامن؛ يتطلب ذلك بيانات اختبار كبيرة وخطة تحميل منفصلة وإذنا لنطاق الاستهداف.
