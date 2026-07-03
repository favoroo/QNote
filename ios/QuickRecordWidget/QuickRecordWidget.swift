//
//  QuickRecordWidget.swift
//  QuickRecordWidget
//
//  QNote 快速记录桌面小组件
//  与 Android 端 QuickRecordWidgetProvider 对齐：4 个按钮（输入框/相册/相机/发送）
//  点击按钮通过 URL scheme 打开 App 并进入快速记录页（iOS WidgetKit 不支持桌面浮层）
//

import WidgetKit
import SwiftUI

/// 时间线数据（Widget 无需动态数据，仅占位）
struct QuickRecordEntry: TimelineEntry {
    let date: Date
}

/// 时间线 Provider：Widget 无数据刷新需求，policy 设为 .never
struct QuickRecordProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuickRecordEntry {
        QuickRecordEntry(date: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (QuickRecordEntry) -> Void) {
        completion(QuickRecordEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuickRecordEntry>) -> Void) {
        completion(Timeline(entries: [QuickRecordEntry(date: Date())], policy: .never))
    }
}

/// Widget 视图：横条布局，左侧"快速记录..."输入框样式 + 右侧三个图标按钮
struct QuickRecordWidgetEntryView: View {
    var body: some View {
        HStack(spacing: 12) {
            // 左侧：模拟输入框样式，点击进入快速记录页（默认 input 模式）
            Link(destination: URL(string: "qnote://quick_record?action=input")!) {
                HStack(spacing: 8) {
                    Image(systemName: "pencil.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.tint)
                    Text("快速记录...")
                        .font(.body)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            // 右侧：三个圆形图标按钮垂直排列
            VStack(spacing: 8) {
                iconButton(symbol: "photo.on.rectangle", action: "photo")
                iconButton(symbol: "camera", action: "camera")
                iconButton(symbol: "arrow.up.circle.fill", action: "send", filled: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .widgetBackground()
    }

    /// 单个圆形图标按钮
    /// - Parameters:
    ///   - symbol: SF Symbol 名称
    ///   - action: URL scheme 的 action 参数（photo/camera/send）
    ///   - filled: 是否使用填充样式（发送按钮高亮）
    private func iconButton(symbol: String, action: String, filled: Bool = false) -> some View {
        Link(destination: URL(string: "qnote://quick_record?action=\(action)")!) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(filled ? Color.white : Color.primary)
                .frame(width: 40, height: 40)
                .background(filled ? Color.accentColor : Color(.secondarySystemBackground))
                .clipShape(Circle())
        }
    }
}

/// Widget 配置：仅 medium 尺寸
struct QuickRecordWidget: Widget {
    let kind = "QuickRecordWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: QuickRecordProvider()) { _ in
            QuickRecordWidgetEntryView()
        }
        .supportedFamilies([.systemMedium])
        .configurationDisplayName("快速记录")
        .description("快速记录日记，支持文字、拍照、相册")
    }
}

/// Widget 背景兼容：iOS 17+ 使用 containerBackground，低版本使用普通 background
extension View {
    @ViewBuilder
    func widgetBackground() -> some View {
        if #available(iOSApplicationExtension 17.0, *) {
            self.containerBackground(.fill.tertiary, for: .widget)
        } else {
            self.background(Color(.systemBackground))
        }
    }
}
