from pathlib import Path
import subprocess,plistlib,os,shutil
root=Path(os.environ.get('EASYO_UPDATE_PROBE', '/tmp/easyo-native-update-probe'));root.mkdir(exist_ok=True)
app=Path(__file__).resolve().parents[3]
framework=app/'macos/Pods/Sparkle/Sparkle.framework'
# Compile the state classes directly from the production source, without launching
# the user's Flutter application or duplicating the implementation.
support=(app/'macos/Runner/AppDelegate.swift').read_text().split('@main')[0]
support=support.replace('import FlutterMacOS\n','')
(root/'UpdaterState.swift').write_text(support)
subprocess.run(['swiftc',str(root/'UpdaterState.swift'),str(app/'tool/update_verification/macos/PendingInstallerChecks.swift'),'-F',str(framework.parent),'-framework','Sparkle','-Xlinker','-rpath','-Xlinker',str(framework.parent),'-o',str(root/'state-checks')],check=True)
subprocess.run([str(root/'state-checks')],check=True)

(root/'keygen.swift').write_text('''import CryptoKit
import Foundation
let k = Curve25519.Signing.PrivateKey()
try k.rawRepresentation.base64EncodedString().write(toFile:CommandLine.arguments[1],atomically:true,encoding:.utf8)
try k.publicKey.rawRepresentation.base64EncodedString().write(toFile:CommandLine.arguments[2],atomically:true,encoding:.utf8)
''')
if not (root/'test-signing-seed').exists(): subprocess.run(['swift',str(root/'keygen.swift'),str(root/'test-signing-seed'),str(root/'test-public')],check=True)
os.chmod(root/'test-signing-seed',0o600)
pub=(root/'test-public').read_text()
# Match the actual application's transport policy before signing both baselines.
# A fixture-only policy would test different redirect behavior from production.
transport_security=plistlib.loads((app/'macos/Runner/Info.plist').read_bytes()).get('NSAppTransportSecurity', {})
source=(app/'macos/Runner/AppDelegate.swift').read_text()
callback=source.split('  func updater(_ updater: SPUUpdater, willDownloadUpdate')[1].split('\n  func updater(')[0]
fixture=(app/'tool/update_verification/macos/UpdateFixture.swift').read_text().replace('// ProductionDownloadCallback', 'func updater(_ updater: SPUUpdater, willDownloadUpdate'+callback)
(root/'UpdateFixture.swift').write_text(support + '\n' + fixture)
for build in (100,101):
 target=root/str(build)/'EasyOUpdateFixture.app'
 if target.exists(): shutil.rmtree(target)
 (target/'Contents/MacOS').mkdir(parents=True,exist_ok=True)
 (target/'Contents/Frameworks').mkdir(exist_ok=True)
 subprocess.run(['ditto',str(framework),str(target/'Contents/Frameworks/Sparkle.framework')],check=True)
 plist={'CFBundleIdentifier':'cn.qkfintech.zhiban.updatefixture','CFBundleName':'EasyOUpdateFixture','CFBundleExecutable':'EasyOUpdateFixture','CFBundlePackageType':'APPL','CFBundleVersion':str(build),'CFBundleShortVersionString':f'0.0.{build}','NSHighResolutionCapable':True,'NSAppTransportSecurity':transport_security,'SUPublicEDKey':pub,'SUEnableAutomaticChecks':False,'SUAllowsAutomaticUpdates':True,'SUAutomaticallyUpdate':True,'ProbeRoot':str(root)}
 (target/'Contents/Info.plist').write_bytes(plistlib.dumps(plist))
 subprocess.run(['swiftc',str(root/'UpdateFixture.swift'),'-F',str(framework.parent),'-framework','Sparkle','-framework','Cocoa','-Xlinker','-rpath','-Xlinker','@executable_path/../Frameworks','-o',str(target/'Contents/MacOS/EasyOUpdateFixture')],check=True)
 subprocess.run(['codesign','--force','--sign','-','--requirements','=designated => identifier \"cn.qkfintech.zhiban.updatefixture\"',str(target)],check=True)
subprocess.run(['codesign','--verify','--deep','--strict',str(root/'100/EasyOUpdateFixture.app')],check=True)
subprocess.run(['codesign','--verify','--deep','--strict',str(root/'101/EasyOUpdateFixture.app')],check=True)
subprocess.run(['hdiutil','create','-srcfolder',str(root/'101'),'-volname','EasyOUpdateFixture','-format','UDZO','-ov',str(root/'fixture.dmg')],check=True)
sig=subprocess.check_output([str(app/'macos/Pods/Sparkle/bin/sign_update'),'--ed-key-file',str(root/'test-signing-seed'),'-p',str(root/'fixture.dmg')],text=True).strip()
(root/'signature').write_text(sig)
print('Native fixture generated (build 100 -> 101); ephemeral test key only')

if os.environ.get('EASYO_DELTA_MATRIX') == '1':
 updates=root/'updates'
 if updates.exists(): shutil.rmtree(updates)
 updates.mkdir()
 subprocess.run(['hdiutil','create','-srcfolder',str(root/'100'),'-volname','EasyOUpdateFixture','-format','UDZO','-ov',str(updates/'fixture-100.dmg')],check=True)
 subprocess.run(['ditto',str(root/'fixture.dmg'),str(updates/'fixture-101.dmg')],check=True)
 subprocess.run([str(app/'macos/Pods/Sparkle/bin/generate_appcast'),'--ed-key-file',str(root/'test-signing-seed'),'--download-url-prefix','https://fixture.invalid/',str(updates)],check=True)
 print('Delta matrix appcast generated')
(root/'test-signing-seed').unlink()
print('Ephemeral private key removed')
