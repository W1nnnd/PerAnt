// SPDX-License-Identifier: GPL-3.0-only
import 'package:material_ui/material_ui.dart';

import 'theme.dart';

enum CompanionMood { idle, thinking, working, waiting, paused, takeover, happy }

/// The original Concept 06 artwork, with an open top and a circular lower clip.
/// Only the visible, active work pose uses an animated decoder.
class CompanionAvatar extends StatelessWidget {
  const CompanionAvatar({
    super.key,
    required this.diameter,
    this.mood = CompanionMood.idle,
    this.animate = false,
    this.onTap,
    this.label = '小蚁',
  });

  final double diameter;
  final CompanionMood mood;
  final bool animate;
  final VoidCallback? onTap;
  final String label;

  @override
  Widget build(BuildContext context) {
    final moving =
        animate &&
        TickerMode.valuesOf(context).enabled &&
        !MediaQuery.disableAnimationsOf(context);
    final asset = switch (mood) {
      CompanionMood.working when moving => 'working.webp',
      CompanionMood.working || CompanionMood.takeover => 'working.png',
      CompanionMood.paused || CompanionMood.thinking => 'resting.png',
      CompanionMood.happy => 'celebrating.png',
      _ => 'welcome.png',
    };
    final ring = (diameter * .034).clamp(3.0, 5.0);
    final inner = diameter - ring * 2;
    final decodeWidth =
        (diameter * 1.46 * MediaQuery.devicePixelRatioOf(context))
            .round()
            .clamp(96, 640);
    return Semantics(
      label: label,
      button: onTap != null,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          width: diameter,
          height: diameter * 1.314,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  height: diameter,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const RadialGradient(
                      center: Alignment(0, -.5),
                      radius: .9,
                      colors: [Color(0xFFF6F9EF), Color(0xFFD8E2CA)],
                    ),
                    border: Border.all(color: Colors.white, width: ring),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x22455C3E),
                        blurRadius: 18,
                        offset: Offset(0, 7),
                      ),
                      BoxShadow(color: Color(0x22455C3E), spreadRadius: 1),
                    ],
                  ),
                ),
              ),
              Positioned(
                left: ring,
                right: ring,
                bottom: ring,
                height: inner * 1.314,
                child: ClipPath(
                  clipper: const _OpenCircleClipper(),
                  child: OverflowBox(
                    alignment: Alignment.topCenter,
                    minWidth: inner * 1.46,
                    maxWidth: inner * 1.46,
                    maxHeight: inner * 1.46,
                    child: Image.asset(
                      'assets/companion/$asset',
                      width: inner * 1.46,
                      height: inner * 1.46,
                      fit: BoxFit.contain,
                      cacheWidth: decodeWidth,
                      gaplessPlayback: true,
                      excludeFromSemantics: true,
                      errorBuilder: (context, error, trace) => Icon(
                        Icons.pets_outlined,
                        color: PerantColors.accent,
                        size: inner * .5,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OpenCircleClipper extends CustomClipper<Path> {
  const _OpenCircleClipper();
  @override
  Path getClip(Size size) {
    final centreY = size.height - size.width / 2;
    return Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width, centreY)
      ..arcToPoint(Offset(0, centreY), radius: Radius.circular(size.width / 2))
      ..close();
  }

  @override
  bool shouldReclip(_OpenCircleClipper oldClipper) => false;
}
