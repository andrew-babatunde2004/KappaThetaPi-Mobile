//
//  AppTab.swift
//  KTPLIFE
//

import SwiftUI

// Only `allCases` is rendered in the bottom tab bar. The retained legacy routes
// keep their screens available to in-app entry points and previews.
enum AppTab: CaseIterable, Identifiable {
    case home
    case community
    case photos
    case calendar
    case attendance

    // Non-tab destinations.
    case messages
    case directory
    case opportunities

    static var allCases: [AppTab] { visibleTabs(for: nil) }

    static func visibleTabs(for group: MemberGroup?) -> [AppTab] {
        var tabs: [AppTab] = [.home, .community]

        if group?.canAccessFilesAndPhotos != false {
            tabs.append(.photos)
        }

        tabs.append(.calendar)
        if group?.canAccessAttendance != false {
            tabs.append(.attendance)
        }
        return tabs
    }

    var id: Self { self }

    var icon: String {
        switch self {
        case .home:
            return "house.fill"
        case .community:
            return "person.2.fill"
        case .messages:
            return "bubble.left.and.bubble.right.fill"
        case .directory:
            return "person.2.fill"
        case .opportunities:
            return "briefcase.fill"
        case .calendar:
            return "calendar"
        case .photos:
            return "photo"
        case .attendance:
            return "checkmark.seal.fill"
        }
    }

    var title: String {
        switch self {
        case .home:
            return "Home"
        case .community:
            return "Community"
        case .messages:
            return "Messages"
        case .directory:
            return "Directory"
        case .opportunities:
            return "Opportunities"
        case .calendar:
            return "Calendar"
        case .photos:
            return "Photos"
        case .attendance:
            return "Attendance"
        }
    }

    var theme: PageTheme {
        switch self {
        case .home:
            return .defaultWhite
        case .community:
            return .community
        case .messages:
            return .community
        case .directory:
            return .defaultWhite
        case .opportunities:
            return .opportunities
        case .calendar:
            return .calendar
        case .photos:
            return .defaultWhite
        case .attendance:
            return .defaultWhite
        }
    }
}

struct PageTheme {
  /// Light pages (Home) use dark chrome on the tab bar; dark pages use light glass + white icons.
  enum SurfaceStyle {
    case light
    case dark
  }

  let surfaceStyle: SurfaceStyle
  let lightModeBackground: Color
  let darkModeBackground: Color

  /// Page background for the current system appearance.
  func backgroundColor(for colorScheme: ColorScheme) -> Color {
    if surfaceStyle == .light {
      return AppSystemColor.background
    }

    if AppAppearance.current == .dark {
      return AppSystemColor.background
    }

    return colorScheme == .dark ? darkModeBackground : lightModeBackground
  }

  /// Liquid glass tint on the bottom tab bar. Tweak opacity here.
  func tabBarGlassTint(for colorScheme: ColorScheme) -> Color {
    switch (surfaceStyle, colorScheme) {
    case (.light, .light):
      return Color.black.opacity(0.07)
    case (.light, .dark):
      return Color.white.opacity(0.12)
    case (.dark, _):
      return Color.white.opacity(0.10)
    @unknown default:
      return Color.white.opacity(0.10)
    }
  }

  func tabBarIconOpacity(isSelected: Bool) -> Double {
    isSelected ? 1 : 0.74
  }

  func tabBarIconColor(isSelected: Bool, colorScheme: ColorScheme) -> Color {
    let opacity = tabBarIconOpacity(isSelected: isSelected)
    switch (surfaceStyle, colorScheme) {
    case (.light, .light):
      return Color(red: 0.12, green: 0.14, blue: 0.18).opacity(opacity)
    default:
      return Color.white.opacity(opacity)
    }
  }

  // MARK: - Presets

  // Dark branded pages: Messages, Calendar, Photos, Auth, Opportunities.
  static let defaultBlue = PageTheme(
    surfaceStyle: .dark,
    lightModeBackground: Color(red: 0.10, green: 0.20, blue: 0.40),
    darkModeBackground: Color(red: 0.06, green: 0.10, blue: 0.22)
  )

  // Standard pages follow the user's system appearance exactly.
  static let defaultWhite = PageTheme(
    surfaceStyle: .light,
    lightModeBackground: AppSystemColor.background,
    darkModeBackground: AppSystemColor.background
  )

  static let calendar = defaultWhite

  static let community = PageTheme(
    surfaceStyle: .light,
    lightModeBackground: AppSystemColor.background,
    darkModeBackground: AppSystemColor.background
  )

  static let opportunities = defaultBlue
  static let auth = defaultBlue

  /// Use in `#Preview` blocks. Pass `.dark` to preview dark mode in the canvas.
  func previewBackground(_ colorScheme: ColorScheme = .light) -> Color {
    backgroundColor(for: colorScheme)
  }
}

private struct PageThemeKey: EnvironmentKey {
  static let defaultValue: PageTheme = .defaultWhite
}

extension EnvironmentValues {
  var pageTheme: PageTheme {
    get { self[PageThemeKey.self] }
    set { self[PageThemeKey.self] = newValue }
  }
}
