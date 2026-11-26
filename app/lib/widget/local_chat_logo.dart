import 'package:flutter/material.dart';
import 'package:localchat_app/gen/assets.gen.dart';
import 'package:localchat_app/widget/rotating_widget.dart';

/// Radius of the clear band between the message bubble and the arrow ring, as a
/// fraction of the icon side.
///
/// Measured on the current `logo-512.png`: the bubble's outermost ink (its tail
/// tip) reaches 0.303 of the side, the ring's innermost ink starts at 0.407, and
/// the whole annulus in between is fully transparent. Cutting at 0.320 lands
/// inside that empty band, so neither layer actually loses any artwork:
///
/// - the bubble sits 0.017 R inside the cut (+2.1 px even at the smallest size
///   the receive tab uses, 120 px), so it is never sliced;
/// - the ring keeps 0.087 R of clearance, so its silhouette is entirely its own
///   edge and the cut never shows up as a rebuilt arc.
///
/// Both clippers derive the radius from the widget's own [Size], so this holds
/// at every size the logo is drawn at. Rotation is radius-preserving, which is
/// why spinning the ring can never pull ink into the empty band either. If the
/// artwork is ever replaced, re-measure these two radii before trusting 0.320.
const double _innerRadiusRatio = 0.320;

/// Side length of the artwork, in logical pixels.
///
/// This is the default for [LocalChatLogo.size], not a fixed contract any more:
/// the receive tab scales it with the window. It is still the value the launch
/// splash pre-loads (see `_precacheStartupLogo` in `main.dart`), so it must stay
/// in sync with whatever that splash actually draws.
const double kLogoSize = 200;

class LocalChatLogo extends StatelessWidget {
  final bool withText;

  /// Side length of the artwork. Pass a window-derived value to let the logo
  /// grow/shrink with the layout; the default keeps the historical 200.
  final double size;

  /// Whether the arrow ring spins. Only the ring rotates, the bubble in the
  /// middle stays upright.
  final bool spinning;

  /// Time for one full turn of the ring.
  final Duration spinDuration;

  /// Colour the artwork is tinted with. Defaults to the theme's primary, which
  /// is what every in-app surface wants; the launch splash passes white because
  /// it sits on a blue background instead.
  final Color? color;

  const LocalChatLogo({
    required this.withText,
    this.size = kLogoSize,
    this.spinning = false,
    this.spinDuration = const Duration(seconds: 15),
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final ring = ClipPath(
      clipper: const _AnnulusClipper(innerRatio: _innerRadiusRatio),
      child: Assets.img.logo512.image(width: size, height: size),
    );

    final bubble = ClipPath(
      clipper: const _DiscClipper(radiusRatio: _innerRadiusRatio),
      child: Assets.img.logo512.image(width: size, height: size),
    );

    final logo = ColorFiltered(
      colorFilter: ColorFilter.mode(
        color ?? Theme.of(context).colorScheme.primary,
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
  bool shouldReclip(_AnnulusClipper oldClipper) => oldClipper.innerRatio != innerRatio;
}

/// Only the centred circle: the bubble with the ring removed.
class _DiscClipper extends CustomClipper<Path> {
  final double radiusRatio;

  const _DiscClipper({required this.radiusRatio});

  @override
  Path getClip(Size size) {
    final rect = Offset.zero & size;
    return Path()..addOval(
      Rect.fromCircle(
        center: rect.center,
        radius: size.shortestSide * radiusRatio,
      ),
    );
  }

  @override
  bool shouldReclip(_DiscClipper oldClipper) => oldClipper.radiusRatio != radiusRatio;
}
