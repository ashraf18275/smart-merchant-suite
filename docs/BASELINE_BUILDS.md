# النسخ المرجعية للبناء — 4 نوفمبر 2026

هذه الملفات هي نقطة الرجوع المرجعية التي طلب صاحب المشروع الاحتفاظ بها قبل مواصلة التطوير. لا تستبدلها ببناء أحدث تلقائيًا، ولا تعتبرها نسخة نهائية للاختبار أو النشر.

## المصدر والبناء

- المستودع: `ashraf18275/smart-merchant-suite`
- الفرع: `feature/multi-user-cloud`
- Commit المصدر المثبت داخل ملفات البناء: `c75d003601f5c069a55757f636251734a4d4cda8`
- GitHub Actions run: [#486](https://github.com/ashraf18275/smart-merchant-suite/actions/runs/41873996556)
- نتيجة التشغيل: success
- Flutter: 3.47.9 stable

## Windows x64

- النوع: Release
- Artifact ID: `13347150570`
- الاسم: `smart-merchant-suite-windows-x64`
- تاريخ الانتهاء من GitHub: 4 ديسمبر 2026
- SHA-256 لحزمة Artifact: `8521afe0029b30813ae426146ededaee65ab274ee144ba32f75323310beb5c17`
- SHA-256 للحزمة الداخلية `smart-merchant-suite-windows-x64.zip`: `559b93d9468d6a27a01705e1146763a0d687c99bbb372caff4ea5d99b665e2a2`
- تم التحقق من سلامة ZIP ومن وجود ملف EXE ومكتبات Flutter وSQLite وVisual C++ runtime داخل الحزمة.

## Android

- النوع: Debug فقط، وليس إصدار متجر موقّعًا للنشر.
- Artifact ID: `13346352419`
- الاسم: `smart-merchant-suite-android-debug-apks`
- تاريخ الانتهاء من GitHub: 18 نوفمبر 2026
- SHA-256 لحزمة Artifact: `b81b0cabad3d6981ba14dabcb236cdd7ababa118a9766248f4712e813bcd976d`

| الملف | ABI | SHA-256 |
|---|---|---|
| `app-arm64-v8a-debug.apk` | arm64-v8a | `351816229c77ccd372aa05ca219ba116f28a048c063a1cf0454056aa09a84064` |
| `app-armeabi-v7a-debug.apk` | armeabi-v7a | `ddc2054ac192143cb5e9230aa4c51b1994fa4ecaac4d0fa7e11413b385f37fb3` |
| `app-x86_64-debug.apk` | x86_64 | `fa5d5078742d50835d313f23a0e1f664dee148c00816577b345a96efd29de904` |

تم فحص نوع ملفات APK والتحقق من سلامة بنية كل ملف، كما تطابقت جميع البصمات مع `SHA256SUMS.txt`.

## قاعدة الرجوع

- احتفظ بهذه النسخ كما هي.
- عند فشل تطوير لاحق، يمكن الرجوع إلى commit المصدر أعلاه وإعادة تنزيل Artifact من تشغيل #486 ما دام غير منتهي الصلاحية.
- لا تُجرِ اختبار المستخدم قبل اكتمال المشروع؛ هذا هو الترتيب المتفق عليه.
- أي بناء أحدث يُحفظ كنسخة مستقلة ولا يحل محل هذه النسخ المرجعية إلا بقرار موثق.
