import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:localchat_app/config/theme.dart';
import 'package:localchat_app/gen/strings.g.dart';
import 'package:localchat_app/model/send_mode.dart';
import 'package:localchat_app/pages/conversation_page.dart';
import 'package:localchat_app/pages/device_details_page.dart';
import 'package:localchat_app/pages/selected_files_page.dart';
import 'package:localchat_app/pages/tabs/send_tab_vm.dart';
import 'package:localchat_app/pages/troubleshoot_page.dart';
import 'package:localchat_app/provider/animation_provider.dart';
import 'package:localchat_app/provider/file_transfer_provider.dart';
import 'package:localchat_app/provider/network/nearby_devices_provider.dart';
import 'package:localchat_app/provider/network/scan_facade.dart';
import 'package:localchat_app/provider/network/send_provider.dart';
import 'package:localchat_app/provider/selection/selected_sending_files_provider.dart';
import 'package:localchat_app/provider/settings_provider.dart';
import 'package:localchat_app/util/favorites.dart';
import 'package:localchat_app/util/native/file_picker.dart';
import 'package:localchat_app/util/native/platform_check.dart';
import 'package:localchat_app/widget/big_button.dart';
import 'package:localchat_app/widget/custom_icon_button.dart';
import 'package:localchat_app/widget/dialogs/add_file_dialog.dart';
import 'package:localchat_app/widget/dialogs/send_mode_help_dialog.dart';
import 'package:localchat_app/widget/file_thumbnail.dart';
import 'package:localchat_app/widget/list_tile/device_list_tile.dart';
import 'package:localchat_app/widget/list_tile/device_placeholder_list_tile.dart';
import 'package:localchat_app/widget/opacity_slideshow.dart';
import 'package:localchat_app/widget/responsive_builder.dart';
import 'package:localchat_app/widget/responsive_list_view.dart';
import 'package:localchat_app/widget/responsive_wrap_view.dart';
import 'package:localchat_app/widget/rotating_widget.dart';
import 'package:localchat_isolates/model/device.dart';
import 'package:localchat_isolates/model/session_status.dart';
import 'package:localchat_isolates/util/file_size_helper.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';

const _horizontalPadding = 15.0;

/// [FORK] 设备卡片上的「发起会话」回调。
///
/// 没有指纹就不给按钮：会话以证书指纹为主键，拿不到指纹时上游会退化成
/// `alias:<名字>` 伪键，对方一改名会话就分裂，不如干脆不开放这条路。
VoidCallback? _startConversation(BuildContext context, Device device) {
  if (device.fingerprint.isEmpty) {
    return null;
  }
  return () async => await context.push(
        () => ConversationPage(peerFingerprint: device.fingerprint, device: device),
      );
}

final pickerOptions = FilePickerOption.getOptionsForPlatform();

class SendTab extends StatelessWidget {
  const SendTab();

  @override
  Widget build(BuildContext context) {
    return const _NearbyRefresh(child: _SendTabBody());
  }
}

/// The tab itself: the pickers and the list of nearby devices.
class _SendTabBody extends StatelessWidget {
  const _SendTabBody();

