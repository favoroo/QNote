# QNote Release 混淆规则：Flutter 引擎 + 插件反射保护，业务代码允许 R8 优化裁剪
# 注意：Flutter Gradle 插件自带基础规则，这里只补应用侧必须保留的部分

# Flutter 引擎与插件注册表（反射调用，必须保留）
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class com.appone.qnote_flutter.** { *; }

# 平台通道方法名靠字符串反射查找，不混淆 MainActivity 及插件类的方法名
-keepclasseswithmembernames class * {
    native <methods>;
}
-keepclassmembers class * {
    @android.webkit.JavascriptInterface <methods>;
}

# 小组件 / 通知 / 快捷记录等原生入口（Manifest 中引用，反射实例化）
-keep class com.appone.qnote_flutter.TodoWidgetProvider { *; }
-keep class com.appone.qnote_flutter.QuickTodoAddActivity { *; }
-keep class com.appone.qnote_flutter.QuickRecordActivity { *; }

# Flutter 引擎引用了 Play Core 分包安装类，但 APK 构建不打包该库
# （仅 deferred-components / App Bundle 场景需要），缺失时只告警不中断
-dontwarn com.google.android.play.core.**
