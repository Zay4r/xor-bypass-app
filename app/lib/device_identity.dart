import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

final class DeviceIdentityInfo {
  const DeviceIdentityInfo({required this.deviceId, required this.publicKey});

  final String deviceId;
  final String publicKey;
}

/// Owns all device private-key loading, generation, and signing operations.
final class DeviceIdentity {
  DeviceIdentity({FlutterSecureStorage? storage})
    : _storage =
          storage ?? const FlutterSecureStorage(aOptions: _androidOptions);

  static const _privateKeyStorageKey = 'ed25519_device_private_key_v1';
  static const _signingContext = 'xor-vpn-auth-v1';
  static const _androidOptions = AndroidOptions(
    encryptedSharedPreferences: true,
    resetOnError: true,
  );

  final FlutterSecureStorage _storage;
  final Ed25519 _algorithm = Ed25519();
  Future<SimpleKeyPair>? _keyPairFuture;

  Future<DeviceIdentityInfo> getIdentity() async {
    final keyPair = await _loadOrCreateKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    final publicKeyBytes = publicKey.bytes;
    if (publicKeyBytes.length != 32) {
      throw StateError('Invalid Ed25519 public key length');
    }

    final digest = await Sha256().hash(publicKeyBytes);
    return DeviceIdentityInfo(
      deviceId: _lowercaseHex(digest.bytes),
      publicKey: base64Encode(publicKeyBytes),
    );
  }

  Future<String> signChallenge({
    required String buildNumber,
    required String challengeId,
    required String challenge,
  }) async {
    final challengeIdBytes = base64Decode(challengeId);
    final challengeBytes = base64Decode(challenge);
    if (challengeIdBytes.length != 16 || challengeBytes.length != 32) {
      throw const FormatException('Malformed authentication challenge');
    }

    final keyPair = await _loadOrCreateKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    if (publicKey.bytes.length != 32) {
      throw StateError('Invalid Ed25519 public key length');
    }

    final buildHash = await Sha256().hash(utf8.encode(buildNumber));
    final publicKeyHash = await Sha256().hash(publicKey.bytes);
    final message = <int>[
      ...utf8.encode(_signingContext),
      ...challengeIdBytes,
      ...challengeBytes,
      ...buildHash.bytes,
      ...publicKeyHash.bytes,
    ];
    final signature = await _algorithm.sign(message, keyPair: keyPair);
    if (signature.bytes.length != 64) {
      throw StateError('Invalid Ed25519 signature length');
    }
    return base64Encode(signature.bytes);
  }

  Future<SimpleKeyPair> _loadOrCreateKeyPair() =>
      _keyPairFuture ??= _readOrGenerateKeyPair();

  Future<SimpleKeyPair> _readOrGenerateKeyPair() async {
    final storedKey = await _storage.read(key: _privateKeyStorageKey);
    if (storedKey != null) {
      final seed = base64Decode(storedKey);
      if (seed.length != 32) {
        throw StateError('Stored Ed25519 private key is invalid');
      }
      return _algorithm.newKeyPairFromSeed(seed);
    }

    final keyPair = await _algorithm.newKeyPair();
    final privateKeyBytes = await keyPair.extractPrivateKeyBytes();
    if (privateKeyBytes.length != 32) {
      throw StateError('Generated Ed25519 private key is invalid');
    }
    await _storage.write(
      key: _privateKeyStorageKey,
      value: base64Encode(privateKeyBytes),
    );
    return keyPair;
  }

  static String _lowercaseHex(List<int> bytes) =>
      bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}
