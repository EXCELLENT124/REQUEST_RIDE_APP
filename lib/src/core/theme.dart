import 'package:flutter/material.dart';

abstract final class RequestRideColors {
  static const midnight = Color(0xFF031B1A);
  static const forest = Color(0xFF073D33);
  static const surface = Color(0xFF0B302D);
  static const emerald = Color(0xFF00D69A);
  static const aqua = Color(0xFF32E0D0);
  static const gold = Color(0xFFFFC857);
  static const cream = Color(0xFFF3FFF9);
  static const coral = Color(0xFFFF6F61);
}

abstract final class RequestRideTheme {
  static ThemeData get dark {
    const colors = ColorScheme.dark(
      primary: RequestRideColors.emerald,
      onPrimary: RequestRideColors.midnight,
      primaryContainer: Color(0xFF075B4C),
      onPrimaryContainer: RequestRideColors.cream,
      secondary: RequestRideColors.gold,
      onSecondary: RequestRideColors.midnight,
      secondaryContainer: Color(0xFF594718),
      onSecondaryContainer: RequestRideColors.cream,
      tertiary: RequestRideColors.aqua,
      surface: RequestRideColors.surface,
      onSurface: RequestRideColors.cream,
      error: RequestRideColors.coral,
    );
    final base = ThemeData(
      brightness: Brightness.dark,
      colorScheme: colors,
      useMaterial3: true,
      scaffoldBackgroundColor: Colors.transparent,
    );
    return base.copyWith(
      textTheme: base.textTheme.copyWith(
        headlineLarge: base.textTheme.headlineLarge?.copyWith(
          fontWeight: FontWeight.w800,
          letterSpacing: -1.1,
        ),
        headlineMedium: base.textTheme.headlineMedium?.copyWith(
          fontWeight: FontWeight.w800,
          letterSpacing: -0.7,
        ),
        headlineSmall: base.textTheme.headlineSmall?.copyWith(
          fontWeight: FontWeight.w700,
        ),
        titleLarge: base.textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w700,
        ),
      ),
      appBarTheme: const AppBarTheme(
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: RequestRideColors.midnight,
        foregroundColor: RequestRideColors.cream,
        surfaceTintColor: Colors.transparent,
      ),
      cardTheme: CardThemeData(
        color: RequestRideColors.surface.withValues(alpha: .88),
        elevation: 0,
        margin: const EdgeInsets.symmetric(vertical: 7),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
          side: BorderSide(
            color: RequestRideColors.emerald.withValues(alpha: .20),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: RequestRideColors.midnight.withValues(alpha: .72),
        contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 17),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(
            color: RequestRideColors.aqua.withValues(alpha: .25),
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(
            color: RequestRideColors.emerald,
            width: 1.5,
          ),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: RequestRideColors.emerald,
          foregroundColor: RequestRideColors.midnight,
          minimumSize: const Size(120, 50),
          textStyle: const TextStyle(fontWeight: FontWeight.w800),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: RequestRideColors.aqua,
          minimumSize: const Size(120, 48),
          side: const BorderSide(color: RequestRideColors.aqua),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: RequestRideColors.aqua),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: const Color(0xFF143F39),
        contentTextStyle: const TextStyle(color: RequestRideColors.cream),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      dividerColor: RequestRideColors.aqua.withValues(alpha: .15),
    );
  }
}

class BrandedBackdrop extends StatelessWidget {
  const BrandedBackdrop({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              RequestRideColors.midnight,
              Color(0xFF07342F),
              Color(0xFF082428),
            ],
          ),
        ),
        child: Stack(
          children: [
            const Positioned(
              top: -180,
              right: -130,
              child: _AmbientGlow(color: RequestRideColors.emerald),
            ),
            const Positioned(
              bottom: -230,
              left: -160,
              child: _AmbientGlow(color: RequestRideColors.gold, size: 500),
            ),
            Positioned.fill(child: child),
          ],
        ),
      );
}

class _AmbientGlow extends StatelessWidget {
  const _AmbientGlow({required this.color, this.size = 420});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(
        dimension: size,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              colors: [color.withValues(alpha: .19), color.withValues(alpha: 0)],
            ),
          ),
        ),
      );
}
