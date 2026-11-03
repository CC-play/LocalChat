import 'dart:async';

import 'package:flutter/material.dart';

/// [FORK] 顶部轻提示。
///
/// Flutter 自带的 `SnackBar` 只能贴底弹出，而聊天页底部就是输入条，
/// 在输入条上弹提示会正好挡住用户要继续输入的地方。这里用 `OverlayEntry`
/// 自己做一条从顶部滑入、几秒后自动收起的提示条。
class TopToast {
  static OverlayEntry? _entry;

  static void show(BuildContext context, String message) {
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) {
      return;
    }

    // 同一时刻只保留一条，新的直接顶掉旧的。
    dismiss();

    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _TopToastView(
        message: message,
        onDismissed: () {
          if (identical(_entry, entry)) {
            _entry = null;
          }
          if (entry.mounted) {
            entry.remove();
          }
        },
      ),
    );
    _entry = entry;
    overlay.insert(entry);
  }

  static void dismiss() {
    final entry = _entry;
    _entry = null;
    if (entry != null && entry.mounted) {
      entry.remove();
    }
  }
}

class _TopToastView extends StatefulWidget {
  final String message;
  final VoidCallback onDismissed;

  const _TopToastView({
    required this.message,
    required this.onDismissed,
  });

  @override
  State<_TopToastView> createState() => _TopToastViewState();
}

class _TopToastViewState extends State<_TopToastView> with SingleTickerProviderStateMixin {
  static const _visibleDuration = Duration(seconds: 3);

  late final AnimationController _controller;
  Timer? _timer;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
      reverseDuration: const Duration(milliseconds: 160),
    );

    _controller.addStatusListener((status) {
      if (_closing && status == AnimationStatus.dismissed && mounted) {
        widget.onDismissed();
      }
    });

    unawaited(_controller.forward());
    _timer = Timer(_visibleDuration, _dismiss);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _dismiss() {
    _timer?.cancel();
    if (_closing || !mounted) {
      return;
    }
    _closing = true;
    unawaited(_controller.reverse());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final animation = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );

    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      // 提示条不该拦住鼠标/手指，否则它会挡住它下面的内容。
      child: IgnorePointer(
        child: SafeArea(
          child: SlideTransition(
            position: Tween<Offset>(begin: const Offset(0, -1.4), end: Offset.zero).animate(animation),
            child: FadeTransition(
              opacity: animation,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.errorContainer,
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: theme.colorScheme.shadow.withValues(alpha: 0.18),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.error, size: 22, color: theme.colorScheme.error),
                        const SizedBox(width: 10),
                        Flexible(
                          child: Text(
                            widget.message,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.normal,
                              height: 1.35,
                              color: theme.colorScheme.onErrorContainer,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
