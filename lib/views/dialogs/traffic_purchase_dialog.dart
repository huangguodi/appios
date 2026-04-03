import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:app/core/constants.dart';
import 'package:app/services/api_service.dart';
import 'package:app/view_models/home_view_model.dart';
import 'package:app/views/dialogs/redeem_key_dialog.dart';
import 'package:app/views/widgets/custom_dialog.dart';

class TrafficPackageOption {
  final String id;
  final String item;
  final String amount;
  final String normalAssetFileName;
  final String selectedAssetFileName;

  const TrafficPackageOption({
    required this.id,
    required this.item,
    required this.amount,
    required this.normalAssetFileName,
    required this.selectedAssetFileName,
  });
}

const List<TrafficPackageOption> _trafficPackages = [
  TrafficPackageOption(
    id: '100GB',
    item: '100GB/流量包',
    amount: '9.99',
    normalAssetFileName: '100GB.png',
    selectedAssetFileName: '100GBs.png',
  ),
  TrafficPackageOption(
    id: '500GB',
    item: '500GB/流量包',
    amount: '29.99',
    normalAssetFileName: '500GB.png',
    selectedAssetFileName: '500GBs.png',
  ),
  TrafficPackageOption(
    id: '1000GB',
    item: '1000GB/流量包',
    amount: '89.99',
    normalAssetFileName: '1000GB.png',
    selectedAssetFileName: '1000GBs.png',
  ),
];

class TrafficPurchaseDialog {
  static Future<void> show(BuildContext context) {
    final hostContext = context;
    return showGeneralDialog(
      context: hostContext,
      barrierDismissible: true,
      barrierLabel: 'traffic_purchase',
      barrierColor: Colors.black.withValues(alpha: 0.25),
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (context, animation, secondaryAnimation) {
        return _TrafficPurchaseDialogContent(hostContext: hostContext);
      },
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
        return FadeTransition(
          opacity: curved,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.05),
              end: Offset.zero,
            ).animate(curved),
            child: child,
          ),
        );
      },
    );
  }
}

class _TrafficPurchaseDialogContent extends StatefulWidget {
  final BuildContext hostContext;

  const _TrafficPurchaseDialogContent({required this.hostContext});

  @override
  State<_TrafficPurchaseDialogContent> createState() => _TrafficPurchaseDialogContentState();
}

class _TrafficPurchaseDialogContentState extends State<_TrafficPurchaseDialogContent> {
  int selectedIndex = 1;
  bool isSubmitting = false;

