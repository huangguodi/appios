import 'package:app/core/constants.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

/// 显示一个带有缩放和淡入淡出动画的通用弹窗
Future<T?> showAnimatedDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  Color barrierColor = const Color(0x80000000),
  Duration transitionDuration = const Duration(milliseconds: 200),
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: barrierColor,
    transitionDuration: transitionDuration,
    pageBuilder: (context, animation, secondaryAnimation) {
      return builder(context);
    },
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      final curvedAnimation = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );

      return FadeTransition(
        opacity: curvedAnimation,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.92, end: 1.0).animate(curvedAnimation),
          child: child,
        ),
      );
    },
  );
}

Future<void> showGlobalMessageDialog({
  required String title,
  required String message,
  bool barrierDismissible = true,
  String confirmText = '确定',
}) async {
  final navigatorState = appNavigatorKey.currentState;
  final overlayState = navigatorState?.overlay;
  if (navigatorState == null ||
      !navigatorState.mounted ||
      overlayState == null ||
      !overlayState.mounted) {
    return;
  }
  await showAnimatedDialog<void>(
    context: overlayState.context,
    barrierDismissible: barrierDismissible,
    builder: (context) {
      return AlertDialog(
        backgroundColor: AppColors.cardBackground,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14.r),
          side: BorderSide(color: const Color(0xFF96CBFF), width: 1.1.w),
        ),
        title: Text(
          title,
          style: TextStyle(
            color: Colors.white,
            fontSize: 20.sp,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: Text(
          message,
          style: TextStyle(
            color: Colors.white70,
            fontSize: 14.sp,
            height: 1.5,
            fontWeight: FontWeight.w500,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(
              confirmText,
              style: const TextStyle(
                color: Color(0xFF96CBFF),
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      );
    },
  );
}