  @override
  Widget build(BuildContext context) {
    return ViewModelBuilder(
      provider: (ref) => sendTabVmProvider,
      init: (context) async => context.global.dispatchAsync(SendTabInitAction(context)), // ignore: discarded_futures
      builder: (context, vm) {
        final sizingInformation = SizingInformation(MediaQuery.sizeOf(context).width);
        final buttonWidth = sizingInformation.isDesktop ? BigButton.desktopWidth : BigButton.mobileWidth;
        final ref = context.ref;
        return ResponsiveListView(
          padding: EdgeInsets.zero,
          children: [
            const SizedBox(height: 20),
            if (vm.selectedFiles.isEmpty) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: _horizontalPadding),
                child: Text(
                  t.sendTab.selection.title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              ResponsiveWrapView(
                outerHorizontalPadding: 15,
                outerVerticalPadding: 10,
                childPadding: 10,
                minChildWidth: buttonWidth,
                children: pickerOptions.map((option) {
                  return BigButton(
                    icon: option.icon,
                    label: option.label,
                    filled: false,
                    onTap: () async => ref.global.dispatchAsync(
                      PickFileAction(
                        option: option,
                        context: context,
                      ),
                    ),
                  );
                }).toList(),
              ),
            ] else ...[
              Card(
                margin: const EdgeInsets.only(bottom: 10, left: _horizontalPadding, right: _horizontalPadding),
                child: Padding(
                  padding: const EdgeInsetsDirectional.only(start: 15, top: 5, bottom: 15),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            t.sendTab.selection.title,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const Spacer(),
                          CustomIconButton(
                            onPressed: () => ref.redux(selectedSendingFilesProvider).dispatch(ClearSelectionAction()),
                            child: Icon(Icons.close, color: Theme.of(context).colorScheme.secondary),
                          ),
                          const SizedBox(width: 5),
                        ],
                      ),
                      const SizedBox(height: 5),
                      Text(t.sendTab.selection.files(files: vm.selectedFiles.length)),
                      Text(t.sendTab.selection.size(size: vm.selectedFiles.fold(0, (prev, curr) => prev + curr.size).asReadableFileSize)),
                      const SizedBox(height: 10),
                      SizedBox(
                        height: defaultThumbnailSize,
                        child: ListView.builder(
                          scrollDirection: Axis.horizontal,
                          itemCount: vm.selectedFiles.length,
                          itemBuilder: (context, index) {
                            final file = vm.selectedFiles[index];
                            return Padding(
                              padding: const EdgeInsets.only(right: 10),
                              child: SmartFileThumbnail.fromCrossFile(file),
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            style: TextButton.styleFrom(
                              foregroundColor: Theme.of(context).colorScheme.onSurface,
                            ),
                            onPressed: () async {
                              await context.push(() => const SelectedFilesPage());
                            },
                            child: Text(t.general.edit),
                          ),
                          const SizedBox(width: 15),
                          ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Theme.of(context).colorScheme.primary,
                              foregroundColor: Theme.of(context).colorScheme.onPrimary,
                            ),
                            onPressed: () async {
                              if (pickerOptions.length == 1) {
                                // open directly
                                await ref.global.dispatchAsync(
                                  PickFileAction(
                                    option: pickerOptions.first,
                                    context: context,
                                  ),
                                );
                                return;
                              }
                              await AddFileDialog.open(
                                context: context,
                                options: pickerOptions,
                              );
                            },
                            icon: const Icon(Icons.add),
                            label: Text(t.general.add),
                          ),
                          const SizedBox(width: 15),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
            Row(
              children: [
                const SizedBox(width: _horizontalPadding),
                Flexible(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Text(t.sendTab.nearbyDevices, style: Theme.of(context).textTheme.titleMedium),
                  ),
                ),
                const SizedBox(width: 10),
                _ScanButton(
                  ips: vm.localIps,
                ),
                Tooltip(
                  message: t.sendTab.manualSending,
                  child: CustomIconButton(
                    onPressed: () async => vm.onTapAddress(context),
                    child: const Icon(Icons.ads_click),
                  ),
                ),
                Tooltip(
                  message: t.dialogs.favoriteDialog.title,
                  child: CustomIconButton(
                    onPressed: () async => await vm.onTapFavorite(context),
                    child: const Icon(Icons.favorite),
                  ),
                ),
                _SendModeButton(
                  onSelect: (mode) async => vm.onTapSendMode(context, mode),
                ),
              ],
            ),
            if (vm.nearbyDevices.isEmpty)
              const Padding(
                padding: EdgeInsets.only(bottom: 10, left: _horizontalPadding, right: _horizontalPadding),
                child: Opacity(
                  opacity: 0.3,
                  child: DevicePlaceholderListTile(),
                ),
              ),
            ...vm.nearbyDevices.map((device) {
              final favoriteEntry = vm.favoriteDevices.findDevice(device);
              return Padding(
                padding: const EdgeInsets.only(bottom: 10, left: _horizontalPadding, right: _horizontalPadding),
                child: Hero(
                  tag: 'device-${device.ip}',
                  child: vm.sendMode == SendMode.multiple
                      ? _MultiSendDeviceListTile(
                          device: device,
                          isFavorite: favoriteEntry != null,
                          nameOverride: favoriteEntry?.alias,
                          vm: vm,
                        )
                      : DeviceListTile(
                          device: device,
                          isFavorite: favoriteEntry != null,
                          nameOverride: favoriteEntry?.alias,
                          onDetailsTap: () async => await context.push(() => DeviceDetailsPage(device: device)),
                          onChatTap: _startConversation(context, device),
                          onTap: () async => await vm.onTapDevice(context, device),
                        ),
                ),
              );
            }),
            const SizedBox(height: 10),
            Center(
              child: TextButton(
                onPressed: () async {
                  await context.push(() => const TroubleshootPage());
                },
                child: Text(t.troubleshootPage.title),
              ),
            ),
            const SizedBox(height: 20),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: _horizontalPadding),
              child: Consumer(
                builder: (context, ref) {
                  final animations = ref.watch(animationProvider);
                  return OpacitySlideshow(
                    durationMillis: 6000,
                    running: animations,
                    children: [
                      Text(
                        t.sendTab.help,
                        style: const TextStyle(color: Colors.grey),
                        textAlign: TextAlign.center,
                      ),
                      if (checkPlatformCanReceiveShareIntent())
                        Text(
                          t.sendTab.shareIntentInfo,
                          style: const TextStyle(color: Colors.grey),
                          textAlign: TextAlign.center,
                        ),
                    ],
                  );
                },
              ),
            ),
            const SizedBox(height: 50),
          ],
        );
      },
    );
  }
}