  @override
  Widget build(BuildContext context) {
    final selectedPackage = _trafficPackages[selectedIndex];
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          Positioned.fill(
            child: Image.asset(
              AppAssets.resolveImage(context, 'gradient3.png'),
              fit: BoxFit.cover,
              width: double.infinity,
              height: double.infinity,
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                  child: Row(
                    children: [
                      GestureDetector(
                        onTap: () => Navigator.of(context).pop(),
                        child: SvgPicture.asset(
                          AppAssets.icClose,
                          width: 24,
                          height: 24,
                          colorFilter: const ColorFilter.mode(Colors.white, BlendMode.srcIn),
                        ),
                      ),
                      const Spacer(),
                      Padding(
                        padding: const EdgeInsets.only(top: 15),
                        child: Image.asset(
                          AppAssets.resolveImage(context, 'logo.png'),
                          width: 40,
                          height: 40,
                        ),
                      ),
                      const Spacer(),
                      GestureDetector(
                        onTap: () {
                          RedeemKeyDialog.show(
                            widget.hostContext,
                            onRedeemed: () => widget.hostContext
                                .read<HomeViewModel>()
                                .refreshUserInfo(),
                          );
                        },
                        child: SvgPicture.asset(
                          AppAssets.icRedeem,
                          width: 24,
                          height: 24,
                          colorFilter: const ColorFilter.mode(
                            Colors.white,
                            BlendMode.srcIn,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 6),
                        const Center(
                          child: Text(
                            '购买新的流量包',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          '节点采用 CN2 GIA + BGP 智能多线高端骨干网络承载，智能优化回国线路，无普通线路\n无劣质中转线路、无超售拥堵\n为你带来超低级延迟体验\n\n购买 1000GB(￥89.99)的流量包套餐\n首页左上角联系客服开通独享节点',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                            height: 1.3,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const Spacer(),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            _buildImagePackageCard(
                              index: 0,
                              selectedIndex: selectedIndex,
                              onTap: isSubmitting ? null : () => setState(() => selectedIndex = 0),
                              normalAssetFileName: _trafficPackages[0].normalAssetFileName,
                              selectedAssetFileName: _trafficPackages[0].selectedAssetFileName,
                            ),
                            const SizedBox(width: 8),
                            _buildImagePackageCard(
                              index: 1,
                              selectedIndex: selectedIndex,
                              onTap: isSubmitting ? null : () => setState(() => selectedIndex = 1),
                              normalAssetFileName: _trafficPackages[1].normalAssetFileName,
                              selectedAssetFileName: _trafficPackages[1].selectedAssetFileName,
                            ),
                            const SizedBox(width: 8),
                            _buildImagePackageCard(
                              index: 2,
                              selectedIndex: selectedIndex,
                              onTap: isSubmitting ? null : () => setState(() => selectedIndex = 2),
                              normalAssetFileName: _trafficPackages[2].normalAssetFileName,
                              selectedAssetFileName: _trafficPackages[2].selectedAssetFileName,
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            onPressed: isSubmitting
                                ? null
                                : () async {
                                    setState(() => isSubmitting = true);
                                    final createdAt = DateTime.now();
                                    final orderFuture = ApiService().createOrder(item: selectedPackage.id);
                                    final payListFuture = ApiService().fetchPayList();
                                    final result = await orderFuture;
                                    final payListResult = await payListFuture;
                                    
                                    if (!mounted) return;
                                    setState(() => isSubmitting = false);
                                    
                                    await _showPaymentOrderDialog(
                                      isSuccess: result.isSuccess,
                                      packageItem: selectedPackage.item,
                                      amount: selectedPackage.amount,
                                      msg: result.msg,
                                      paymentMethods: payListResult.isSuccess ? payListResult.methods : const [],
                                      onPaid: () {
                                        if (mounted) {
                                          Navigator.of(context).pop();
                                        }
                                      },
                                      orderNo: result.orderNo,
                                      createdAt: result.isSuccess ? createdAt : null,
                                    );
                                  },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF96CBFF),
                              foregroundColor: Colors.black,
                              disabledBackgroundColor: const Color(0xFF96CBFF).withValues(alpha: 0.7),
                              disabledForegroundColor: Colors.black54,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              elevation: 0,
                            ),
                            child: AnimatedSwitcher(
                              duration: const Duration(milliseconds: 220),
                              transitionBuilder: (child, animation) => FadeTransition(opacity: animation, child: child),
                              child: isSubmitting
                                  ? const Text(
                                      key: ValueKey('confirm_creating'),
                                      '创建订单中',
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w700,
                                        color: Colors.black,
                                      ),
                                    )
                                  : const Text(
                                      key: ValueKey('confirm_text'),
                                      '确认',
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w700,
                                        color: Colors.black,
                                      ),
                                    ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        const Center(
                          child: Text(
                            '购买后立即生效，流量包自动叠加\n疑问咨询：联系群主或您的推荐人\n投诉/退款/售后：首页左上角联系客服图标\n卡密兑换：右上角兑换图标',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: 12,
                              height: 1.5,
                            ),
                          ),
                        ),
                        const SizedBox(height: 20),
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

  Widget _buildImagePackageCard({
    required int index,
    required int selectedIndex,
    required VoidCallback? onTap,
    required String normalAssetFileName,
    required String selectedAssetFileName,
  }) {
    final isSelected = index == selectedIndex;
    final tagAlignment = index == 1
        ? (isSelected
            ? const Alignment(0.60, -0.50)
            : const Alignment(0.72, -0.52))
        : const Alignment(0.77, -0.69);
    return Expanded(
      flex: isSelected ? 115 : 100,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          margin: EdgeInsets.only(top: isSelected ? 0 : 16.0),
          child: Stack(
            children: [
              Image.asset(
                AppAssets.resolveImage(context, isSelected ? selectedAssetFileName : normalAssetFileName),
                fit: BoxFit.contain,
              ),
              Positioned.fill(
                child: Align(
                  alignment: tagAlignment,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFF2B4A5F).withValues(alpha: 0.95),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: const Text(
                      '时长',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
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

  Future<void> _showPaymentOrderDialog({
    required bool isSuccess,
    required String packageItem,
    required String amount,
    required String msg,
    required List<PaymentMethod> paymentMethods,
    VoidCallback? onPaid,
    String? orderNo,
    DateTime? createdAt,
  }) async {
    await showAnimatedDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) {
        if (!isSuccess) {
          return AlertDialog(
            backgroundColor: AppColors.cardBackground,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: const BorderSide(color: Color(0xFF96CBFF), width: 1.1),
            ),
            titlePadding: const EdgeInsets.fromLTRB(20, 16, 8, 0),
            title: Row(
              children: [
                const Expanded(
                  child: Text(
                    '下单失败',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  icon: const Icon(Icons.close_rounded, color: Colors.white60, size: 20),
                ),
              ],
            ),
            content: Text(
              msg,
              style: const TextStyle(color: Colors.white70, fontSize: 14),
            ),
          );
        }

        final initialMethodId = paymentMethods.isNotEmpty ? paymentMethods.first.id : null;
        int? selectedMethodId = initialMethodId;
        const orderTypes = ['年', '半年', '季', '月'];
        var selectedOrderType = '月';
        var isPaying = false;
        return StatefulBuilder(
          builder: (context, setDialogState) {
            IconData iconFor(String name) {
              final normalized = name.toLowerCase();
              if (name.contains('支付宝')) return Icons.account_balance_wallet_rounded;
              if (name.contains('微信')) return Icons.wechat_rounded;
              if (normalized.contains('usdt') || name.contains('泰达')) return Icons.currency_bitcoin_rounded;
              return Icons.payments_rounded;
            }
            double multiplierForType(String type) {
              if (type == '季') return 1.8;
              if (type == '半年') return 3;
              if (type == '年') return 4.8;
              return 1;
            }

            final baseAmount =
                double.tryParse(amount.replaceAll(',', '').trim()) ?? 0;
            final displayAmount =
                (baseAmount * multiplierForType(selectedOrderType))
                    .toStringAsFixed(2);

            return Dialog(
              backgroundColor: Colors.transparent,
              insetPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 20),
              child: Container(
                constraints: const BoxConstraints(maxWidth: 560),
                decoration: BoxDecoration(
                  color: const Color(0xFF15293B),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: const Color(0xFF96CBFF), width: 1.1),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.32),
                      blurRadius: 22,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 30,
                            height: 30,
                            decoration: BoxDecoration(
                              color: const Color(0xFF96CBFF).withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: const Icon(Icons.lock_rounded, size: 18, color: Color(0xFF96CBFF)),
                          ),
                          const SizedBox(width: 10),
                          const Expanded(
                            child: Text(
                              '确认支付',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          InkWell(
                            borderRadius: BorderRadius.circular(99),
                            onTap: () => Navigator.of(dialogContext).pop(),
                            child: const Padding(
                              padding: EdgeInsets.all(4),
                              child: Icon(Icons.close_rounded, color: Colors.white60, size: 20),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.06),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
                        ),
                        child: Column(
                          children: [
                            _buildOrderDetailRow('订单号', orderNo ?? '--'),
                            const SizedBox(height: 2),
                            _buildOrderDetailRow('流量包', packageItem),
                            const SizedBox(height: 2),
                            _buildOrderDetailRow('付款金额', displayAmount),
                            const SizedBox(height: 2),
                            _buildOrderDetailRow('创建时间', createdAt == null ? '--' : _formatOrderTime(createdAt)),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          const Text(
                            '时长',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: Row(
                                children: orderTypes.map((type) {
                                  final selected = selectedOrderType == type;
                                  return Padding(
                                    padding: const EdgeInsets.only(left: 2),
                                    child: InkWell(
                                      borderRadius: BorderRadius.circular(999),
                                      onTap: () => setDialogState(() => selectedOrderType = type),
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: selected
                                              ? const Color(0xFF96CBFF).withValues(alpha: 0.18)
                                              : Colors.white.withValues(alpha: 0.05),
                                          borderRadius: BorderRadius.circular(999),
                                          border: Border.all(
                                            color: selected
                                                ? const Color(0xFF96CBFF)
                                                : Colors.white.withValues(alpha: 0.1),
                                          ),
                                        ),
                                        child: Text(
                                          type,
                                          style: TextStyle(
                                            color: selected ? const Color(0xFF96CBFF) : Colors.white70,
                                            fontSize: 13,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                    ),
                                  );
                                }).toList(),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      const Text(
                        '选择支付方式',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      if (paymentMethods.isEmpty)
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.05),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Text(
                            '暂无可用支付方式',
                            style: TextStyle(color: Colors.white54, fontSize: 12),
                          ),
                        )
                      else
                        Container(
                          constraints: const BoxConstraints(maxHeight: 160),
                          child: ListView.builder(
                            shrinkWrap: true,
                            padding: EdgeInsets.zero,
                            itemCount: paymentMethods.length,
                            itemBuilder: (context, index) {
                              final method = paymentMethods[index];
                              final selected = selectedMethodId == method.id;
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(11),
                                  onTap: () => setDialogState(() => selectedMethodId = method.id),
                                  child: Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                                    decoration: BoxDecoration(
                                      color: selected
                                          ? const Color(0xFF96CBFF).withValues(alpha: 0.18)
                                          : Colors.white.withValues(alpha: 0.05),
                                      borderRadius: BorderRadius.circular(11),
                                      border: Border.all(
                                        color: selected
                                            ? const Color(0xFF96CBFF)
                                            : Colors.white.withValues(alpha: 0.1),
                                      ),
                                    ),
                                    child: Row(
                                      children: [
                                        Icon(iconFor(method.name), color: const Color(0xFF96CBFF), size: 18),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text(
                                            method.name,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 12,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ),
                                        Icon(
                                          selected ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                                          color: selected ? const Color(0xFF96CBFF) : Colors.white30,
                                          size: 17,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: isPaying ? null : () => Navigator.of(dialogContext).pop(),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.white70,
                                side: BorderSide(color: Colors.white.withValues(alpha: 0.22)),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                padding: const EdgeInsets.symmetric(vertical: 12),
                              ),
                              child: const Text('取消'),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            flex: 2,
                            child: ElevatedButton(
                              onPressed: selectedMethodId == null || isPaying || orderNo == null || orderNo.isEmpty
                                  ? null
                                  : () async {
                                      final selected = paymentMethods.firstWhere((e) => e.id == selectedMethodId);
                                      setDialogState(() => isPaying = true);
                                      final checkoutResult = await ApiService().checkoutOrder(
                                        method: selected.id.toString(),
                                        tradeNo: orderNo,
                                        type: selectedOrderType,
                                      );
                                      if (!dialogContext.mounted) return;
                                      setDialogState(() => isPaying = false);

                                      if (!checkoutResult.isSuccess || checkoutResult.payUrl == null) {
                                        await _showTipDialog(
                                          title: '支付发起失败',
                                          message: checkoutResult.msg,
                                          isError: true,
                                        );
                                        return;
                                      }

                                      final payUri = Uri.tryParse(checkoutResult.payUrl!);
                                      if (payUri == null) {
                                        await _showTipDialog(
                                          title: '支付发起失败',
                                          message: '支付地址无效',
                                          isError: true,
                                        );
                                        return;
                                      }

                                      if (checkoutResult.needClientQrcode == 1) {
                                        final shouldOpenBrowser = await _showPaymentQrDialog(
                                          payUrl: checkoutResult.payUrl!,
                                          paymentMethodName: selected.name,
                                        );
                                        if (!dialogContext.mounted) return;
                                        if (!shouldOpenBrowser) {
                                          return;
                                        }
                                      }

                                      final opened = await launchUrl(payUri, mode: LaunchMode.externalApplication);
                                      if (!dialogContext.mounted) return;
                                      if (!opened) {
                                        await _showTipDialog(
                                          title: '打开支付页面失败',
                                          message: '请稍后重试',
                                          isError: true,
                                        );
                                        return;
                                      }

                                      Navigator.of(dialogContext).pop();
                                      await _showPayingAndWatchOrder(
                                        orderNo,
                                        onPaid: onPaid,
                                      );
                                    },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF1EB980),
                                foregroundColor: Colors.white,
                                disabledBackgroundColor: Colors.white24,
                                disabledForegroundColor: Colors.white54,
                                elevation: 0,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                padding: const EdgeInsets.symmetric(vertical: 12),
                              ),
                              child: isPaying
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2.2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Text(
                                      '立即支付',
                                      style: TextStyle(fontWeight: FontWeight.w800),
                                    ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildOrderDetailRow(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 62,
          child: Text(
            '$label：',
            style: const TextStyle(
              color: Colors.white54,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }

  String _formatOrderTime(DateTime time) {
    return "${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')} ${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}";
  }

  Future<bool> _showPaymentQrDialog({
    required String payUrl,
    required String paymentMethodName,
  }) async {
    final normalizedMethod = paymentMethodName.toLowerCase();
    final isWeChat = paymentMethodName.contains('微信') || normalizedMethod.contains('wechat');
    final isAlipay = paymentMethodName.contains('支付宝') || normalizedMethod.contains('alipay');
    final themePrimaryColor = isWeChat
        ? const Color(0xFF09C562)
        : isAlipay
            ? const Color(0xFF1677FF)
            : const Color(0xFF11C988);
    final themeAccentColor = isWeChat
        ? const Color(0xFF5EE68E)
        : isAlipay
            ? const Color(0xFF6EB0FF)
            : const Color(0xFF96CBFF);
    final titleText = isWeChat
        ? '微信扫码付款'
        : isAlipay
            ? '支付宝扫码付款'
            : '扫码付款';
    final payHintText = isWeChat
        ? '打开微信APP扫码付款'
        : isAlipay
            ? '打开支付宝APP扫码付款'
            : '打开支付宝/ 微信APP扫码付款';
    final payIcon = isWeChat
        ? Icons.wechat_rounded
        : isAlipay
            ? Icons.account_balance_wallet_rounded
            : Icons.qr_code_2_rounded;
    final shouldOpenBrowser = await showAnimatedDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) {
        final media = MediaQuery.of(dialogContext);
        final isCompact = media.size.height < 760 || media.size.width < 390;
        final qrSizeByWidth = (media.size.width - 120).clamp(160.0, 220.0).toDouble();
        final qrSizeByHeight = (media.size.height * 0.30).clamp(150.0, 220.0).toDouble();
        final qrSize = qrSizeByWidth < qrSizeByHeight ? qrSizeByWidth : qrSizeByHeight;
        final qrCornerSize = isCompact ? 18.0 : 22.0;
        final titleFontSize = isCompact ? 18.0 : 24.0;
        final hintFontSize = isCompact ? 15.0 : 18.0;
        final subHintFontSize = isCompact ? 11.0 : 12.0;
        final buttonFontSize = isCompact ? 14.0 : 16.0;
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: EdgeInsets.symmetric(
            horizontal: isCompact ? 12 : 20,
            vertical: isCompact ? 12 : 24,
          ),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 420),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Color.alphaBlend(themePrimaryColor.withValues(alpha: 0.22), const Color(0xFF1D3650)),
                  const Color(0xFF13283B),
                ],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: themeAccentColor, width: 1.1),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.35),
                  blurRadius: 24,
                  offset: const Offset(0, 12),
                ),
              ],
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: media.size.height * 0.86),
              child: SingleChildScrollView(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(isCompact ? 14 : 18, 14, isCompact ? 14 : 18, 14),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: isCompact ? 30 : 34,
                            height: isCompact ? 30 : 34,
                            decoration: BoxDecoration(
                              color: themeAccentColor.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Icon(payIcon, color: themeAccentColor, size: isCompact ? 19 : 22),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              titleText,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: titleFontSize,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          InkWell(
                            borderRadius: BorderRadius.circular(99),
                            onTap: () => Navigator.of(dialogContext).pop(false),
                            child: const Padding(
                              padding: EdgeInsets.all(4),
                              child: Icon(Icons.close_rounded, color: Colors.white60, size: 20),
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: isCompact ? 10 : 14),
                      Container(
                        padding: EdgeInsets.all(isCompact ? 8 : 12),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(14),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.16),
                              blurRadius: 12,
                              offset: const Offset(0, 6),
                            ),
                          ],
                        ),
                        child: Stack(
                          children: [
                            QrImageView(
                              data: payUrl,
                              size: qrSize,
                              backgroundColor: Colors.white,
                              eyeStyle: const QrEyeStyle(
                                eyeShape: QrEyeShape.square,
                                color: Colors.black,
                              ),
                              dataModuleStyle: const QrDataModuleStyle(
                                dataModuleShape: QrDataModuleShape.square,
                                color: Colors.black,
                              ),
                            ),
                            Positioned(
                              left: 0,
                              top: 0,
                              child: Container(
                                width: qrCornerSize,
                                height: qrCornerSize,
                                decoration: BoxDecoration(
                                  border: Border(
                                    left: BorderSide(color: themePrimaryColor, width: 3),
                                    top: BorderSide(color: themePrimaryColor, width: 3),
                                  ),
                                ),
                              ),
                            ),
                            Positioned(
                              right: 0,
                              top: 0,
                              child: Container(
                                width: qrCornerSize,
                                height: qrCornerSize,
                                decoration: BoxDecoration(
                                  border: Border(
                                    right: BorderSide(color: themePrimaryColor, width: 3),
                                    top: BorderSide(color: themePrimaryColor, width: 3),
                                  ),
                                ),
                              ),
                            ),
                            Positioned(
                              left: 0,
                              bottom: 0,
                              child: Container(
                                width: qrCornerSize,
                                height: qrCornerSize,
                                decoration: BoxDecoration(
                                  border: Border(
                                    left: BorderSide(color: themePrimaryColor, width: 3),
                                    bottom: BorderSide(color: themePrimaryColor, width: 3),
                                  ),
                                ),
                              ),
                            ),
                            Positioned(
                              right: 0,
                              bottom: 0,
                              child: Container(
                                width: qrCornerSize,
                                height: qrCornerSize,
                                decoration: BoxDecoration(
                                  border: Border(
                                    right: BorderSide(color: themePrimaryColor, width: 3),
                                    bottom: BorderSide(color: themePrimaryColor, width: 3),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(height: isCompact ? 10 : 12),
                      Text(
                        payHintText,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: hintFontSize,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '如无法扫码，可继续在浏览器内完成支付',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.72),
                          fontSize: subHintFontSize,
                        ),
                      ),
                      SizedBox(height: isCompact ? 10 : 14),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () => Navigator.of(dialogContext).pop(false),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.white70,
                                side: BorderSide(color: Colors.white.withValues(alpha: 0.22)),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                padding: EdgeInsets.symmetric(vertical: isCompact ? 11 : 13),
                              ),
                              child: Text(
                                '取消',
                                style: TextStyle(fontWeight: FontWeight.w700, fontSize: buttonFontSize),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            flex: 2,
                            child: ElevatedButton(
                              onPressed: () => Navigator.of(dialogContext).pop(true),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: themePrimaryColor,
                                foregroundColor: Colors.white,
                                elevation: 0,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                padding: EdgeInsets.symmetric(vertical: isCompact ? 11 : 13),
                              ),
                              child: Text(
                                '继续打开浏览器',
                                style: TextStyle(fontWeight: FontWeight.w800, fontSize: buttonFontSize),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
    return shouldOpenBrowser == true;
  }

  Future<void> _showTipDialog({
    required String title,
    required String message,
    bool isError = false,
    VoidCallback? onClosed,
  }) async {
    await showAnimatedDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: AppColors.cardBackground,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: const BorderSide(color: Color(0xFF96CBFF), width: 1.1),
          ),
          titlePadding: const EdgeInsets.fromLTRB(20, 16, 8, 0),
          title: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                ),
              ),
              IconButton(
                onPressed: () {
                  Navigator.of(dialogContext).pop();
                  onClosed?.call();
                },
                icon: const Icon(Icons.close_rounded, color: Colors.white60, size: 20),
              ),
            ],
          ),
          content: Text(
            message,
            style: const TextStyle(color: Colors.white70, fontSize: 14),
          ),
        );
      },
    );
  }

  Future<void> _showPayingAndWatchOrder(String tradeNo, {VoidCallback? onPaid}) async {
    await showAnimatedDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        var started = false;

        Future<void> watchOrder() async {
          for (var i = 0; i < 60; i++) {
            final statusResult = await ApiService().queryOrderStatus(tradeNo: tradeNo);
            if (!mounted || !dialogContext.mounted) return;
            if (!statusResult.isSuccess) {
              Navigator.of(dialogContext).pop();
              await _showTipDialog(
                title: '查询失败',
                message: statusResult.msg,
                isError: true,
              );
              return;
            }

            final status = statusResult.status;
            if (status == 1) {
              Navigator.of(dialogContext).pop();
              onPaid?.call();
              await _showTipDialog(
                title: '购买成功',
                message: '支付成功，流量包已叠加',
              );
              return;
            }
            if (status == 2) {
              Navigator.of(dialogContext).pop();
              await _showTipDialog(
                title: '订单已过期',
                message: '订单已过期，请重新发起购买',
                isError: true,
              );
              return;
            }
            await Future.delayed(const Duration(seconds: 2));
          }

          if (!mounted || !dialogContext.mounted) return;
          Navigator.of(dialogContext).pop();
          await _showTipDialog(
            title: '支付中',
            message: '暂未确认支付成功，请稍后在订单中查看状态',
          );
        }

        if (!started) {
          started = true;
          Future.microtask(watchOrder);
        }

        return AlertDialog(
          backgroundColor: AppColors.cardBackground,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: const BorderSide(color: Color(0xFF96CBFF), width: 1.1),
          ),
          titlePadding: const EdgeInsets.fromLTRB(20, 16, 8, 0),
          title: Row(
            children: [
              const Expanded(
                child: Text(
                  '支付中',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                ),
              ),
              IconButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                icon: const Icon(Icons.close_rounded, color: Colors.white60, size: 20),
              ),
            ],
          ),
          content: const Row(
            children: [
              SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2.2,
                  color: Color(0xFF96CBFF),
                ),
              ),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  '请在浏览器完成支付，正在查询订单状态...',
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
