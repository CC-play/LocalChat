import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:localsend_app/config/init.dart';
import 'package:localsend_app/config/theme.dart';
import 'package:localsend_app/gen/assets.gen.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/pages/conversations_page.dart';
import 'package:localsend_app/pages/home_page_controller.dart';
import 'package:localsend_app/pages/tabs/receive_tab.dart';
import 'package:localsend_app/pages/tabs/send_tab.dart';
import 'package:localsend_app/pages/tabs/settings_tab.dart';
import 'package:localsend_app/provider/selection/selected_sending_files_provider.dart';
import 'package:localsend_app/util/native/cross_file_converters.dart';
import 'package:localsend_app/widget/responsive_builder.dart';
import 'package:refena_flutter/refena_flutter.dart';

enum HomeTab {
  // [FORK] 新增会话 Tab，并放到首位（默认选中的 Tab 见 main.dart）
  conversations(Icons.chat_bubble_outline),
  receive(Icons.wifi),
  send(Icons.send),
  settings(Icons.settings)
  ;

  const HomeTab(this.icon);

  final IconData icon;

  String get label {
    switch (this) {
      case HomeTab.receive:
        return t.receiveTab.title;
      case HomeTab.send:
        return t.sendTab.title;
      case HomeTab.conversations:
        return t.conversation.title;
      case HomeTab.settings:
        return t.settingsTab.title;
    }
  }
}

/// [FORK] 侧边栏顶部三个 Tab。设置项单独钉在侧边栏底部，不参与这组索引。
const List<HomeTab> _railTabs = [HomeTab.conversations, HomeTab.receive, HomeTab.send];

class HomePage extends StatefulWidget {
  final HomeTab initialTab;

  /// It is important for the initializing step
  /// because the first init clears the cache
  final bool appStart;

  const HomePage({
    required this.initialTab,
    required this.appStart,
    super.key,
  });

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with Refena {
  bool _dragAndDropIndicator = false;

  @override
  void initState() {
    super.initState();

    ensureRef((ref) async {
      ref.redux(homePageControllerProvider).dispatch(ChangeTabAction(widget.initialTab));
      await postInit(context, ref, widget.appStart);
    });
  }

  @override
  Widget build(BuildContext context) {
    Translations.of(context); // rebuild on locale change
    final vm = context.watch(homePageControllerProvider);

    return DropTarget(
      onDragEntered: (_) {
        setState(() {
          _dragAndDropIndicator = true;
        });
      },
      onDragExited: (_) {
        setState(() {
          _dragAndDropIndicator = false;
        });
      },
      onDragDone: (event) async {
        // the drop may contain a mix of files and directories
        final droppedDirectories = event.files.where((file) => Directory(file.path).existsSync()).toList();
        final droppedFiles = event.files.where((file) => !Directory(file.path).existsSync()).toList();

        for (final directory in droppedDirectories) {
          await ref.redux(selectedSendingFilesProvider).dispatchAsync(AddDirectoryAction(directory.path));
        }

        if (droppedFiles.isNotEmpty) {
          await ref
              .redux(selectedSendingFilesProvider)
              .dispatchAsync(
                AddFilesAction(
                  files: droppedFiles,
                  converter: CrossFileConverters.convertXFile,
                ),
              );
        }
        vm.changeTab(HomeTab.send);
      },
      child: ResponsiveBuilder(
        builder: (sizingInformation) {
          return Scaffold(
            body: Row(
              children: [
                if (!sizingInformation.isMobile)
                  NavigationRail(
                    // [FORK] 侧边栏只留图标（宽 72），label 仅供 tooltip / 无障碍使用。
                    // 设置项不在 destinations 里，而是钉在底部的 trailing。
                    selectedIndex: _railTabs.contains(vm.currentTab) ? _railTabs.indexOf(vm.currentTab) : null,
                    onDestinationSelected: (index) => vm.changeTab(_railTabs[index]),
                    extended: false,
                    labelType: NavigationRailLabelType.none,
                    trailingAtBottom: true,
                    backgroundColor: Theme.of(context).cardColorWithElevation,
                    leading: Padding(
                      padding: const EdgeInsets.only(top: 8, bottom: 12),
                      child: Tooltip(
                        message: t.appName,
                        waitDuration: const Duration(milliseconds: 350),
                        child: Assets.img.logo128.image(width: 34, height: 34),
                      ),
                    ),
                    trailing: Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _RailItem(
                        icon: HomeTab.settings.icon,
                        label: HomeTab.settings.label,
                        selected: vm.currentTab == HomeTab.settings,
                        onTap: () => vm.changeTab(HomeTab.settings),
                      ),
                    ),
                    destinations: _railTabs.map((tab) {
                      return NavigationRailDestination(
                        icon: Tooltip(
                          message: tab.label,
                          waitDuration: const Duration(milliseconds: 350),
                          child: Icon(tab.icon),
                        ),
                        label: Text(tab.label),
                      );
                    }).toList(),
                  ),
                Expanded(
                  child: SafeArea(
                    left: sizingInformation.isMobile,
                    child: Stack(
                      children: [
                        PageView(
                          controller: vm.controller,
                          physics: const NeverScrollableScrollPhysics(),
                          children: const [
                            // [FORK] 顺序必须与 HomeTab 枚举一致
                            ConversationsPage(),
                            ReceiveTab(),
                            SendTab(),
                            SettingsTab(),
                          ],
                        ),
                        if (_dragAndDropIndicator)
                          Container(
                            width: double.infinity,
                            decoration: BoxDecoration(
                              color: Theme.of(context).scaffoldBackgroundColor,
                            ),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(Icons.file_download, size: 128),
                                const SizedBox(height: 30),
                                Text(t.sendTab.placeItems, style: Theme.of(context).textTheme.titleLarge),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            bottomNavigationBar: sizingInformation.isMobile
                ? NavigationBar(
                    selectedIndex: vm.currentTab.index,
                    onDestinationSelected: (index) => vm.changeTab(HomeTab.values[index]),
                    // [FORK] 窄窗口时同样只留图标，文字靠悬浮 tooltip（默认取 label）。
                    labelBehavior: NavigationDestinationLabelBehavior.alwaysHide,
                    destinations: HomeTab.values.map((tab) {
                      return NavigationDestination(
                        icon: Icon(tab.icon),
                        label: tab.label,
                        tooltip: tab.label,
                      );
                    }).toList(),
                  )
                : null,
          );
        },
      ),
    );
  }
}

/// [FORK] 钉在侧边栏底部的单个图标项（NavigationRail 的 destinations 只能是一整组，
/// 没法把其中一项单独沉底，所以设置项自己画一个同样式的）。
class _RailItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _RailItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: label,
      waitDuration: const Duration(milliseconds: 350),
      child: InkWell(
        onTap: onTap,
        borderRadius: const BorderRadius.all(Radius.circular(32)),
        child: SizedBox(
          width: 72,
          height: 56,
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeInOut,
              width: 64,
              height: 32,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: selected ? colorScheme.secondaryContainer : Colors.transparent,
                borderRadius: const BorderRadius.all(Radius.circular(16)),
              ),
              child: Icon(
                icon,
                size: 24,
                color: selected ? colorScheme.onSecondaryContainer : colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
