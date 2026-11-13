import 'package:flutter/material.dart';
import 'package:routerino/routerino.dart';

class CustomBottomSheet extends StatelessWidget {
  final String title;
  final String? description;
  final Widget child;

  /// When set, a close (×) button is drawn in the top-right corner of the sheet.
  ///
  /// Omitted by default, so sheets that rely on their bottom action buttons keep
  /// the stock layout.
  final VoidCallback? onClose;

  /// Matches [RouterinoBottomSheet]'s defaults, so both variants look identical.
  static const double _maxWidth = 550;
  static const double _borderRadius = 20;
  static const EdgeInsets _padding = EdgeInsets.all(20);
  static const double _cornerButtonSize = 40;

  const CustomBottomSheet({
    required this.title,
    required this.description,
    required this.child,
    this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final backgroundColor = Theme.of(context).scaffoldBackgroundColor;
    final close = onClose;

    if (close == null) {
      return RouterinoBottomSheet(
        title: title,
        description: description,
        backgroundColor: backgroundColor,
        borderRadius: _borderRadius,
        child: child,
      );
    }

    // RouterinoBottomSheet has no slot for a corner button, so the header is
    // rebuilt here: same type scale and paddings as upstream, plus a close
    // button level with the title instead of an action at the bottom.
    return Row(
      mainAxisAlignment: MainAxisAlignment.center, // center it for tablets
      children: [
        Flexible(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _maxWidth),
            child: Container(
              padding: EdgeInsets.only(
                // handle safe area
                bottom: MediaQuery.of(context).padding.bottom,
              ),
              decoration: BoxDecoration(
                color: backgroundColor,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(_borderRadius),
                  topRight: Radius.circular(_borderRadius),
                ),
              ),
              child: Padding(
                padding: _padding,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        // Mirrors the button width so the title stays optically
                        // centered on the sheet, not on the free space left of it.
                        const SizedBox(width: _cornerButtonSize),
                        Expanded(
                          child: Text(
                            title,
                            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                            textAlign: TextAlign.center,
                          ),
                        ),
                        SizedBox(
                          width: _cornerButtonSize,
                          height: _cornerButtonSize,
                          child: IconButton(
                            onPressed: close,
                            tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                            iconSize: 20,
                            padding: EdgeInsets.zero,
                            icon: const Icon(Icons.close),
                          ),
                        ),
                      ],
                    ),
                    if (description != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 20),
                        child: Center(
                          child: Text(description!, style: const TextStyle(fontSize: 16), textAlign: TextAlign.center),
                        ),
                      ),
                    Material(
                      // we need this, otherwise inkwells inside child do not work properly
                      type: MaterialType.transparency,
                      child: child,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
