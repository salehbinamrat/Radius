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


## الجزء الثاني — ترقية FreeRADIUS واختبار البروتوكول
- تحقق الجزء الأول من نجاح مسارات config-tests وdotnet-tests وcompose-integration في push وPR عند 8ec8f067c76f0638e8048f37bd3bfae81de17a5f: https://github.com/salehbinamrat/Radius/actions/runs/45447009194 و https://github.com/salehbinamrat/Radius/actions/runs/45447038889 .
- تم اختيار Debian Trixie stable وحزمة FreeRADIUS 3.2.7+dfsg-1+deb13u2 المثبتة بالإصدار في Dockerfile، بناء على سجل Debian الأمني وصفحة الحزمة: https://security-tracker.debian.org/tracker/CVE-2024-3596 و https://packages.debian.org/en/stable/net/freeradius .
- كلا تعريفَي عميل المختبر يفرضان require_message_authenticator=yes وlimit_proxy_state=yes. الخيار الثاني زائد عند تفعيل الأول وفق توثيق 3.2.7 لكنه يحافظ على سياسة صريحة. لا سماح لأجهزة قديمة غير مختبرة ولا استثناء ضمني.
- اختبار CI جديد يقتصر على loopback داخل الحاوية؛ يرفض طلبا غير موقع ويتحقق من رفض موقع لحساب اصطناعي غير موجود. تبقى اختبارات المصادقة الصحيحة والمحاسبة والاستعادة والأدوار السابقة إلزامية. لا يثبت هذا توافق راوتر حقيقي.
- لم يتم تثبيت digest لصور الأساس بعد ولا توليد ملفات قفل أو SBOM. يلزم تدقيق إضافي للثغرات والاعتماديات وترقية آمنة من قواعد البيانات القديمة واختبارات فعلية منفصلة لـ v6 وv7. نتائج الإصدار الجديد معلقة؛ لا تراجع إلى الإصدار الضعيف في الإنتاج ولا نشر إنتاجي.


## الجزء الثالث — التحقق من الفشل وتثبيت مصادر البناء
- الفشل الوسيط 577–582 في config-tests ناتج عن رفع اختبار الترقية قبل اكتمال Dockerfile وسياسة العميل وربط اختبار البروتوكول بـ CI. الفشل 572–573 سببه رفع اختبارات سلامة CI قبل تطبيقها. لا تعطيل للاختبارات ولا تغيير للنتائج التاريخية.
- إصدار 860d0e984b718cff09ee04d436f2cf9a882b05ee اجتاز جميع الوظائف على push وPR: https://github.com/salehbinamrat/Radius/actions/runs/45448500051 و https://github.com/salehbinamrat/Radius/actions/runs/45448516076 . سجل التكامل يؤكد FreeRADIUS 3.2.7+dfsg-1+deb13u2 ورفض الحزمة غير الموقعة ونجاح اختبارات الشهادات والاستعادة والأدوار.
- تثبيت صور الأساس الأربع في Dockerfiles بالبصمات المرصودة في سجل البناء الناجح. هذا يثبت هوية الصور ولا يشهد بخلوها من الثغرات. PostgreSQL يبقى بوسم متغير إلى حين الحصول على بصمة الصورة والتحقق منها.
- توليد ملفات قفل NuGet/npm من سجلات الحزم أثناء الاختبار؛ نشر مرشحات القفل العامة فقط مع SHA-256 للمراجعة، ثم إدراج الملفات الفعلية في commit لاحق وفرض npm ci و--locked-mode وإزالة خطوة التوليد المؤقتة. لا يعتبر هذا الجزء قفلا نهائيا أو بناء قابلا للتكرار حتى الالتزام بالقفل.
- رفع الاختبارات والإصلاحات المترابطة معا في commit ذري واحد، لا تخفيف لأي فحص. نتائج هذا commit معلقة؛ لا دمج قبل التحقق.

## إصلاح اختبار صورة Node المثبتة
- عمليتا 45450161875 و45450147724 فشلتا في الاختبار نفسه: tests/js/frontend-upgrade.test.mjs كان يتوقع FROM node:24-bookworm-slim AS ui-build بلا digest؛ نجحت 62 من 63 اختبارات JavaScript، ونجحت .NET، ولم يبدأ Compose.
- تشديد الاختبار ليفرض Node 24 وdigest صحيحا من 64 خانة، ورفض الوسم المتغير والبصمة الناقصة وNode 22. تشديد تحقق Python أيضا؛ لا تغيير للصورة أو إعدادات CI أو شروط TypeScript ولا تعطيل لأي اختبار. الاختبار المباشر للنمط على Dockerfile الفعلي والحالات السلبية نجح؛ قبول الاختبارات الكاملة معلق على GitHub.

