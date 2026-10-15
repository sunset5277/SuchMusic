import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/audio_player_service.dart';
import '../widgets/design_dialog.dart';
import 'about_page.dart';
import 'band_page.dart';

/// 设置页面
/// 布局参考 cankao/1.txt 设计稿（430x932）：
/// 白色导航栏 + "播放设置"分组（与其他应用同时播放开关）+ "其他"分组（清理缓存/关于）
class SettingsPage extends StatefulWidget {
  final Future<void> Function()? onLogout;

  const SettingsPage({super.key, this.onLogout});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  static const _mixPrefKey = 'allowMixWithOthers';
  bool _allowMixWithOthers = false;

  @override
  void initState() {
    super.initState();
    _loadMixSetting();
  }

  Future<void> _loadMixSetting() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        _allowMixWithOthers = prefs.getBool(_mixPrefKey) ?? false;
      });
    } catch (_) {}
  }

  Future<void> _toggleMix(bool value) async {
    setState(() => _allowMixWithOthers = value);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_mixPrefKey, value);
    } catch (_) {}
    await AudioPlayerService.applyMixWithOthers(value);
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final s = size.width / 430; // 设计稿等比缩放系数
    final topPadding = MediaQuery.of(context).padding.top;

    return Scaffold(
      backgroundColor: const Color(0xFFF1F2F4),
      body: Column(
        children: [
          // 白色导航栏：返回 + 居中标题
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
                          const Icon(
                            Icons.arrow_back_ios_new,
                            size: 20,
                            color: Colors.black,
                          ),
                          SizedBox(width: 8 * s - 3), // 返回文字左移 3px
                          Text(
                            '返回',
                            style: TextStyle(
                              color: Colors.black,
                              fontSize: 14 * s, // 12 + 2
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Center(
                    child: Text(
                      '设置',
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
              // 卡片左右距屏幕各 15px
              padding: const EdgeInsets.symmetric(horizontal: 15),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 严格按设计稿纵向坐标（430x932）：导航栏底 49 → 标题 66 间距 17
                  SizedBox(height: 17 * s),
                  _buildSectionHeader('播放设置', s),
                  SizedBox(height: 10 * s),
                  _buildCard(
                    s: s,
                    onTap: () => _toggleMix(!_allowMixWithOthers),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '与其他应用同时播放',
                            style: TextStyle(
                              color: Colors.black,
                              fontSize: 16 * s,
                            ),
                          ),
                        ),
                        _buildMixSwitch(s),
                      ],
                    ),
                  ),
                  SizedBox(height: 10 * s),
                  _buildSectionHeader('其他', s),
                  SizedBox(height: 10 * s),
                  _buildCard(
                    s: s,
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (context) => const BandPage()),
                      );
                    },
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '小米手环',
                            style: TextStyle(
                              color: Colors.black,
                              fontSize: 16 * s,
                            ),
                          ),
                        ),
                        const Icon(
                          Icons.chevron_right,
                          size: 20,
                          color: Color(0xFFCCCCCC),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(height: 10 * s),
                  _buildCard(
                    s: s,
                    onTap: _showClearCacheDialog,
                    child: Text(
                      '清理缓存',
                      style: TextStyle(
                        color: Colors.black,
                        fontSize: 16 * s,
                      ),
                    ),
                  ),
                  SizedBox(height: 10 * s),
                  _buildCard(
                    s: s,
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (context) => const AboutPage()),
                      );
                    },
                    child: Text(
                      '关于 Such Music',
                      style: TextStyle(
                        color: Colors.black,
                        fontSize: 16 * s,
                      ),
                    ),
                  ),
                  // 退出登录（仅登录状态显示）
                  if (widget.onLogout != null) ...[
                    SizedBox(height: 26 * s),
                    _buildCard(
                      s: s,
                      onTap: _showLogoutDialog,
                      child: const Center(
                        child: Text(
                          '退出登录',
                          style: TextStyle(
                            color: Color(0xFFE53935),
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                  ],
                  SizedBox(height: 40),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 分组标题：设计稿中为 20 高的文本块（如 66→86）
  Widget _buildSectionHeader(String title, double s) {
    return SizedBox(
      height: 20 * s,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          title,
          style: TextStyle(
            color: const Color(0xFF838383),
            fontSize: 15.5 * s,
          ),
        ),
      ),
    );
  }

  /// 白色圆角条目卡片（设计稿 388x44 圆角 10，卡片高度 52px）
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
        height: 52,
        padding: EdgeInsets.symmetric(horizontal: 9 * s),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10 * s),
        ),
        alignment: Alignment.centerLeft,
        child: child,
      ),
    );
  }

  /// 设计稿样式开关：灰色轨道白色圆钮（关）/ 主题蓝轨道右侧圆钮（开）
  Widget _buildMixSwitch(double s) {
    return GestureDetector(
      onTap: () => _toggleMix(!_allowMixWithOthers),
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
        width: 53 * s + 6, // 整体缩小 2px：59x31
        height: 25 * s + 6,
        padding: EdgeInsets.all(4 * s), // 内边距 1 + 1 + 2
        decoration: BoxDecoration(
          color: _allowMixWithOthers
              ? const Color(0xFF2F84FE)
              : const Color(0xFFC4C4C4),
          borderRadius: BorderRadius.circular(84),
        ),
        child: AnimatedAlign(
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          alignment: _allowMixWithOthers
              ? Alignment.centerRight
              : Alignment.centerLeft,
          child: Container(
            width: 23 * s, // 圆钮随轨道缩小 2px
            height: 23 * s,
            decoration: const BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
            ),
          ),
        ),
      ),
    );
  }

  /// 清理缓存：确认后清理并提示结果（条数 + 释放空间）
  void _showClearCacheDialog() {
    DesignDialog.showConfirm(
      context,
      titleText: '确认清除',
      contentText: '确定要清除所有缓存数据吗？',
      onConfirm: () async {
        final (count, bytes) = await AudioPlayerService.clearCoverCache();
        if (!context.mounted) return;
        final sizeText = bytes >= 1024 * 1024
            ? '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB'
            : '${(bytes / 1024).toStringAsFixed(0)} KB';
        DesignToast.show(
          context,
          bytes > 0 ? '已清理 $count 项缓存，释放 $sizeText' : '暂无缓存需要清理',
        );
      },
    );
  }

  void _showLogoutDialog() {
    DesignDialog.showConfirm(
      context,
      titleText: '退出登录',
      contentText: '确定要退出登录吗？',
      onConfirm: () {
        widget.onLogout?.call();
        Navigator.pop(context);
      },
    );
  }
}
