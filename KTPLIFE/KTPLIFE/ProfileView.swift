//
//  ProfileView.swift
//  KTPLIFE
//

import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

struct ProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var authManager: AuthManager
    @EnvironmentObject private var pushNotificationManager: PushNotificationManager
    @EnvironmentObject private var avatarRepository: AvatarRepository
    @AppStorage(AppAppearance.storageKey) private var appearanceRawValue = AppAppearance.system.rawValue
    @State private var profile: UserProfile?
    @State private var firstName = ""
    @State private var lastName = ""
    @State private var major = ""
    @State private var graduationYear = ""
    @State private var dateOfBirth = ""
    @State private var phone = ""
    @State private var email = ""
    @State private var personalEmail = ""
    @State private var linkedinURL = ""
    @State private var pledgeClass = ""
    @State private var aboutMe = ""
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var selectedProfilePhoto: PhotosPickerItem?
    @State private var profilePhotoPreview: UIImage?
    @State private var isUpdatingProfilePhoto = false
    @State private var isDeletingAccount = false
    @State private var showsDeleteAccountConfirmation = false
    @State private var errorMessage: String?

    private var isPreview: Bool {
        ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }

    private var apiService: KTPAPIService {
        KTPAPIService(accessTokenProvider: { [authManager] in
            try await authManager.validAccessToken()
        })
    }

    private var selectedAppearance: AppAppearance {
        AppAppearance(rawValue: appearanceRawValue) ?? .system
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading profile...")
                } else if profile == nil {
                    ContentUnavailableView(
                        "Profile unavailable",
                        systemImage: "person.crop.circle.badge.exclamationmark",
                        description: Text(errorMessage ?? "The profile could not be loaded.")
                    )
                } else {
                    profileForm
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }

                if profile != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(isSaving ? "Saving..." : "Save") {
                            Task { await saveProfile() }
                        }
                        .disabled(isSaving || isDeletingAccount)
                    }
                }
            }
        }
        // Profile is presented in its own full-screen hosting controller. Apply
        // the live preference at that boundary so Appearance changes—including
        // returning to System—update before this screen is dismissed.
        .preferredColorScheme(selectedAppearance.preferredColorScheme)
        .task {
            await loadProfile()
        }
        .alert("Delete Account?", isPresented: $showsDeleteAccountConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Account", role: .destructive) {
                Task { await deleteAccount() }
            }
        } message: {
            Text("This permanently anonymizes your KTP Me profile and signs you out. Your messages and shared photos remain so other members’ conversations and albums are not broken. Chapter SSO access must be revoked separately by eboard.")
        }
    }

    private var profileForm: some View {
        Form {
            Section {
                VStack(spacing: 12) {
                    ZStack(alignment: .bottomTrailing) {
                        CurrentUserAvatarView(size: 92, previewImage: profilePhotoPreview)

                        PhotosPicker(
                            selection: $selectedProfilePhoto,
                            matching: .images,
                            preferredItemEncoding: .current
                        ) {
                            Image(systemName: isUpdatingProfilePhoto ? "hourglass" : "camera.fill")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 30, height: 30)
                                .background(AppSurfaceColor.primaryControl, in: Circle())
                                .overlay {
                                    Circle().stroke(AppSystemColor.elevatedBackground, lineWidth: 2)
                                }
                        }
                        .buttonStyle(.plain)
                        .disabled(isUpdatingProfilePhoto || isSaving)
                        .accessibilityLabel(isUpdatingProfilePhoto ? "Updating profile picture" : "Change profile picture")
                    }

                    Text(profile?.displayName ?? "KTP Member")
                        .font(AppFont.title(24))

                    if let username = profile?.username?.nonEmptyTrimmed {
                        Text("@\(username)")
                            .font(AppFont.footnote())
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .appElevatedSurface(radius: 28)
            } header: {
                Text("My Account")
                    .font(AppFont.title(22))
                    .foregroundStyle(AppSystemColor.primaryLabel)
                    .textCase(nil)
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
            .listRowBackground(Color.clear)

            Section {
                VStack(alignment: .leading, spacing: 18) {
                    profileField(title: "First name") {
                        TextField("First name", text: $firstName)
                            .textContentType(.givenName)
                    }
                    profileField(title: "Last name") {
                        TextField("Last name", text: $lastName)
                            .textContentType(.familyName)
                    }
                    profileField(title: "Major") {
                        TextField("Major or program", text: $major)
                    }
                    profileField(title: "Graduation year") {
                        TextField("e.g. 2027", text: $graduationYear)
                            .keyboardType(.numberPad)
                    }
                    profileField(title: "Pledge class") {
                        TextField("Pledge class", text: $pledgeClass)
                    }
                    profileField(title: "Date of birth") {
                        TextField("MM/DD/YYYY", text: $dateOfBirth)
                            .textContentType(.birthdate)
                            .keyboardType(.numbersAndPunctuation)
                    }
                    profileField(title: "Phone") {
                        TextField("Phone number", text: $phone)
                            .textContentType(.telephoneNumber)
                            .keyboardType(.phonePad)
                    }
                    profileField(title: "UGA email") {
                        TextField("name@uga.edu", text: $email)
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                    }
                    profileField(title: "Personal email") {
                        TextField("Personal email", text: $personalEmail)
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                    }
                    profileField(title: "LinkedIn") {
                        TextField("linkedin.com/in/username", text: $linkedinURL)
                            .textContentType(.URL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        profileFieldHeader("About me")

                        TextEditor(text: $aboutMe)
                            .frame(minHeight: 120)
                            .padding(8)
                            .scrollContentBackground(.hidden)
                            .background(AppSystemColor.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .onChange(of: aboutMe) { _, value in
                                if value.count > 600 {
                                    aboutMe = String(value.prefix(600))
                                }
                            }

                        Text("\(aboutMe.count)/600")
                            .font(AppFont.caption())
                            .foregroundStyle(AppSystemColor.secondaryLabel)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .padding(.vertical, 6)
            } header: {
                Label("Profile Details", systemImage: "person.text.rectangle")
            }
            .listRowBackground(AppSystemColor.elevatedBackground)

            if let memberGroup = profile?.memberGroup?.nonEmptyTrimmed {
                Section("Membership") {
                    LabeledContent("Group", value: memberGroup.capitalized)
                }
                .listRowBackground(AppSystemColor.elevatedBackground)
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(AppFont.footnote())
                        .foregroundStyle(.red)
                }
                .listRowBackground(AppSystemColor.elevatedBackground)
            }

            Section("Support and community") {
                Link(destination: URL(string: "https://ugaktp.com/code-of-conduct")!) {
                    SettingsRowLabel(
                        title: "Community Guidelines",
                        subtitle: "Chapter standards and expectations",
                        systemImage: "person.3.fill"
                    )
                }

                Link(destination: URL(string: "mailto:uga.ktp@gmail.com")!) {
                    SettingsRowLabel(
                        title: "Contact Support",
                        subtitle: "Get help from the KTP team",
                        systemImage: "envelope.fill"
                    )
                }
            }
            .listRowBackground(AppSystemColor.elevatedBackground)

            if profile?.memberGroup?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "eboard" {
                Section("Chapter leadership") {
                    NavigationLink {
                        ReportsView()
                    } label: {
                        SettingsRowLabel(
                            title: "Review Reports",
                            subtitle: "Manage member-submitted reports",
                            systemImage: "checklist"
                        )
                    }
                }
                .listRowBackground(AppSystemColor.elevatedBackground)
            }

            Section("Settings") {
                NavigationLink {
                    AppearanceSettingsView()
                } label: {
                    SettingsRowLabel(
                        title: "Appearance",
                        subtitle: "System, light, or dark mode",
                        systemImage: "circle.lefthalf.filled"
                    )
                }

                NavigationLink {
                    NotificationSettingsView(apiService: apiService)
                } label: {
                    SettingsRowLabel(
                        title: "Notifications",
                        subtitle: "Choose the updates you receive",
                        systemImage: "bell.fill"
                    )
                }
            }
            .listRowBackground(AppSystemColor.elevatedBackground)

            Section("Account") {
                Button {
                    Task {
                        await pushNotificationManager.unregister(using: apiService)
                        await authManager.signOut()
                        dismiss()
                    }
                } label: {
                    Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(isDeletingAccount)
                .frame(maxWidth: .infinity)

                Button(role: .destructive) {
                    showsDeleteAccountConfirmation = true
                } label: {
                    Label(
                        isDeletingAccount ? "Deleting Account..." : "Delete Account",
                        systemImage: "trash"
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(isDeletingAccount)
                .frame(maxWidth: .infinity)
            }
            .listRowBackground(AppSystemColor.elevatedBackground)
        }
        .tint(AppSurfaceColor.primaryControl)
        .listSectionSpacing(20)
        .scrollContentBackground(.hidden)
        .background(AppSystemColor.background)
        .onChange(of: selectedProfilePhoto) { _, item in
            guard let item else { return }
            Task { await updateProfilePicture(from: item) }
        }
    }

    @MainActor
    private func loadProfile() async {
        if let cachedProfile = authManager.currentUserProfile {
            apply(cachedProfile)
            isLoading = false
        }

#if DEBUG
        if isPreview {
            apply(.preview)
            isLoading = false
            return
        }
#endif

        do {
            let loadedProfile = try await apiService.fetchCurrentUserProfile()
            guard !Task.isCancelled else { return }
            authManager.updateCurrentUserProfile(loadedProfile)
            apply(loadedProfile)
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            if profile == nil {
                errorMessage = "Could not load your profile. \(error.localizedDescription)"
            }
        }

        isLoading = false
    }

    @MainActor
    private func saveProfile() async {
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil

        let request = UpdateUserProfileRequest(
            preferredName: nil,
            firstName: firstName.nonEmptyTrimmed,
            lastName: lastName.nonEmptyTrimmed,
            dateOfBirth: requestBirthdate(from: dateOfBirth),
            major: major.nonEmptyTrimmed,
            graduationDate: graduationYear.nonEmptyTrimmed,
            phone: phone.nonEmptyTrimmed,
            email: email.nonEmptyTrimmed,
            personalEmail: personalEmail.nonEmptyTrimmed,
            linkedinURL: linkedinURL.nonEmptyTrimmed,
            pledgeClass: pledgeClass.nonEmptyTrimmed,
            aboutMe: aboutMe.nonEmptyTrimmed
        )

        do {
            let updatedProfile = try await apiService.updateCurrentUserProfile(request)
            authManager.updateCurrentUserProfile(updatedProfile)
            apply(updatedProfile)
            dismiss()
        } catch {
            errorMessage = "Could not save your profile. \(error.localizedDescription)"
        }

        isSaving = false
    }

    @MainActor
    private func deleteAccount() async {
        guard !isDeletingAccount else { return }
        isDeletingAccount = true
        errorMessage = nil

        do {
            await pushNotificationManager.unregister(using: apiService)
            try await apiService.deleteCurrentUser()
            await authManager.signOut()
            dismiss()
        } catch {
            errorMessage = "Could not delete your account. Please try again or contact support. \(error.localizedDescription)"
            isDeletingAccount = false
        }
    }

    private func apply(_ profile: UserProfile) {
        self.profile = profile
        firstName = profile.firstName ?? ""
        lastName = profile.lastName ?? ""
        major = profile.major ?? ""
        graduationYear = profile.graduationYear ?? ""
        dateOfBirth = displayBirthdate(profile.dateOfBirth)
        phone = profile.phone ?? ""
        email = profile.email ?? ""
        personalEmail = profile.personalEmail ?? ""
        linkedinURL = profile.linkedinURL ?? ""
        pledgeClass = profile.pledgeClass ?? ""
        aboutMe = profile.aboutMe ?? ""
    }

    @MainActor
    private func updateProfilePicture(from item: PhotosPickerItem) async {
        guard !isUpdatingProfilePhoto else { return }
        isUpdatingProfilePhoto = true
        errorMessage = nil
        let previousPreview = profilePhotoPreview
        defer {
            isUpdatingProfilePhoto = false
            selectedProfilePhoto = nil
        }

        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data)
            else {
                throw ProfilePictureError.unreadableImage
            }

            profilePhotoPreview = image
            let imageType = item.supportedContentTypes.first(where: { $0.conforms(to: .image) && $0.preferredMIMEType != nil }) ?? .jpeg
            let uploadImage = try ImageUploadEncoder.encodeForUpload(data: data, contentType: imageType)
            let updatedProfile = try await apiService.updateCurrentUserProfilePicture(
                MessageAttachmentUpload(
                    data: uploadImage.data,
                    fileName: "profile-picture.\(uploadImage.fileExtension)",
                    mimeType: uploadImage.mimeType
                )
            )
            avatarRepository.clear()
            authManager.updateCurrentUserProfile(updatedProfile)
            apply(updatedProfile)
        } catch is CancellationError {
            profilePhotoPreview = previousPreview
        } catch {
            profilePhotoPreview = previousPreview
            errorMessage = "Could not update your profile picture. Please try again."
        }
    }

    @ViewBuilder
    private func profileField<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            profileFieldHeader(title)
            content()
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .background(AppSystemColor.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func profileFieldHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(AppFont.caption(weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(AppSystemColor.secondaryLabel)
    }

    private func displayBirthdate(_ rawValue: String?) -> String {
        guard let rawValue = rawValue?.nonEmptyTrimmed else { return "" }
        let dateOnlyValue = String(rawValue.prefix(10))
        guard let date = ProfileDateFormatters.api.date(from: dateOnlyValue) else { return rawValue }
        return ProfileDateFormatters.display.string(from: date)
    }

    private func requestBirthdate(from displayValue: String) -> String? {
        guard let value = displayValue.nonEmptyTrimmed else { return nil }

        if let date = ProfileDateFormatters.display.date(from: value) {
            return ProfileDateFormatters.api.string(from: date)
        }

        let dateOnlyValue = String(value.prefix(10))
        if let date = ProfileDateFormatters.api.date(from: dateOnlyValue) {
            return ProfileDateFormatters.api.string(from: date)
        }

        return value
    }
}

private struct SettingsRowLabel: View {
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AppSystemColor.background)
                .frame(width: 34, height: 34)
                .background(AppSystemColor.primaryLabel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(AppSystemColor.primaryLabel)

                Text(subtitle)
                    .font(AppFont.caption())
                    .foregroundStyle(AppSystemColor.secondaryLabel)
            }
        }
        .padding(.vertical, 4)
    }
}

private enum ProfileDateFormatters {
    static let api: DateFormatter = makeFormatter("yyyy-MM-dd")
    static let display: DateFormatter = makeFormatter("MM/dd/yyyy")

    private static func makeFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter
    }
}

private enum ProfilePictureError: LocalizedError {
    case unreadableImage

    var errorDescription: String? {
        "Could not read the selected image."
    }
}

private struct AppearanceSettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(AppAppearance.storageKey) private var appearanceRawValue = AppAppearance.system.rawValue

    private var selectedAppearance: AppAppearance {
        AppAppearance(rawValue: appearanceRawValue) ?? .system
    }

    private var previewUsesDarkColors: Bool {
        selectedAppearance == .dark || (selectedAppearance == .system && colorScheme == .dark)
    }

    var body: some View {
        Form {
            Section {
                AppearancePreview(
                    appearance: selectedAppearance,
                    usesDarkColors: previewUsesDarkColors
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            } header: {
                Text("Preview")
            } footer: {
                Text("Your choice applies throughout KTP Life. The sign-in screen continues to follow your iPhone setting.")
            }
            .listRowBackground(Color.clear)

            Section("Choose an appearance") {
                ForEach(AppAppearance.allCases) { appearance in
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            appearanceRawValue = appearance.rawValue
                        }
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: appearance.systemImage)
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(
                                    appearance == selectedAppearance
                                        ? AppSystemColor.background
                                        : AppSystemColor.primaryLabel
                                )
                                .frame(width: 38, height: 38)
                                .background(
                                    appearance == selectedAppearance
                                        ? AppSystemColor.primaryLabel
                                        : AppSystemColor.insetBackground,
                                    in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                                )

                            VStack(alignment: .leading, spacing: 3) {
                                Text(appearance.title)
                                    .font(AppFont.subheadline(weight: .semibold))
                                    .foregroundStyle(AppSystemColor.primaryLabel)

                                Text(appearance.subtitle)
                                    .font(AppFont.caption())
                                    .foregroundStyle(AppSystemColor.secondaryLabel)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Spacer(minLength: 10)

                            Image(systemName: appearance == selectedAppearance ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(
                                    appearance == selectedAppearance
                                        ? AppSurfaceColor.primaryControl
                                        : AppSystemColor.secondaryLabel.opacity(0.5)
                                )
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(appearance == selectedAppearance ? .isSelected : [])
                }
            }
            .listRowBackground(AppSystemColor.elevatedBackground)

            Section("How it works") {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("System updates automatically")
                            .font(AppFont.subheadline(weight: .semibold))
                            .foregroundStyle(AppSystemColor.primaryLabel)
                        Text("When System is selected, KTP Life changes with your iPhone’s scheduled or manual appearance.")
                            .font(AppFont.caption())
                            .foregroundStyle(AppSystemColor.secondaryLabel)
                    }
                } icon: {
                    Image(systemName: "iphone.gen3")
                        .foregroundStyle(AppSurfaceColor.primaryControl)
                }
            }
            .listRowBackground(AppSystemColor.elevatedBackground)
        }
        .tint(AppSurfaceColor.primaryControl)
        .listSectionSpacing(20)
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(AppSystemColor.background)
    }
}

private struct AppearancePreview: View {
    let appearance: AppAppearance
    let usesDarkColors: Bool

    private var background: Color {
        usesDarkColors ? .black : Color(uiColor: .systemGroupedBackground)
    }

    private var surface: Color {
        usesDarkColors ? Color(white: 0.12) : .white
    }

    private var primary: Color {
        usesDarkColors ? .white : Color(uiColor: .label)
    }

    private var secondary: Color {
        usesDarkColors ? .white.opacity(0.58) : Color(uiColor: .secondaryLabel)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("KTP Life")
                        .font(AppFont.subheadline(weight: .bold))
                        .foregroundStyle(primary)
                    Text(appearance.title)
                        .font(AppFont.caption())
                        .foregroundStyle(secondary)
                }

                Spacer()

                Image(systemName: appearance.systemImage)
                    .foregroundStyle(primary)
                    .frame(width: 32, height: 32)
                    .background(surface, in: Circle())
            }
            .padding(16)

            VStack(spacing: 10) {
                ForEach(0..<3, id: \.self) { index in
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(index == 0 ? AppSurfaceColor.primaryControl : secondary.opacity(0.22))
                            .frame(width: 34, height: 34)

                        VStack(alignment: .leading, spacing: 5) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(primary.opacity(0.80))
                                .frame(width: index == 1 ? 102 : 132, height: 6)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(secondary.opacity(0.42))
                                .frame(width: index == 2 ? 126 : 158, height: 5)
                        }

                        Spacer()
                    }
                    .padding(10)
                    .background(surface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .background(background, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(secondary.opacity(0.22), lineWidth: 1)
        }
        .animation(.easeInOut(duration: 0.18), value: usesDarkColors)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(appearance.title) appearance preview")
    }
}

