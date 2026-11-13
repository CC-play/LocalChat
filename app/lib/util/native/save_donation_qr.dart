import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:gal/gal.dart';
import 'package:localchat_app/util/native/directories.dart';
import 'package:localchat_app/util/native/platform_check.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

final _logger = Logger('DonationQrSave');

const _assetPath = 'assets/img/donate_qrcode.png';

/// Where the reward QR code ends up, which decides what the confirmation says.
enum DonationQrDestination {
  /// Mobile: handed to the OS gallery, the app keeps no copy.
  gallery,

  /// Desktop: written into the Downloads folder as a regular file.
  downloads,
}

/// Thrown when the user refuses the gallery permission on mobile.
class DonationQrSavePermissionDenied implements Exception {
  const DonationQrSavePermissionDenied();
}

/// Saves the in-app reward QR code to the place the platform expects images.
///
/// Mobile goes through the system gallery (`Gal`), desktop writes the asset into
/// the default download directory. The gallery branch returns `null` because the
/// OS owns the file from then on and has no user-facing path to show; the
/// desktop branch returns the absolute path it wrote.
///
/// Throws [DonationQrSavePermissionDenied] when the gallery permission is
/// refused, [GalException] when the gallery fails the save, and
/// [FileSystemException] when the desktop write fails.
Future<(DonationQrDestination, String?)> saveDonationQrCode() async {
  final data = await rootBundle.load(_assetPath);
  final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  final name = _fileName(now: DateTime.now());

  if (!checkPlatformIsDesktop()) {
    // The user explicitly asked to save, so an explicit permission prompt is
    // expected here rather than a silent failure.
    if (!await Gal.hasAccess() && !await Gal.requestAccess()) {
      throw const DonationQrSavePermissionDenied();
    }

    await Gal.putImageBytes(bytes, name: name);
    _logger.info('Saved QR code to gallery as $name');
    return (DonationQrDestination.gallery, null);
  }

  final directory = await getDefaultDestinationDirectory();
  // The directory helper hands back forward slashes; normalize so the path we
  // show the user is the same one Explorer shows.
  var filePath = p.normalize(p.join(directory, '$name.png'));

  // Same-second saves (a double click before the dialog closes) must not
  // silently overwrite the previous copy.
  for (var index = 1; await File(filePath).exists(); index++) {
    filePath = p.normalize(p.join(directory, '${name}_$index.png'));
  }

  await File(filePath).writeAsBytes(bytes, flush: true);
  _logger.info('Saved QR code to $filePath');
  return (DonationQrDestination.downloads, filePath);
}

/// `localchat_donate_qr_20261113_105907` — sortable and collision free at the
/// one-second resolution a human can click at.
String _fileName({required DateTime now}) {
  String two(int value) => value.toString().padLeft(2, '0');

  final date = '${now.year}${two(now.month)}${two(now.day)}';
  final time = '${two(now.hour)}${two(now.minute)}${two(now.second)}';
  return 'localchat_donate_qr_${date}_$time';
}
