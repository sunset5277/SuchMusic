import 'package:flutter/material.dart';

/// 设计稿风格弹窗组件（参照 cankao/1.txt，430 宽画布）
/// 白底圆角 15 卡片（宽 353/430 屏宽）、蓝色确认按钮（高 36、圆角 8、#3080FF、
/// 宽度随文字自适应）、取消为灰字文本（#8A8A8A）
/// 全 App 通用：更新弹窗、设置页确认弹窗等均使用本组件
class DesignDialog {
  DesignDialog._();

  static const Color confirmBlue = Color(0xFF3080FF); // 确认按钮蓝
  static const Color cancelGray = Color(0xFF8A8A8A); // 取消文字灰
  static const Color titleDark = Color(0xFF333333);
  static const Color contentGray = Color(0xFF666666);

  /// 设计稿比例：屏宽 / 430
  static double s(BuildContext context) =>
      MediaQuery.of(context).size.width / 430;

  /// 透明底 Dialog 包装（去掉默认灰白底和默认边距，卡片宽度按设计稿控制）
  static Widget shell(
    BuildContext context, {
    required Widget child,
  }) {
    final k = s(context);
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: EdgeInsets.symmetric(horizontal: 38 * k, vertical: 24),
      child: child,
    );
  }

  /// 白底圆角卡片容器
  static Widget card(
    BuildContext context, {
    required List<Widget> children,
  }) {
    final k = s(context);
    return Container(
      width: 353 * k,
      padding: EdgeInsets.fromLTRB(24 * k, 26 * k, 24 * k, 18 * k),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(15 * k),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }

  /// 弹窗标题
  static Widget title(BuildContext context, String text) {
    final k = s(context);
    return Text(
      text,
      style: TextStyle(
        fontSize: 18 * k,
        fontWeight: FontWeight.w600,
        color: titleDark,
        height: 1.3,
      ),
    );
  }

  /// 弹窗正文
  static Widget body(BuildContext context, String text) {
    final k = s(context);
    return Text(
      text,
      style: TextStyle(
        fontSize: 14.5 * k,
        color: contentGray,
        height: 1.6,
      ),
    );
  }

  /// 蓝底白字确认按钮（高 34、圆角 8、宽度随文字自适应）
  /// [enabled] 为 false 时置灰且不可点击
  static Widget confirmButton(
    BuildContext context,
    String text,
    VoidCallback? onTap, {
    bool enabled = true,
  }) {
    final k = s(context);
    return GestureDetector(
      onTap: enabled ? onTap : null,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 34 * k,
        padding: EdgeInsets.symmetric(horizontal: 17 * k),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: enabled ? confirmBlue : const Color(0xFFB9D0F5),
          borderRadius: BorderRadius.circular(8 * k),
        ),
        child: Text(
          text,
          style: TextStyle(color: Colors.white, fontSize: 15.6 * k),
        ),
      ),
    );
  }

  /// 灰字取消按钮（设计稿为纯文本）
  static Widget cancelText(
    BuildContext context,
    String text,
    VoidCallback onTap,
  ) {
    final k = s(context);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 8 * k, vertical: 7 * k),
        child: Text(
          text,
          style: TextStyle(color: cancelGray, fontSize: 13.6 * k),
        ),
      ),
    );
  }

  /// 通用确认弹窗：标题 + 正文 + 右下角〔取消灰字〕〔确定蓝按钮〕
  /// 点空白区域不可关闭（与设计稿弹窗交互一致）
  static void showConfirm(
    BuildContext context, {
    required String titleText,
    required String contentText,
    String confirmLabel = '确定',
    String cancelLabel = '取消',
    bool showCancel = true,
    VoidCallback? onConfirm,
    VoidCallback? onCancel,
  }) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        final k = s(ctx);
        return shell(
          ctx,
          child: card(
            ctx,
            children: [
              DesignDialog.title(ctx, titleText),
              SizedBox(height: 12 * k),
              DesignDialog.body(ctx, contentText),
              SizedBox(height: 26 * k),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (showCancel) ...[
                    DesignDialog.cancelText(ctx, cancelLabel, () {
                      Navigator.of(ctx).pop();
                      onCancel?.call();
                    }),
                    SizedBox(width: 12 * k),
                  ],
                  DesignDialog.confirmButton(ctx, confirmLabel, () {
                    Navigator.of(ctx).pop();
                    onConfirm?.call();
                  }),
                ],
              ),
            ],
          ),
        );
    });
  }
}

/// 设计稿风格轻提示：白底黑字圆角提示条，屏幕底部居中
/// 宽度随文字内容自适应（仅超长时截断），圆角 8、白底黑字
/// 出现：上滑淡入；消失：下滑淡出，2 秒后自动退出
class DesignToast {
  DesignToast._();

  static void show(BuildContext context, String text) {
    final overlay = Overlay.of(context, rootOverlay: true);
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _ToastView(
        text: text,
        onDismissed: () {
          if (entry.mounted) entry.remove();
        },
      ),
    );
    overlay.insert(entry);
  }
}

class _ToastView extends StatefulWidget {
  final String text;
  final VoidCallback onDismissed;
  const _ToastView({required this.text, required this.onDismissed});

  @override
  State<_ToastView> createState() => _ToastViewState();
}

class _ToastViewState extends State<_ToastView> {
  bool _shown = false;
  static const _dur = Duration(milliseconds: 260);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _shown = true);
    });
    Future.delayed(const Duration(seconds: 2), () {
      if (!mounted) return;
      setState(() => _shown = false);
      Future.delayed(_dur, () {
        if (mounted) widget.onDismissed();
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final k = DesignDialog.s(context);
    return Positioned.fill(
      child: IgnorePointer(
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: EdgeInsets.only(bottom: 80 * k),
            child: AnimatedSlide(
              offset: _shown ? Offset.zero : const Offset(0, 0.3),
              duration: _dur,
              curve: _shown ? Curves.easeOutCubic : Curves.easeInCubic,
              child: AnimatedOpacity(
                opacity: _shown ? 1.0 : 0.0,
                duration: _dur,
                child: Material(
                  color: Colors.transparent,
                  child: IntrinsicWidth(
                    child: Container(
                      constraints: BoxConstraints(
                        maxWidth: MediaQuery.of(context).size.width * 0.86,
                      ),
                      padding: EdgeInsets.symmetric(
                          horizontal: 16 * k, vertical: 9 * k),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(8 * k),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.25),
                            blurRadius: 20 * k,
                            offset: Offset(0, 4 * k),
                          ),
                        ],
                      ),
                      child: Text(
                        widget.text,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.black,
                          fontSize: 15.6 * k,
                          fontWeight: FontWeight.w400,
                          letterSpacing: 0,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