## الجزء الرابع — تثبيت الاعتماديات وصورة PostgreSQL
- أثبت الإصدار 6068d8618630162ded76f25ad97db89525cb63d4 نجاح push وPR بكامل الوظائف (45451042203 و45451055162). أصلح الخطأ النحوي السابق في اختبار Python دون إضعاف الاختبار. سجلات PR: 63 JavaScript و141 Python و226 .NET، وتكامل Compose ناجح.
- استخرجت ملفات القفل الأربعة الفعلية من سجلات CI الناجحة، وتحققت من تطابق SHA-256 لكل ملف ومن بنية JSON ومصادر npm العامة وسلامة بيانات الحزم، ثم أدرجتها دون تعديل المحتوى.
- SHA-256: frontend/package-lock.json b644b77b7630410b5c49d9176a211bc78bc25f8e9fca15747d1f2a6092d218a5؛ API packages.lock.json da0f630f9ad7aeab1c5ab07e993b4a0bbda5471aafb7b1c685a05e3e5bbec8a5؛ .NET tests a4e0fbdccd5bf9cfea47a1fee4a459c9573c0387dfb965df1e3059c1d739e15f؛ browser b49b14b86018e1a8a35ff1d77cd6ab399f03bd377f069089217f0526c6b258b6.
- ثبت PostgreSQL في ملفات Compose الثلاثة على digest cd0e9518bda5f2ea667ff84d22795d089720c883f288e215d97ce57437e8ef37 المرصود في الاختبار الناجح؛ لا ترقية إصدار قاعدة البيانات ولا تغيير البيانات.
- فرض npm ci وdotnet restore --locked-mode في CI وDocker، والتحقق من عدم تغير ملفات القفل، وحذف أداة استخراج القفل المؤقتة بعد انتهاء غرضها. اختبارات إضافية تربط القفل بالملفات المصدرية وتفرض البصمات.
- لم يثبت نجاح البناء المقيد الجديد بعد؛ يلزم نجاح push وPR، ثم استكمال تدقيق CVE وSBOM وفصل الأدوار وتوثيق الاستثناءات. لا اعتماد إنتاجي ولا انتقال إلى 02. لا تغيير لإعدادات المستودع.

## الجزء الخامس — الفحص الأمني الإلزامي وSBOM
- الإصدار f427e9bc9100d207aa975ac387369aaaec6829f5 اجتاز الوظائف الست في push وPR: https://github.com/salehbinamrat/Radius/actions/runs/45452548922 و https://github.com/salehbinamrat/Radius/actions/runs/45452560370 .
- فرض تدقيق NuGet المباشر والمتعدي من مستوى low دون تغيير TreatWarningsAsErrors، وnpm audit للاعتماديات المباشرة والمتعدية بما فيها أدوات التطوير، بحد فشل high/critical (تظل النتائج الأقل ظاهرة). لا إصلاح آلي يغير القفل.
- فحص صور التشغيل الثلاث الفعلية بمعرفاتها المحلية عبر Trivy 0.76.2؛ مرجع الإصدار https://github.com/aquasecurity/trivy/releases/tag/v0.76.2 ، تحقق SHA-256 للأرشيف من بيانات أصل الإصدار. لا تجاهل للثغرات غير المصححة أو تجاوز لفشل الماسح. هذا الاختيار لا يفحص كل صور البناء الوسيطة؛ تدقيقها ما زال مطلوبا.
- إنشاء CycloneDX SBOM لقفل الاعتماديات وصور التشغيل، وإرفاق تقارير JSON وSBOM في Actions بواسطة upload-artifact المثبت على SHA المؤكد للوسم v4.6.2. لا إرسال لملفات .env أو بيانات العملاء؛ تحفظ التقارير 14 يوما.
- اختبارات الحماية من إزالة البوابة أو تخفيضها، ورفع التعديلات المترابطة معا. نتائج التنفيذ الجديد لم تثبت بعد؛ أي ثغرة high/critical أو فشل أداة الفحص يمنع الدمج. فصل الأدوار ودليل توافق الأجهزة الفعلية ما زالا غير مكتملين.

