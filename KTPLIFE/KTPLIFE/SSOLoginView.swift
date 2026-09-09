//
//  SSOLoginView.swift
//  KTPLIFE
//

import SafariServices
import SwiftUI

struct SSOLoginView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var typedRecruitmentQuestion = ""
    @State private var typewriterTask: Task<Void, Never>?
    @State private var enrollmentPage: EnrollmentPage?

    let isLoading: Bool
    let errorMessage: String?
    let signIn: () -> Void
    let signInWithDifferentAccount: () -> Void

    init(
        isLoading: Bool,
        errorMessage: String?,
        signIn: @escaping () -> Void,
        signInWithDifferentAccount: @escaping () -> Void = {}
    ) {
        self.isLoading = isLoading
        self.errorMessage = errorMessage
        self.signIn = signIn
        self.signInWithDifferentAccount = signInWithDifferentAccount
    }

    private let recruitmentQuestion = "Ready to join the University of Georgia’s premier Professional Technology Fraternity?"
    private let rushEnrollmentURL = URL(
        string: "https://ugaktp.com/rush/how-it-works"
    )!

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                VStack {
                    ZStack(alignment: .top) {
                        Text(recruitmentQuestion)
                            .opacity(0)
                            .accessibilityHidden(true)

                        Text(typedRecruitmentQuestion)
                            .accessibilityLabel(recruitmentQuestion)
                    }
                    .font(.system(size: 31, weight: .bold, design: .default))
                    .foregroundStyle(SSOLoginPalette.headlineText(for: colorScheme))
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.80)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 18)
                .frame(maxHeight: .infinity)
                .offset(y: -geometry.size.height * 0.09)

                VStack(alignment: .leading, spacing: 0) {
                    KTPLogoMark(maxWidth: 112, maxHeight: 44, alignment: .leading)
                        .colorMultiply(SSOLoginPalette.headlineText(for: colorScheme))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 22)
                        .padding(.top, 14)
                        .accessibilityHidden(true)

                    Spacer(minLength: 0)

                    actionPanel(
                        minimumHeight: max(210, geometry.size.height * 0.30),
                        bottomInset: geometry.safeAreaInsets.bottom
                    )
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        .ignoresSafeArea(edges: .bottom)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isLoading)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: errorMessage)
        .onAppear(perform: startTypewriterAnimation)
        .onDisappear {
            typewriterTask?.cancel()
            typewriterTask = nil
        }
        .sheet(item: $enrollmentPage) { page in
            EnrollmentSafariView(url: page.url)
        }
    }

    @ViewBuilder
    private func actionPanel(minimumHeight: CGFloat, bottomInset: CGFloat) -> some View {
        VStack(spacing: 14) {
            if #available(iOS 26.0, *), !reduceTransparency {
                GlassEffectContainer(spacing: 14) {
                    actionButtons(useGlass: true)
                }
            } else {
                actionButtons(useGlass: false)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 13, weight: .semibold, design: .default))
                    .foregroundStyle(SSOLoginPalette.errorText(for: colorScheme))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 24)
        .padding(.bottom, max(16, bottomInset + 8))
        .frame(maxWidth: .infinity, minHeight: minimumHeight, alignment: .top)
        .background(
            SSOLoginPalette.actionPanel(for: colorScheme),
            in: UnevenRoundedRectangle(
                topLeadingRadius: SSOLoginLayout.panelCornerRadius,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: SSOLoginLayout.panelCornerRadius,
                style: .continuous
            )
        )
    }

    private func actionButtons(useGlass: Bool) -> some View {
        VStack(spacing: 14) {
            Button(action: signIn) {
                HStack(spacing: 10) {
                    if isLoading {
                        ProgressView()
                            .tint(.white)
                            .transition(.scale.combined(with: .opacity))
                    }

                    Text(isLoading ? "Connecting…" : "Continue with KTP")
                        .contentTransition(.opacity)
                }
                .font(.system(size: 19, weight: .bold, design: .default))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 58)
                .contentShape(
                    RoundedRectangle(
                        cornerRadius: SSOLoginLayout.buttonCornerRadius,
                        style: .continuous
                    )
                )
            }
            .buttonStyle(.plain)
            .modifier(SSOLoginActionSurface(
                tint: SSOLoginPalette.signInButton,
                useGlass: useGlass
            ))
            .disabled(isLoading)
            .opacity(isLoading ? 0.72 : 1)

            Button {
                enrollmentPage = EnrollmentPage(url: rushEnrollmentURL)
            } label: {
                Text("Sign Up for Rush")
                    .font(.system(size: 19, weight: .bold, design: .default))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 58)
                    .contentShape(
                        RoundedRectangle(
                            cornerRadius: SSOLoginLayout.buttonCornerRadius,
                            style: .continuous
                        )
                    )
            }
            .buttonStyle(.plain)
            .modifier(SSOLoginActionSurface(
                tint: SSOLoginPalette.rushButton,
                useGlass: useGlass
            ))

            Button(action: signInWithDifferentAccount) {
                Text("Sign in with a different account")
                    .font(.system(size: 15, weight: .semibold, design: .default))
                    .foregroundStyle(.white.opacity(isLoading ? 0.55 : 0.90))
                    .underline()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isLoading)
            .accessibilityHint("Opens a private sign-in session without using the previously selected account")
        }
    }

    private func startTypewriterAnimation() {
        typewriterTask?.cancel()

        guard !reduceMotion else {
            typedRecruitmentQuestion = recruitmentQuestion
            return
        }

        typedRecruitmentQuestion = ""
        typewriterTask = Task { @MainActor in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(300))
                } catch {
                    return
                }

                for character in recruitmentQuestion {
                    guard !Task.isCancelled else { return }
                    typedRecruitmentQuestion.append(character)

                    do {
                        try await Task.sleep(for: .milliseconds(28))
                    } catch {
                        return
                    }
                }

                do {
                    try await Task.sleep(for: .seconds(6))
                } catch {
                    return
                }

                typedRecruitmentQuestion = ""
            }
        }
    }
}

