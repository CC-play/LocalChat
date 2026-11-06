import 'package:flutter/material.dart';
import 'package:localchat_app/gen/strings.g.dart';
import 'package:localchat_app/util/device_type_ext.dart';
import 'package:localchat_app/widget/custom_progress_bar.dart';
import 'package:localchat_app/widget/device_bage.dart';
import 'package:localchat_app/widget/list_tile/custom_list_tile.dart';
import 'package:localchat_isolates/model/device.dart';

class DeviceListTile extends StatelessWidget {
  final Device device;
  final bool isFavorite;

  /// If not null, this name is used instead of [Device.alias].
  /// This is the case when the device is marked as favorite.
  final String? nameOverride;

  final String? info;
  final double? progress;
  final VoidCallback? onTap;
  final VoidCallback? onDetailsTap;

  /// [FORK] 发起会话：从发送页直接进入与这台设备的聊天。
  ///
  /// 与 [onDetailsTap] 并排显示，这里只负责「有没有」——具体能不能开，
  /// 由调用方按有没有指纹判断（没有指纹就没有稳定的会话主键）。
  final VoidCallback? onChatTap;

  const DeviceListTile({
    required this.device,
    this.isFavorite = false,
    this.nameOverride,
    this.info,
    this.progress,
    this.onTap,
    this.onDetailsTap,
    this.onChatTap,
  });

  @override
  Widget build(BuildContext context) {
    final badgeColor = Color.lerp(Theme.of(context).colorScheme.secondaryContainer, Colors.white, 0.3)!;
    return CustomListTile(
      icon: Icon(device.deviceType.icon, size: 46),
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(nameOverride ?? device.alias, style: const TextStyle(fontSize: 20)),
          if (isFavorite) ...[
            const SizedBox(width: 5),
            Icon(Icons.check_circle, size: 16),
          ],
        ],
      ),
      // [FORK] 「发起会话」在左、「设备详情」在右：两颗按钮同一行，
      // 顺序与用户的直觉一致（先聊，再看信息）。
      trailing: onChatTap == null && onDetailsTap == null
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (onChatTap != null)
                  IconButton(
                    icon: const Icon(Icons.chat_bubble_outline),
                    tooltip: t.conversation.startConversation,
                    onPressed: onChatTap,
                  ),
                if (onDetailsTap != null)
                  IconButton(
                    icon: const Icon(Icons.info_outline),
                    onPressed: onDetailsTap,
                  ),
              ],
            ),
      subTitle: Wrap(
        runSpacing: 10,
        spacing: 10,
        children: [
          if (info != null)
            Text(info!, style: const TextStyle(color: Colors.grey))
          else if (progress != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: CustomProgressBar(progress: progress!),
            )
          else ...[
            if (device.ip != null)
              DeviceBadge(
                backgroundColor: badgeColor,
                foregroundColor: Theme.of(context).colorScheme.onSecondaryContainer,
                label: 'HTTP',
              )
            else
              DeviceBadge(
                backgroundColor: badgeColor,
                foregroundColor: Theme.of(context).colorScheme.onSecondaryContainer,
                label: 'WebRTC',
              ),
            if (device.deviceModel != null)
              DeviceBadge(
                backgroundColor: badgeColor,
                foregroundColor: Theme.of(context).colorScheme.onSecondaryContainer,
                label: device.deviceModel!,
              ),
          ],
        ],
      ),
      onTap: onTap,
    );
  }
}
