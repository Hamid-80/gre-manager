روش اول: اجرای مستقیم و تمیز (بدون ذخیره فایل روی سرور - پیشنهاد من)
این دستور اسکریپت شما را مستقیماً از گیت‌هابتان می‌خواند و در همان لحظه اجرا می‌کند (هیچ فایلی روی هارد سرور باقی نمی‌ماند):

Bash
sudo bash <(curl -sSL https://raw.githubusercontent.com/Hamid-80/gre-manager/main/gre_manager.sh)
روش دوم: دانلود فایل روی سرور و اجرا
اگر دوست دارید اسکریپت روی سرور دانلود شود تا برای اجراهای بعدی نیازی به اینترنت یا دانلود مجدد نباشد، این دستور را بزنید:

Bash
curl -sSL https://raw.githubusercontent.com/Hamid-80/gre-manager/main/gre_manager.sh -o gre_manager.sh && chmod +x gre_manager.sh && sudo ./gre_manager.sh
(با این کار، فایل gre_manager.sh روی سرور ذخیره می‌شود و در دفعات بعدی فقط کافیست دستور sudo ./gre_manager.sh را بزنید).
