// پسته‌بازار — رابط مخصوص ویندوز: منوی کناری ثابت، تم دسکتاپ، میان‌بُرهای صفحه‌کلید، بزرگ‌نمایی و تمام‌صفحه (F11).
// فقط وقتی Platform.isWindows باشد استفاده می‌شود؛ روی اندروید هیچ‌کدام از این‌ها اجرا نمی‌شود.
import 'dart:ffi' hide Size;

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'edition.dart' show EditionBadge;
import 'live_query.dart' show activeTab;
import 'sync_service.dart';

const Color _kBrand = Color(0xFF5B7F2A);
const Color _kBrandDark = Color(0xFF3F5B1B);
const Color _kPageBg = Color(0xFFF2F4EF);
const Color _kLine = Color(0xFFDDE3D6);

/// ---------------------------------------------------------------------------
/// تنظیمات ظاهری ویندوز (ذخیره در SharedPreferences؛ اگر خوانده نشد پیش‌فرض)
/// ---------------------------------------------------------------------------
class DeskPrefs {
  DeskPrefs._();

  /// ضریب اندازهٔ متن (Ctrl +/-)
  static final ValueNotifier<double> zoom = ValueNotifier<double>(1.0);

  /// منوی کناری جمع‌شده (فقط آیکون)
  static final ValueNotifier<bool> collapsed = ValueNotifier<bool>(false);

  static Future<void> load() async {
    try {
      final SharedPreferences sp = await SharedPreferences.getInstance();
      final double? z = sp.getDouble('desk_zoom');
      if (z != null && z >= 0.8 && z <= 1.6) zoom.value = z;
      collapsed.value = sp.getBool('desk_collapsed') ?? false;
    } catch (_) {}
  }

  static Future<void> _save() async {
    try {
      final SharedPreferences sp = await SharedPreferences.getInstance();
      await sp.setDouble('desk_zoom', zoom.value);
      await sp.setBool('desk_collapsed', collapsed.value);
    } catch (_) {}
  }

  static void zoomBy(double d) {
    zoom.value = (((zoom.value + d) * 100).round() / 100).clamp(0.8, 1.6).toDouble();
    _save();
  }

  static void zoomReset() {
    zoom.value = 1.0;
    _save();
  }

  static void toggleCollapsed() {
    collapsed.value = !collapsed.value;
    _save();
  }
}

/// ---------------------------------------------------------------------------
/// تمام‌صفحه (F11) با user32 — بدون پلاگین؛ هر خطا بی‌صدا نادیده گرفته می‌شود.
/// ---------------------------------------------------------------------------
class DeskWindow {
  DeskWindow._();

  static bool _full = false;
  static bool _wasMax = false;
  static int _oldStyle = 0;

  static bool get isFullScreen => _full;

