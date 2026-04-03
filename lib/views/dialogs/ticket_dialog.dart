import 'dart:async';

import 'package:app/core/constants.dart';
import 'package:app/services/api_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

class TicketDialog {
  static Future<void> show(BuildContext context) {
    return showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'ticket_dialog',
      barrierColor: Colors.black.withValues(alpha: 0.25),
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (dialogContext, animation, secondaryAnimation) {
        return const _TicketDialogContent();
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

class _TicketDialogContent extends StatefulWidget {
  const _TicketDialogContent();

  @override
  State<_TicketDialogContent> createState() => _TicketDialogContentState();
}

class _TicketDialogContentState extends State<_TicketDialogContent>
    with WidgetsBindingObserver {
  static const List<String> _quickMessages = ['人工客服', '独享节点', '投诉', '未到账'];
  static const Duration _pollInterval = Duration(seconds: 3);

  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  Timer? _pollTimer;
  bool _isPolling = false;
  bool _isPollInFlight = false;
  List<TicketMessage> _messages = const [];
  TicketStatusInfo? _status;
  bool _isLoading = true;
  bool _isSending = false;
  bool _isClosingTicket = false;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadMessages();
    _startPolling();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopPolling();
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _startPolling();
      return;
    }
    _stopPolling();
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).padding.bottom;
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
                      children: [
                        const SizedBox(height: 10),
                        _buildStatusBanner(),
                        const SizedBox(height: 12),
                        Expanded(child: _buildMessageArea()),
                        const SizedBox(height: 10),
                        _buildQuickMessages(),
                        const SizedBox(height: 10),
                        _buildInputBar(bottomInset),
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

  Widget _buildStatusBanner() {
    final statusText = _statusText(_status?.status);
    final subText = _statusSubText(_status);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
      ),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: _statusColor(_status?.status),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  statusText,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (subText.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 0),
                    child: Text(
                      subText,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (_canCloseTicket)
            TextButton(
              onPressed: _isClosingTicket ? null : _closeTicket,
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFF96CBFF),
                padding: const EdgeInsets.symmetric(horizontal: 5),
              ),
              child: _isClosingTicket
                  ? const SizedBox(
                      width: 10,
                      height: 10,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Color(0xFF96CBFF),
                      ),
                    )
                  : const Text(
                      '结束',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                      ),
                    ),
            ),
        ],
      ),
    );
  }

  Widget _buildMessageArea() {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(
          strokeWidth: 2.2,
          color: Color(0xFF96CBFF),
        ),
      );
    }
    if (_errorText != null && _messages.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Text(
            _errorText!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
        ),
      );
    }
    if (_messages.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 24),
          child: Text(
            '发送“人工客服”或“人工”即可开始接入人工服务',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white70, fontSize: 14, height: 1.6),
          ),
        ),
      );
    }
    return ListView.separated(
      controller: _scrollController,
      padding: const EdgeInsets.only(top: 8, bottom: 8),
      itemCount: _messages.length,
      separatorBuilder: (context, index) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final message = _messages[index];
        if (message.sender == 'system') {
          return Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                message.content,
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ),
          );
        }

        final isUser = message.sender == 'user';
        return Align(
          alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 280),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: isUser
                    ? const Color(0xFF96CBFF)
                    : Colors.white.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(12),
                border: isUser
                    ? null
                    : Border.all(color: Colors.white.withValues(alpha: 0.12)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    message.content,
                    style: TextStyle(
                      color: isUser ? Colors.black : Colors.white,
                      fontSize: 13,
                      height: 1.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (message.createTime.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 0),
                      child: Text(
                        _formatMessageTime(message.createTime),
                        style: TextStyle(
                          color: isUser
                              ? Colors.black.withValues(alpha: 0.55)
                              : Colors.white54,
                          fontSize: 11,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildQuickMessages() {
    return Align(
      alignment: Alignment.centerLeft,
      child: Wrap(
        spacing: 2,
        runSpacing: 2,
        children: _quickMessages.map((item) {
          return Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: _isSending ? null : () => _sendMessage(item),
              borderRadius: BorderRadius.circular(10),
              child: Ink(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                decoration: BoxDecoration(
                  color: _isSending
                      ? Colors.white.withValues(alpha: 0.06)
                      : Colors.white.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: Colors.white.withValues(
                      alpha: _isSending ? 0.08 : 0.18,
                    ),
                  ),
                ),
                child: Text(
                  item,
                  style: TextStyle(
                    color: _isSending
                        ? Colors.white.withValues(alpha: 0.45)
                        : Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildInputBar(double bottomInset) {
    final canSend = _controller.text.trim().isNotEmpty && !_isSending;
    return Padding(
      padding: EdgeInsets.only(bottom: 30),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: _controller,
              minLines: 1,
              maxLines: 4,
              enabled: !_isSending,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) {
                if (canSend) {
                  _sendMessage(_controller.text);
                }
              },
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration: InputDecoration(
                hintText: '输入消息...',
                hintStyle: const TextStyle(color: Colors.white38),
                filled: true,
                fillColor: Colors.white.withValues(alpha: 0.09),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(
                    color: Colors.white.withValues(alpha: 0.18),
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
          const SizedBox(width: 5),
          SizedBox(
            width: 48,
            height: 48,
            child: ElevatedButton(
              onPressed: canSend ? () => _sendMessage(_controller.text) : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF96CBFF),
                foregroundColor: Colors.black,
                disabledBackgroundColor: Colors.white.withValues(alpha: 0.12),
                disabledForegroundColor: Colors.white.withValues(alpha: 0.35),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                padding: EdgeInsets.zero,
                elevation: 0,
              ),
              child: _isSending
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.2,
                        color: Colors.black87,
                      ),
                    )
                  : const Text(
                      '发送',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _loadMessages({bool showLoading = true}) async {
    if (showLoading && mounted) {
      setState(() {
        _isLoading = true;
        _errorText = null;
      });
    }

    final result = await ApiService().fetchTicketMessages();
    if (!mounted) return;

    if (!result.isSuccess) {
      final statusResult = await ApiService().fetchTicketStatus();
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorText = result.msg;
        _status = statusResult.data ?? _status;
      });
      return;
    }

    setState(() {
      _isLoading = false;
      _errorText = null;
      _messages = _mergeMessages(result.messages, result.status);
      _status = result.status ?? _status;
    });
    _scrollToBottom();
  }

  void _startPolling() {
    if (_isPolling) {
      return;
    }
    _isPolling = true;
    AppPollingTaskRegistry.instance.registerTask(
      id: 'ticket_dialog_polling',
      interval: _pollInterval,
      initialDelay: _pollInterval,
      owner: 'ticket_dialog',
      active: true,
    );
    _scheduleNextPoll();
  }

  void _stopPolling() {
    _isPolling = false;
    AppPollingTaskRegistry.instance.setTaskActive('ticket_dialog_polling', false);
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  void _scheduleNextPoll() {
    _pollTimer?.cancel();
    if (!_isPolling) {
      return;
    }
    AppPollingTaskRegistry.instance.registerTask(
      id: 'ticket_dialog_polling',
      interval: _pollInterval,
      initialDelay: _pollInterval,
      owner: 'ticket_dialog',
      active: true,
    );
    _pollTimer = Timer(_pollInterval, () async {
      await _pollMessages();
      if (_isPolling) {
        _scheduleNextPoll();
      }
    });
  }

  Future<void> _pollMessages() async {
    if (!_isPolling || _isPollInFlight) {
      return;
    }
    _isPollInFlight = true;
    try {
      AppPollingTaskRegistry.instance.markTaskExecuted('ticket_dialog_polling');
      await _loadMessages(showLoading: false);
    } finally {
      _isPollInFlight = false;
    }
  }

  Future<void> _sendMessage(String value) async {
    final text = value.trim();
    if (text.isEmpty || _isSending) return;
    FocusScope.of(context).unfocus();
    setState(() => _isSending = true);

    final result = await ApiService().sendTicketMessage(message: text);
    if (!mounted) return;

    if (!result.isSuccess) {
      setState(() => _isSending = false);
      _showTip(result.msg);
      return;
    }

    _controller.clear();
    setState(() => _isSending = false);
    await _loadMessages(showLoading: false);
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  void _showTip(String message) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  Color _statusColor(String? status) {
    if (_status?.isClosed == true) return Colors.white54;
    if (_status?.isActive == true) return const Color(0xFF1EB980);
    switch (status) {
      case 'active':
        return const Color(0xFF1EB980);
      case 'queued':
        return const Color(0xFFFFC857);
      case 'closed':
        return Colors.white54;
      case 'idle':
      default:
        return const Color(0xFF96CBFF);
    }
  }

  String _statusText(String? status) {
    if (_status?.isClosed == true) return '工单已结束';
    if (_status?.isActive == true) return '已接入人工客服';
    switch (status) {
      case 'active':
        return '已接入人工客服';
      case 'queued':
        return '排队中';
      case 'closed':
        return '工单已结束';
      case 'idle':
      default:
        return '等待发起人工服务';
    }
  }

  String _statusSubText(TicketStatusInfo? status) {
    if (status == null) {
      return '发送“人工客服”或“人工”即可开始';
    }
    if (status.isClosed) {
      return '当前会话已结束，如需继续处理可重新发送消息';
    }
    if (status.latestAdminMessage != null) {
      return status.latestAdminMessage!.content;
    }
    if (status.isActive) {
      return '人工客服已接入，请直接发送问题';
    }
    switch (status.status) {
      case 'queued':
        return '前方还有 ${status.queueAhead} 人，当前排队 ${status.waitingUser} 人';
      case 'active':
        return '人工客服已接入，请直接发送问题';
      case 'closed':
        return '如需继续处理，可再次发送消息';
      case 'idle':
      default:
        return '发送“人工客服”或“人工”即可开始';
    }
  }

  String _formatMessageTime(String value) {
    try {
      final parsed = DateTime.parse(value).toLocal();
      final month = parsed.month.toString().padLeft(2, '0');
      final day = parsed.day.toString().padLeft(2, '0');
      final hour = parsed.hour.toString().padLeft(2, '0');
      final minute = parsed.minute.toString().padLeft(2, '0');
      return '$month-$day $hour:$minute';
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

  bool get _canCloseTicket {
    final status = _status;
    if (status == null) return false;
    if (status.isClosed) return false;
    return status.isActive || status.status == 'queued';
  }

  List<TicketMessage> _mergeMessages(
    List<TicketMessage> messages,
    TicketStatusInfo? status,
  ) {
    final merged = List<TicketMessage>.from(messages);
    final latestAdminMessage = status?.latestAdminMessage;
    if (latestAdminMessage != null) {
      final exists = merged.any((item) {
        if (latestAdminMessage.seq != null && item.seq != null) {
          return item.seq == latestAdminMessage.seq;
        }
        return item.sender == latestAdminMessage.sender &&
            item.content == latestAdminMessage.content &&
            item.createTime == latestAdminMessage.createTime;
      });
      if (!exists) {
        merged.add(latestAdminMessage);
      }
    }
    merged.sort((a, b) {
      final aSeq = a.seq ?? -1;
      final bSeq = b.seq ?? -1;
      return aSeq.compareTo(bSeq);
    });
    return merged;
  }

  Future<void> _closeTicket() async {
    if (_isClosingTicket) return;
    setState(() => _isClosingTicket = true);
    final result = await ApiService().closeTicket();
    if (!mounted) return;
    setState(() => _isClosingTicket = false);
    if (!result.isSuccess) {
      _showTip(result.msg);
      return;
    }
    _showTip(result.msg);
    await _loadMessages(showLoading: false);
  }
}
