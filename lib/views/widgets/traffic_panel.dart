import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import 'package:app/core/constants.dart';
import 'package:app/core/utils.dart';
import 'package:app/view_models/home_view_model.dart';

class TrafficPanel extends StatelessWidget {
  final VoidCallback? onPurchaseTap;
  const TrafficPanel({super.key, this.onPurchaseTap});

  String _formatQuotaValue(int quota) {
    if (quota <= 0) return "0B  ";
    const gb = 1024 * 1024 * 1024;
    if (quota >= gb) {
      final value = quota / gb;
      return "${value.toStringAsFixed(2)}GB  ";
    }
    return "${formatBytes(quota)}  ";
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 8.h),
      decoration: BoxDecoration(
        color: AppColors.cardBackground.withValues(alpha: 0.42),
        borderRadius: BorderRadius.circular(20.r),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.2),
            blurRadius: 14.r,
            offset: Offset(0, 6.h),
          ),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Selector<HomeViewModel, (String, String)>(
              selector: (_, vm) => (vm.uploadSpeed, vm.downloadSpeed),
              builder: (context, speeds, child) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.south_east,
                          color: Colors.redAccent,
                          size: 16.sp,
                        ),
                        SizedBox(width: 6.w),
                        Text(
                          speeds.$2, // Download
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 15.sp,
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 1.h),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.north_east,
                          color: Colors.greenAccent,
                          size: 16.sp,
                        ),
                        SizedBox(width: 6.w),
                        Text(
                          speeds.$1, // Upload
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 14.sp,
                          ),
                        ),
                      ],
                    ),
                  ],
                );
              },
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Selector<HomeViewModel, int>(
                  selector: (_, vm) => vm.quotaBytes,
                  builder: (context, quota, child) {
                    final hasQuota = quota > 0;
                    final quotaText = hasQuota
                        ? _formatQuotaValue(quota)
                        : "0B  ";
                    return Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.data_usage_rounded,
                          color: Colors.amber.shade300,
                          size: 16.sp,
                        ),
                        SizedBox(width: 2.w),
                        Text(
                          quotaText,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 14.sp,
                          ),
                        ),
                      ],
                    );
                  },
                ),
                SizedBox(height: 2.h),
                GestureDetector(
                  onTap: onPurchaseTap,
                  child: Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: 10.w,
                      vertical: 4.h,
                    ),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          Colors.white.withValues(alpha: 0.2),
                          Colors.white.withValues(alpha: 0.1),
                        ],
                      ),
                      borderRadius: BorderRadius.circular(12.r),
                      border: Border.all(
                        color: const Color(0xFF96CBFF).withValues(alpha: 0.26),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            " 购买流量包",
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 11.sp,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        SizedBox(width: 6.w),
                        Icon(
                          Icons.arrow_forward_ios,
                          size: 11.sp,
                          color: Colors.white,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