  static void toggleFullScreen() {
    try {
      final DynamicLibrary u = DynamicLibrary.open('user32.dll');
      final int Function(Pointer<Utf16>, Pointer<Utf16>) findWindow = u.lookupFunction<
          IntPtr Function(Pointer<Utf16>, Pointer<Utf16>), int Function(Pointer<Utf16>, Pointer<Utf16>)>('FindWindowW');
      final int Function(int, int) getLong =
          u.lookupFunction<IntPtr Function(IntPtr, Int32), int Function(int, int)>('GetWindowLongPtrW');
      final int Function(int, int, int) setLong = u
          .lookupFunction<IntPtr Function(IntPtr, Int32, IntPtr), int Function(int, int, int)>('SetWindowLongPtrW');
      final int Function(int, int, int, int, int, int, int) setPos = u.lookupFunction<
          Int32 Function(IntPtr, IntPtr, Int32, Int32, Int32, Int32, Uint32),
          int Function(int, int, int, int, int, int, int)>('SetWindowPos');
      final int Function(int, int) showWindow =
          u.lookupFunction<Int32 Function(IntPtr, Int32), int Function(int, int)>('ShowWindow');
      final int Function(int) isZoomed = u.lookupFunction<Int32 Function(IntPtr), int Function(int)>('IsZoomed');
      final int Function(int) metrics = u.lookupFunction<Int32 Function(Int32), int Function(int)>('GetSystemMetrics');

      final Pointer<Utf16> cls = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
      final int hwnd = findWindow(cls, nullptr);
      calloc.free(cls);
      if (hwnd == 0) return;

      const int gwlStyle = -16;
      const int wsOverlapped = 0x00CF0000; // WS_OVERLAPPEDWINDOW
      if (!_full) {
        _wasMax = isZoomed(hwnd) != 0;
        if (_wasMax) showWindow(hwnd, 9); // SW_RESTORE
        _oldStyle = getLong(hwnd, gwlStyle);
        setLong(hwnd, gwlStyle, _oldStyle & ~wsOverlapped);
        // SWP_FRAMECHANGED | SWP_SHOWWINDOW | SWP_NOOWNERZORDER
        setPos(hwnd, 0, 0, 0, metrics(0), metrics(1), 0x0020 | 0x0040 | 0x0200);
        _full = true;
      } else {
        setLong(hwnd, gwlStyle, _oldStyle);
        // SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER
        setPos(hwnd, 0, 0, 0, 0, 0, 0x0020 | 0x0002 | 0x0001 | 0x0004);
        showWindow(hwnd, _wasMax ? 3 : 9); // SW_MAXIMIZE / SW_RESTORE
        _full = false;
      }
    } catch (_) {}
  }
}

/// ---------------------------------------------------------------------------
/// تم دسکتاپ (Material 3، سبز پسته‌ای، کارت‌های تخت، فیلدهای پُر، اسکرول‌بار همیشه‌پیدا)
/// ---------------------------------------------------------------------------
ThemeData buildDeskTheme() {
  final ColorScheme cs = ColorScheme.fromSeed(seedColor: _kBrand, brightness: Brightness.light).copyWith(
    primary: _kBrand,
    surface: Colors.white,
  );
  final OutlineInputBorder border = OutlineInputBorder(
    borderRadius: BorderRadius.circular(10),
    borderSide: const BorderSide(color: _kLine),
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: cs,
    fontFamily: 'Vazirmatn', // در پروژهٔ ویندوز در pubspec معرفی می‌شود؛ اگر نبود فونت سیستم
    scaffoldBackgroundColor: _kPageBg,
    visualDensity: const VisualDensity(horizontal: -1, vertical: -1),
    splashFactory: InkRipple.splashFactory,
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.white,
      foregroundColor: Color(0xFF1F2A14),
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      toolbarHeight: 56,
      shape: Border(bottom: BorderSide(color: _kLine)),
      titleTextStyle: TextStyle(fontFamily: 'Vazirmatn', fontSize: 17, fontWeight: FontWeight.bold, color: Color(0xFF1F2A14)),
    ),
    cardTheme: CardThemeData(
      color: Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: 5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: const BorderSide(color: _kLine)),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 8,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: border,
      enabledBorder: border,
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: _kBrand, width: 1.6),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(96, 42),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        minimumSize: const Size(96, 42),
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(96, 42),
        side: const BorderSide(color: _kLine),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    chipTheme: ChipThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      side: const BorderSide(color: _kLine),
    ),
    listTileTheme: ListTileThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14),
    ),
    dividerTheme: const DividerThemeData(color: _kLine, space: 1, thickness: 1),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 500),
      decoration: BoxDecoration(color: const Color(0xE61F2A14), borderRadius: BorderRadius.circular(8)),
      textStyle: const TextStyle(fontFamily: 'Vazirmatn', color: Colors.white, fontSize: 12),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbVisibility: WidgetStateProperty.all(true),
      thickness: WidgetStateProperty.all(9),
      radius: const Radius.circular(8),
      thumbColor: WidgetStateProperty.resolveWith(
          (Set<WidgetState> s) => s.contains(WidgetState.hovered) ? const Color(0xFF8A9A78) : const Color(0xFFB9C4AA)),
    ),
    // بدون انیمیشنِ صفحه: باز شدن صفحه‌ها فوری است (سریع‌تر و دسکتاپی‌تر) و عرض محتوا محدود می‌شود
    pageTransitionsTheme: const PageTransitionsTheme(builders: <TargetPlatform, PageTransitionsBuilder>{
      TargetPlatform.windows: _DeskPageTransitions(),
      TargetPlatform.linux: _DeskPageTransitions(),
      TargetPlatform.android: _DeskPageTransitions(),
    }),
  );
}