/// [FORK] Keeps the nearby list fresh while the send tab is on screen.
///
/// Multicast is only ever a burst: this device announces three times when it
/// starts, every other device announces when *it* starts. A peer that started
/// while nobody was listening (app in background, another tab open, the Wi-Fi
/// asleep) therefore stayed invisible until the user pressed refresh — the
/// "the nearby list is often empty" report. Repeating the announcement while
/// the list is being looked at fixes it in both directions: the peers answer
/// our announcement and enter our store, and that answer makes us enter theirs.
///
/// Only the announcement is repeated, never the subnet scan: that is three UDP
/// datagrams, while a scan probes 256 hosts per interface.
class _NearbyRefresh extends StatefulWidget {
  final Widget child;

  const _NearbyRefresh({required this.child});

  @override
  State<_NearbyRefresh> createState() => _NearbyRefreshState();
}

class _NearbyRefreshState extends State<_NearbyRefresh> {
  static const _interval = Duration(seconds: 8);

  Timer? _timer;

  // Not in initState: reading a provider touches the Refena inherited widget,
  // which is only allowed once the dependencies are set up.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_timer != null) {
      return;
    }

    _timer = Timer.periodic(_interval, (_) => _announce());

    // Announce right away as well: opening the tab is the moment the user
    // expects the list to be correct. After the frame, because the first
    // announcement changes providers, which must not happen during build.
    WidgetsBinding.instance.addPostFrameCallback((_) => _announce());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _announce() {
    if (!mounted) {
      return;
    }

    // Nothing to gain in the background: peers cannot reach the server either,
    // and the announcement would just wake the radio. The app announces once
    // when it is resumed again.
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null && lifecycle != AppLifecycleState.resumed) {
      return;
    }

    // A running scan announces by itself; skipping avoids a second burst on
    // top of the one that scan just sent.
    final state = context.ref.read(nearbyDevicesProvider);
    if (state.runningFavoriteScan || state.runningIps.isNotEmpty) {
      return;
    }

    context.redux(nearbyDevicesProvider).dispatch(StartMulticastScan());
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}

/// A button that opens a popup menu to select [T].
/// This is used for the scan button and the send mode button.
class _CircularPopupButton<T> extends StatelessWidget {
  final String tooltip;
  final PopupMenuItemBuilder<T> itemBuilder;
  final PopupMenuItemSelected<T>? onSelected;
  final Widget child;

