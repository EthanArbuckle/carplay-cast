#define CRASH_REPORT_URL @"https://us-central1-decoded-cove-239422.cloudfunctions.net/process_crash_reports"
#define UPLOADED_LOGS_PLIST_PATH @"/var/mobile/Library/Preferences/com.ethanarbuckle.carplay-uploaded-crashlogs.plist"

void symbolicateAndUploadCrashlogs(void);