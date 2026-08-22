import SwiftUI

// MARK: - Pi Design System

/// 统一的 UI 设计规范，所有组件通过此 enum 获取颜色、字体、间距等 Token。
/// 不引入新状态，不修改协议，纯 UI 层常量。
enum PiDesignSystem {
    
    // MARK: - Colors
    
    enum Color {
        // Surface
        static let background = SwiftUI.Color(uiColor: .systemBackground)
        static let surface     = SwiftUI.Color(uiColor: .secondarySystemBackground)
        static let card        = SwiftUI.Color(uiColor: .secondarySystemBackground)
        static let codeBg      = SwiftUI.Color(uiColor: .tertiarySystemFill)
        
        // Text
        static let primary     = SwiftUI.Color.primary
        static let secondary   = SwiftUI.Color.secondary
        static let tertiary    = SwiftUI.Color.secondary.opacity(0.6)
        
        // Accent
        static let accent      = SwiftUI.Color.accentColor
        
        // Agent States
        static let piBrand     = SwiftUI.Color.indigo
        static let thinking    = SwiftUI.Color.orange
        static let streaming   = SwiftUI.Color.blue
        static let tool        = SwiftUI.Color.purple
        static let completed   = SwiftUI.Color.green
        static let failed      = SwiftUI.Color.red
        static let idle        = SwiftUI.Color.secondary
        
        // Diff
        static let diffAdd     = SwiftUI.Color.green
        static let diffRemove  = SwiftUI.Color.red
        static let diffAddBg   = SwiftUI.Color.green.opacity(0.08)
        static let diffRemoveBg = SwiftUI.Color.red.opacity(0.08)
        
        // Connection
        static let connected   = SwiftUI.Color.green
        static let disconnected = SwiftUI.Color.red
        static let pcOffline   = SwiftUI.Color.orange
        
        // User bubble
        static let userBubbleStart = SwiftUI.Color.blue
        static let userBubbleEnd   = SwiftUI.Color.indigo
        
        // Borders
        static let border      = SwiftUI.Color.secondary.opacity(0.12)
        static let divider     = SwiftUI.Color.secondary.opacity(0.18)
    }
    
    // MARK: - Typography
    
    enum Font {
        static let title       = SwiftUI.Font.title3.weight(.bold)
        static let headline    = SwiftUI.Font.headline
        static let subheadline = SwiftUI.Font.subheadline.weight(.semibold)
        static let body        = SwiftUI.Font.body
        static let caption     = SwiftUI.Font.caption
        static let captionBold = SwiftUI.Font.caption.weight(.semibold)
        static let caption2    = SwiftUI.Font.caption2
        static let mono        = SwiftUI.Font.system(.caption, design: .monospaced)
        static let monoSpan    = SwiftUI.Font.system(.footnote, design: .monospaced)
        static let monoDigit   = SwiftUI.Font.caption2.monospacedDigit()
    }
    
    // MARK: - Spacing
    
    enum Spacing {
        static let xs: CGFloat  = 4
        static let sm: CGFloat  = 8
        static let md: CGFloat  = 12
        static let lg: CGFloat  = 16
        static let xl: CGFloat  = 24
        static let xxl: CGFloat = 32
    }
    
    // MARK: - Radius
    
    enum Radius {
        static let sm: CGFloat  = 8
        static let md: CGFloat  = 10
        static let lg: CGFloat  = 12
        static let xl: CGFloat  = 16
        static let bubble: CGFloat = 18
        static let pill: CGFloat   = 99
    }
    
    // MARK: - Shadow
    
    enum Shadow {
        static func card(_ color: SwiftUI.Color = .black) -> some View {
            color.opacity(0.06)
        }
        static let userBubbleRadius: CGFloat = 4
        static let userBubbleY: CGFloat = 2
    }
    
    // MARK: - Icon
    
    enum Icon {
        static func small(_ name: String) -> some View {
            Image(systemName: name).font(.system(size: 10))
        }
        static func medium(_ name: String) -> some View {
            Image(systemName: name).font(.system(size: 14, weight: .semibold))
        }
    }
    
    // MARK: - Touch
    
    enum Touch {
        static let minHeight: CGFloat = 44
        static let minWidth: CGFloat  = 44
    }
    
    // MARK: - Animation
    
    enum Animation {
        static let `default`: SwiftUI.Animation = .easeInOut(duration: 0.22)
        static let quick: SwiftUI.Animation = .easeOut(duration: 0.15)
        static let slow: SwiftUI.Animation = .easeInOut(duration: 0.35)
    }
    
    // MARK: - Agent State Mapping
    
    static func statusColor(_ state: AgentStatus) -> SwiftUI.Color {
        switch state {
        case .idle:       return Color.idle
        case .receiving, .thinking, .planning: return Color.thinking
        case .usingTool:  return Color.tool
        case .streaming:  return Color.streaming
        case .completed:  return Color.completed
        case .error:      return Color.failed
        }
    }
    
    static func statusLabel(_ state: AgentStatus) -> String {
        switch state {
        case .idle:       return "就绪"
        case .receiving:  return "接收中"
        case .thinking:   return "思考中"
        case .planning:   return "规划中"
        case .usingTool:  return "执行工具"
        case .streaming:  return "生成中"
        case .completed:  return "完成"
        case .error(let msg): return msg.isEmpty ? "出错" : msg
        }
    }
    
    static func statusIcon(_ state: AgentStatus) -> String {
        switch state {
        case .idle:       return "circle"
        case .receiving:  return "arrow.down.circle"
        case .thinking:   return "brain"
        case .planning:   return "lightbulb"
        case .usingTool:  return "hammer"
        case .streaming:  return "text.bubble"
        case .completed:  return "checkmark.circle.fill"
        case .error:      return "exclamationmark.triangle.fill"
        }
    }
}

// MARK: - Card Modifier

extension View {
    func piCard(color: Color = PiDesignSystem.Color.card, radius: CGFloat = PiDesignSystem.Radius.lg) -> some View {
        self
            .background(color, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(PiDesignSystem.Color.border, lineWidth: 1)
            }
    }
    
    func piSurface() -> some View {
        self.background(PiDesignSystem.Color.surface)
    }
    
    func piChip(_ tint: Color = PiDesignSystem.Color.secondary) -> some View {
        self
            .padding(.horizontal, PiDesignSystem.Spacing.sm)
            .padding(.vertical, PiDesignSystem.Spacing.xs - 1)
            .background(tint.opacity(0.08), in: Capsule())
    }
}