class _DeskPageTransitions extends PageTransitionsBuilder {
  const _DeskPageTransitions();

  @override
  Widget buildTransitions<T>(PageRoute<T> route, BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation, Widget child) {
    // روی مانیتورهای خیلی عریض (بیش از ۱۶۸۰ پیکسل) محتوا وسط می‌ماند؛ در حالت عادی کل صفحه پر می‌شود
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 1680), child: child),
    );
  }
}

/// ---------------------------------------------------------------------------
/// قاب اصلی ویندوز: منوی کناری + محتوا (Navigator داخلی تا منو همیشه دیده شود)
/// ---------------------------------------------------------------------------
class DeskShell extends StatelessWidget {
  const DeskShell({
    super.key,
    required this.navKey,
    required this.menu,
    required this.content,
    required this.onTab,
  });

  final GlobalKey<NavigatorState> navKey;

  /// همان فهرست منوی کشویی سیستم (ListTileها)
  final Widget menu;
  final Widget content;
  final void Function(int) onTab;

  static const List<_TabDef> _tabs = <_TabDef>[
    _TabDef(Icons.home_outlined, Icons.home, 'خانه'),
    _TabDef(Icons.shopping_cart_outlined, Icons.shopping_cart, 'خرید'),
    _TabDef(Icons.sell_outlined, Icons.sell, 'فروش'),
    _TabDef(Icons.warehouse_outlined, Icons.warehouse, 'موجودی'),
  ];

  void _back() {
    final NavigatorState? n = navKey.currentState;
    if (n == null || !n.canPop()) return;
    // وقتی کاربر داخل یک فیلد متن تایپ می‌کند Esc صفحه را نمی‌بندد
    final BuildContext? fc = FocusManager.instance.primaryFocus?.context;
    if (fc != null && fc.findAncestorWidgetOfExactType<EditableText>() != null) return;
    n.maybePop();
  }

