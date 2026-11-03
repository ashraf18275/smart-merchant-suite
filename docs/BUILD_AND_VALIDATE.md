# البناء والتحقق

## ما يثبته CI
- Flutter CI يشغل flutter analyze وflutter test على Ubuntu.
- Android ينتج APK تجريبية debug منفصلة حسب بنية المعالج، مع SHA-256؛ ليست ملفات متجر.
- Windows ينتج حزمة Release x64 مضغوطة مع SHA-256.
- لا تثبت هذه الخطوات التثبيت أو الطباعة أو RTL على جهاز فعلي.

## تنزيل
افتح Actions واختر آخر تشغيل ناجح على فرع الميزة، ثم نزّل smart-merchant-suite-android-debug-apks أو smart-merchant-suite-windows-x64. تنتهي ملفات Android بعد 14 يومًا وWindows بعد 30 يومًا. طابق SHA256SUMS.txt بعد التنزيل.

## تشغيل المطور
1. ثبّت Flutter stable وAndroid SDK أو Visual Studio Desktop development with C++.
2. من جذر المشروع نفذ flutter pub get.
3. شغّل flutter analyze ثم flutter test.
4. أنشئ ملفات المنصة عند الحاجة عبر flutter create.
5. اختبر على محاكي أو جهاز تجريبي، دون بيانات نشاط حقيقية.

الخادم والمصادقة والمزامنة لا تزال تأسيسية ولا تتصل بها واجهة التطبيق. لا تضع أسرار خدمة مميزة داخل تطبيق العميل.
