import 'package:flutter/material.dart';
import 'package:localchat_app/gen/assets.gen.dart';
import 'package:localchat_app/gen/strings.g.dart';
import 'package:localchat_app/util/native/platform_check.dart';
import 'package:localchat_app/util/native/save_donation_qr.dart';
import 'package:localchat_app/widget/dialogs/custom_bottom_sheet.dart';
import 'package:logging/logging.dart';
import 'package:routerino/routerino.dart';

final _logger = Logger('DonationQrDialog');

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
          // The close button takes the corner slot, so the title does not need
          // the full dialog width anymore.
          titlePadding: const EdgeInsets.fromLTRB(24, 12, 12, 0),
          title: Row(
            children: [
              Expanded(child: Text(t.dialogs.donateQr.title)),
              _CloseButton(onPressed: () => Navigator.of(dialogContext).pop()),
            ],
          ),
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
            FilledButton.icon(
              onPressed: () => _save(dialogContext),
              icon: const Icon(Icons.download),
              label: Text(t.dialogs.donateQr.saveToDownloads),
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

  /// Closes the dialog first and reports the outcome on the page behind it:
  /// a snackbar raised while the sheet is still up would be covered by it.
  static Future<void> _save(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();

    try {
      final (destination, path) = await saveDonationQrCode();
      final message = switch (destination) {
        DonationQrDestination.gallery => t.dialogs.donateQr.savedToGallery,
        DonationQrDestination.downloads => t.dialogs.donateQr.savedToDownloads(path: path ?? ''),
      };

      messenger.showSnackBar(
        SnackBar(content: Text(message, maxLines: 2, overflow: TextOverflow.ellipsis)),
      );
    } on DonationQrSavePermissionDenied {
      messenger.showSnackBar(SnackBar(content: Text(t.dialogs.donateQr.galleryPermissionDenied)));
    } catch (e, s) {
      _logger.warning('Could not save the reward QR code', e, s);
      messenger.showSnackBar(SnackBar(content: Text(t.dialogs.donateQr.saveFailed)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return CustomBottomSheet(
      title: t.dialogs.donateQr.title,
      description: t.dialogs.donateQr.content,
      onClose: () => context.popUntilRoot(),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _qrCode(),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => _save(context),
              icon: const Icon(Icons.download),
              label: Text(t.dialogs.donateQr.saveToGallery),
            ),
          ],
        ),
      ),
    );
  }
}

/// Square icon button that mirrors [AlertDialog]'s title line height, so the
/// corner slot does not push the title down.
class _CloseButton extends StatelessWidget {
  final VoidCallback onPressed;

  const _CloseButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onPressed,
      tooltip: t.general.close,
      iconSize: 20,
      visualDensity: VisualDensity.compact,
      icon: const Icon(Icons.close),
    );
  }
}