## معالجة الفشل الأمني المثبت — 24 نوفمبر 2026
- التشغيلان 45454409215 و45454392076: config-tests وdotnet-tests ناجحان؛ compose-integration اجتاز اختبارات الوظائف حتى فحص Trivy. API ناجح، radius وdb فشلا. التقارير أُنشئت. PR log: https://github.com/salehbinamrat/Radius/actions/runs/45454409215 .
- في سجل PR: radius 94 نتيجة package/CVE، 26 CVE فريدة، كلها HIGH؛ db 145 نتيجة، 66 CVE فريدة، بينها 4 نتائج CRITICAL. ليست كل النتائج ثغرات مستقلة؛ لا تخفيف للبوابة.
- Debian يضع CVE-2026-127029 وCVE-2026-127030 في freeradius 3.2.7+dfsg-1+deb13u2 وكذلك 3.2.10 في testing/unstable بحالة vulnerable/unfixed: https://security-tracker.debian.org/tracker/CVE-2026-127029 و https://security-tracker.debian.org/tracker/CVE-2026-127030 . ليست مشكلة BlastRADIUS السابقة. تعطيل EAP وinner-tunnel ورفض EAP مبكرا يقلل سطح الهجوم في ملف المختبر PAP/CHAP/MS-CHAP، لكنه ليس إصلاحا للحزم ولا مبررا لاستثناء CVE. اختبار سلكي عادي للرفض مع المحافظة على الاختبارات السابقة.
- Debian يثبت إصلاح CVE-2025-7458 وCVE-2023-45853 في Trixie مقابل Bookworm: https://security-tracker.debian.org/tracker/CVE-2025-7458 و https://security-tracker.debian.org/tracker/CVE-2023-45853 . libxml2 CVE-2026-6653 ما زال متأثرا في الاثنين: https://security-tracker.debian.org/tracker/CVE-2026-6653 . PostgreSQL 16.16-trixie الرسمي مرشح لفحص منفصل فقط (digest من https://github.com/docker-library/repo-info/blob/master/repos/postgres/remote/16.16-trixie.md). لا تشغيل ولا ربط volumes ولا تبديل قاعدة بيانات؛ يلزم قبول الفحص واستعادة منطقية منفصلة والتحقق من locale/collation قبل أي انتقال.
- توسيع التقارير لإظهار FixedVersion وStatus لتحديد ما يمكن ترقيته بالفعل. فشل أي فحص يبقى مانعا للدمج، لا تجاهل لغير المصحح. هذه معالجة جزئية للمخاطر وتشخيص البديل وليست حلا مثبتا لكل الثغرات. يبقى الإصدار الحالي غير صالح للاعتماد الإنتاجي ولا انتقال إلى 02.

## إعادة التحقق من الفشل الأمني — 2026-11-24
- الإصدار 9811cb0bbc96830c0f7a926483d4b9e28aa2cf4d: push 45455968745 وPR 45455983731، config-tests وdotnet-tests ناجحان، ونجحت اختبارات التكامل حتى البوابة الأمنية. سجل PR: https://github.com/salehbinamrat/Radius/actions/runs/45455983731 .
- اختبار رفض EAP الموقع نجح. API اجتاز الفحص. FreeRADIUS: 94 نتيجة حزمة/CVE، 26 CVE فريدة، لا CRITICAL. PostgreSQL الحالي: 119 نتيجة، 40 CVE فريدة، 3 حرجة. مرشح Trixie: 73 نتيجة، 22 CVE فريدة، نتيجة حرجة واحدة CVE-2026-6653. لم يحدد Trivy FixedVersion لأي من هذه النتائج في التشغيل المذكور، والحالات affected/fix_deferred/will_not_fix؛ لا يعني ذلك انعدام أي إصلاح مصدري.
- سجل Debian الرسمي يثبت بقاء CVE-2026-127029 وCVE-2026-127030 غير مصححتين في حزم FreeRADIUS المدعومة: https://security-tracker.debian.org/tracker/source-package/freeradius . وتوجد تصحيحات من المنبع e415f818dcdf91626e5e7314b3a4f819ab11f572 و064567a08f3b9d9b4863fab6060fafe296ac7de9، منشورة بعد تاريخ إصدار 3.2.10؛ لا نعتمد بناء فرع التطوير كإصدار إنتاجي ولا نغير بيانات تعريف الحزم لخداع الماسح. يلزم إصدار مدعوم أو backport موثق مبني ومختبر، وتظل بوابة الفحص إلزامية.
- مرشح PostgreSQL الرسمي 16.16-alpine3.24 مثبت ببصمة من https://github.com/docker-library/repo-info/blob/master/repos/postgres/remote/16.16-alpine3.24.md . يضاف لفحص مستقل بنفس المعايير، لا تغيير لصورة التشغيل الحالية أو ملفات Compose أو البيانات؛ يجب التحقق من توافق locale/collation والاستعادة المنطقية في قاعدة معزولة قبل أي اعتماد.
- هذه محاولة علاج مبنية على الأدلة وليست إغلاقا للفشل؛ لا نتجاوز الثغرات، ولا ننتقل إلى المرحلة التالية أو ندمج قبل قبول النتائج. لا يوجد حاليا مرشح مثبت خال من النتائج العالية والحرجة لكل الخدمات.

