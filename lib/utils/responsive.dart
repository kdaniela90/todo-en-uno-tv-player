import 'package:flutter/material.dart';

class R {
  static double w(BuildContext ctx) => MediaQuery.of(ctx).size.width;

  static bool isPhone(BuildContext ctx)  => w(ctx) < 700;
  static bool isTablet(BuildContext ctx) => w(ctx) >= 700 && w(ctx) < 1100;
  static bool isTV(BuildContext ctx)     => w(ctx) >= 1100;

  /// Columnas para grids — más columnas = tarjetas más pequeñas
  static int gridCols(BuildContext ctx) {
    final width = w(ctx);
    if (width < 600)  return 3;
    if (width < 800)  return 4;
    if (width < 1100) return 6;
    return 7;
  }

  /// Ancho del panel de categorías — más ancho para ver el texto completo
  static double catPanelW(BuildContext ctx) {
    final width = w(ctx);
    if (width < 600)  return 170;
    if (width < 1100) return 240;
    return 290;
  }

  static double padding(BuildContext ctx) => isPhone(ctx) ? 8 : 12;
  static double fs(BuildContext ctx, double base) => isPhone(ctx) ? base * 0.85 : base;
}
