// E2EE 跨端线格式互通测试（2026-11-15 11bb 配套，双平台验证）。
//
// 背景：客户实测「同一账号同一密文，App 端可解、H5（Flutter Web）不可解」，
// 需实证排除「cryptography 包 WebCrypto 实现与移动端字节格式不一致」方向。
//
// 方法：用固定种子按 e2ee_service.dart 的实际调用参数（X25519 →
// HKDF-SHA256(salt=空, info='e2ee-wrap-v1') → AES-256-GCM，密文||16B tag）
// 在 VM（纯 Dart）上生成确定性 KAT 向量（tool/e2ee_kat_gen.dart 产出），
// 硬编码进本测试。同一份测试代码在两个平台各跑一遍：
// - VM 跑：纯 Dart 实现基准（等价 App/Android 端行为）；
// - Chrome 跑：dart2js + WebCrypto 实现 —— 若重算包裹输出与 VM 向量
//   **逐字节一致**且能解出同一会话密钥，即证明 Web 端加解密与移动端互通，
//   Web 解密失败只能出在密文之外的匹配环节（= uid 精度根因）。
//
// 运行：
//   flutter test test/e2ee_wire_format_test.dart                 # VM（纯 Dart）
//   flutter test test/e2ee_wire_format_test.dart --platform chrome  # WebCrypto
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

const String wrapInfo = 'e2ee-wrap-v1';

/// tool/e2ee_kat_gen.dart 在 VM（纯 Dart）上用固定种子产出的向量：
/// 接收方身份密钥（recvPriv=种子、recvPub=配对公钥）、发送端临时公钥 ephPub、
/// 会话密钥 sessionKey 经 VM 端 wrap 后的包裹密文 c（含 16B tag）与 nonce n。
const Map<String, String> katFromVm = {
  'recvPub': 'B6N8vBQgk8i3VdwbEOhstCY3StFqqFPtC9/AsrhtHHw=',
  'recvPriv': 'AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA=',
  'ephPub': 'WGmv9FBUlzLLqu1eXfmzCm2jHLDldCutWtShp2jxpns=',
  'n': 'AQwXIi04Q05ZZG96',
  'c': 'csrJxls2TGP4GAfSKmW5uLi8IMeBxXeFMXpwQjeR7ANmVDotIBFr1QhgoOGJVZhE',
  'sessionKey': 'AwgNEhccISYrMDU6P0RJTlNYXWJnbHF2e4CFio+UmZ4=',
};

/// 与 e2ee_service._unwrap 相同的拆封链：ECDH(myPriv, ep) → HKDF → AES-GCM。
Future<List<int>?> unwrapChain(
  X25519 x25519,
  AesGcm aes,
  String wrappedB64,
  String epPubB64,
  String nonceB64,
  String privB64,
) async {
  try {
    final myKp = await x25519.newKeyPairFromSeed(base64.decode(privB64));
    final shared = await x25519.sharedSecretKey(
      keyPair: myKp,
      remotePublicKey: SimplePublicKey(base64.decode(epPubB64),
          type: KeyPairType.x25519),
    );
    final kek = await Hkdf(hmac: Hmac.sha256(), outputLength: 32)
        .deriveKey(secretKey: shared, info: utf8.encode(wrapInfo))
        .then((k) => k.extractBytes());
    final wrapped = base64.decode(wrappedB64);
    if (wrapped.length <= 16) return null;
    final mac = Mac(wrapped.sublist(wrapped.length - 16));
    return await aes.decrypt(
      SecretBox(wrapped.sublist(0, wrapped.length - 16),
          nonce: base64.decode(nonceB64), mac: mac),
      secretKey: SecretKey(kek),
    );
  } catch (_) {
    return null;
  }
}

void main() {
  final x25519 = X25519();
  final aes = AesGcm.with256bits();

  // 与 KAT 生成器完全相同的固定输入（测试内重算，而非随机）
  final recvSeed = List<int>.generate(32, (i) => i + 1);
  final ephSeed = List<int>.generate(32, (i) => i + 33);
  final sessionKey = List<int>.generate(32, (i) => (i * 5 + 3) & 0xff);
  final nonce = List<int>.generate(12, (i) => (i * 11 + 1) & 0xff);

  test('ECIES wrap→unwrap 自洽（发送/接收同一平台实现）', () async {
    final recvKp = await x25519.newKeyPairFromSeed(recvSeed);
    final recvPubB64 =
        base64.encode((await recvKp.extractPublicKey()).bytes);

    final eph = await x25519.newKeyPairFromSeed(ephSeed);
    final ephPubB64 =
        base64.encode((await eph.extractPublicKey()).bytes);
    final shared = await x25519.sharedSecretKey(
      keyPair: eph,
      remotePublicKey: SimplePublicKey(base64.decode(recvPubB64),
          type: KeyPairType.x25519),
    );
    final kek = await Hkdf(hmac: Hmac.sha256(), outputLength: 32)
        .deriveKey(secretKey: shared, info: utf8.encode(wrapInfo))
        .then((k) => k.extractBytes());
    final box = await aes.encrypt(sessionKey,
        secretKey: SecretKey(kek), nonce: nonce);
    final wrappedB64 = base64.encode([...box.cipherText, ...box.mac.bytes]);

    final got = await unwrapChain(
        x25519, aes, wrappedB64, ephPubB64, base64.encode(nonce),
        base64.encode(recvSeed));
    expect(got, sessionKey);
  });

  test('解包 VM（纯 Dart）产出的 KAT 向量：App→H5 方向互通', () async {
    final got = await unwrapChain(x25519, aes, katFromVm['c']!,
        katFromVm['ephPub']!, katFromVm['n']!, katFromVm['recvPriv']!);
    expect(got, base64.decode(katFromVm['sessionKey']!));
  });

  test('本平台重算包裹与 VM KAT 逐字节一致：H5→App 方向互通', () async {
    final recvKp = await x25519.newKeyPairFromSeed(recvSeed);
    final recvPubB64 =
        base64.encode((await recvKp.extractPublicKey()).bytes);
    expect(recvPubB64, katFromVm['recvPub']);

    final eph = await x25519.newKeyPairFromSeed(ephSeed);
    final ephPubB64 =
        base64.encode((await eph.extractPublicKey()).bytes);
    final shared = await x25519.sharedSecretKey(
      keyPair: eph,
      remotePublicKey: SimplePublicKey(base64.decode(recvPubB64),
          type: KeyPairType.x25519),
    );
    final kek = await Hkdf(hmac: Hmac.sha256(), outputLength: 32)
        .deriveKey(secretKey: shared, info: utf8.encode(wrapInfo))
        .then((k) => k.extractBytes());
    final box = await aes.encrypt(sessionKey,
        secretKey: SecretKey(kek), nonce: nonce);
    final wrappedB64 = base64.encode([...box.cipherText, ...box.mac.bytes]);
    // 关键断言：WebCrypto 的 ECDH+HKDF+AES-GCM 输出必须与 VM 纯 Dart 一致
    expect(wrappedB64, katFromVm['c']);
  });
}
