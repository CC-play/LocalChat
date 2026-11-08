import 'package:flutter/material.dart';
import 'package:localchat_app/gen/assets.gen.dart';
import 'package:localchat_app/widget/rotating_widget.dart';

/// Radius of the clear band between the message bubble and the arrow ring, as a
/// fraction of the icon side.
///
/// Measured on `logo-512.png`: the bubble reaches 0.289 of the side (its tail
/// tip) and the arrow ring starts at 0.346. Clipping in the middle of that gap
/// keeps both sides clear, so the ring can spin without dragging the bubble
/// along.
const double _innerRadiusRatio = 0.320;

const double _logoSize = 200;

class LocalChatLogo extends StatelessWidget {
  final bool withText;

  /// Whether the arrow ring spins. Only the ring rotates, the bubble in the
  /// middle stays upright.
  final bool spinning;

  /// Time for one full turn of the ring.
  final Duration spinDuration;

  const LocalChatLogo({
    required this.withText,
    this.spinning = false,
    this.spinDuration = const Duration(seconds: 15),
  });

  @override
  Widget build(BuildContext context) {
    final ring = ClipPath(
      clipper: const _AnnulusClipper(innerRatio: _innerRadiusRatio),
      child: Assets.img.logo512.image(width: _logoSize, height: _logoSize),
    );

    final bubble = ClipPath(
      clipper: const _DiscClipper(radiusRatio: _innerRadiusRatio),
      child: Assets.img.logo512.image(width: _logoSize, height: _logoSize),
    );

    final logo = ColorFiltered(
      colorFilter: ColorFilter.mode(
        Theme.of(context).colorScheme.primary,
        BlendMode.srcATop,
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (spinning)
            RotatingWidget(
              duration: spinDuration,
              child: ring,
            )
          else
            ring,
          bubble,
        ],
      ),
    );

    if (withText) {
      return Column(
        children: [
          logo,
          const Text(
            'LocalChat',
            style: TextStyle(fontSize: 36, fontWeight: FontWeight.bold),
            textAlign: TextAlign.center,
          ),
        ],
      );
    } else {
      return logo;
    }
  }
}

/// Everything outside a centred circle: the arrow ring with the bubble removed.
class _AnnulusClipper extends CustomClipper<Path> {
  final double innerRatio;

  const _AnnulusClipper({required this.innerRatio});

  @override
  Path getClip(Size size) {
    final rect = Offset.zero & size;
    final hole = Path()
      ..addOval(
        Rect.fromCircle(
          center: rect.center,
          radius: size.shortestSide * innerRatio,
        ),
      );
    return Path.combine(
      PathOperation.difference,
      Path()..addRect(rect),
      hole,
    );
  }

  @override
  bool shouldReclip(_AnnulusClipper oldClipper) =>
      oldClipper.innerRatio != innerRatio;
}

/// Only the centred circle: the bubble with the ring removed.
class _DiscClipper extends CustomClipper<Path> {
  final double radiusRatio;

  const _DiscClipper({required this.radiusRatio});

  @override
  Path getClip(Size size) {
    final rect = Offset.zero & size;
    return Path()
      ..addOval(
        Rect.fromCircle(
          center: rect.center,
          radius: size.shortestSide * radiusRatio,
        ),
      );
  }

  @override
  bool shouldReclip(_DiscClipper oldClipper) =>
      oldClipper.radiusRatio != radiusRatio;
}