/// Reuses the shared, disk-backed avatar repository used by message threads.
struct CurrentUserAvatarView: View {
    @Environment(\.displayScale) private var displayScale
    @EnvironmentObject private var authManager: AuthManager
    @EnvironmentObject private var avatarRepository: AvatarRepository
    @State private var image: UIImage?

    let size: CGFloat
    let previewImage: UIImage?

    init(size: CGFloat, previewImage: UIImage? = nil) {
        self.size = size
        self.previewImage = previewImage
    }

    private var userID: String? {
        authManager.currentUserID
    }

    private var fallbackInitials: String {
        let name = authManager.currentUserProfile?.displayName
            ?? authManager.currentUserPreferredUsername
            ?? "KTP"
        let initials = String(name.split(separator: " ").prefix(2).compactMap(\.first)).uppercased()
        return initials.isEmpty ? "KT" : initials
    }

    private var apiService: KTPAPIService {
        KTPAPIService(accessTokenProvider: { [authManager] in
            try await authManager.validAccessToken()
        })
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(AppSystemColor.elevatedBackground)

            if let previewImage {
                Image(uiImage: previewImage)
                    .resizable()
                    .scaledToFill()
            } else if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Text(fallbackInitials)
                    .font(.system(size: size * 0.3, weight: .bold, design: .rounded))
                    .foregroundStyle(AppSystemColor.primaryLabel)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay {
            Circle()
                .stroke(AppSystemColor.separator.opacity(0.5), lineWidth: 1)
        }
        .task(id: "\(userID ?? "unknown")-\(authManager.currentUserProfile?.profilePictureAssetID ?? "no-photo")-\(Int(size * displayScale))") {
            await loadImage()
        }
        .accessibilityLabel("Your profile picture")
    }

    @MainActor
    private func loadImage() async {
        guard let userID else {
            image = nil
            return
        }

        let loadedImage = await avatarRepository.image(
            for: userID,
            pointSize: size,
            displayScale: displayScale,
            loadData: {
                try await apiService.fetchProfilePictureData(for: userID)
            }
        )
        guard !Task.isCancelled else { return }
        image = loadedImage
    }
}

#if DEBUG
#Preview("Profile") {
    ProfileView()
        .environmentObject(AuthManager.previewSignedOut)
        .environmentObject(AvatarRepository())
}
#endif
