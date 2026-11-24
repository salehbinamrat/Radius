# المرحلة 03K — ترقية حزمة React وTypeScript وVite وNode.js

**تاريخ المقارنة:** 24 نوفمبر 2026
**النطاق:** بناء لوحة FreeRADIUS NOC المحلية؛ لا تغييرات على تشغيل FreeRADIUS وPostgreSQL وMikroTik أو سياسة صلاحيات API.

## الإصدارات المثبتة

| المكون | السابق | الإصدار المستقر المعتمد لهذه المرحلة |
|---|---|---|
| React / React DOM | 19.2.0 | **19.3.1** |
| @types/react / @types/react-dom | 19.2.0 | **19.3.0** |
| TypeScript | 5.9.3 | **7.0.2** (الإصدار الأصلي Native TypeScript) |
| Vite | 7.3.0 | **8.3.8** |
| @vitejs/plugin-react | 5.1.4 | **6.3.0** |
| Node.js في الحاوية وCI | 22 | **24 LTS** |

التبعية المباشرة محددة بإصدار ثابت دون \`^\` أو \`~\` أو \`latest\` أو \`canary\`. لا تتغير CSS أو الواجهات أو المنطق البرمجي الخاص بالمشتركين. لا تتطلب ترقية المكتبات تغيير SQL أو واجهات RADIUS.

**مصادر مراجعة الإصدارات:** https://github.com/facebook/react/releases ، https://www.npmjs.com/package/typescript ، https://github.com/vitejs/vite/releases ، https://github.com/vitejs/vite-plugin-react/releases ، https://nodejs.org/en/about/previous-releases .

## ضمان التوافق قبل الدمج

- يظل نمط TypeScript \`strict\` مع \`noEmit\`؛ لا تُعطّل الأخطاء لتمرير البناء.
- يحتفظ Vite بتجميع \`src/main.tsx\` إلى \`wwwroot/modern/noc-react.mjs\` بملفات محلية متوافقة مع سياسة Content Security Policy.
- تُشغّل اختبارات JS وتحقق Python الساكن، ثم \`npm run check\` و\`npm run build\` على Node 24 في CI.
- يبقى البناء متعدد المراحل \`Dockerfile\` على Debian، ويجب أن ينجح نشر .NET ومكونات React داخل صورة الخدمة.
- لا دمج قبل نجاح \`dotnet-tests\` و\`config-tests\` المتوازيين، ثم تكامل PostgreSQL/FreeRADIUS والترحيلات والاستعادة المشفرة وتجربة HTTPS المعزولة.
- لم يُدخل \`React Server Components\` أو \`React Compiler\` أو مكونات خادم React؛ هذه لوحة تعمل محليا مع API آمن، وإضافتها دون حاجة عملية قد توسع سطح الهجوم.

## أوامر التطوير والاختبار (مختبر مستقل)

\`\`\`bash
# من جذر المشروع بعد سحب الفرع المراجع:
node --version            # 24.x
npm --version
bash scripts/ci-config-checks.sh
dotnet restore tests/RadiusManager.Tests/RadiusManager.Tests.csproj
dotnet test tests/RadiusManager.Tests/RadiusManager.Tests.csproj --no-restore -c Release

cd src/RadiusManager.Api/frontend
npm install --no-audit --no-fund --ignore-scripts
npm run check
npm run build
node --check ../wwwroot/modern/noc-react.mjs
cd ../../..
docker compose config --quiet
\`\`\`

يُفضل إنشاء \`package-lock.json\` وتثبيته في المستودع قبل التحول إلى \`npm ci\` في كل البيئات، بعد مراجعته وتأكيده عبر CI. لا نستخدم \`npm ci\` دون ملف قفل موجود ومتوافق. وتحتاج أول مرة \`npm install\` اتصالا بالخدمة الرسمية لـnpm.

## التنفيذ التالي (كل مرحلة في فرع واختبارات مستقلة)

**COMMAND 03L — BROWSER E2E AND FRONTEND PRODUCTION HARDENING**

> Add real automated Playwright Chromium tests of the self-hosted React NOC shell over loopback HTTPS in an ephemeral lab, with an isolated user and database. Assert existing Basic lab login compatibility, secure session login+CSRF+logout, RTL layout, voucher secret one-time visibility and clearing on navigation, validated plan edits, usage request race rejection, and responsive 100/125/150% zoom. Pin browser binaries, never use production credentials, never bypass TLS trust in production, and report coverage gaps. Merge only on green CI.

**COMMAND 04A — TRUSTED REAL-TIME NOTIFICATIONS (SignalR)**

> Implement an authenticated and scoped ASP.NET Core SignalR hub for read-only notifications only, sourced from server-verified data and with no personal secrets or user-specific credentials. Rate-limit, authorize subscriptions, handle reconnect, replay and fail-closed states, test stale events and avoid exposing the hub publicly. Do not touch live RouterOS, NAS/CoA or subscriber records.

**COMMAND 04B — PRODUCTION SECURITY AND RECOVERY**

> Finish admin audit coverage, tenant/ownership scoped authorization and recovery, backup restore, persistent TLS certificate/key rotation and browser acceptance before any production use. New schema, changes to permission policy and live-router cutover require separate owner approval.
