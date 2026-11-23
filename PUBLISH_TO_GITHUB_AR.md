# خطوات رفع النسخة التأسيسية إلى salehbinamrat/Radius

## الحالة

عند تجهيز هذه الحزمة كان المستودع `https://github.com/salehbinamrat/Radius` فارغا.
محاولة الرفع عبر الاتصال الحالي بـ GitHub رُفضت بالخطأ 403: `Resource not accessible by integration`؛ لذا لا تفترض أن المستودع يحتوي المشروع.

## تحذير

هذه نسخة مختبر فقط. لا تعمل بها على شبكة مشتركيك ولا تضع كلمات مرور حقيقية داخل المستودع.

## طريقة الرفع مع فرع منفصل وطلب دمج

هذه الخطوات تُنفذ على جهاز مثبت عليه Git، وداخل المجلد المفكوك من ZIP:

1. أنشئ مجلدا محليا مؤقتا فارغا، ثم نفذ:

```bash
mkdir radius-upload && cd radius-upload
git init -b main
git config user.name "YOUR_GITHUB_NAME"
git config user.email "YOUR_EMAIL"
printf '# Radius\n\nProject source is developed in feature branches and merged after CI tests.\n' > README.md
git add README.md
git commit -m "chore: initialize repository"
git remote add origin https://github.com/salehbinamrat/Radius.git
git push -u origin main
```

2. أنشئ فرعا للعمل وانسخ فيه **محتويات** الحزمة المفكوكة (وليس ملف ZIP نفسه) مع استبدال README.md التأسيسي:

```bash
git switch -c feat/radius-phase1-lab
# الآن انسخ محتويات الحزمة التي تحتوي README_AR.md وcompose.yaml وsrc وradius وtests وغيرها إلى هذا المجلد.
git status --short
git add .
git commit -m "feat: bootstrap local RADIUS phase-one lab"
git push -u origin feat/radius-phase1-lab
```

3. افتح طلب دمج من `feat/radius-phase1-lab` إلى `main`، وانتظر نجاح الوظائف الثلاث الموجودة في `.github/workflows/ci.yml` قبل أي دمج.

**تنبيه:** في حال لم يعد المستودع فارغا أو تغير `main`، لا تشغّل الخطوات كما هي، بل افحص آخر حالة للمستودع أولا وتجنب أي رفع قسري.
