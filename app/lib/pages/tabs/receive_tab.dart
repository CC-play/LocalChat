import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:localchat_app/gen/strings.g.dart';
import 'package:localchat_app/model/state/server/server_state.dart';
import 'package:localchat_app/pages/home_page.dart';
import 'package:localchat_app/pages/home_page_controller.dart';
import 'package:localchat_app/pages/receive_history_page.dart';
import 'package:localchat_app/pages/web_share_page.dart';
import 'package:localchat_app/provider/animation_provider.dart';
import 'package:localchat_app/provider/local_ip_provider.dart';
import 'package:localchat_app/provider/network/server/server_provider.dart';
import 'package:localchat_app/provider/settings_provider.dart';
import 'package:localchat_app/util/ui/snackbar.dart';
import 'package:localchat_app/widget/animations/initial_fade_transition.dart';
import 'package:localchat_app/widget/column_list_view.dart';
import 'package:localchat_app/widget/custom_icon_button.dart';
import 'package:localchat_app/widget/dialogs/device_name_dialog.dart';
import 'package:localchat_app/widget/local_chat_logo.dart';
import 'package:localchat_app/widget/responsive_list_view.dart';
import 'package:localchat_isolates/isolate.dart';
import 'package:localchat_isolates/util/sleep.dart';
import 'package:refena_flutter/addons.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';

class ReceiveTab extends StatefulWidget {
  const ReceiveTab();

  @override
  State<ReceiveTab> createState() => _ReceiveTabState();
}

/// 接收页 logo 边长的下限 / 上限（逻辑像素）。
const double _logoMinSize = 120;
const double _logoMaxSize = 240;

/// logo 之外，接收页上下所有固定内容占掉的高度：
/// 页面内边距 60 + 底部链接按钮区 65 + 别名行 58 + 离线提示 29 ≈ 212，留 3px 余量。
const double _logoReservedHeight = 215;

/// logo 与设备名之间的留白，按 logo 边长取比例，再夹在这个区间里。
///
/// 这两行原本是直接相邻的（间距 0），视觉上只剩图形自身的空白（约 2px）
/// 和 48px 文字行高上方的空白（约 10px），看着贴太近。
const double _logoNameGapRatio = 0.09;
const double _logoNameGapMin = 12;
const double _logoNameGapMax = 22;

/// logo 边长 -> 它与设备名之间的留白。
double _logoNameGap(double logoSize) => (logoSize * _logoNameGapRatio).clamp(_logoNameGapMin, _logoNameGapMax).toDouble();

/// 按窗口尺寸算 logo 边长。
///
/// 窄窗口由宽度决定（内容区宽度的一半多一点），矮窗口由剩余高度决定，
/// 取两者较小值并夹在 [_logoMinSize]–[_logoMaxSize] 之间，
/// 这样大窗口下不会再显得空旷、小窗口下也不会把别名挤到按钮上。
double _logoSizeFor(BuildContext context) {
  final window = MediaQuery.sizeOf(context);
  // 内容区被 ConstrainedBox 限制在 defaultMaxWidth，左右各 30 内边距。
  final byWidth = (math.min(window.width, ResponsiveListView.defaultMaxWidth) - 60) * 0.55;
  // 高度方向除固定内容外还要让出 logo 下方的留白；留白与 logo 边长成正比，
  // 所以解 size + size * ratio = 可用高度，得 size = 可用 / (1 + ratio)。
  // 留白落进钳制区间（size < 133）时实际值比比例值大约 1px，由 3px 余量吸收。
  final byHeight = (window.height - _logoReservedHeight) / (1 + _logoNameGapRatio);
  return math.max(_logoMinSize, math.min(math.min(byWidth, byHeight), _logoMaxSize));
}

class _ReceiveTabState extends State<ReceiveTab> {
  /// Whether the advanced network info is shown
  bool _showAdvanced = false;

  /// Whether the history button is shown
  /// This extra boolean is needed to delay the animation
  bool _showHistoryButton = true;

  Future<void> _toggleAdvanced() async {
    if (_showAdvanced) {
      setState(() => _showAdvanced = false);
      await sleepAsync(200);
      if (mounted) {
        setState(() => _showHistoryButton = true);
      }
    } else {
      setState(() {
        _showAdvanced = true;
        _showHistoryButton = false;
      });
    }
  }

  /// [FORK] 改设备名称。改的是设置里那个值，改完立刻重启接收服务 ——
  /// 页面上显示的是**服务启动时**的别名（`serverState.alias`），不重启的话
  /// 名字改了页面却纹丝不动；多播通告里的名字也要等发现重启才会重新读取。
  Future<void> _editAlias(
    BuildContext context, {
    required ServerState? serverState,
    required String fallbackAlias,
  }) async {
    final currentName = serverState?.alias ?? fallbackAlias;
    final newName = await showDialog<String>(
      context: context,
      builder: (_) => DeviceNameDialog(
        initialName: currentName,
        transferActive: serverState?.session != null,
      ),
    );
    if (newName == null || newName == currentName || !context.mounted) {
      return;
    }

    await context.ref.notifier(settingsProvider).setAlias(newName);
    if (serverState == null || !context.mounted) {
      // 服务没在跑，名字会在下次启动时生效。
      return;
    }

    try {
      await context.ref.notifier(serverProvider).restartServerFromSettings();
    } catch (e) {
      if (context.mounted) {
        context.showSnackBar(e.toString());
      }
      return;
    }

    if (!context.mounted) {
      return;
    }
    // 广播里的别名取自同步状态，只有重开发现才会重新读一遍。
    if (context.ref.read(parentIsolateProvider).discovery != null) {
      context.ref.redux(parentIsolateProvider).dispatch(IsolateDiscoveryRestartAction());
    }
  }

