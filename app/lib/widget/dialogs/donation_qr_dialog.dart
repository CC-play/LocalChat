import 'package:flutter/material.dart';
import 'package:localchat_app/gen/assets.gen.dart';
import 'package:localchat_app/gen/strings.g.dart';
import 'package:localchat_app/util/native/platform_check.dart';
import 'package:localchat_app/widget/dialogs/custom_bottom_sheet.dart';
import 'package:routerino/routerino.dart';

/// Shows the maintainer's reward QR code (WeChat 赞赏码).
///
/// No payment is started from inside the app — the user scans the code with
/// their own wallet. Keeping it that way avoids any store-billing ties.
class DonationQrDialog extends StatelessWidget {
  const DonationQrDialog({super.key});

  /// A QR code still decodes reliably at this size; bigger only costs memory.
  static const double qrSize = 240;

  static Future<void> open(BuildContext context) async {
    if (checkPlatformIsDesktop()) {
      await showDialog(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(t.dialogs.donateQr.title),
          content: SizedBox(
            width: qrSize,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _qrCode(),
                const SizedBox(height: 12),
                Text(t.dialogs.donateQr.content, textAlign: TextAlign.center),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(t.general.close),
            ),
          ],
        ),
      );
    } else {
      await context.pushBottomSheet(() => const DonationQrDialog());
    }
  }

  static Widget _qrCode() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Assets.img.donateQrcode.image(width: qrSize, height: qrSize, fit: BoxFit.contain),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CustomBottomSheet(
      title: t.dialogs.donateQr.title,
      description: t.dialogs.donateQr.content,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _qrCode(),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () => context.popUntilRoot(),
              child: Text(t.general.close),
            ),
          ],
        ),
      ),
    );
  }
}
