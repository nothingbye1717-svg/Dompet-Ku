"""Patch generated Flutter Android project for scheduled local bill notifications."""
from pathlib import Path
import re

manifest = Path('android/app/src/main/AndroidManifest.xml')
s = manifest.read_text()
if 'android.permission.RECEIVE_BOOT_COMPLETED' not in s:
    perms = '''    <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
    <uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED" />
'''
    s = s.replace('<application', perms + '    <application', 1)
if 'com.dexterous.flutterlocalnotifications.ScheduledNotificationReceiver' not in s:
    receivers = '''
        <receiver android:exported="false" android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationReceiver" />
        <receiver android:exported="false" android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationBootReceiver">
            <intent-filter>
                <action android:name="android.intent.action.BOOT_COMPLETED" />
                <action android:name="android.intent.action.MY_PACKAGE_REPLACED" />
                <action android:name="android.intent.action.QUICKBOOT_POWERON" />
            </intent-filter>
        </receiver>
'''
    s = s.replace('</application>', receivers + '    </application>', 1)
s = re.sub(r'android:label="[^"]*"', 'android:label="DompetKu"', s, count=1)
manifest.write_text(s)

kts = Path('android/app/build.gradle.kts')
groovy = Path('android/app/build.gradle')
if kts.exists():
    s = kts.read_text()
    if 'isCoreLibraryDesugaringEnabled' not in s:
        s = s.replace('compileOptions {', 'compileOptions {\n        isCoreLibraryDesugaringEnabled = true', 1)
    s += '\n\ndependencies {\n    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")\n}\n'
    kts.write_text(s)
elif groovy.exists():
    s = groovy.read_text()
    if 'coreLibraryDesugaringEnabled' not in s:
        s = s.replace('compileOptions {', 'compileOptions {\n        coreLibraryDesugaringEnabled true', 1)
    s += "\n\ndependencies {\n    coreLibraryDesugaring 'com.android.tools:desugar_jdk_libs:2.1.4'\n}\n"
    groovy.write_text(s)
else:
    raise SystemExit('Could not find generated app Gradle file')
print('Patched AndroidManifest and Gradle for scheduled notifications')


# Install the private, opt-in Android notification listener and Flutter bridge.
# flutter create --project-name dompetku --org com.dompetku creates this package.
kotlin_dir = Path('android/app/src/main/kotlin/com/dompetku/dompetku')
kotlin_dir.mkdir(parents=True, exist_ok=True)
for name in ('MainActivity.kt', 'BankNotificationListener.kt', 'TransactionParser.kt'):
    source = Path('android_native') / name
    if not source.exists():
        raise SystemExit(f'Missing {source}; upload android_native folder')
    (kotlin_dir / name).write_bytes(source.read_bytes())

s = manifest.read_text()
if 'android.service.notification.NotificationListenerService' not in s:
    listener = '''
        <service
            android:name=".BankNotificationListener"
            android:label="DompetKu Auto Track"
            android:exported="false"
            android:permission="android.permission.BIND_NOTIFICATION_LISTENER_SERVICE">
            <intent-filter>
                <action android:name="android.service.notification.NotificationListenerService" />
            </intent-filter>
        </service>
'''
    s = s.replace('</application>', listener + '    </application>', 1)
# Android 11+ package visibility: only declare the exact, verified myBSN ID.
# We deliberately do NOT request QUERY_ALL_PACKAGES.
if '<queries>' not in s:
    query = '''
    <queries>
        <intent>
            <action android:name="android.intent.action.MAIN" />
            <category android:name="android.intent.category.LAUNCHER" />
        </intent>
        <package android:name="com.bsn.mybsn" />
    </queries>
'''
    s = s.replace('<application', query + '    <application', 1)
elif '<package android:name="com.bsn.mybsn"' not in s:
    s = s.replace('</queries>', '        <package android:name="com.bsn.mybsn" />\n    </queries>', 1)
manifest.write_text(s)
print('Installed notification listener, method channel and selected-app visibility')
