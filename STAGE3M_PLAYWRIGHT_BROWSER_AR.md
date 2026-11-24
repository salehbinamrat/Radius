# 03M — تشغيل اختبارات متصفح Chromium حقيقية ضمن CI

**24 نوفمبر 2026 — اختبار مختبري فقط.**

## التنفيذ
- أضيف `@playwright/test@1.65.1` المثبت بإصدار محدد في `tests/browser/package.json` بصورة مستقلة عن تبعيات الإنتاج. لا تدخل المكتبة في الحاوية المنشورة للـAPI.
- `tests/browser/dashboard.spec.mjs`: يتحقق من تحميل واجهة الدخول وأجزاء React 19 في متصفح Chromium فعلي، ومن بقاء `/api/plans` و`/api/lab-accounts` محميين عند عدم وجود جلسة، ومن عدم ظهور بيانات الكروت السرية.
- يختبر نتائج حاسبة السعة الأصلية (360 / 270 Mbps / 21.87 TB)، تعديل القيم، كشف المدخلات غير الصالحة، وعرضها على هاتف بعرض 390px.
- لا يزيف هذا الاختبار جلسة موثوقة: فك إخفاء `#dashboard` في DOM يستخدم فقط لاختبار شكل الواجهة التي لا تتطلب مصادقة من الخادم؛ أي محاولة للوصول إلى API المحمي تظل مرفوضة (401).
- يضاف الاختبار إلى مرحلة `compose-integration` **بعد نجاح مساري C# وReact بالتوازي وتشغيل Docker الفعلي**، فيحول أي عطل متصفح إلى فشل يمنع الدمج.
- أوامر تشغيل المختبر بعد تشغيل Docker:

```bash
npm install --prefix tests/browser --no-audit --no-fund --ignore-scripts
tests/browser/node_modules/.bin/playwright install --with-deps chromium
tests/browser/node_modules/.bin/playwright test --config tests/browser/playwright.config.mjs
```

## حدود الثقة
لا يتضمن هذا الاختبار تسجيل دخول حقيقي في المتصفح، أو سيناريوهات دفع/محاسبة إنتاجية، أو تجاوزات للسياسات الأمنية، ولا يثبت جهوزية النظام للإنتاج. يستمر تحقق HTTPS Session وCSRF ومزامنة PostgreSQL واستعادة النسخ المشفرة من الاختبارات القديمة في Docker.
