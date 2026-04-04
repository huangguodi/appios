import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:app/core/constants.dart';

class ModeSwitch extends StatefulWidget {
  final ConnectionMode mode;
  final bool isSwitching;
  final ValueChanged<ConnectionMode> onModeChanged;

  const ModeSwitch({
    super.key,
    required this.mode,
    required this.isSwitching,
    required this.onModeChanged,
  });

  @override
  State<ModeSwitch> createState() => _ModeSwitchState();
}

class _ModeSwitchState extends State<ModeSwitch>
    with SingleTickerProviderStateMixin {
  late AnimationController _bounceController;
  late Animation<double> _bounceAnimation;

  @override
  void initState() {
    super.initState();
    _bounceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _bounceAnimation = Tween<double>(
      begin: 0,
      end: 0,
    ).animate(_bounceController);
  }

  @override
  void dispose() {
    _bounceController.dispose();
    super.dispose();
  }

  void _triggerBounceAnimation(ConnectionMode targetMode) {
    double currentVal = _getAlignmentValue(widget.mode);
    double targetVal = _getAlignmentValue(targetMode);
    double distance = targetVal - currentVal;
    double peakOffset = distance * 0.3;

    _bounceAnimation = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween(
          begin: 0.0,
          end: peakOffset,
        ).chain(CurveTween(curve: Curves.easeOut)),
        weight: 50,
      ),
      TweenSequenceItem(
        tween: Tween(
          begin: peakOffset,
          end: 0.0,
        ).chain(CurveTween(curve: Curves.easeIn)),
        weight: 50,
      ),
    ]).animate(_bounceController);

    _bounceController.reset();
    _bounceController.forward();
  }

  void _handleTap(ConnectionMode targetMode) {
    // 如果正在切换，则忽略点击，并给予反馈动画
    if (widget.isSwitching) {
      if (widget.mode != targetMode) {
        _triggerBounceAnimation(targetMode);
      }
      return;
    }

    // 如果点击的是当前模式，也忽略（避免重复触发）
    if (widget.mode == targetMode) return;

    // Trigger change in parent
    widget.onModeChanged(targetMode);
  }

  double _getAlignmentValue(ConnectionMode mode) {
    switch (mode) {
      case ConnectionMode.off:
        return -1.0;
      case ConnectionMode.smart:
        return 0.0;
      case ConnectionMode.global:
        return 1.0;
    }
  }

  Alignment _getAlignment() {
    double base = _getAlignmentValue(widget.mode);
    return Alignment(
      base + (_bounceController.isAnimating ? _bounceAnimation.value : 0.0),
      0.0,
    );
  }

  Color _getModeColor() {
    switch (widget.mode) {
      case ConnectionMode.off:
        return AppColors.modeOff;
      case ConnectionMode.smart:
        return AppColors.modeSmart;
      case ConnectionMode.global:
        return AppColors.modeGlobal;
    }
  }

  IconData _getModeIcon() {
    switch (widget.mode) {
      case ConnectionMode.off:
        return Icons.power_off;
      case ConnectionMode.smart:
        return Icons.auto_awesome;
      case ConnectionMode.global:
        return Icons.public;
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final switchWidth = constraints.maxWidth.clamp(300.0, 560.0);
        final switchHeight = 60.h;
        final sliderWidth = (switchWidth - 18.w) / 3;

        return Stack(
          alignment: Alignment.center,
          children: [
            AnimatedBuilder(
              animation: _bounceController,
              builder: (context, child) {
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  width: switchWidth,
                  height: switchHeight,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20.r),
                    color: AppColors.cardBackground,
                    border: Border.all(
                      color: widget.mode == ConnectionMode.off
                          ? Colors.white.withValues(alpha: 0.1)
                          : _getModeColor(),
                      width: 1.6.w,
                    ),
                    boxShadow: widget.mode != ConnectionMode.off
                        ? [
                            BoxShadow(
                              color: _getModeColor().withValues(alpha: 0.3),
                              blurRadius: 20.r,
                              spreadRadius: 2.r,
                            ),
                          ]
                        : [],
                  ),
                  child: Stack(
                    children: [
                      Center(
                        child: Row(
                          children: [
                            Expanded(
                              child: GestureDetector(
                                behavior: HitTestBehavior.translucent,
                                onTap: () => _handleTap(ConnectionMode.off),
                                child: Center(
                                  child: Text(
                                    AppStrings.modeOff,
                                    style: TextStyle(
                                      color: widget.mode == ConnectionMode.off
                                          ? Colors.white
                                          : Colors.white.withValues(alpha: 0.3),
                                      fontWeight: FontWeight.bold,
                                      fontSize: 15.sp,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            Expanded(
                              child: GestureDetector(
                                behavior: HitTestBehavior.translucent,
                                onTap: () => _handleTap(ConnectionMode.smart),
                                child: Center(
                                  child: Text(
                                    AppStrings.modeSmart,
                                    style: TextStyle(
                                      color: widget.mode == ConnectionMode.smart
                                          ? Colors.white
                                          : Colors.white.withValues(alpha: 0.3),
                                      fontWeight: FontWeight.bold,
                                      fontSize: 15.sp,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            Expanded(
                              child: GestureDetector(
                                behavior: HitTestBehavior.translucent,
                                onTap: () => _handleTap(ConnectionMode.global),
                                child: Center(
                                  child: Text(
                                    AppStrings.modeGlobal,
                                    style: TextStyle(
                                      color:
                                          widget.mode == ConnectionMode.global
                                          ? Colors.white
                                          : Colors.white.withValues(alpha: 0.3),
                                      fontWeight: FontWeight.bold,
                                      fontSize: 15.sp,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      AnimatedAlign(
                        duration: _bounceController.isAnimating
                            ? Duration.zero
                            : const Duration(milliseconds: 300),
                        curve: Curves.easeInOut,
                        alignment: _getAlignment(),
                        child: IgnorePointer(
                          child: Container(
                            margin: EdgeInsets.all(5.r),
                            width: sliderWidth,
                            height: switchHeight - 10.h,
                            decoration: BoxDecoration(
                              color: _getModeColor(),
                              borderRadius: BorderRadius.circular(14.r),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.3),
                                  blurRadius: 8.r,
                                  offset: Offset(0, 4.h),
                                ),
                              ],
                            ),
                            child: Center(
                              child: Icon(
                                _getModeIcon(),
                                color: Colors.white,
                                size: 28.sp,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ],
        );
      },
    );
  }
}
