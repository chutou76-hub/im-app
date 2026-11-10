// 一键打包准备（三合一）：配置同步 + APP 图标 + 启动图
//
// 用法：dart run tool/apply_config.dart [--icons] [--splash]
//   不带参数：三条链路全跑，但图标/启动图源图内容没变化时自动跳过（秒完成）
//   --icons   强制重新生成 APP 图标
//   --splash  强制重新生成启动图
//
// 一条命令完成（不用再分开跑这三条）：
//   1. 配置同步：appName/包名/版本/接口地址 → AndroidManifest / build.gradle.kts /
//      pubspec.yaml / update_service / 运行时 assets/config/app_config.json
//   2. 包名变化时自动迁移 Kotlin 源码（MainActivity.kt 换目录 + 重写 package 声明 +
//      删空旧目录）—— 不迁移的话 Manifest 的 .MainActivity 按新 namespace 解析不到类，
//      APK 一启动就闪退（ClassNotFoundException）
//   3. 图标生成：  dart run flutter_launcher_icons        （源图 assets/icon/app_icon.png）
//   4. 启动图生成：dart run flutter_native_splash:create   （源图 assets/icon/splash_logo.png）
//
// ⚠ 包名变更后必须先 flutter clean 再 flutter build apk（详见运行结束的提示）；
//   极光 AppKey 与包名绑定，换包名要去极光控制台用新包名重建应用并替换 AppKey。

import 'dart:convert';
import 'dart:io';

const _configFile = 'config/app_build.json';
const _manifest = 'android/app/src/main/AndroidManifest.xml';
const _gradle = 'android/app/build.gradle';
const _gradleKts = 'android/app/build.gradle.kts';
const _pubspec = 'pubspec.yaml';
const _runtimeCfg = 'assets/config/app_config.json';
const _aboutPage = 'lib/services/update_service.dart';
const _kotlinRoot = 'android/app/src/main/kotlin';
const _splashSrc = 'assets/icon/splash_logo.png';
const _cacheFile = 'tool/.gen_cache.json';

