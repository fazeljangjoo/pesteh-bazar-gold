// S7 — نشانگر وضعیت همگام‌سازی («همگام / در حال همگام‌سازی / آفلاین») و نوار «به‌روزرسانی جدید — اعمال».
import 'package:flutter/material.dart';

import 'db.dart';
import 'sync_service.dart';

String syncStatusLabel(SyncStatus s) => switch (s) {
      SyncStatus.synced => 'همگام',
      SyncStatus.syncing => 'در حال همگام‌سازی',
      SyncStatus.offline => 'آفلاین',
    };

Color syncStatusColor(SyncStatus s) => switch (s) {
      SyncStatus.synced => const Color(0xFF2E7D32),
      SyncStatus.syncing => const Color(0xFFEF6C00),
      SyncStatus.offline => const Color(0xFF757575),
    };

/// گلوله + برچسب کوچک؛ هر جا که جا باشد (کارت صفحهٔ اصلی، صفحهٔ همگام‌سازی)
class SyncStatusChip extends StatelessWidget {
  const SyncStatusChip({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<SyncInfo>(
      valueListenable: SyncService.I.info,
      builder: (context, info, _) {
        final s = info.status;
        final c = syncStatusColor(s);
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: c.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 9, height: 9, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
            const SizedBox(width: 6),
            Text(syncStatusLabel(s), style: TextStyle(color: c, fontSize: 12, fontWeight: FontWeight.w600)),
          ]),
        );
      },
    );
  }
}

/// نوار شناور «به‌روزرسانی جدید — اعمال». فقط وقتی تغییرِ دستگاه دیگر آمده و فرمی باز است دیده می‌شود.
/// تا وقتی فرم باز است دکمه غیرفعال است (هیچ‌وقت فرم در حال تایپ پاک نمی‌شود)؛ با بسته‌شدن فرم خودکار اعمال می‌شود.
class RemoteUpdateBanner extends StatelessWidget {
  const RemoteUpdateBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: SyncService.I.remotePending,
      builder: (context, pending, _) {
        if (!pending) return const SizedBox.shrink();
        return ValueListenableBuilder<int>(
          valueListenable: AppDb.I.version,
          builder: (context, _, __) {
            final editing = AppDb.I.isEditing;
            return Material(
              elevation: 4,
              color: Theme.of(context).colorScheme.inverseSurface,
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.system_update_alt, size: 18, color: Theme.of(context).colorScheme.onInverseSurface),
                  const SizedBox(width: 8),
                  Text(
                    editing ? 'به‌روزرسانی جدید — بعد از بستن فرم اعمال می‌شود' : 'به‌روزرسانی جدید',
                    style: TextStyle(color: Theme.of(context).colorScheme.onInverseSurface, fontSize: 13),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: editing ? null : () => SyncService.I.pollNow(),
                    child: const Text('اعمال'),
                  ),
                ]),
              ),
            );
          },
        );
      },
    );
  }
}