  void _sync(BuildContext context) {
    SyncService.I.syncNow(pull: true);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('همگام‌سازی با سرور شروع شد'), duration: Duration(seconds: 2)));
  }

  @override
  Widget build(BuildContext context) {
    final Map<ShortcutActivator, VoidCallback> keys = <ShortcutActivator, VoidCallback>{
      const SingleActivator(LogicalKeyboardKey.digit1, control: true): () => onTab(0),
      const SingleActivator(LogicalKeyboardKey.digit2, control: true): () => onTab(1),
      const SingleActivator(LogicalKeyboardKey.digit3, control: true): () => onTab(2),
      const SingleActivator(LogicalKeyboardKey.digit4, control: true): () => onTab(3),
      const SingleActivator(LogicalKeyboardKey.keyB, control: true): DeskPrefs.toggleCollapsed,
      const SingleActivator(LogicalKeyboardKey.f5): () => _sync(context),
      const SingleActivator(LogicalKeyboardKey.f11): DeskWindow.toggleFullScreen,
      const SingleActivator(LogicalKeyboardKey.escape): _back,
      const SingleActivator(LogicalKeyboardKey.equal, control: true): () => DeskPrefs.zoomBy(0.05),
      const SingleActivator(LogicalKeyboardKey.add, control: true): () => DeskPrefs.zoomBy(0.05),
      const SingleActivator(LogicalKeyboardKey.numpadAdd, control: true): () => DeskPrefs.zoomBy(0.05),
      const SingleActivator(LogicalKeyboardKey.minus, control: true): () => DeskPrefs.zoomBy(-0.05),
      const SingleActivator(LogicalKeyboardKey.numpadSubtract, control: true): () => DeskPrefs.zoomBy(-0.05),
      const SingleActivator(LogicalKeyboardKey.digit0, control: true): DeskPrefs.zoomReset,
    };
    return CallbackShortcuts(
      bindings: keys,
      child: Focus(
        autofocus: true,
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints box) {
            return ValueListenableBuilder<bool>(
              valueListenable: DeskPrefs.collapsed,
              builder: (BuildContext context, bool userCollapsed, Widget? _) {
                // پنجرهٔ باریک: منو خودکار جمع می‌شود
                final bool collapsed = userCollapsed || box.maxWidth < 980;
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    _Sidebar(
                      collapsed: collapsed,
                      tabs: _tabs,
                      menu: menu,
                      onTab: onTab,
                      onSync: () => _sync(context),
                    ),
                    Expanded(child: ColoredBox(color: _kPageBg, child: content)),
                  ],
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _TabDef {
  const _TabDef(this.icon, this.selectedIcon, this.label);
  final IconData icon;
  final IconData selectedIcon;
  final String label;
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.collapsed,
    required this.tabs,
    required this.menu,
    required this.onTab,
    required this.onSync,
  });

  final bool collapsed;
  final List<_TabDef> tabs;
  final Widget menu;
  final void Function(int) onTab;
  final VoidCallback onSync;

  @override
  Widget build(BuildContext context) {
    final ThemeData base = Theme.of(context);
    final Widget menuThemed = Theme(
      data: base.copyWith(
        listTileTheme: ListTileThemeData(
          dense: true,
          visualDensity: const VisualDensity(horizontal: -2, vertical: -2),
          minLeadingWidth: 24,
          horizontalTitleGap: 10,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12),
          iconColor: const Color(0xFF55664A),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          titleTextStyle: const TextStyle(fontFamily: 'Vazirmatn', fontSize: 13.5, color: Color(0xFF1F2A14)),
        ),
      ),
      child: menu,
    );
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      width: collapsed ? 72 : 272,
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(left: BorderSide(color: _kLine)),
      ),
      // Material لازم است: ListTile و Text بدونِ Material خطا می‌دهند / زیرخط می‌خورند
      child: Material(
        type: MaterialType.transparency,
        child: Column(
        children: <Widget>[
          _SidebarHeader(collapsed: collapsed),
          ValueListenableBuilder<int>(
            valueListenable: activeTab,
            builder: (BuildContext context, int cur, Widget? _) => Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
              child: Column(
                children: <Widget>[
                  for (int i = 0; i < tabs.length; i++)
                    _NavItem(
                      icon: tabs[i].icon,
                      selectedIcon: tabs[i].selectedIcon,
                      label: tabs[i].label,
                      hint: 'Ctrl+${i + 1}',
                      selected: cur == i,
                      collapsed: collapsed,
                      onTap: () => onTab(i),
                    ),
                ],
              ),
            ),
          ),
          const Divider(height: 12),
          if (!collapsed) ...<Widget>[
            const Padding(
              padding: EdgeInsets.fromLTRB(18, 2, 18, 4),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: Text('امکانات بیشتر', style: TextStyle(fontSize: 11.5, color: Color(0xFF7A8870), fontWeight: FontWeight.bold)),
              ),
            ),
            Expanded(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 6), child: menuThemed)),
          ] else
            const Spacer(),
          const Divider(height: 1),
          _SidebarFooter(collapsed: collapsed, onSync: onSync),
        ],
      ),
      ),
    );
  }
}

