# Flutter 插件大多自带 consumer 规则，这里只放兜底规则。
# 若真机回归出现 ClassNotFoundException / NoSuchMethodError，
# 按报错类名在此追加 -keep 规则后重新打包。

# 崩溃堆栈保留源文件名与行号（配合 mapping.txt 可用 retrace 还原）
-keepattributes SourceFile,LineNumberTable