void main(List<String> args) {
  // Windows 控制台默认 GBK 代码页，Dart 输出的 UTF-8 中文/框线会显示成乱码
  // （鈺愨晲 就是 UTF-8 被按 GBK 解码的样子）。切到 UTF-8 代码页，失败不影响流程。
  if (Platform.isWindows) {
    try {
      Process.runSync('cmd', ['/c', 'chcp 65001 >nul']);
    } catch (_) {}
  }
  final forceIcons = args.contains('--icons');
  final forceSplash = args.contains('--splash');

  final cfgFile = File(_configFile);
  if (!cfgFile.existsSync()) {
    stderr.writeln('✗ 找不到配置文件 $_configFile');
    exit(1);
  }

  final cfg = jsonDecode(cfgFile.readAsStringSync()) as Map<String, dynamic>;
  final appName = (cfg['appName'] ?? '').toString();
  final pkg = (cfg['packageName'] ?? '').toString();
  // iOS 包名：不填则跟随 packageName（2026-09-19）。
  // 为什么单独一个字段：给外包做壳时 iOS 包名由**苹果描述文件**决定
  // （profile 与包名绑死，错一个字母都签不上），可能和 Android 不同。
  final iosPkg = (cfg['iosPackageName'] ?? '').toString().trim().isNotEmpty
      ? (cfg['iosPackageName'] ?? '').toString().trim()
      : pkg;
  final verName = (cfg['versionName'] ?? '').toString();
  final verCode = (cfg['versionCode'] ?? 1).toString();
  final apiBase = (cfg['apiBase'] ?? '').toString();
  final wsBase = (cfg['wsBase'] ?? '').toString();
  final icon = (cfg['icon'] ?? '').toString();

  stdout.writeln('读取配置 $_configFile');
  stdout.writeln('  应用名 : $appName');
  stdout.writeln('  包名   : $pkg');
  if (iosPkg != pkg) stdout.writeln('  iOS包名 : $iosPkg');
  stdout.writeln('  版本   : $verName (code $verCode)');
  stdout.writeln('  接口   : $apiBase');
  stdout.writeln('  WS     : $wsBase');
  stdout.writeln('  图标   : $icon');
  stdout.writeln('');

  var changed = 0;

  // 1) 应用名 → AndroidManifest
  if (appName.isNotEmpty) {
    changed += _replaceOnce(
      _manifest,
      RegExp(r'android:label="[^"]*"'),
      'android:label="$appName"',
      '应用名 → AndroidManifest',
    );
    // iOS 桌面显示名（Mac 打 ipa 同样走这份配置，2026-09-18）。
    // 注意：Dart 的 replaceFirst 对 RegExp 的 replacement **不解析 $1 组引用**
    //（实测会原样写入字面量），必须用 replaceFirstMapped 手动拼组。
    const _iosPlist = 'ios/Runner/Info.plist';
    String _plistString(String key, String value) =>
        '<key>$key</key>\n\t\t<string>$value</string>';
    changed += _replaceMapped(
        _iosPlist,
        RegExp(r'<key>CFBundleDisplayName</key>\s*<string>[^<]*</string>'),
        (m) => _plistString('CFBundleDisplayName', appName),
        '应用名 → Info.plist CFBundleDisplayName');
    changed += _replaceMapped(
        _iosPlist,
        RegExp(r'<key>CFBundleName</key>\s*<string>[^<]*</string>'),
        (m) => _plistString('CFBundleName', appName),
        '应用名 → Info.plist CFBundleName');
  }

  // 2) 包名：先读出 gradle 里当前的旧包名（迁移 Kotlin 源码要用），再替换
  final gradlePath = File(_gradle).existsSync() ? _gradle : _gradleKts;
  final oldPkg = _readCurrentPackage(gradlePath);
  if (pkg.isNotEmpty && oldPkg != null && oldPkg != pkg) {
    changed += _migrateKotlinSources(oldPkg, pkg);
  }
  if (pkg.isNotEmpty) {
    changed += _replaceOnce(
      gradlePath,
      RegExp(r'applicationId\s*=\s*"[^"]*"'),
      'applicationId = "$pkg"',
      '包名 → applicationId',
    );
    changed += _replaceOnce(
      gradlePath,
      RegExp(r'namespace\s*=\s*"[^"]*"'),
      'namespace = "$pkg"',
      '包名 → namespace',
    );
    // 一致性兜底：历史遗留情况——旧版工具只改了 gradle 没迁 Kotlin 源码，
    // 此时 gradle 与配置一致、上面的迁移不会触发，按 MainActivity.kt 的
    // 实际 package 声明再兜一次（这正是「换包名后一启动就闪退」的根源）。
    changed += _ensureKotlinPackageMatches(pkg);
  }

  // 2.5) iOS 包名 → project.pbxproj（2026-09-19）。
  // 为什么必须同步：Codemagic/Mac 打 IPA 时签名按包名匹配描述文件，
  // 工程包名与 profile 不一致会报「No matching profiles found」。
  // 以前这个文件只有 Android applicationId 会同步，iOS 包名一直要手改——
  // 实测踩坑（com.futoolapp.tool 外包就因此签不上）。
  // 细节：
  //   - 替换**全部**出现（Runner 主 target 3 处 + RunnerTests 3 处），
  //     replaceFirst 只改第一处会留下 RunnerTests 的旧前缀；
  //   - RunnerTests 的包名带 .RunnerTests 后缀，替换时保留原后缀；
  //   - 值统一写成带引号形式（pbxproj 引号可省略，带引号永远合法）。
  if (iosPkg.isNotEmpty) {
    const pbxproj = 'ios/Runner.xcodeproj/project.pbxproj';
    final f = File(pbxproj);
    if (!f.existsSync()) {
      stdout.writeln('  ⚠ 跳过（文件不存在）：$pbxproj');
    } else {
      final src = f.readAsStringSync();
      final out = src.replaceAllMapped(
        RegExp(r'PRODUCT_BUNDLE_IDENTIFIER\s*=\s*"?([^";]+)"?\s*;'),
        (m) {
          final old = m.group(1)!;
          final suffix = old.endsWith('.RunnerTests') ? '.RunnerTests' : '';
          return 'PRODUCT_BUNDLE_IDENTIFIER = "$iosPkg$suffix";';
        },
      );
      if (out == src) {
        stdout.writeln('  · 未变：iOS 包名 → pbxproj（已是 $iosPkg）');
      } else {
        f.writeAsStringSync(out);
        stdout.writeln('  ✓ iOS 包名 → $pbxproj（$iosPkg）');
        changed++;
      }
    }
  }

  // 3) 版本 → pubspec.yaml（Gradle 的 flutter.versionName/Code 自动跟随）
  if (verName.isNotEmpty) {
    changed += _replaceOnce(
      _pubspec,
      RegExp(r'^version:\s*\S+', multiLine: true),
      'version: $verName+$verCode',
      '版本 → pubspec',
    );
  }

  // 3.5) 版本基准 → update_service currentVersion（后台版本对比用，必须与打包版本一致）
  if (verName.isNotEmpty) {
    changed += _replaceOnce(
      _aboutPage,
      RegExp(r"static const currentVersion = '[^']*';"),
      "static const currentVersion = '$verName';",
      '版本基准 → update_service（检查更新对比用）',
    );
  }

  // 4) 接口地址 → 运行时配置（App 启动时读取）。
  // jpushAppKey 透传：config/app_build.json 配了才写（2026-09-18 修复——
  // 以前整体重写会把手工放进 runtime config 的 jpushAppKey 抹掉）。
  final jpushKey = (cfg['jpushAppKey'] ?? '').toString();
  final runtime = File(_runtimeCfg);
  if (!runtime.existsSync()) {
    runtime.createSync(recursive: true);
  }
  final runtimeJson = jsonEncode(
    jpushKey.isNotEmpty
        ? {'apiBase': apiBase, 'wsBase': wsBase, 'jpushAppKey': jpushKey}
        : {'apiBase': apiBase, 'wsBase': wsBase},
  );
  if (runtime.readAsStringSync().trim() != runtimeJson) {
    runtime.writeAsStringSync('$runtimeJson\n');
    stdout.writeln('  ✓ 接口地址 → $_runtimeCfg');
    changed++;
  }

  // 5) APP 图标 + 启动图（三合一：源图内容没变自动跳过，换图后自动重新生成）
  final cache = _readCache();
  if (icon.isNotEmpty) {
    _maybeGenerate(
      label: 'APP 图标',
      srcPath: icon,
      pkgName: 'flutter_launcher_icons',
      cache: cache,
      force: forceIcons,
    );
  }
  _maybeGenerate(
    label: '启动图',
    srcPath: _splashSrc,
    pkgName: 'flutter_native_splash:create',
    cache: cache,
    force: forceSplash,
  );
  _writeCache(cache);

  stdout.writeln('');
  stdout.writeln(changed > 0
      ? '✓ 完成，共更新 $changed 处。打包：flutter build apk --release'
      : '✓ 配置已是最新，无需改动。');

  // 包名变更的强制提示（漏掉这两步是「换包名后一启动就闪退」的最常见原因）
  if (pkg.isNotEmpty && oldPkg != null && oldPkg != pkg) {
    stdout.writeln('');
    stdout.writeln(
        '============================================================');
    stdout.writeln('⚠ 包名已变更：$oldPkg → $pkg');
    stdout.writeln('  1. 必须先执行 flutter clean 再 flutter build apk');
    stdout.writeln('     （不 clean 会残留旧包名的编译产物，APK 一启动就闪退）');
    stdout.writeln('  2. 极光 AppKey 与包名绑定：去极光控制台用新包名重建应用，');
    stdout.writeln(
        '     把新 AppKey 替换到 android/app/build.gradle.kts 的 JPUSH_APPKEY');
    stdout.writeln('  3. 换包名 = 换应用：老版本无法覆盖升级，需卸载重装');
    stdout.writeln(
        '============================================================');
  }
  // iOS 包名与描述文件的配套提示（签名按包名匹配，错一个字母都签不上）
  if (iosPkg.isNotEmpty) {
    stdout.writeln('');
    stdout.writeln(
        '============================================================');
    stdout.writeln('⚠ iOS 包名：$iosPkg');
    stdout.writeln('  1. 苹果后台的 App ID 与 ad-hoc 描述文件必须用同一个包名；');
    stdout.writeln('  2. codemagic.yaml 的 bundle_identifier 也要改成这个值；');
    stdout.writeln('  3. 换包名 = 描述文件全部重新生成，旧 profile 不通用。');
    stdout.writeln(
        '============================================================');
  }
}

