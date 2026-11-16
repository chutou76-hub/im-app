// E2EE 跨端线格式 KAT（Known Answer Test）生成器（2026-11-15 11bb 配套）。
//
// 用固定种子在**VM（纯 Dart 实现）**上按 e2ee_service.dart 的实际调用参数
// 产出一条确定性 ECIES 包裹向量，打印 JSON —— 该向量随后被硬编码进
// test/e2ee_wire_format_test.dart，供 Chrome（dart2js + WebCrypto）平台
// 解包比对：若 Web 端能解出同一会话密钥且重加密输出逐字节一致，即证明
// cryptography 包 Web/VM 两侧 X25519/HKDF/AES-GCM 字节格式互通，
// 排除「WebCrypto 实现差异导致 Web 解密必失败」方向。
//
// 运行：dart run tool/e2ee_kat_gen.dart
import 'dart:convert';

import 'package:cryptography/cryptography.dart';

const String wrapInfo = 'e2ee-wrap-v1';

Future<void> main() async {
  final x25519 = X25519();
  final aes = AesGcm.with256bits();

  // 固定种子（雪花量级测试统一用可复现输入；种子非零、无低阶点风险）
  final recvSeed = List<int>.generate(32, (i) => i + 1);
  final ephSeed = List<int>.generate(32, (i) => i + 33);
  final sessionKey = List<int>.generate(32, (i) => (i * 5 + 3) & 0xff);
  final nonce = List<int>.generate(12, (i) => (i * 11 + 1) & 0xff);

  // 接收方身份密钥（newKeyPairFromSeed 在 Web/VM 都是纯 Dart，确定性）
  final recvKp = await x25519.newKeyPairFromSeed(recvSeed);
  final recvPubB64 =
      base64.encode((await recvKp.extractPublicKey()).bytes);
  final recvPrivB64 = base64.encode(recvSeed);

  // 发送端 _wrap：ECDH(eph, recvPub) → HKDF(info=wrap-v1, salt=空) → AES-GCM
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
  final box =
      await aes.encrypt(sessionKey, secretKey: SecretKey(kek), nonce: nonce);
  final wrappedB64 = base64.encode([...box.cipherText, ...box.mac.bytes]);

  // 用同一份纯 Dart 代码自解一次（VM 侧健全性）
  final myKp = await x25519.newKeyPairFromSeed(base64.decode(recvPrivB64));
  final shared2 = await x25519.sharedSecretKey(
    keyPair: myKp,
    remotePublicKey: SimplePublicKey(base64.decode(ephPubB64),
        type: KeyPairType.x25519),
  );
  final kek2 = await Hkdf(hmac: Hmac.sha256(), outputLength: 32)
      .deriveKey(secretKey: shared2, info: utf8.encode(wrapInfo))
      .then((k) => k.extractBytes());
  final ct = base64.decode(wrappedB64);
  final mac = Mac(ct.sublist(ct.length - 16));
  final sk = await aes.decrypt(
    SecretBox(ct.sublist(0, ct.length - 16), nonce: nonce, mac: mac),
    secretKey: SecretKey(kek2),
  );
  assert(sk.length == 32);

  print(jsonEncode({
    'recvPub': recvPubB64,
    'recvPriv': recvPrivB64,
    'ephPub': ephPubB64,
    'n': base64.encode(nonce),
    'c': wrappedB64,
    'sessionKey': base64.encode(sessionKey),
  }));
}