## تصحيح حزمة PostgreSQL Alpine — 2026-11-24
- الإصدار 0697d5411efc6e5c7b6748ad256c13d64ddeef22: push 45467298393 وPR 45467312334؛ .NET وconfig ناجحان. التكامل يفشل عند فحص الصور. https://github.com/salehbinamrat/Radius/actions/runs/45467312334 .
- نتائج CVE الفريدة: radius 26، db 40، Trixie 22، Alpine 1 (CVE-2026-86144؛ libxml2 2.13.9-r2؛ FixedVersion=2.13.9-r3). مصدر الإصلاح: https://pkgs.alpinelinux.org/packages?arch=x86_64&branch=v3.24&name=libxml2 و https://osv.dev/vulnerability/ALPINE-CVE-2026-86144 .
- أضيف Dockerfile مرشح معزول يبني فوق صورة Alpine الرسمية المثبتة ويثبت libxml2=2.13.9-r3 من مستودع APK الموقع ويتحقق من الإصدار. يمسح Trivy معرّف الصورة المبنية نفسها. لا استثناء أو تعديل لقاعدة الثغرات، ولا تغيير لصور التشغيل أو Compose. لا تشغيل أو ربط بيانات. يلزم نجاح الفحص واستعادة منطقية واختبار collation قبل اعتماد الصورة.
- FreeRADIUS: سجل Debian https://security-tracker.debian.org/tracker/source-package/freeradius لا يزال يصنف CVE-2026-127029 وCVE-2026-127030 غير مصححتين. لم أجد حزمة Debian مستقرة مصححة؛ لا تغيير رقمي صوري ولا ادعاء بأن معالجة EAP أصلحت الحزمة. يجب توفير بناء مدعوم مصحح وفحصه، فضلا عن بقية ثغرات النظام. البوابة تبقى مانعة للدمج.

## إصلاح تحقق APK — 2026-11-24
- PR 45468997870 وpush 45468985032 للإصدار 4985a6765781144b2ccbfc61517bfb172dc4f0ce: config و.NET ناجحان؛ API scan ناجح؛ radius وdb ومرشح Trixie لا تزال بواباتها تفشل. بناء مرشح Alpine توقف بعد نجاح ترقية libxml2 من 2.13.9-r2 إلى 2.13.9-r3 (APK: OK، 45 حزمة)، بسبب مطابقة النص البشري في apk info -v مع grep -Fx. سجل: https://github.com/salehbinamrat/Radius/actions/runs/45468997870 .
- استبدلت مطابقة تنسيق العرض باستعلام APK الأصلي apk info --exists 'libxml2=2.13.9-r3'، مع اختبار سلبي للنسخة r2، وset -eu حتى يفشل البناء إذا لم توجد النسخة المطلوبة. تحققت من تنفيذ info_exists في المصدر الرسمي apk-tools/src/app_info.c: تحليل قيد الاعتماد والتحقق من المزود المثبت عبر apk_dep_is_provided. https://github.com/alpinelinux/apk-tools/blob/master/src/app_info.c . اختبار التحقق الثابت محدث؛ الفحص الفعلي للصورة الناتجة لا يزال إلزاميا وغير مثبت بعد.
- لا تغيير لبوابة Trivy أو صور التشغيل أو البيانات. Debian tracker ما زال يسجل ثغرتي FreeRADIUS كغير مصححتين؛ لا دمج أو انتقال قبل استكمال معالجة الفشل.