class _SidebarHeader extends StatelessWidget {
  const _SidebarHeader({required this.collapsed});
  final bool collapsed;

  @override
  Widget build(BuildContext context) {
    final Widget logo = ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Image.asset(
        'assets/images/pesteh-bazar-icon.png',
        width: 40,
        height: 40,
        fit: BoxFit.cover,
        errorBuilder: (BuildContext c, Object e, StackTrace? s) => Container(
          width: 40,
          height: 40,
          color: Colors.white24,
          child: const Icon(Icons.spa, color: Colors.white),
        ),
      ),
    );
    return Container(
      height: collapsed ? 72 : 92,
      padding: EdgeInsets.symmetric(horizontal: collapsed ? 0 : 16),
      decoration: const BoxDecoration(
        gradient: LinearGradient(colors: <Color>[_kBrandDark, _kBrand], begin: Alignment.topRight, end: Alignment.bottomLeft),
      ),
      child: collapsed
          ? Center(child: logo)
          : Row(
              children: <Widget>[
                logo,
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: const <Widget>[
                      Text('پسته بازار',
                          style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                      SizedBox(height: 6),
                      Align(alignment: AlignmentDirectional.centerStart, child: _BadgeOnDark()),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}

class _BadgeOnDark extends StatelessWidget {
  const _BadgeOnDark();
  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14)),
        child: const EditionBadge(),
      );
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.hint,
    required this.selected,
    required this.collapsed,
    required this.onTap,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final String hint;
  final bool selected;
  final bool collapsed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final Color fg = selected ? cs.onPrimaryContainer : const Color(0xFF55664A);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Tooltip(
        message: collapsed ? '$label ($hint)' : '',
        child: Material(
          color: selected ? cs.primaryContainer : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            hoverColor: _kBrand.withOpacity(0.08),
            onTap: onTap,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: collapsed ? 0 : 14, vertical: 11),
              child: collapsed
                  ? Center(child: Icon(selected ? selectedIcon : icon, color: fg, size: 24))
                  : Row(
                      children: <Widget>[
                        Icon(selected ? selectedIcon : icon, color: fg, size: 22),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(label,
                              style: TextStyle(
                                  fontSize: 14.5, color: fg, fontWeight: selected ? FontWeight.bold : FontWeight.w500)),
                        ),
                        Text(hint, style: const TextStyle(fontSize: 10.5, color: Color(0xFF9AA690))),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SidebarFooter extends StatelessWidget {
  const _SidebarFooter({required this.collapsed, required this.onSync});
  final bool collapsed;
  final VoidCallback onSync;

  @override
  Widget build(BuildContext context) {
    final List<Widget> btns = <Widget>[
      IconButton(tooltip: 'همگام‌سازی با سرور (F5)', icon: const Icon(Icons.sync), onPressed: onSync),
      IconButton(
          tooltip: 'کوچک‌کردن متن (Ctrl -)',
          icon: const Icon(Icons.zoom_out),
          onPressed: () => DeskPrefs.zoomBy(-0.05)),
      IconButton(
          tooltip: 'بزرگ‌کردن متن (Ctrl +)', icon: const Icon(Icons.zoom_in), onPressed: () => DeskPrefs.zoomBy(0.05)),
      IconButton(
          tooltip: 'تمام‌صفحه (F11)', icon: const Icon(Icons.fullscreen), onPressed: DeskWindow.toggleFullScreen),
      IconButton(
          tooltip: collapsed ? 'باز کردن منو (Ctrl+B)' : 'جمع کردن منو (Ctrl+B)',
          icon: Icon(collapsed ? Icons.menu : Icons.menu_open),
          onPressed: DeskPrefs.toggleCollapsed),
    ];
    final IconThemeData it = IconThemeData(color: const Color(0xFF55664A), size: 20);
    return IconTheme(
      data: it,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: collapsed
            ? Column(mainAxisSize: MainAxisSize.min, children: btns)
            : Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: btns),
      ),
    );
  }
}
