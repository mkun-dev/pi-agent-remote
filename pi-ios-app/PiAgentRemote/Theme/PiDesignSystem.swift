import SwiftUI

extension SwiftUI.Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }

        self.init(.sRGB,
                  red: Double(r) / 255,
                  green: Double(g) / 255,
                  blue: Double(b) / 255,
                  opacity: Double(a) / 255)
    }
}

// MARK: - Pi Design System

/// 统一的 UI 设计规范，所有组件通过此 enum 获取颜色、字体、间距等 Token。
/// 不引入新状态，不修改协议，纯 UI 层常量。
enum PiDesignSystem {
    
    // MARK: - Colors
    
    enum Color {
        // Surface
        static let background = SwiftUI.Color(hex: "#0D1117")
        static let surface = SwiftUI.Color(hex: "#161B22")
        static let card = SwiftUI.Color(hex: "#161B22")
        static let panelElevated = SwiftUI.Color(hex: "#1C2128")
        static let codeBg = SwiftUI.Color.white.opacity(0.04)

        // Text
        static let primary = SwiftUI.Color(hex: "#E6EDF3")
        static let secondary = SwiftUI.Color(hex: "#8B949E")
        static let tertiary = SwiftUI.Color(hex: "#8B949E").opacity(0.72)

        // Accent
        static let accent = SwiftUI.Color(hex: "#58A6FF")

        // Agent States
        static let piBrand = SwiftUI.Color(hex: "#58A6FF")
        static let thinking = SwiftUI.Color(hex: "#D29922")
        static let streaming = SwiftUI.Color(hex: "#58A6FF")
        static let tool = SwiftUI.Color(hex: "#58A6FF")
        static let completed = SwiftUI.Color(hex: "#3FB950")
        static let failed = SwiftUI.Color(hex: "#F85149")
        static let idle = SwiftUI.Color(hex: "#8B949E")

        // Diff
        static let diffAdd = SwiftUI.Color(hex: "#3FB950")
        static let diffRemove = SwiftUI.Color(hex: "#F85149")
        static let diffAddBg = SwiftUI.Color(hex: "#3FB950").opacity(0.14)
        static let diffRemoveBg = SwiftUI.Color(hex: "#F85149").opacity(0.14)

        // Connection
        static let connected = SwiftUI.Color(hex: "#3FB950")
        static let disconnected = SwiftUI.Color(hex: "#F85149")
        static let pcOffline = SwiftUI.Color(hex: "#D29922")

        // User bubble
        static let userBubbleStart = SwiftUI.Color(hex: "#58A6FF")
        static let userBubbleEnd = SwiftUI.Color(hex: "#3B82F6")

        // Borders
        static let border = SwiftUI.Color.white.opacity(0.08)
        static let divider = SwiftUI.Color.white.opacity(0.10)
    }
    
    // MARK: - Typography
    
    enum Font {
        static let title = SwiftUI.Font.system(size: 28, weight: .bold)
        static let headline = SwiftUI.Font.system(size: 17, weight: .semibold)
        static let subheadline = SwiftUI.Font.system(size: 15, weight: .semibold)
        static let body = SwiftUI.Font.system(size: 15)
        static let caption = SwiftUI.Font.system(size: 12, weight: .medium)
        static let captionBold = SwiftUI.Font.system(size: 12, weight: .semibold)
        static let caption2 = SwiftUI.Font.system(size: 11, weight: .medium)
        static let mono = SwiftUI.Font.system(size: 13, weight: .regular, design: .monospaced)
        static let monoSpan = SwiftUI.Font.system(size: 14, weight: .regular, design: .monospaced)
        static let monoDigit = SwiftUI.Font.system(size: 11, weight: .medium, design: .monospaced)
    }
    
    // MARK: - Spacing
    
    enum Spacing {
        static let xs: CGFloat  = 4
        static let sm: CGFloat  = 8
        static let md: CGFloat  = 16
        static let lg: CGFloat  = 24
        static let xl: CGFloat  = 32
        static let xxl: CGFloat = 32
    }
    
    // MARK: - Radius
    
    enum Radius {
        static let sm: CGFloat  = 8
        static let md: CGFloat  = 16
        static let lg: CGFloat  = 20
        static let xl: CGFloat  = 24
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
    
    func piCapsuleSurface(tint: Color = PiDesignSystem.Color.panelElevated) -> some View {
        self
            .background(tint, in: Capsule())
            .overlay {
                Capsule().stroke(PiDesignSystem.Color.border, lineWidth: 1)
            }
    }
    
    func piTintCapsule(_ tint: Color, opacity: Double = 0.12) -> some View {
        self
            .background(tint.opacity(opacity), in: Capsule())
    }
    
    func piPrimaryButton(radius: CGFloat = 14) -> some View {
        self
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(PiDesignSystem.Color.accent, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
    
    func piSecondaryButton(radius: CGFloat = 14) -> some View {
        self
            .buttonStyle(.plain)
            .foregroundStyle(PiDesignSystem.Color.primary)
            .background(PiDesignSystem.Color.panelElevated, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(PiDesignSystem.Color.border, lineWidth: 1)
            }
    }
    
    func piInputSurface(radius: CGFloat = 14) -> some View {
        self
            .background(PiDesignSystem.Color.panelElevated, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(PiDesignSystem.Color.border, lineWidth: 1)
            }
    }
    
    func piIconButtonSurface(radius: CGFloat = 12) -> some View {
        self
            .buttonStyle(.plain)
            .background(PiDesignSystem.Color.panelElevated, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(PiDesignSystem.Color.border, lineWidth: 1)
            }
    }
    
    func piGlassCard(radius: CGFloat = 22) -> some View {
        self
            .background(.ultraThinMaterial)
            .background(PiDesignSystem.Color.surface.opacity(0.92))
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(PiDesignSystem.Color.border, lineWidth: 1)
            }
    }
    
    func piCircleSurface(tint: Color = PiDesignSystem.Color.panelElevated, lineWidth: CGFloat = 1) -> some View {
        self
            .background(tint, in: Circle())
            .overlay {
                Circle().stroke(PiDesignSystem.Color.border, lineWidth: lineWidth)
            }
    }
    
    func piTintCircle(_ tint: Color, opacity: Double = 0.12) -> some View {
        self
            .background(tint.opacity(opacity), in: Circle())
    }
    
    func piFilledCircle(_ tint: Color) -> some View {
        self
            .background(tint, in: Circle())
    }
    
    func piPreviewClip(radius: CGFloat = 14, lineWidth: CGFloat = 1) -> some View {
        self
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(PiDesignSystem.Color.border, lineWidth: lineWidth)
            }
    }
    
    func piTintPanel(_ tint: Color, opacity: Double = 0.08, borderOpacity: Double = 0.22, radius: CGFloat = 12) -> some View {
        self
            .background(tint.opacity(opacity), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(tint.opacity(borderOpacity), lineWidth: 1)
            }
    }
}