/// 单处替换：没变则返回 0（不写文件），变了返回 1
int _replaceOnce(String path, Pattern from, String to, String label) {
  final f = File(path);
  if (!f.existsSync()) {
    stdout.writeln('  ⚠ 跳过（文件不存在）：$path');
    return 0;
  }
  final src = f.readAsStringSync();
  final out = src.replaceFirst(from, to);
  if (out == src) {
    stdout.writeln('  · 未变：$label');
    return 0;
  }
  f.writeAsStringSync(out);
  stdout.writeln('  ✓ $label');
  return 1;
}

/// 正则 + 回调替换（replaceFirstMapped）：Dart 的 replaceFirst 字符串替换
/// 不解析 $1 组引用，需要用组的替换一律走这里。
int _replaceMapped(
    String path, Pattern from, String Function(Match) to, String label) {
  final f = File(path);
  if (!f.existsSync()) {
    stdout.writeln('  ⚠ 跳过（文件不存在）：$path');
    return 0;
  }
  final src = f.readAsStringSync();
  final out = src.replaceFirstMapped(from, to);
  if (out == src) {
    stdout.writeln('  · 未变：$label');
    return 0;
  }
  f.writeAsStringSync(out);
  stdout.writeln('  ✓ $label');
  return 1;
}

/// 读 gradle 里当前的 namespace（即上次同步的包名）
String? _readCurrentPackage(String gradlePath) {
  final f = File(gradlePath);
  if (!f.existsSync()) return null;
  final m =
      RegExp(r'namespace\s*=\s*"([^"]*)"').firstMatch(f.readAsStringSync());
  return m?.group(1);
}

