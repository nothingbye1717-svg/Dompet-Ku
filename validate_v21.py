"""Static checks for V2.1 Android source after flutter create and patch_android.py."""
from pathlib import Path
import xml.etree.ElementTree as ET

root = Path('.')
manifest = root / 'android/app/src/main/AndroidManifest.xml'
source = root / 'android/app/src/main/kotlin/com/dompetku/dompetku'
assert manifest.exists(), 'AndroidManifest.xml not found; run flutter create and patch first'
xml = ET.parse(manifest).getroot()
ns = '{http://schemas.android.com/apk/res/android}'
queries = xml.find('queries')
assert queries is not None, 'Missing Android package visibility queries'
packages = [p.get(ns + 'name') for p in queries.findall('package')]
assert 'com.bsn.mybsn' in packages, 'myBSN package not declared in <queries>'
assert all('QUERY_ALL_PACKAGES' not in x.attrib.get(ns + 'name', '') for x in xml.findall('uses-permission'))
services = xml.findall('.//service')
assert any(s.get(ns + 'name') == '.BankNotificationListener' for s in services), 'Missing listener service'
for f in ['MainActivity.kt', 'BankNotificationListener.kt', 'TransactionParser.kt']:
    assert (source / f).exists(), f'Missing native file: {f}'
main = (source / 'MainActivity.kt').read_text()
assert '"com.bsn.mybsn"' in main
assert '"addCustomApp"' in main and '"removeCustomApp"' in main
print('PASS: Android manifest, myBSN visibility, listener and Kotlin files')
