import 'package:flutter/material.dart';

import 'db.dart';

/// شمارهٔ تبِ فعالِ صفحهٔ اصلی (۰ خانه، ۱ خرید، ۲ فروش، ۳ موجودی).
/// تب‌های پنهان تا وقتی باز نشوند از دیتابیس نمی‌خوانند.
final ValueNotifier<int> activeTab = ValueNotifier<int>(0);

/// جایگزین الگوی «ValueListenableBuilder + FutureBuilder(future: کوئری())».
///
/// مشکل قبلی: کوئری داخل build ساخته می‌شد، پس با هر setState (مثلاً هر حرفی که
/// در جستجو تایپ می‌شد) کل کوئری دوباره اجرا می‌شد.
/// اینجا کوئری فقط در این حالت‌ها اجرا می‌شود:
///  ۱) بار اول،
///  ۲) وقتی دیتابیس تغییر کند (AppDb.I.version)،
/// و اگر [tab] داده شده و این صفحه تبِ فعال نباشد، تا باز شدن تب عقب می‌افتد.
class LiveQuery<T> extends StatefulWidget {
  const LiveQuery({super.key, required this.load, required this.builder, this.tab});

  final Future<T> Function() load;
  final AsyncWidgetBuilder<T> builder;

  /// شمارهٔ تب (فقط برای صفحه‌هایی که داخل IndexedStack صفحهٔ اصلی هستند).
  /// برای صفحه‌هایی که با Navigator.push باز می‌شوند null بگذارید.
  final int? tab;

  @override
  State<LiveQuery<T>> createState() => _LiveQueryState<T>();
}

class _LiveQueryState<T> extends State<LiveQuery<T>> {
  Future<T>? _future;
  bool _dirty = true;
  bool _inited = false;
  bool _gated = false;

  bool get _active => !_gated || activeTab.value == widget.tab;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_inited) return;
    _inited = true;
    // فقط وقتی داخل مسیر اصلی (تب‌های خانه) هستیم محدودیتِ «تب فعال» اعمال می‌شود؛
    // صفحه‌ای که با push باز شده همیشه فعال است.
    final route = ModalRoute.of(context);
    _gated = widget.tab != null && (route == null || route.isFirst);
    AppDb.I.version.addListener(_onDbChanged);
    activeTab.addListener(_reloadIfNeeded);
    if (_active) {
      _dirty = false;
      _future = widget.load();
    }
  }

  @override
  void dispose() {
    AppDb.I.version.removeListener(_onDbChanged);
    activeTab.removeListener(_reloadIfNeeded);
    super.dispose();
  }

  void _onDbChanged() {
    _dirty = true;
    _reloadIfNeeded();
  }

  void _reloadIfNeeded() {
    if (!mounted || !_dirty || !_active) return;
    _dirty = false;
    setState(() => _future = widget.load());
  }

  @override
  Widget build(BuildContext context) {
    final f = _future;
    if (f == null) return widget.builder(context, AsyncSnapshot<T>.nothing());
    return FutureBuilder<T>(future: f, builder: widget.builder);
  }
}