/// 包名变化：把 kotlin/<旧包>/ 下所有源码迁到 kotlin/<新包>/，重写 package 声明，
/// 删除旧目录。返回处理文件数。
int _migrateKotlinSources(String oldPkg, String newPkg) {
  var count = 0;
  final oldDir = Directory('$_kotlinRoot/${oldPkg.replaceAll('.', '/')}');
  final newDir = Directory('$_kotlinRoot/${newPkg.replaceAll('.', '/')}');

  if (oldDir.existsSync()) {
    newDir.createSync(recursive: true);
    for (final e in oldDir.listSync(recursive: true).whereType<File>()) {
      final rel = e.path.substring(oldDir.path.length + 1);
      var src = e.readAsStringSync();
      if (rel.endsWith('.kt')) {
        src = src.replaceFirst(
          RegExp('^package\\s+' + RegExp.escape(oldPkg) + r'\s*$',
              multiLine: true),
          'package $newPkg',
        );
      }
      final target = File('${newDir.path}/$rel');
      target.parent.createSync(recursive: true);
      target.writeAsStringSync(src);
      e.deleteSync();
      count++;
    }
    // 从旧目录一路向上删空目录（最多删到 kotlin 根）
    var d = oldDir;
    while (d.path != _kotlinRoot && d.existsSync() && d.listSync().isEmpty) {
      d.deleteSync();
      d = d.parent;
    }
    stdout.writeln('  ✓ Kotlin 源码迁移：$oldPkg → $newPkg（$count 个文件）');
  } else if (!newDir.existsSync()) {
    final newDirPath = newPkg.replaceAll('.', '/');
    stdout.writeln(
        '  ⚠ 找不到 Kotlin 源码目录：$_kotlinRoot/${oldPkg.replaceAll('.', '/')}');
    stdout.writeln('    请手动创建 $_kotlinRoot/$newDirPath/MainActivity.kt，');
    stdout.writeln('    第一行必须写 package $newPkg，否则 APK 一启动就闪退！');
  }
  return count;
}