private struct EnrollmentPage: Identifiable {
    let url: URL
    var id: URL { url }
}

private struct EnrollmentSafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = false
        let controller = SFSafariViewController(url: url, configuration: configuration)
        controller.dismissButtonStyle = .close
        return controller
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

private enum SSOLoginLayout {
    static let buttonCornerRadius: CGFloat = 17
    static let panelCornerRadius: CGFloat = 28
}

private enum SSOLoginPalette {
    static func brandBlue(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.30, green: 0.64, blue: 1.00)
            : Color(red: 0.055, green: 0.345, blue: 0.70)
    }

    static func actionPanel(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color(uiColor: .secondarySystemBackground) : .black
    }

    static func headlineText(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? .white : .black
    }

    static let signInButton = Color(
        red: 44.0 / 255.0,
        green: 42.0 / 255.0,
        blue: 44.0 / 255.0
    )
    static let rushButton = Color(red: 0.94, green: 0.70, blue: 0.20)

    static func errorText(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 1.00, green: 0.48, blue: 0.45)
            : Color(red: 1.00, green: 0.58, blue: 0.54)
    }
}

private struct SSOLoginActionSurface: ViewModifier {
    let tint: Color
    let useGlass: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), useGlass {
            content
                .glassEffect(
                    .regular.tint(tint).interactive(),
                    in: RoundedRectangle(
                        cornerRadius: SSOLoginLayout.buttonCornerRadius,
                        style: .continuous
                    )
                )
        } else {
            content
                .background(
                    tint,
                    in: RoundedRectangle(
                        cornerRadius: SSOLoginLayout.buttonCornerRadius,
                        style: .continuous
                    )
                )
                .overlay {
                    RoundedRectangle(
                        cornerRadius: SSOLoginLayout.buttonCornerRadius,
                        style: .continuous
                    )
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                }
        }
    }
}

/// Startup screen reproduced from Figma node 41:159 while authentication state restores.
struct KTPSplashView: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            KTPLogoMark(maxWidth: 236, maxHeight: 135)
                .foregroundStyle(.white)
                .offset(y: -12)
        }
        .accessibilityLabel("Kappa Theta Pi Phi Chapter")
    }
}

#if DEBUG
#Preview("SSO Login") {
    SSOLoginView(isLoading: false, errorMessage: nil, signIn: {})
        .environment(\.pageTheme, PageTheme.auth)
        .preferredColorScheme(.light)
}
#endif
