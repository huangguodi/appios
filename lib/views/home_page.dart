import 'dart:async';
import 'dart:io';

import 'package:app/services/api_service.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:image/image.dart' as img;
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zxing2/qrcode.dart' as zxing;
import 'package:app/core/constants.dart';
import 'package:app/core/utils.dart';
import 'package:app/view_models/home_view_model.dart';
import 'package:app/views/dialogs/ticket_dialog.dart';
import 'package:app/views/widgets/traffic_panel.dart';
import 'package:app/views/widgets/mode_switch.dart';
import 'package:app/views/widgets/node_selector.dart';
import 'package:app/views/dialogs/traffic_purchase_dialog.dart';
import 'package:app/views/widgets/custom_dialog.dart';

class HomePage extends StatelessWidget {
  final ConnectionMode initialMode;

  const HomePage({super.key, this.initialMode = ConnectionMode.off});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => HomeViewModel(initialMode: initialMode)..init(),
      child: const _HomePageContent(),
    );
  }
}

class _HomePageContent extends StatefulWidget {
  const _HomePageContent();

  @override
  State<_HomePageContent> createState() => _HomePageContentState();
}

class _HomePageContentState extends State<_HomePageContent>
    with WidgetsBindingObserver {
  bool _showingExpiredTrafficDialog = false;
  bool _didPrecacheHomeAssets = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final vm = context.read<HomeViewModel>();
    if (state == AppLifecycleState.resumed) {
      vm.onAppResumed();
    } else if (state == AppLifecycleState.paused) {
      vm.onAppPaused();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_didPrecacheHomeAssets) {
      return;
    }
    _didPrecacheHomeAssets = true;
    precacheImage(
      AssetImage(AppAssets.resolveImage(context, 'gradient.png')),
      context,
    );
    precacheImage(
      AssetImage(AppAssets.resolveImage(context, 'gradient1.png')),
      context,
    );
    precacheImage(
      AssetImage(AppAssets.resolveImage(context, 'gradient2.png')),
      context,
    );
    precacheImage(
      AssetImage(AppAssets.resolveImage(context, 'gradient3.png')),
      context,
    );
    precacheImage(
      AssetImage(AppAssets.resolveImage(context, 'logo.png')),
      context,
    );
  }

  String _getBackgroundImage(BuildContext context, ConnectionMode mode) {
    switch (mode) {
      case ConnectionMode.off:
        return AppAssets.resolveImage(context, 'gradient.png');
      case ConnectionMode.smart:
        return AppAssets.resolveImage(context, 'gradient1.png');
      case ConnectionMode.global:
        return AppAssets.resolveImage(context, 'gradient2.png');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Stack(
        children: [
          Positioned.fill(
            child: RepaintBoundary(
              child: Selector<HomeViewModel, ConnectionMode>(
                selector: (_, vm) => vm.connectionMode,
                builder: (context, connectionMode, child) {
                  final backgroundImage = _getBackgroundImage(
                    context,
                    connectionMode,
                  );
                  return AnimatedSwitcher(
                    duration: const Duration(milliseconds: 500),
                    transitionBuilder:
                        (Widget child, Animation<double> animation) {
                          return FadeTransition(
                            opacity: animation,
                            child: child,
                          );
                        },
                    child: Image.asset(
                      backgroundImage,
                      key: ValueKey<String>(backgroundImage),
                      fit: BoxFit.cover,
                      width: double.infinity,
                      height: double.infinity,
                      gaplessPlayback: true,
                      errorBuilder: (context, error, stackTrace) =>
                          Container(color: AppColors.background),
                    ),
                  );
                },
              ),
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                RepaintBoundary(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 10,
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 76,
                          child: Align(
                            alignment: Alignment.topLeft,
                            child: Padding(
                              padding: const EdgeInsets.only(top: 12.0),
                              child: GestureDetector(
                                onTap: () => TicketDialog.show(context),
                                child: SvgPicture.asset(
                                  AppAssets.icSupport,
                                  width: 24,
                                  height: 24,
                                  colorFilter: const ColorFilter.mode(
                                    Color.fromARGB(255, 255, 255, 255),
                                    BlendMode.srcIn,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(top: 15.0),
                          child: Hero(
                            tag: 'app_logo',
                            flightShuttleBuilder:
                                (
                                  BuildContext flightContext,
                                  Animation<double> animation,
                                  HeroFlightDirection flightDirection,
                                  BuildContext fromHeroContext,
                                  BuildContext toHeroContext,
                                ) {
                                  return Material(
                                    color: Colors.transparent,
                                    child: Image.asset(
                                      AppAssets.resolveImage(
                                        context,
                                        'logo.png',
                                      ),
                                      fit: BoxFit.contain,
                                    ),
                                  );
                                },
                            child: Material(
                              color: Colors.transparent,
                              child: Image.asset(
                                AppAssets.resolveImage(context, 'logo.png'),
                                width: 40,
                                height: 40,
                              ),
                            ),
                          ),
                        ),
                        SizedBox(
                          width: 76,
                          child: Padding(
                            padding: const EdgeInsets.only(top: 12.0),
                            child: Selector<HomeViewModel, bool>(
                              selector: (_, vm) => vm.isDeviceBound,
                              builder: (context, isDeviceBound, child) {
                                return Row(
                                  mainAxisAlignment: MainAxisAlignment.end,
                                  children: [
                                    if (!isDeviceBound) ...[
                                      GestureDetector(
                                        onTap:
                                            () => DeviceBindDialog.show(context),
                                        child: SvgPicture.asset(
                                          AppAssets.icQrCode,
                                          width: 24,
                                          height: 24,
                                          colorFilter: const ColorFilter.mode(
                                            Colors.white,
                                            BlendMode.srcIn,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                    ],
                                    GestureDetector(
                                      onTap: () => InviteDialog.show(context),
                                      child: SvgPicture.asset(
                                        AppAssets.icInvite,
                                        width: 24,
                                        height: 24,
                                        colorFilter: const ColorFilter.mode(
                                          Colors.white,
                                          BlendMode.srcIn,
                                        ),
                                      ),
                                    ),
                                  ],
                                );
                              },
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const Spacer(flex: 5),
                Selector<HomeViewModel, ConnectionMode>(
                  selector: (_, vm) => vm.connectionMode,
                  builder: (context, connectionMode, child) {
                    return AnimatedSwitcher(
                      duration: const Duration(milliseconds: 220),
                      child: connectionMode == ConnectionMode.global
                          ? const Padding(
                              key: ValueKey('global-node-button'),
                              padding: EdgeInsets.symmetric(horizontal: 22),
                              child: RepaintBoundary(child: NodeSelector()),
                            )
                          : const SizedBox.shrink(
                              key: ValueKey('global-node-empty'),
                            ),
                    );
                  },
                ),
                const SizedBox(height: 6),
                RepaintBoundary(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    child: TrafficPanel(
                      onPurchaseTap: () => TrafficPurchaseDialog.show(context),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                RepaintBoundary(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Selector<HomeViewModel, (ConnectionMode, bool)>(
                      selector: (_, vm) => (vm.connectionMode, vm.isSwitching),
                      builder: (context, modeState, child) {
                        return ModeSwitch(
                          mode: modeState.$1,
                          isSwitching: modeState.$2,
                          onModeChanged: context.read<HomeViewModel>().setMode,
                        );
                      },
                    ),
                  ),
                ),
                Selector<HomeViewModel, (String, ConnectionMode)>(
                  selector: (_, vm) => (vm.adsSignature, vm.connectionMode),
                  builder: (context, adsState, child) {
                    final ads = context.read<HomeViewModel>().ads;
                    if (ads.isEmpty) {
                      return const SizedBox(height: 20);
                    }
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(height: 6),
                        RepaintBoundary(
                          child: _AdBannerCarousel(
                            ads: ads,
                            mode: adsState.$2,
                            onAdTap: _handleAdTap,
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
          Selector<HomeViewModel, int>(
            selector: (_, vm) => vm.pendingExpiredTrafficLogNoticeCount,
            builder: (context, pendingCount, child) {
              if (!_showingExpiredTrafficDialog && pendingCount > 0) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!mounted) return;
                  _showNextExpiredTrafficDialog(context.read<HomeViewModel>());
                });
              }
              return const SizedBox.shrink();
            },
          ),
          Positioned(
            left: 14,
            bottom: 8,
            child: Selector<HomeViewModel, (String?, String?, bool)>(
              selector: (_, vm) => (
                vm.iosVpnStatusText,
                vm.iosVpnStatusDetail,
                vm.canRetryIosVpnStart,
              ),
              builder: (context, statusState, child) {
                final text = statusState.$1;
                if (text == null || text.isEmpty) {
                  return const SizedBox.shrink();
                }
                final detail = statusState.$2;
                final canRetry = statusState.$3;
                final content = Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      text,
                      style: TextStyle(
                        color: canRetry ? Colors.white70 : Colors.white54,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (detail != null && detail.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 210),
                        child: Text(
                          detail,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 9.5,
                            fontWeight: FontWeight.w400,
                            height: 1.25,
                          ),
                        ),
                      ),
                    ],
                  ],
                );
                if (!canRetry) {
                  return content;
                }
                return GestureDetector(
                  onTap: context.read<HomeViewModel>().retryIosVpnStart,
                  behavior: HitTestBehavior.opaque,
                  child: content,
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _handleAdTap(String linkUrl) async {
    final trimmed = linkUrl.trim();
    if (trimmed.isEmpty || !mounted) return;
    Uri? uri = Uri.tryParse(trimmed);
    if (uri == null || uri.scheme.isEmpty) {
      uri = Uri.tryParse('https://$trimmed');
    }
    if (uri == null || !mounted) {
      _showAdLinkTip('广告链接无效');
      return;
    }

    final scheme = uri.scheme.toLowerCase();
    if (scheme == 'app') {
      await _handleInternalAppLink(uri);
      return;
    }
    final isWebUrl = scheme == 'http' || scheme == 'https';
    final primaryMode = isWebUrl
        ? LaunchMode.externalApplication
        : LaunchMode.externalNonBrowserApplication;

    var opened = await launchUrl(uri, mode: primaryMode);
    if (!opened && !isWebUrl) {
      opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
    if (!opened && mounted) {
      _showAdLinkTip(isWebUrl ? '打开浏览器失败' : '打开应用失败');
    }
  }

  Future<void> _handleInternalAppLink(Uri uri) async {
    final action =
        (uri.host.isNotEmpty
                ? uri.host
                : (uri.pathSegments.isNotEmpty ? uri.pathSegments.first : ''))
            .trim()
            .toLowerCase();
    switch (action) {
      case 'paytraffic':
        await TrafficPurchaseDialog.show(context);
        return;
      default:
        _showAdLinkTip('暂不支持的应用内跳转');
    }
  }

  void _showAdLinkTip(String message) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _showNextExpiredTrafficDialog(HomeViewModel vm) async {
    if (_showingExpiredTrafficDialog || !mounted) return;
    final notice = vm.consumeNextExpiredTrafficLogNotice();
    if (notice == null) return;
    _showingExpiredTrafficDialog = true;
    final shouldPurchase = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('流量包过期提醒'),
          content: Text(
            '${notice.label} 流量包于 ${notice.createDate} 过期\n过期了流量：${formatBytes(notice.trafficBytes)}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('知道了'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('购买流量包'),
            ),
          ],
        );
      },
    );
    _showingExpiredTrafficDialog = false;
    if (!mounted) return;
    if (shouldPurchase == true) {
      await TrafficPurchaseDialog.show(context);
    }
    if (vm.pendingExpiredTrafficLogNotices.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _showNextExpiredTrafficDialog(vm);
      });
    }
  }
}

class _AdBannerCarousel extends StatefulWidget {
  final List<HomeAd> ads;
  final ConnectionMode mode;
  final Future<void> Function(String linkUrl) onAdTap;

  const _AdBannerCarousel({
    required this.ads,
    required this.mode,
    required this.onAdTap,
  });

  @override
  State<_AdBannerCarousel> createState() => _AdBannerCarouselState();
}

class _AdBannerCarouselState extends State<_AdBannerCarousel>
    with WidgetsBindingObserver {
  static const Duration _autoSlideInterval = Duration(seconds: 4);
  static const Duration _manualInteractionCooldown = Duration(seconds: 10);

  final PageController _pageController = PageController();
  Timer? _autoSlideTimer;
  int _currentIndex = 0;
  bool _isAutoSliding = false;
  bool _isPointerInteracting = false;
  AppLifecycleState _appLifecycleState = AppLifecycleState.resumed;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _syncCarousel();
  }

  @override
  void didUpdateWidget(covariant _AdBannerCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.ads.length != widget.ads.length) {
      _syncCarousel();
    } else if (widget.ads.length > 1 && _autoSlideTimer == null) {
      _restartAutoSlide();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _autoSlideTimer?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appLifecycleState = state;
    if (state == AppLifecycleState.resumed) {
      _restartAutoSlide();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      _pauseAutoSlide();
    }
  }

  void _syncCarousel() {
    if (widget.ads.length <= 1) {
      _pauseAutoSlide();
      if (_currentIndex != 0) {
        setState(() {
          _currentIndex = 0;
        });
      }
      if (_pageController.hasClients) {
        _pageController.jumpToPage(0);
      }
      return;
    }

    if (_currentIndex >= widget.ads.length) {
      _currentIndex = 0;
      if (_pageController.hasClients) {
        _pageController.jumpToPage(0);
      }
    }
    _restartAutoSlide();
  }

  void _restartAutoSlide() {
    _autoSlideTimer?.cancel();
    if (!mounted ||
        widget.ads.length <= 1 ||
        _isPointerInteracting ||
        _appLifecycleState != AppLifecycleState.resumed) {
      return;
    }
    _autoSlideTimer = Timer(_autoSlideInterval, () {
      if (!mounted || !_pageController.hasClients || widget.ads.length <= 1) {
        return;
      }
      final nextIndex = (_currentIndex + 1) % widget.ads.length;
      _isAutoSliding = true;
      _pageController.animateToPage(
        nextIndex,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeInOut,
      );
    });
  }

  void _pauseAutoSlide() {
    _autoSlideTimer?.cancel();
    _autoSlideTimer = null;
  }

  void _pauseAutoSlideForInteraction() {
    _pauseAutoSlide();
    if (!mounted || widget.ads.length <= 1) {
      return;
    }
    _autoSlideTimer = Timer(_manualInteractionCooldown, () {
      if (mounted) {
        _restartAutoSlide();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 80,
      child: Stack(
        alignment: Alignment.bottomCenter,
        children: [
          MouseRegion(
            onEnter: (_) {
              _isPointerInteracting = true;
              _pauseAutoSlide();
            },
            onExit: (_) {
              _isPointerInteracting = false;
              _restartAutoSlide();
            },
            child: Listener(
              onPointerDown: (_) {
                _isPointerInteracting = true;
                _pauseAutoSlide();
              },
              onPointerUp: (_) {
                _isPointerInteracting = false;
                _pauseAutoSlideForInteraction();
              },
              onPointerCancel: (_) {
                _isPointerInteracting = false;
                _restartAutoSlide();
              },
              child: ScrollConfiguration(
                behavior: MaterialScrollBehavior().copyWith(
                  dragDevices: {
                    PointerDeviceKind.touch,
                    PointerDeviceKind.mouse,
                    PointerDeviceKind.trackpad,
                    PointerDeviceKind.stylus,
                    PointerDeviceKind.unknown,
                  },
                ),
                child: PageView.builder(
                  controller: _pageController,
                  itemCount: widget.ads.length,
                  onPageChanged: (index) {
                    if (_currentIndex != index) {
                      setState(() {
                        _currentIndex = index;
                      });
                    }
                    if (_isAutoSliding) {
                      _isAutoSliding = false;
                      _restartAutoSlide();
                      return;
                    }
                    _pauseAutoSlideForInteraction();
                  },
                  itemBuilder: (context, index) {
                    return _AdBannerItem(
                      ad: widget.ads[index],
                      mode: widget.mode,
                      onTap: widget.onAdTap,
                    );
                  },
                ),
              ),
            ),
          ),
          if (widget.ads.length > 1)
            Positioned(
              top: 2,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 2,
                    vertical: 2,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: List.generate(widget.ads.length, (index) {
                      final isActive = index == _currentIndex;
                      return AnimatedContainer(
                        duration: const Duration(milliseconds: 220),
                        width: isActive ? 9 : 6,
                        height: 6,
                        margin: const EdgeInsets.symmetric(horizontal: 2),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(999),
                          color: isActive
                              ? const Color(0xFF96CBFF)
                              : Colors.white.withValues(alpha: 0.45),
                        ),
                      );
                    }),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _AdBannerItem extends StatelessWidget {
  final HomeAd ad;
  final ConnectionMode mode;
  final Future<void> Function(String linkUrl) onTap;

  const _AdBannerItem({
    required this.ad,
    required this.mode,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final overlayColor = _getAdOverlayColor(mode);
    return GestureDetector(
      onTap: () => onTap(ad.linkUrl),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(5),
          color: Colors.white.withValues(alpha: 0.08),
          border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.18),
              blurRadius: 14,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.network(
              ad.imageUrl,
              fit: BoxFit.cover,
              filterQuality: FilterQuality.low,
              errorBuilder: (context, error, stackTrace) {
                return Container(
                  color: AppColors.cardBackground,
                  alignment: Alignment.center,
                  child: Text(
                    ad.title.isNotEmpty ? ad.title : '广告加载失败',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                );
              },
              loadingBuilder: (context, child, loadingProgress) {
                if (loadingProgress == null) return child;
                return Container(
                  color: AppColors.cardBackground,
                  alignment: Alignment.center,
                  child: const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.2,
                      color: Color(0xFF96CBFF),
                    ),
                  ),
                );
              },
            ),
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      overlayColor.withValues(alpha: 0.18),
                      overlayColor.withValues(alpha: 0.1),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Color _getAdOverlayColor(ConnectionMode mode) {
    switch (mode) {
      case ConnectionMode.off:
        return const Color(0xFF2F556E);
      case ConnectionMode.smart:
        return const Color(0xFF35508F);
      case ConnectionMode.global:
        return const Color(0xFF214C90);
    }
  }
}

class InviteDialog {
  static Future<void> show(BuildContext context) {
    return showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'invite_dialog',
      barrierColor: Colors.black.withValues(alpha: 0.25),
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (dialogContext, animation, secondaryAnimation) {
        return _InviteDialogContent(
          key: ValueKey(DateTime.now().microsecondsSinceEpoch),
          refreshToken: DateTime.now().microsecondsSinceEpoch,
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

class _InviteDialogContent extends StatefulWidget {
  final int refreshToken;

  const _InviteDialogContent({super.key, required this.refreshToken});

  @override
  State<_InviteDialogContent> createState() => _InviteDialogContentState();
}

class _InviteDialogContentState extends State<_InviteDialogContent> {
  InviteInfo? _inviteInfo;
  String? _errorMessage;
  bool _isLoading = true;
  final Map<String, Timer> _copyResetTimers = {};
  final Set<String> _copiedActions = <String>{};

  @override
  void initState() {
    super.initState();
    _loadInviteInfo();
  }

  @override
  void dispose() {
    for (final timer in _copyResetTimers.values) {
      timer.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
                const SizedBox(height: 5),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 6, 20, 24),
                    child: _buildBody(),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(
        child: SizedBox(
          width: 26,
          height: 26,
          child: CircularProgressIndicator(
            strokeWidth: 2.4,
            color: Color(0xFF96CBFF),
          ),
        ),
      );
    }

    if (_errorMessage != null) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 20),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  '邀请好友',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  _errorMessage!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 14,
                    height: 1.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _loadInviteInfo,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF96CBFF),
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      elevation: 0,
                    ),
                    child: const Text(
                      '重新加载',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
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

    final inviteInfo = _inviteInfo!;
    final canCopyGiftCode = inviteInfo.giftCode.trim().isNotEmpty;
    final canCopyContent = inviteInfo.content.trim().isNotEmpty;
    final hasAndroidDownloadUrl = inviteInfo.androidDownloadUrl.trim().isNotEmpty;
    final hasIosDownloadUrl = inviteInfo.iosDownloadUrl.trim().isNotEmpty;
    final hasWindowsDownloadUrl =
        inviteInfo.windowsDownloadUrl.trim().isNotEmpty;
    final inviteRewardGb = inviteInfo.inviteCount * 10;
    return ScrollConfiguration(
      behavior: MaterialScrollBehavior().copyWith(
        scrollbars: false,
        dragDevices: {
          PointerDeviceKind.touch,
          PointerDeviceKind.mouse,
          PointerDeviceKind.trackpad,
          PointerDeviceKind.stylus,
          PointerDeviceKind.unknown,
        },
      ),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        padding: EdgeInsets.zero,
        children: [
          _buildSummaryCard(
            label: '已邀请人数',
            value: '${inviteInfo.inviteCount}',
            footer: '好友',
            secondaryLabel: '已奖励流量',
            secondaryValue: '${inviteRewardGb}GB',
          ),
          const SizedBox(height: 8),
          _buildInfoCard(
            title: '礼品码',
            value: inviteInfo.giftCode,
            copyLabel: _isCopied('gift_code') ? '已复制' : '复制',
            hidePreview: true,
            onCopy: canCopyGiftCode
                ? () => _copyText('gift_code', inviteInfo.giftCode)
                : null,
            isCopied: _isCopied('gift_code'),
          ),
          const SizedBox(height: 8),
          _buildInfoCard(
            title: '推广文案',
            value: inviteInfo.content,
            copyLabel: _isCopied('invite_content') ? '已复制' : '复制',
            hidePreview: true,
            onCopy: canCopyContent
                ? () => _copyText('invite_content', inviteInfo.content)
                : null,
            isCopied: _isCopied('invite_content'),
          ),
          if (hasAndroidDownloadUrl) ...[
          const SizedBox(height: 8),
            _buildInfoCard(
              title: '安卓下载地址',
              value: inviteInfo.androidDownloadUrl,
              copyLabel: _isCopied('download_url_android') ? '已复制' : '复制',
              hidePreview: true,
              onCopy: () => _copyText(
                'download_url_android',
                inviteInfo.androidDownloadUrl,
              ),
              isCopied: _isCopied('download_url_android'),
            ),
          ],
          if (hasIosDownloadUrl) ...[
          const SizedBox(height: 8),
            _buildInfoCard(
              title: '苹果下载地址',
              value: inviteInfo.iosDownloadUrl,
              copyLabel: _isCopied('download_url_ios') ? '已复制' : '复制',
              hidePreview: true,
              onCopy: () => _copyText(
                'download_url_ios',
                inviteInfo.iosDownloadUrl,
              ),
              isCopied: _isCopied('download_url_ios'),
            ),
          ],
          if (hasWindowsDownloadUrl) ...[
          const SizedBox(height: 8),
            _buildInfoCard(
              title: '电脑下载地址',
              value: inviteInfo.windowsDownloadUrl,
              copyLabel: _isCopied('download_url_windows') ? '已复制' : '复制',
              hidePreview: true,
              onCopy: () => _copyText(
                'download_url_windows',
                inviteInfo.windowsDownloadUrl,
              ),
              isCopied: _isCopied('download_url_windows'),
            ),
          ],
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  Widget _buildSummaryCard({
    required String label,
    required String value,
    required String footer,
    String? secondaryLabel,
    String? secondaryValue,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: Colors.white60,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  value.trim().isEmpty ? '--' : value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              if (secondaryLabel != null && secondaryValue != null) ...[
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      secondaryLabel,
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      secondaryValue,
                      style: const TextStyle(
                        color: Color(0xFF96CBFF),
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
          const SizedBox(height: 4),
          Text(
            footer,
            style: const TextStyle(
              color: Colors.white54,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoCard({
    required String title,
    required String value,
    required String copyLabel,
    required VoidCallback? onCopy,
    bool hidePreview = false,
    bool isCopied = false,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              OutlinedButton(
                onPressed: onCopy,
                style: OutlinedButton.styleFrom(
                  foregroundColor: isCopied
                      ? Colors.black
                      : const Color(0xFF96CBFF),
                  backgroundColor: isCopied ? Colors.white : Colors.transparent,
                  side: BorderSide(
                    color: isCopied ? Colors.white : const Color(0xFF96CBFF),
                    width: 1,
                  ),
                  minimumSize: const Size(0, 40),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
                child: Text(copyLabel),
              ),
            ],
          ),
          if (!hidePreview) ...[
            const SizedBox(height: 10),
            SelectableText(
              value.trim().isEmpty ? '--' : value,
              maxLines: 2,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 13,
                height: 1.45,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _loadInviteInfo() async {
    final platform = _resolvePlatform();
    if (platform == null) {
      setState(() {
        _inviteInfo = null;
        _isLoading = false;
        _errorMessage = '当前平台暂不支持邀请功能';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final result = await ApiService().fetchInviteInfo(platform: platform);
    if (!mounted) return;

    setState(() {
      _isLoading = false;
      if (result.isSuccess) {
        _inviteInfo = result.data;
        _errorMessage = null;
      } else {
        _inviteInfo = null;
        _errorMessage = result.msg;
      }
    });
  }

  String? _resolvePlatform() {
    if (kIsWeb) return null;
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    if (Platform.isWindows) return 'windows';
    return null;
  }

  bool _isCopied(String key) => _copiedActions.contains(key);

  Future<void> _copyText(String key, String text) async {
    final normalized = text.trim();
    if (normalized.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: normalized));
    if (!mounted) return;
    _copyResetTimers[key]?.cancel();
    setState(() {
      _copiedActions.add(key);
    });
    _copyResetTimers[key] = Timer(const Duration(seconds: 2), () {
      if (!mounted) return;
      setState(() {
        _copiedActions.remove(key);
      });
      _copyResetTimers.remove(key);
    });
  }
}

class DeviceBindDialog {
  static Future<void> show(BuildContext context) {
    return showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'device_bind_dialog',
      barrierColor: Colors.black.withValues(alpha: 0.25),
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (dialogContext, animation, secondaryAnimation) {
        return const _DeviceBindDialogContent();
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

class _DeviceBindDialogContent extends StatelessWidget {
  const _DeviceBindDialogContent();

  @override
  Widget build(BuildContext context) {
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
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 95),
              child: Column(
                children: [
                  Row(
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
                  Expanded(
                    child: Center(
                      child: SingleChildScrollView(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 360),
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.fromLTRB(18, 22, 18, 18),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(18),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.14),
                              ),
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                SvgPicture.asset(
                                  AppAssets.icQrCode,
                                  width: 36,
                                  height: 36,
                                  colorFilter: const ColorFilter.mode(
                                    Colors.white,
                                    BlendMode.srcIn,
                                  ),
                                ),
                                const SizedBox(height: 5),
                                const Text(
                                  '设备共享',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 22,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                const SizedBox(height: 10),
                                const Text(
                                  '出示此设备二维码，新设备扫码即可绑定，新设备将共享老设备的节点、流量包等',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: Colors.white70,
                                    fontSize: 12,
                                    height: 1.4,
                                  ),
                                ),
                                const SizedBox(height: 18),
                                SizedBox(
                                  width: double.infinity,
                                  child: ElevatedButton(
                                    onPressed: () =>
                                        DeviceBindQrDialog.show(context),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: const Color(0xFF96CBFF),
                                      foregroundColor: Colors.black,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(14),
                                      ),
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 20,
                                      ),
                                      elevation: 0,
                                    ),
                                    child: const Text(
                                      '共享二维码',
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                SizedBox(
                                  width: double.infinity,
                                  child: OutlinedButton(
                                    onPressed: () => _openScanner(context),
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: const Color(0xFF96CBFF),
                                      side: const BorderSide(
                                        color: Color(0xFF96CBFF),
                                        width: 1,
                                      ),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(14),
                                      ),
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 16,
                                      ),
                                    ),
                                    child: const Text(
                                      '扫一扫',
                                      style: TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
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
    );
  }

  Future<void> _openScanner(BuildContext context) async {
    if (kIsWeb) {
      await _showBindTip(
        context,
        title: '暂不支持',
        message: '当前平台暂不支持扫一扫，请使用移动设备扫码绑定',
      );
      return;
    }
    if (Platform.isWindows) {
      await _openWindowsScanner(context);
      return;
    }
    if (!Platform.isAndroid) {
      await _showBindTip(
        context,
        title: '暂不支持',
        message: '当前平台暂不支持扫一扫，请使用移动设备扫码绑定',
      );
      return;
    }
    final permission = await Permission.camera.request();
    if (!permission.isGranted) {
      if (!context.mounted) return;
      await _showBindTip(context, title: '无法扫码', message: '请先允许相机权限后再进行扫码绑定');
      return;
    }
    if (!context.mounted) return;
    await DeviceBindScannerDialog.show(context);
  }

  Future<void> _openWindowsScanner(BuildContext context) async {
    final bindToken = await _pickBindTokenFromImage(context);
    if (bindToken == null || !context.mounted) {
      return;
    }

    final result = await ApiService().scanDeviceBind(bindToken: bindToken);
    if (!context.mounted) return;

    if (result.isSuccess) {
      await DeviceBindScannerDialog.showSuccessDialogAndExit(context);
      return;
    }

    await _showBindTip(context, title: '绑定失败', message: result.msg);
  }

  Future<String?> _pickBindTokenFromImage(BuildContext context) async {
    final imageFile = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: '二维码图片',
          extensions: ['png', 'jpg', 'jpeg', 'bmp', 'gif', 'webp'],
        ),
      ],
    );
    if (imageFile == null || imageFile.path.isEmpty) {
      return null;
    }

    final bindToken = await _decodeBindTokenFromImage(imageFile.path);
    if (bindToken != null) {
      return bindToken;
    }

    if (!context.mounted) return null;
    await _showBindTip(context, title: '二维码无效', message: '未识别到有效绑定二维码，请重新选择图片');
    return null;
  }

  Future<String?> _decodeBindTokenFromImage(String imagePath) async {
    try {
      final bytes = await File(imagePath).readAsBytes();
      final decodedImage = img.decodeImage(bytes);
      if (decodedImage == null) {
        return null;
      }

      final convertedImage = decodedImage.convert(numChannels: 4);
      final pixelBytes = convertedImage.getBytes(order: img.ChannelOrder.rgba);
      final pixelData = Int32List.view(
        pixelBytes.buffer,
        pixelBytes.offsetInBytes,
        pixelBytes.lengthInBytes ~/ 4,
      );
      final source = zxing.RGBLuminanceSource(
        convertedImage.width,
        convertedImage.height,
        pixelData,
      );

      for (final binarizer in [
        zxing.HybridBinarizer(source),
        zxing.GlobalHistogramBinarizer(source),
      ]) {
        try {
          final result = zxing.QRCodeReader().decode(
            zxing.BinaryBitmap(binarizer),
          );
          final bindToken = DeviceBindScannerDialog.extractBindToken(
            result.text,
          );
          if (bindToken != null) {
            return bindToken;
          }
        } catch (_) {}
      }
    } catch (_) {}

    return null;
  }

  Future<void> _showBindTip(
    BuildContext context, {
    required String title,
    required String message,
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
          title: Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w700,
            ),
          ),
          content: Text(
            message,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 14,
              height: 1.5,
              fontWeight: FontWeight.w500,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text(
                '知道了',
                style: TextStyle(
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
}

class DeviceBindQrDialog {
  static Future<void> show(BuildContext context) {
    return showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'device_bind_qr_dialog',
      barrierColor: Colors.black.withValues(alpha: 0.25),
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (dialogContext, animation, secondaryAnimation) {
        return const _DeviceBindQrDialogContent();
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

class _DeviceBindQrDialogContent extends StatefulWidget {
  const _DeviceBindQrDialogContent();

  @override
  State<_DeviceBindQrDialogContent> createState() =>
      _DeviceBindQrDialogContentState();
}

class _DeviceBindQrDialogContentState
    extends State<_DeviceBindQrDialogContent> {
  DeviceBindApplyInfo? _bindInfo;
  String? _errorMessage;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadBindInfo();
  }

  @override
  Widget build(BuildContext context) {
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
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 55),
              child: Column(
                children: [
                  Row(
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
                  Expanded(
                    child: Center(
                      child: SingleChildScrollView(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 360),
                          child: _buildBody(),
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
    );
  }

  Widget _buildBody() {
    final media = MediaQuery.of(context);
    final isCompact = media.size.height < 640 || media.size.width < 360;
    final qrSize = isCompact ? 170.0 : 220.0;
    if (_isLoading) {
      return const SizedBox(
        width: 28,
        height: 28,
        child: CircularProgressIndicator(
          strokeWidth: 2.4,
          color: Color(0xFF96CBFF),
        ),
      );
    }

    if (_errorMessage != null) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 20),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _errorMessage!,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 14,
                height: 1.5,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _loadBindInfo,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF96CBFF),
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  elevation: 0,
                ),
                child: const Text(
                  '重新加载',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ],
        ),
      );
    }

    final bindInfo = _bindInfo!;
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(18, isCompact ? 16 : 20, 18, 18),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            '共享二维码',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 14),
          Container(
            padding: EdgeInsets.all(isCompact ? 10 : 12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
            child: QrImageView(
              data: bindInfo.bindUrl,
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
          ),
          SizedBox(height: isCompact ? 12 : 16),
          Text(
            '请使用新设备 扫一扫 完成绑定',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white,
              fontSize: isCompact ? 15 : 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _formatExpireTime(bindInfo.expireTime),
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 12,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _loadBindInfo() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    final result = await ApiService().applyDeviceBind();
    if (!mounted) return;
    setState(() {
      _isLoading = false;
      if (result.isSuccess) {
        _bindInfo = result.data;
        _errorMessage = null;
      } else {
        _bindInfo = null;
        _errorMessage = result.msg;
      }
    });
  }

  String _formatExpireTime(String expireTime) {
    if (expireTime.trim().isEmpty) {
      return '二维码有效期 10 分钟';
    }
    try {
      final parsed = DateTime.parse(expireTime).toLocal();
      final year = parsed.year.toString().padLeft(4, '0');
      final month = parsed.month.toString().padLeft(2, '0');
      final day = parsed.day.toString().padLeft(2, '0');
      final hour = parsed.hour.toString().padLeft(2, '0');
      final minute = parsed.minute.toString().padLeft(2, '0');
      return '有效期至 $year-$month-$day $hour:$minute';
    } catch (_) {
      return '有效期至 ${expireTime.replaceFirst('T', ' ')}';
    }
  }
}

class DeviceBindScannerDialog {
  static Future<void> show(BuildContext context) {
    return showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'device_bind_scanner_dialog',
      barrierColor: Colors.black.withValues(alpha: 0.25),
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (dialogContext, animation, secondaryAnimation) {
        return const _DeviceBindScannerDialogContent();
      },
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
        );
        return FadeTransition(opacity: curved, child: child);
      },
    );
  }

  static String? extractBindToken(String rawValue) {
    final normalized = rawValue.trim();
    if (normalized.isEmpty) return null;
    final uri = Uri.tryParse(normalized);
    final queryToken = uri?.queryParameters['bind_token']?.trim();
    if (queryToken != null && queryToken.isNotEmpty) {
      return queryToken;
    }
    if (RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(normalized)) {
      return normalized;
    }
    return null;
  }

  static Future<void> showSuccessDialogAndExit(BuildContext context) async {
    final overlayState = appNavigatorKey.currentState?.overlay;
    if (overlayState == null || !overlayState.mounted) {
      await ApiService().exitApplication();
      return;
    }

    await showAnimatedDialog<void>(
      context: overlayState.context,
      barrierDismissible: false,
      builder: (successContext) {
        return AlertDialog(
          backgroundColor: AppColors.cardBackground,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: const BorderSide(color: Color(0xFF96CBFF), width: 1.1),
          ),
          title: const Text(
            '绑定成功',
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w700,
            ),
          ),
          content: const Text(
            '绑定成功，请重新打开APP生效',
            style: TextStyle(
              color: Colors.white70,
              fontSize: 14,
              height: 1.5,
              fontWeight: FontWeight.w500,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                Navigator.of(successContext).pop();
                await ApiService().exitApplication();
              },
              child: const Text(
                '确认',
                style: TextStyle(
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
}

class _DeviceBindScannerDialogContent extends StatefulWidget {
  const _DeviceBindScannerDialogContent();

  @override
  State<_DeviceBindScannerDialogContent> createState() =>
      _DeviceBindScannerDialogContentState();
}

class _DeviceBindScannerDialogContentState
    extends State<_DeviceBindScannerDialogContent>
    with WidgetsBindingObserver {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    facing: CameraFacing.back,
    formats: const [BarcodeFormat.qrCode],
  );
  bool _isProcessing = false;
  bool _isScannerSuspended = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    unawaited(_syncScannerLifecycle(state));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
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
                  const Text(
                    '扫一扫绑定',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
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
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      MobileScanner(
                        controller: _controller,
                        onDetect: _handleBarcodeDetect,
                      ),
                      DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: const Color(0xFF96CBFF),
                            width: 2,
                          ),
                          borderRadius: BorderRadius.circular(20),
                        ),
                      ),
                      if (_isProcessing)
                        ColoredBox(
                          color: Colors.black.withValues(alpha: 0.45),
                          child: const Center(
                            child: CircularProgressIndicator(
                              color: Color(0xFF96CBFF),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(24, 14, 24, 28),
              child: Text(
                '请扫描老设备出示的绑定二维码',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 13,
                  height: 1.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _handleBarcodeDetect(BarcodeCapture capture) async {
    if (_isProcessing) return;
    final rawValue = capture.barcodes.isNotEmpty
        ? capture.barcodes.first.rawValue?.trim() ?? ''
        : '';
    final bindToken = DeviceBindScannerDialog.extractBindToken(rawValue);
    if (bindToken == null) {
      _isProcessing = true;
      await _controller.stop();
      if (!mounted) return;
      await _showScanTip(title: '二维码无效', message: '未识别到有效绑定二维码，请重新扫码');
      if (!mounted) return;
      _isProcessing = false;
      await _controller.start();
      return;
    }

    setState(() {
      _isProcessing = true;
    });
    await _controller.stop();

    final result = await ApiService().scanDeviceBind(bindToken: bindToken);
    if (!mounted) return;

    if (result.isSuccess) {
      Navigator.of(context).pop();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      if (!mounted) return;
      await DeviceBindScannerDialog.showSuccessDialogAndExit(context);
      return;
    }

    await _showScanTip(title: '绑定失败', message: result.msg);
    if (!mounted) return;
    setState(() {
      _isProcessing = false;
    });
    await _controller.start();
  }

  Future<void> _syncScannerLifecycle(AppLifecycleState state) async {
    if (!mounted) {
      return;
    }
    if (state == AppLifecycleState.resumed) {
      if (_isProcessing || !_isScannerSuspended) {
        return;
      }
      _isScannerSuspended = false;
      try {
        await _controller.start();
      } catch (_) {}
      return;
    }
    if (_isScannerSuspended) {
      return;
    }
    _isScannerSuspended = true;
    try {
      await _controller.stop();
    } catch (_) {}
  }

  Future<void> _showScanTip({
    required String title,
    required String message,
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
          title: Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w700,
            ),
          ),
          content: Text(
            message,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 14,
              height: 1.5,
              fontWeight: FontWeight.w500,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text(
                '知道了',
                style: TextStyle(
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
}