  @override
  Widget build(BuildContext context) {
    final alias = context.watch(settingsProvider.select((s) => s.alias));
    final serverState = context.watch(serverProvider);
    final localIps = context.watch(localIpProvider.select((s) => s.localIps));
    // 只算一次：logo 边长和它下面的留白都基于这个值，保证两者比例一致。
    final logoSize = _logoSizeFor(context);

    return Stack(
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: ResponsiveListView.defaultMaxWidth),
            child: Padding(
              padding: const EdgeInsets.all(30),
              child: ColumnListView(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        InitialFadeTransition(
                          duration: const Duration(milliseconds: 300),
                          delay: const Duration(milliseconds: 200),
                          child: Consumer(
                            builder: (context, ref) {
                              final animations = ref.watch(animationProvider);
                              final activeTab = ref.watch(homePageControllerProvider.select((state) => state.currentTab));
                              // Only the arrow ring spins, the bubble stays still.
                              return LocalChatLogo(
                                withText: false,
                                size: logoSize,
                                spinDuration: const Duration(seconds: 15),
                                spinning: serverState != null && animations && activeTab == HomeTab.receive,
                              );
                            },
                          ),
                        ),
                        SizedBox(height: _logoNameGap(logoSize)),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(serverState?.alias ?? alias, style: const TextStyle(fontSize: 48)),
                              ),
                            ),
                            const SizedBox(width: 4),
                            // [FORK] 名字就在眼前，改它不必翻到设置页。
                            Tooltip(
                              message: t.receiveTab.editAlias,
                              child: CustomIconButton(
                                key: const ValueKey('edit-alias-btn'),
                                onPressed: () => _editAlias(context, serverState: serverState, fallbackAlias: alias),
                                child: Icon(
                                  Icons.edit,
                                  size: 22,
                                  color: Theme.of(context).colorScheme.outline,
                                ),
                              ),
                            ),
                          ],
                        ),
                        Visibility(
                          visible: serverState == null,
                          maintainSize: true,
                          maintainAnimation: true,
                          maintainState: true,
                          child: InitialFadeTransition(
                            duration: const Duration(milliseconds: 300),
                            delay: const Duration(milliseconds: 500),
                            child: Text(
                              t.general.offline,
                              style: const TextStyle(fontSize: 24),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Center(
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          await context.global.dispatchAsync(NavigateAction.push(const WebSharePage()));
                        },
                        icon: Icon(Icons.language),
                        label: Text(t.receiveTab.link),
                      ),
                    ),
                  ),
                  const SizedBox(height: 15),
                ],
              ),
            ),
          ),
        ),
        _InfoBox(
          serverState: serverState,
          localIps: localIps,
          showAdvanced: _showAdvanced,
        ),
        _CornerButtons(
          showAdvanced: _showAdvanced,
          showHistoryButton: _showHistoryButton,
          toggleAdvanced: _toggleAdvanced,
        ),
      ],
    );
  }
}

class _CornerButtons extends StatelessWidget {
  final bool showAdvanced;
  final bool showHistoryButton;
  final Future<void> Function() toggleAdvanced;

  const _CornerButtons({
    required this.showAdvanced,
    required this.showHistoryButton,
    required this.toggleAdvanced,
  });

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topRight,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            if (!showAdvanced)
              AnimatedOpacity(
                opacity: showHistoryButton ? 1 : 0,
                duration: const Duration(milliseconds: 200),
                child: CustomIconButton(
                  onPressed: () async {
                    await context.push(() => const ReceiveHistoryPage());
                  },
                  child: const Icon(Icons.history),
                ),
              ),
            CustomIconButton(
              key: const ValueKey('info-btn'),
              onPressed: toggleAdvanced,
              child: const Icon(Icons.info),
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoBox extends StatelessWidget {
  final ServerState? serverState;
  final List<String> localIps;
  final bool showAdvanced;

  const _InfoBox({
    required this.serverState,
    required this.localIps,
    required this.showAdvanced,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedCrossFade(
      crossFadeState: showAdvanced ? CrossFadeState.showSecond : CrossFadeState.showFirst,
      duration: const Duration(milliseconds: 200),
      firstChild: Container(),
      secondChild: Align(
        alignment: Alignment.topRight,
        child: Padding(
          padding: const EdgeInsets.all(15),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(15),
              child: Table(
                columnWidths: const {
                  0: IntrinsicColumnWidth(),
                  1: IntrinsicColumnWidth(),
                  2: IntrinsicColumnWidth(),
                },
                children: [
                  TableRow(
                    children: [
                      Text(t.receiveTab.infoBox.alias),
                      const SizedBox(width: 10),
                      Padding(
                        padding: const EdgeInsets.only(right: 30),
                        child: SelectableText(serverState?.alias ?? '-'),
                      ),
                    ],
                  ),
                  TableRow(
                    children: [
                      Text(t.receiveTab.infoBox.ip),
                      const SizedBox(width: 10),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (localIps.isEmpty) Text(t.general.unknown),
                          ...localIps.map((ip) => SelectableText(ip)),
                        ],
                      ),
                    ],
                  ),
                  TableRow(
                    children: [
                      Text(t.receiveTab.infoBox.port),
                      const SizedBox(width: 10),
                      SelectableText(serverState?.port.toString() ?? '-'),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