  const _CircularPopupButton({
    required this.tooltip,
    required this.onSelected,
    required this.itemBuilder,
    required this.child,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(9999),
      child: Material(
        type: MaterialType.transparency,
        child: DividerTheme(
          data: DividerThemeData(
            color: Theme.of(context).brightness == Brightness.light ? Colors.teal.shade100 : Colors.grey.shade700,
          ),
          child: PopupMenuButton(
            offset: const Offset(0, 40),
            onSelected: onSelected,
            tooltip: tooltip,
            itemBuilder: itemBuilder,
            child: child,
          ),
        ),
      ),
    );
  }
}

/// The scan button that uses [_CircularPopupButton].
class _ScanButton extends StatelessWidget {
  final List<String> ips;

  const _ScanButton({
    required this.ips,
  });

  @override
  Widget build(BuildContext context) {
    final (scanningFavorites, scanningIps) = context.ref.watch(nearbyDevicesProvider.select((s) => (s.runningFavoriteScan, s.runningIps)));
    final animations = context.ref.watch(animationProvider);

    final spinning = (scanningFavorites || scanningIps.isNotEmpty) && animations;
    final iconColor = !animations && scanningIps.isNotEmpty ? Theme.of(context).colorScheme.warning : null;

    if (ips.length <= StartSmartScan.maxInterfaces) {
      return Tooltip(
        message: t.sendTab.scan,
        child: RotatingWidget(
          duration: const Duration(seconds: 2),
          spinning: spinning,
          reverse: true,
          child: CustomIconButton(
            onPressed: () async {
              context.redux(nearbyDevicesProvider).dispatch(ClearFoundDevicesAction());
              await context.global.dispatchAsync(StartSmartScan());
            },
            child: Icon(Icons.sync, color: iconColor),
          ),
        ),
      );
    }

    return _CircularPopupButton(
      tooltip: t.sendTab.scan,
      onSelected: (ip) async {
        context.redux(nearbyDevicesProvider).dispatch(ClearFoundDevicesAction());
        await context.global.dispatchAsync(StartLegacySubnetScan(subnets: [ip]));
      },
      itemBuilder: (_) {
        return [
          ...ips.map(
            (ip) => PopupMenuItem(
              value: ip,
              padding: const EdgeInsets.only(left: 12, right: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _RotatingSyncIcon(ip),
                  const SizedBox(width: 10),
                  Text(ip),
                ],
              ),
            ),
          ),
        ];
      },
      child: RotatingWidget(
        duration: const Duration(seconds: 2),
        spinning: spinning,
        reverse: true,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(Icons.sync, color: iconColor),
        ),
      ),
    );
  }
}

/// A separate widget, so it gets the latest data from provider.
class _RotatingSyncIcon extends StatelessWidget {
  final String ip;

  const _RotatingSyncIcon(this.ip);

  @override
  Widget build(BuildContext context) {
    final scanningIps = context.ref.watch(nearbyDevicesProvider.select((s) => s.runningIps));
    return RotatingWidget(
      duration: const Duration(seconds: 2),
      spinning: scanningIps.contains(ip),
      reverse: true,
      child: const Icon(Icons.sync),
    );
  }
}

class _SendModeButton extends StatelessWidget {
  final void Function(SendMode mode) onSelect;

