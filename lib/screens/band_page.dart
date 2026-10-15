import 'dart:async';

import 'package:flutter/material.dart';

import '../services/band/band_channel.dart';
import '../services/band/band_service.dart';

/// 「小米手环」页面（最小入口）。
///
/// 仅展示连接状态与启用开关，不承载复杂交互——手环侧的丰富交互由快应用完成。
/// 布局风格沿用设置页（白色导航栏 + 白卡片，主色 #2F84FE）。
class BandPage extends StatefulWidget {
  const BandPage({super.key});

  @override
  State<BandPage> createState() => _BandPageState();
}

class _BandPageState extends State<BandPage> {
  final BandService _service = BandService();
  StreamSubscription<int>? _stateSub;
  bool _enabled = false;
  int _state = BandChannel.stateUnavailable;
  bool _sdkAvailable = false;

  @override
  void initState() {
    super.initState();
    _enabled = _service.enabled;
    _state = _service.connectionState;
    _sdkAvailable = _service.sdkAvailable;
    _stateSub = _service.onStateChanged.listen((s) {
      if (mounted) setState(() => _state = s);
    });
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    super.dispose();
  }

  Future<void> _toggle(bool value) async {
    setState(() => _enabled = value);
    await _service.setEnabled(value);
    if (!mounted) return;
    setState(() {
      _state = _service.connectionState;
      _sdkAvailable = _service.sdkAvailable;
    });
  }

  String get _stateText {
    switch (_state) {
      case BandChannel.stateConnected:
        return '已连接';
      case BandChannel.stateDisconnected:
        return '未连接';
      default:
        return '不可用';
    }
  }

  Color get _stateColor {
    switch (_state) {
      case BandChannel.stateConnected:
        return const Color(0xFF2F84FE);
      case BandChannel.stateDisconnected:
        return const Color(0xFF838383);
      default:
        return const Color(0xFFCCCCCC);
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final s = size.width / 430;
    final topPadding = MediaQuery.of(context).padding.top;

    return Scaffold(
      backgroundColor: const Color(0xFFF1F2F4),
      body: Column(
        children: [
          Container(
            padding: EdgeInsets.only(top: topPadding),
            color: Colors.white,
            child: SizedBox(
              height: 44 * s,
              child: Stack(
                children: [
                  Positioned(
                    left: 12 * s,
                    top: 0,
                    bottom: 0,
                    child: GestureDetector(
                      onTap: () => Navigator.pop(context),
                      behavior: HitTestBehavior.opaque,
                      child: Row(
                        children: [
                          const Icon(Icons.arrow_back_ios_new,
                              size: 20, color: Colors.black),
                          SizedBox(width: 8 * s - 3),
                          Text('返回',
                              style: TextStyle(color: Colors.black, fontSize: 14 * s)),
                        ],
                      ),
                    ),
                  ),
                  Center(
                    child: Text(
                      '小米手环',
                      style: TextStyle(
                        color: Colors.black,
                        fontSize: 17.5 * s,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 15),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(height: 17 * s),
                  _buildSectionHeader('设备', s),
                  SizedBox(height: 10 * s),
                  _buildCard(
                    s: s,
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '启用手环通讯',
                            style: TextStyle(color: Colors.black, fontSize: 16 * s),
                          ),
                        ),
                        Switch(
                          value: _enabled,
                          activeThumbColor: const Color(0xFF2F84FE),
                          onChanged: _toggle,
                        ),
                      ],
                    ),
                  ),
                  SizedBox(height: 10 * s),
                  _buildCard(
                    s: s,
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '连接状态',
                            style: TextStyle(color: Colors.black, fontSize: 16 * s),
                          ),
                        ),
                        Row(
                          children: [
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: _stateColor,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              _stateText,
                              style: TextStyle(color: _stateColor, fontSize: 15 * s),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  SizedBox(height: 16 * s),
                  Text(
                    '说明：手环快应用需与本 App 使用一致的包名与签名（com.such.music.such_music）'
                    '才能建立通信；未放置小米官方 SDK（xms-wearable-lib）时，此功能自动降级为不可用，'
                    '不影响其它功能。详见 docs/手环通讯.md。',
                    style: TextStyle(
                      color: const Color(0xFF838383),
                      fontSize: 13 * s,
                      height: 1.5,
                    ),
                  ),
                  if (_enabled && !_sdkAvailable) ...[
                    SizedBox(height: 12 * s),
                    Text(
                      '当前未检测到小米官方 SDK（本仓库不包含该 AAR）。请按文档将 '
                      'xms-wearable-lib*.aar 放入 android/app/libs/ 后重新构建。',
                      style: TextStyle(
                        color: const Color(0xFFE53935),
                        fontSize: 13 * s,
                        height: 1.5,
                      ),
                    ),
                  ],
                  const SizedBox(height: 40),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title, double s) {
    return SizedBox(
      height: 20 * s,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          title,
          style: TextStyle(color: const Color(0xFF838383), fontSize: 15.5 * s),
        ),
      ),
    );
  }

  Widget _buildCard({
    required double s,
    required Widget child,
    VoidCallback? onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.symmetric(horizontal: 9 * s, vertical: 4),
        constraints: const BoxConstraints(minHeight: 52),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10 * s),
        ),
        alignment: Alignment.centerLeft,
        child: child,
      ),
    );
  }
}
