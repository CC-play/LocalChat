import 'package:flutter/material.dart';
import 'package:localchat_app/config/theme.dart';
import 'package:localchat_app/gen/strings.g.dart';

/// [FORK] 接收页的「改设备名称」输入框。
///
/// 改的是设置里同一个值（`settingsProvider.alias`），只是把入口挪到了看得见名字的地方。
/// 取消 / 点遮罩返回 `null`；保存返回去掉首尾空格后的新名字。
class DeviceNameDialog extends StatefulWidget {
  final String initialName;

  /// 有传输正在进行：保存要重启接收服务，先提醒一句。
  final bool transferActive;

  const DeviceNameDialog({
    required this.initialName,
    this.transferActive = false,
  });

  @override
  State<DeviceNameDialog> createState() => _DeviceNameDialogState();
}

class _DeviceNameDialogState extends State<DeviceNameDialog> {
  late final TextEditingController _controller = TextEditingController(text: widget.initialName);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 空名字不能存：服务端会把空别名换成随机名，用户会以为改名失败。
  bool get _canSave => _controller.text.trim().isNotEmpty;

  void _submit() {
    if (!_canSave) {
      return;
    }
    Navigator.of(context).pop(_controller.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: Text(t.receiveTab.editAlias),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextFormField(
            controller: _controller,
            autofocus: true,
            textAlign: TextAlign.center,
            textInputAction: TextInputAction.done,
            onChanged: (_) => setState(() {}),
            onFieldSubmitted: (_) => _submit(),
          ),
          if (widget.transferActive) ...[
            const SizedBox(height: 12),
            Text(
              t.receiveTab.editAliasBusy,
              style: TextStyle(color: theme.colorScheme.warning, fontSize: 12),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.general.cancel),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: theme.colorScheme.primary,
            foregroundColor: theme.colorScheme.onPrimary,
          ),
          onPressed: _canSave ? _submit : null,
          child: Text(t.general.save),
        ),
      ],
    );
  }
}
