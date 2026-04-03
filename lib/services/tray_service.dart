import 'package:app/core/logger.dart';
import 'package:app/services/mihomo_service.dart';
import 'dart:io';
import 'package:system_tray/system_tray.dart';
import 'package:window_manager/window_manager.dart';

class TrayService {
  static final TrayService _instance = TrayService._internal();
  factory TrayService() => _instance;
  TrayService._internal();

  final SystemTray _systemTray = SystemTray();
  final AppWindow _appWindow = AppWindow();
  bool _isInitialized = false;

  Future<void> init() async {
    if (!Platform.isWindows || _isInitialized) return;

    // 初始化系统托盘
    String iconPath = Platform.isWindows ? 'assets/app_icon.ico' : 'assets/logo.png';
    
    await _systemTray.initSystemTray(
      title: "加速器",
      iconPath: iconPath,
    );

    // 创建菜单
    await _updateMenu();

    // 处理托盘点击事件
    _systemTray.registerSystemTrayEventHandler((eventName) {
      AppLogger.d("SystemTray event: $eventName");
      if (eventName == kSystemTrayEventClick) {
        Platform.isWindows ? _appWindow.show() : _systemTray.popUpContextMenu();
      } else if (eventName == kSystemTrayEventRightClick) {
        _systemTray.popUpContextMenu();
      }
    });

    _isInitialized = true;
  }

  Future<void> _updateMenu() async {
    final Menu menu = Menu();
    await menu.buildFrom([
      MenuItemLabel(
        label: '退出',
        onClicked: (menuItem) async {
          // 退出前先清理代理设置
          await MihomoService().stop();
          await windowManager.destroy();
          exit(0);
        },
      ),
    ]);
    await _systemTray.setContextMenu(menu);
  }
}
