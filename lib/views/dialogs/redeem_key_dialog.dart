import 'package:app/core/constants.dart';
import 'package:app/core/utils.dart';
import 'package:app/services/api_service.dart';
import 'package:app/views/widgets/custom_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

class RedeemKeyDialog {
  static Future<void> show(
    BuildContext context, {
    Future<void> Function()? onRedeemed,
  }) {
    return showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'redeem_key',
      barrierColor: Colors.black.withValues(alpha: 0.25),
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (dialogContext, animation, secondaryAnimation) {
        return _RedeemKeyDialogContent(
          hostContext: context,
          onRedeemed: onRedeemed,
        );
      },
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
        );
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

class _RedeemKeyDialogContent extends StatefulWidget {
  final BuildContext hostContext;
  final Future<void> Function()? onRedeemed;

  const _RedeemKeyDialogContent({required this.hostContext, this.onRedeemed});

  @override
  State<_RedeemKeyDialogContent> createState() =>
      _RedeemKeyDialogContentState();
}

class _RedeemKeyDialogContentState extends State<_RedeemKeyDialogContent> {
  final TextEditingController _controller = TextEditingController();
  bool _isSubmitting = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canRedeem = _controller.text.trim().isNotEmpty;
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
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      GestureDetector(
                        onTap: () => Navigator.of(context).pop(),
                        child: SvgPicture.asset(
                          AppAssets.icClose,
                          width: 24,
                          height: 24,
                          colorFilter: const ColorFilter.mode(
                            Colors.white,
                            BlendMode.srcIn,
                          ),
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
                      const SizedBox(width: 24, height: 24),
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
                            '兑换礼品卡密',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 22,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        const SizedBox(height: 9),
                        const SizedBox(
                          width: double.infinity,
                          child: Text(
                            '输入礼品卡密兑换流量包，兑换成功后流量实时到账，立即生效使用',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                              height: 1.5,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _controller,
                                enabled: !_isSubmitting,
                                onChanged: (_) => setState(() {}),
                                style: const TextStyle(color: Colors.white, fontSize: 14),
                                decoration: InputDecoration(
                                  hintText: '礼品卡密',
                                  hintStyle: const TextStyle(
                                    color: Colors.white38,
                                  ),
                                  filled: true,
                                  fillColor: Colors.white.withValues(
                                    alpha: 0.09,
                                  ),
                                  enabledBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(12),
                                    borderSide: BorderSide(
                                      color: Colors.white.withValues(
                                        alpha: 0.24,
                                      ),
                                    ),
                                  ),
                                  focusedBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(12),
                                    borderSide: const BorderSide(
                                      color: Color(0xFF96CBFF),
                                      width: 1.2,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            SizedBox(
                              width: 33,
                              height: 48,
                              child: OutlinedButton.icon(
                                onPressed: _isSubmitting
                                    ? null
                                    : _fillClipboardText,
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: const Color(0xFF96CBFF),
                                  side: const BorderSide(
                                    color: Color(0xFF96CBFF),
                                    width: 1,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                  ),
                                ),
                                label: const Text('粘贴'),
                              ),
                            ),
                          ],
                        ),
                        const Spacer(),
                        Padding(
                          padding: EdgeInsets.only(bottom: 30),
                          child: SizedBox(
                            width: double.infinity,
                            child: ElevatedButton(
                              onPressed: _isSubmitting || !canRedeem
                                  ? null
                                  : _submit,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF96CBFF),
                                foregroundColor: Colors.black,
                                disabledBackgroundColor: const Color(
                                  0xFF96CBFF,
                                ).withValues(alpha: 0.7),
                                disabledForegroundColor: Colors.black54,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                padding: const EdgeInsets.symmetric(
                                  vertical: 14,
                                ),
                                elevation: 0,
                              ),
                              child: _isSubmitting
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2.2,
                                        color: Colors.black87,
                                      ),
                                    )
                                  : const Text(
                                      '立即兑换',
                                      style: TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.w700,
                                        color: Colors.black,
                                      ),
                                    ),
                            ),
                          ),
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

  Future<void> _fillClipboardText() async {
    final clipData = await Clipboard.getData('text/plain');
    final text = clipData?.text?.trim() ?? '';
    if (text.isEmpty || !mounted) return;
    _controller.text = text;
    _controller.selection = TextSelection.fromPosition(
      TextPosition(offset: _controller.text.length),
    );
    setState(() {});
  }

  Future<void> _submit() async {
    final key = _controller.text.trim();
    if (key.isEmpty) {
      await _showTipDialog(
        context: context,
        title: '兑换失败',
        message: '卡密不能为空',
        isError: true,
      );
      return;
    }

    setState(() => _isSubmitting = true);
    final result = await ApiService().redeemAgentKey(key: key);
    if (!mounted) return;

    if (!result.isSuccess) {
      setState(() => _isSubmitting = false);
      await _showTipDialog(
        context: context,
        title: '兑换失败',
        message: result.msg,
        isError: true,
      );
      return;
    }

    try {
      await widget.onRedeemed?.call();
    } catch (_) {}

    if (!mounted) return;
    final successMessage = _buildSuccessMessage(result);
    Navigator.of(context).pop();
    if (!widget.hostContext.mounted) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    if (!widget.hostContext.mounted) return;
    await _showTipDialog(
      context: widget.hostContext,
      title: '兑换成功',
      message: successMessage,
    );
  }

  String _buildSuccessMessage(AgentKeyRedeemResult result) {
    final details = <String>[
      if (result.trafficQuota != null) '流量：${formatBytes(result.trafficQuota)}',
      if (result.validDays != null) '期限：${result.validDays}天',
      if (result.usedTime != null && result.usedTime!.isNotEmpty)
        '时间：${_formatUsedTime(result.usedTime!)}',
    ];
    if (details.isEmpty) return result.msg;
    return details.join('\n');
  }

  String _formatUsedTime(String value) {
    try {
      final parsed = DateTime.parse(value).toLocal();
      final year = parsed.year.toString().padLeft(4, '0');
      final month = parsed.month.toString().padLeft(2, '0');
      final day = parsed.day.toString().padLeft(2, '0');
      final hour = parsed.hour.toString().padLeft(2, '0');
      final minute = parsed.minute.toString().padLeft(2, '0');
      final second = parsed.second.toString().padLeft(2, '0');
      return '$year-$month-$day $hour:$minute:$second';
    } catch (_) {
      final normalized = value.replaceFirst('T', ' ');
      final timezoneIndex = normalized.indexOf('+');
      if (timezoneIndex > 0) {
        return normalized.substring(0, timezoneIndex);
      }
      final zIndex = normalized.indexOf('Z');
      if (zIndex > 0) {
        return normalized.substring(0, zIndex);
      }
      return normalized;
    }
  }

  Future<void> _showTipDialog({
    required BuildContext context,
    required String title,
    required String message,
    bool isError = false,
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
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              IconButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                icon: const Icon(
                  Icons.close_rounded,
                  color: Colors.white60,
                  size: 20,
                ),
              ),
            ],
          ),
          content: Text(
            message,
            style: const TextStyle(color: Colors.white70, fontSize: 14),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(
                '确定',
                style: TextStyle(
                  color: isError ? Colors.redAccent : const Color(0xFF96CBFF),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