/// 包名一致性兜底：若 kotlin/<pkg>/MainActivity.kt 不存在或 package 声明不符，
/// 先修声明；若整个文件还在旧包目录下（gradle 已改、源码没迁的历史遗留），
/// 按其 package 声明推断旧包名整体迁移。返回处理文件数。
int _ensureKotlinPackageMatches(String pkg) {
  final pkgPath = pkg.replaceAll('.', '/');
  final expected = File('$_kotlinRoot/$pkgPath/MainActivity.kt');
  if (expected.existsSync()) {
    final src = expected.readAsStringSync();
    if (src.startsWith('package $pkg')) return 0;
    expected.writeAsStringSync(src.replaceFirst(
        RegExp(r'^package\s+[\w.]+', multiLine: true), 'package $pkg'));
    stdout.writeln('  ✓ 修正 MainActivity.kt 的 package 声明 → $pkg');
    return 1;
  }
  final root = Directory(_kotlinRoot);
  if (!root.existsSync()) return 0;
  final oldPkgs = <String>{};
  for (final e in root.listSync(recursive: true).whereType<File>()) {
    if (!e.path.endsWith('MainActivity.kt')) continue;
    final m = RegExp(r'^package\s+([\w.]+)', multiLine: true)
        .firstMatch(e.readAsStringSync());
    final decl = m?.group(1);
    if (decl != null && decl != pkg) oldPkgs.add(decl);
  }
  var count = 0;
  for (final old in oldPkgs) {
    count += _migrateKotlinSources(old, pkg);
  }
  if (oldPkgs.isEmpty) {
    stdout.writeln(
        '  ⚠ 未找到 MainActivity.kt，请手动创建 $_kotlinRoot/$pkgPath/MainActivity.kt');
    stdout.writeln('    第一行写 package $pkg，否则 APK 一启动就闪退！');
  }
  return count;
}

/// 源图内容（大小+mtime）与缓存一致则跳过，否则执行生成器并更新缓存
void _maybeGenerate({
  required String label,
  required String srcPath,
  required String pkgName,
  required Map<String, String> cache,
  required bool force,
}) {
  final f = File(srcPath);
  if (!f.existsSync()) {
    stdout.writeln('  ⚠ $label 源图不存在：$srcPath（跳过生成）');
    return;
  }
  final sig =
      '${f.lengthSync()}_${f.lastModifiedSync().millisecondsSinceEpoch}';
  if (!force && cache[srcPath] == sig) {
    stdout.writeln('  · $label：源图未变化，跳过（强制重生成加 --icons/--splash）');
    return;
  }
  stdout.writeln('  → 生成 $label：dart run $pkgName ...');
  // 子进程（flutter_launcher_icons / flutter_native_splash）输出是 UTF-8，
  // Dart 默认按系统编码（Windows=GBK）解码会变成「鈺愨晲」式乱码，显式按 UTF-8 解
  final utf8lax = const Utf8Codec(allowMalformed: true);
  final r = Process.runSync(Platform.resolvedExecutable, ['run', pkgName],
      stdoutEncoding: utf8lax, stderrEncoding: utf8lax);
  final out = r.stdout.toString().trim();
  final err = r.stderr.toString().trim();
  if (out.isNotEmpty) stdout.writeln(out);
  if (err.isNotEmpty) stderr.writeln(err);
  if (r.exitCode != 0) {
    stderr
        .writeln('  ✗ $label 生成失败（exit ${r.exitCode}），可单独重跑：dart run $pkgName');
  } else {
    cache[srcPath] = sig;
    stdout.writeln('  ✓ $label 生成完成');
  }
}

Map<String, String> _readCache() {
  final f = File(_cacheFile);
  if (!f.existsSync()) return {};
  try {
    final raw = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    return raw.map((k, v) => MapEntry(k, v.toString()));
  } catch (_) {
    return {};
  }
}

void _writeCache(Map<String, String> cache) {
  final f = File(_cacheFile);
  if (!f.parent.existsSync()) f.parent.createSync(recursive: true);
  f.writeAsStringSync(JsonEncoder.withIndent('  ').convert(cache));
}