  const _SendModeButton({required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return _CircularPopupButton<int>(
      tooltip: t.sendTab.sendMode,
      onSelected: (mode) async {
        switch (mode) {
          case 0:
            onSelect(SendMode.single);
            break;
          case 1:
            onSelect(SendMode.multiple);
            break;
          case 2:
            onSelect(SendMode.link);
            break;
          case -1:
            await showDialog(context: context, builder: (_) => const SendModeHelpDialog());
            break;
        }
      },
      itemBuilder: (_) => [
        PopupMenuItem(
          value: 0,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Consumer(
                builder: (context, ref) {
                  final sendMode = ref.watch(settingsProvider.select((s) => s.sendMode));
                  return Visibility(
                    visible: sendMode == SendMode.single,
                    maintainSize: true,
                    maintainAnimation: true,
                    maintainState: true,
                    child: const Icon(Icons.check_circle),
                  );
                },
              ),
              const SizedBox(width: 10),
              Text(t.sendTab.sendModes.single),
            ],
          ),
        ),
        PopupMenuItem(
          value: 1,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Consumer(
                builder: (context, ref) {
                  final sendMode = ref.watch(settingsProvider.select((s) => s.sendMode));
                  return Visibility(
                    visible: sendMode == SendMode.multiple,
                    maintainSize: true,
                    maintainAnimation: true,
                    maintainState: true,
                    child: const Icon(Icons.check_circle),
                  );
                },
              ),
              const SizedBox(width: 10),
              Text(t.sendTab.sendModes.multiple),
            ],
          ),
        ),
        PopupMenuItem(
          value: 2,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Visibility(
                visible: false,
                maintainSize: true,
                maintainAnimation: true,
                maintainState: true,
                child: Icon(Icons.check_circle),
              ),
              const SizedBox(width: 10),
              Text(t.sendTab.sendModes.link),
            ],
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: -1,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Directionality(
                textDirection: TextDirection.ltr,
                child: Icon(Icons.help),
              ),
              const SizedBox(width: 10),
              Text(t.sendTab.sendModeHelp),
            ],
          ),
        ),
      ],
      child: const Padding(
        padding: EdgeInsets.all(8),
        child: Icon(Icons.settings),
      ),
    );
  }
}

/// An advanced list tile which shows the progress of the file transfer.
class _MultiSendDeviceListTile extends StatelessWidget {
  final Device device;
  final bool isFavorite;
  final String? nameOverride;
  final SendTabVm vm;

  const _MultiSendDeviceListTile({
    required this.device,
    required this.isFavorite,
    required this.nameOverride,
    required this.vm,
  });

  @override
  Widget build(BuildContext context) {
    final ref = context.ref;
    final session = ref.watch(sendProvider).values.firstWhereOrNull((s) => s.target.ip == device.ip);
    final String? info;
    final double? progress;
    if (session != null) {
      final files = session.files.values.where((f) => f.token != null);
      final transferNotifier = ref.watch(fileTransferProvider);
      final currBytes = files.fold<int>(
        0,
        (prev, curr) => prev + ((transferNotifier.getProgress(sessionId: session.sessionId, fileId: curr.file.id) * curr.file.size).round()),
      );
      final totalBytes = files.fold<int>(0, (prev, curr) => prev + curr.file.size);
      progress = totalBytes == 0 ? 0 : currBytes / totalBytes;
      info = session.hashedFileCount < session.files.length
          ? t.sendPage.calculatingChecksum(curr: session.hashedFileCount, n: session.files.length)
          : session.status.humanString;
    } else {
      progress = null;
      info = null;
    }
    return DeviceListTile(
      device: device,
      info: info,
      progress: progress,
      isFavorite: isFavorite,
      nameOverride: nameOverride,
      onDetailsTap: () async => await context.push(() => DeviceDetailsPage(device: device)),
      onChatTap: _startConversation(context, device),
      onTap: () async => await vm.onTapDeviceMultiSend(context, device),
    );
  }
}

extension on SessionStatus {
  String? get humanString {
    switch (this) {
      case SessionStatus.waiting:
        return t.sendPage.waiting;
      case SessionStatus.recipientBusy:
        return t.sendPage.busy;
      case SessionStatus.declined:
        return t.sendPage.rejected;
      case SessionStatus.tooManyAttempts:
        return t.sendPage.tooManyAttempts;
      case SessionStatus.sending:
        return null;
      case SessionStatus.finished:
        return t.general.finished;
      case SessionStatus.finishedWithErrors:
        return t.progressPage.total.title.finishedError;
      case SessionStatus.canceledBySender:
        return t.progressPage.total.title.canceledSender;
      case SessionStatus.canceledByReceiver:
        return t.progressPage.total.title.canceledReceiver;
    }
  }
}
