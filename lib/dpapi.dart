import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

final class _Blob extends Struct {
  @Uint32()
  external int cbData;
  external Pointer<Uint8> pbData;
}

typedef _ProtectNative = Int32 Function(
    Pointer<_Blob>, Pointer<Utf16>, Pointer<_Blob>, Pointer<Void>, Pointer<Void>, Uint32, Pointer<_Blob>);
typedef _ProtectDart = int Function(
    Pointer<_Blob>, Pointer<Utf16>, Pointer<_Blob>, Pointer<Void>, Pointer<Void>, int, Pointer<_Blob>);
typedef _UnprotectNative = Int32 Function(
    Pointer<_Blob>, Pointer<Pointer<Utf16>>, Pointer<_Blob>, Pointer<Void>, Pointer<Void>, Uint32, Pointer<_Blob>);
typedef _UnprotectDart = int Function(
    Pointer<_Blob>, Pointer<Pointer<Utf16>>, Pointer<_Blob>, Pointer<Void>, Pointer<Void>, int, Pointer<_Blob>);
typedef _FreeNative = Pointer<Void> Function(Pointer<Void>);
typedef _FreeDart = Pointer<Void> Function(Pointer<Void>);

/// رمزگذاری با DPAPI ویندوز: فقط همین کاربرِ ویندوز روی همین کامپیوتر می‌تواند رمزگشایی کند.
class Dpapi {
  Dpapi._();

  static final DynamicLibrary _crypt = DynamicLibrary.open('crypt32.dll');
  static final DynamicLibrary _k32 = DynamicLibrary.open('kernel32.dll');
  static final _ProtectDart _protect = _crypt.lookupFunction<_ProtectNative, _ProtectDart>('CryptProtectData');
  static final _UnprotectDart _unprotect =
      _crypt.lookupFunction<_UnprotectNative, _UnprotectDart>('CryptUnprotectData');
  static final _FreeDart _localFree = _k32.lookupFunction<_FreeNative, _FreeDart>('LocalFree');

  static Uint8List? _run(Uint8List data, bool encrypt) {
    final inBlob = calloc<_Blob>();
    final outBlob = calloc<_Blob>();
    final buf = calloc<Uint8>(data.isEmpty ? 1 : data.length);
    try {
      if (data.isNotEmpty) buf.asTypedList(data.length).setAll(0, data);
      inBlob.ref.cbData = data.length;
      inBlob.ref.pbData = buf;
      final ok = encrypt
          ? _protect(inBlob, nullptr, nullptr, nullptr, nullptr, 0, outBlob)
          : _unprotect(inBlob, nullptr, nullptr, nullptr, nullptr, 0, outBlob);
      if (ok == 0) return null;
      final res = Uint8List.fromList(outBlob.ref.pbData.asTypedList(outBlob.ref.cbData));
      _localFree(outBlob.ref.pbData.cast<Void>());
      return res;
    } catch (_) {
      return null;
    } finally {
      calloc.free(buf);
      calloc.free(inBlob);
      calloc.free(outBlob);
    }
  }

  static Uint8List? protect(Uint8List data) => _run(data, true);
  static Uint8List? unprotect(Uint8List data) => _run(data, false);
}

/// نگهداری توکن ورود: روی ویندوز با DPAPI رمز می‌شود (پیشوند «dpapi:»).
/// اگر DPAPI در دسترس نبود، همان مقدار ساده برمی‌گردد (برنامه از کار نمی‌افتد).
/// مقدارهای قدیمیِ ساده هم خوانده می‌شوند و در اولین ذخیرهٔ بعدی رمز می‌شوند.
class TokenVault {
  static const _prefix = 'dpapi:';

  static String seal(String token) {
    if (!Platform.isWindows) return token;
    final enc = Dpapi.protect(Uint8List.fromList(utf8.encode(token)));
    return enc == null ? token : '$_prefix${base64.encode(enc)}';
  }

  /// null = رمزگشایی نشد (مثلاً فایل از کامپیوتر دیگر آمده) → باید دوباره وارد شد
  static String? open(String stored) {
    if (!stored.startsWith(_prefix)) return stored;
    if (!Platform.isWindows) return null;
    try {
      final dec = Dpapi.unprotect(base64.decode(stored.substring(_prefix.length)));
      return dec == null ? null : utf8.decode(dec);
    } catch (_) {
      return null;
    }
  }
}
