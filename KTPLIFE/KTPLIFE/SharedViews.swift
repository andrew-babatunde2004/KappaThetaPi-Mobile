//
//  SharedViews.swift
//  KTPLIFE
//

import Foundation
import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    static let storageKey = "appAppearance"

    case system
    case light
    case dark

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var subtitle: String {
        switch self {
        case .system:
            "Automatically matches your iPhone setting"
        case .light:
            "Uses bright backgrounds and dark text"
        case .dark:
            "Uses darker surfaces in low-light environments"
        }
    }

    var systemImage: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.stars.fill"
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    static var current: AppAppearance {
        guard let rawValue = UserDefaults.standard.string(forKey: storageKey),
              let appearance = AppAppearance(rawValue: rawValue)
        else {
            return .system
        }
        return appearance
    }
}

private struct AppAppearanceKey: EnvironmentKey {
    static let defaultValue = AppAppearance.system
}

extension EnvironmentValues {
    var appAppearance: AppAppearance {
        get { self[AppAppearanceKey.self] }
        set { self[AppAppearanceKey.self] = newValue }
    }
}

struct KTPLogoMark: View {
    var maxWidth: CGFloat = 220
    var maxHeight: CGFloat = 78
    var alignment: Alignment = .center

    var body: some View {
        Image("KTPLogo")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .appTextPrimary()
            .frame(maxWidth: maxWidth, maxHeight: maxHeight, alignment: alignment)
    }
}

struct EmptyState: View {
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(AppFont.headline())
                .appTextOnCard()

            Text(message)
                .font(AppFont.subheadline())
                .appTextOnCardSecondary()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .matteCard(radius: 28)
    }
}

struct AppSectionHeading: View {
    let eyebrow: String?
    let title: String
    let systemImage: String?

    init(
        eyebrow: String? = nil,
        title: String,
        systemImage: String? = nil
    ) {
        self.eyebrow = eyebrow
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                if let eyebrow {
                    Text(eyebrow)
                        .font(AppFont.caption(weight: .bold))
                        .tracking(1.2)
                        .textCase(.uppercase)
                        .foregroundStyle(AppSystemColor.secondaryLabel)
                }

                Text(title)
                    .font(AppFont.largeTitle())
                    .foregroundStyle(AppSystemColor.primaryLabel)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .allowsTightening(true)
            }

            Spacer(minLength: 8)

            if let systemImage {
                AppIconBadge(systemImage: systemImage, size: 48)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AppIconBadge: View {
    let systemImage: String
    var size: CGFloat = 42

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(AppSystemColor.primaryLabel)
            .frame(width: size, height: size)
            .background(AppSystemColor.insetBackground, in: RoundedRectangle(cornerRadius: size * 0.34, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.34, style: .continuous)
                    .stroke(AppSystemColor.separator.opacity(0.32), lineWidth: 1)
            }
    }
}

struct AppStatusSurface: View {
    let message: String
    var systemImage: String = "info.circle"

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            AppIconBadge(systemImage: systemImage)

            Text(message)
                .font(AppFont.subheadline())
                .foregroundStyle(AppSystemColor.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .appElevatedSurface()
    }
}

extension View {

    func loginCard(radius: CGFloat = 24) -> some View {
        background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(AppSurfaceColor.loginCard)
        )
        .overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(AppSurfaceColor.cardBorder, lineWidth: 1)
        }
    }
}

extension View {
    func matteCard(radius: CGFloat = 26) -> some View {
        background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(AppSurfaceColor.card)
        )
        .overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(AppSurfaceColor.cardBorder, lineWidth: 1)
        }
    }

    func appElevatedSurface(radius: CGFloat = 22) -> some View {
        background(
            AppSystemColor.elevatedBackground,
            in: RoundedRectangle(cornerRadius: radius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(AppSystemColor.separator.opacity(0.38), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.055), radius: 14, y: 6)
    }
}

enum AppSurfaceColor {
    static let loginCard = Color(red: 0.17, green: 0.27, blue: 0.45)
    static let card = Color(white: 0.08)
    static let cardBorder = Color(red: 0.23, green: 0.33, blue: 0.51)
    static let primaryControl = Color(red: 0.27, green: 0.37, blue: 0.55)
    static let disabledControl = Color(red: 0.14, green: 0.24, blue: 0.42)
    static let lightPanel = Color(red: 0.66, green: 0.70, blue: 0.78)
    static let lightPanelSecondary = Color(red: 0.70, green: 0.73, blue: 0.80)
    static let lightPanelBorder = Color(red: 0.54, green: 0.59, blue: 0.68)
    static let darkPill = Color(red: 0.14, green: 0.16, blue: 0.20)
    static let mutedPill = Color(red: 0.60, green: 0.64, blue: 0.72)
}

/// Semantic system surfaces shared by the standard app pages.
/// Branded authentication and opportunity panels intentionally use AppSurfaceColor instead.
enum AppSystemColor {
    static var background: Color {
        switch AppAppearance.current {
        case .system, .light:
            Color(uiColor: .systemBackground)
        case .dark:
            Color.black
        }
    }

    static var elevatedBackground: Color {
        switch AppAppearance.current {
        case .system, .light:
            Color(uiColor: .secondarySystemBackground)
        case .dark:
            Color(white: 0.09)
        }
    }

    static var insetBackground: Color {
        switch AppAppearance.current {
        case .system, .light:
            Color(uiColor: .tertiarySystemFill)
        case .dark:
            Color.white.opacity(0.12)
        }
    }

    static var primaryLabel: Color {
        switch AppAppearance.current {
        case .system, .light:
            Color(uiColor: .label)
        case .dark:
            Color.white
        }
    }

    static var secondaryLabel: Color {
        switch AppAppearance.current {
        case .system, .light:
            Color(uiColor: .secondaryLabel)
        case .dark:
            Color.white.opacity(0.68)
        }
    }

    static var separator: Color {
        switch AppAppearance.current {
        case .system, .light:
            Color(uiColor: .separator)
        case .dark:
            Color.white.opacity(0.18)
        }
    }
}
