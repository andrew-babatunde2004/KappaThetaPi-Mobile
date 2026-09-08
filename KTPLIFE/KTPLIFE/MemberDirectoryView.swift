//
//  MemberDirectoryView.swift
//  KTPLIFE
//

import SwiftUI

struct MemberDirectoryView: View {
    @EnvironmentObject private var authManager: AuthManager
    @EnvironmentObject private var avatarRepository: AvatarRepository
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @State private var directorySearchText = ""
    @State private var directoryMembers: [DirectoryMember] = []
    @State private var filteredDirectoryMembers: [DirectoryMember] = []
    @State private var isLoadingDirectory = false
    @State private var directoryLoadError: String?
    @State private var selectedMember: DirectoryMember?

    let messageMember: (DirectoryMember) -> Void
    let allowedGroups: [MemberGroup]?

    init(
        messageMember: @escaping (DirectoryMember) -> Void = { _ in },
        allowedGroups: [MemberGroup]? = nil
    ) {
        self.messageMember = messageMember
        self.allowedGroups = allowedGroups
    }

    private var isPreview: Bool {
        ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }

    private var apiService: KTPAPIService {
        KTPAPIService(accessTokenProvider: { [authManager] in
            try await authManager.validAccessToken()
        })
    }
    
    var body: some View {
        let service = apiService

        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                DirectorySearchBar(searchText: $directorySearchText)

                if isLoadingDirectory {
                    DirectoryStatusCard(message: "Loading directory...")
                } else if let directoryLoadError {
                    DirectoryStatusCard(message: directoryLoadError)
                } else if filteredDirectoryMembers.isEmpty {
                    DirectoryStatusCard(
                        message: directorySearchText.isEmpty ?
                        "No members in the directory yet."
                        : "No members found matching '\(directorySearchText)'."
                    )
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredDirectoryMembers) { member in
                            DirectoryMemberCard(
                                member: member,
                                apiService: service,
                                messageMember: messageMember,
                                selectMember: { selectedMember = member }
                            )

                            if member.id != filteredDirectoryMembers.last?.id {
                                Divider()
                                    .padding(.leading, 60)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .task {
            await loadDirectoryMembers()
        }
        .onChange(of: directorySearchText) { _, _ in
            updateFilteredDirectoryMembers()
        }
        .onChange(of: allowedGroups) { _, _ in
            updateFilteredDirectoryMembers()
        }
        .sheet(item: $selectedMember) { member in
            NavigationStack {
                MemberProfileView(
                    member: member,
                    apiService: service,
                    messageMember: { member in
                        selectedMember = nil
                        Task { @MainActor in
                            await Task.yield()
                            messageMember(member)
                        }
                    }
                )
            }
        }
    }

    private func updateFilteredDirectoryMembers() {
        let query = directorySearchText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        filteredDirectoryMembers = directoryMembers.filter { member in
            guard allowedGroups?.contains(member.group) ?? true else { return false }
            guard !query.isEmpty else { return true }

            return member.name.lowercased().contains(query) ||
                member.role.lowercased().contains(query) ||
                member.group.title.lowercased().contains(query) ||
                (member.year?.lowercased().contains(query) ?? false)
        }
    }

    private func replaceDirectoryMembers(with members: [DirectoryMember]) {
        directoryMembers = members
        updateFilteredDirectoryMembers()
    }

    @MainActor
    private func loadDirectoryMembers() async {
#if DEBUG
        if isPreview {
            replaceDirectoryMembers(with: DirectoryMember.previewSamples)
            directoryLoadError = nil
            return
        }
#endif
        
        isLoadingDirectory = true
        directoryLoadError = nil
        
        do {
            if authManager.currentUserGroup == .rush {
                // The server's leadership response can include chairs. Rushees see
                // only the e-board subset in the app.
                replaceDirectoryMembers(with: try await apiService.fetchLeadershipMembers()
                    .filter { $0.group == .eboard })
            } else {
                replaceDirectoryMembers(with: try await apiService.fetchDirectoryMembers())
            }
            prefetchInitialAvatars(from: directoryMembers)
        } catch {
            replaceDirectoryMembers(with: [])
            directoryLoadError = directoryErrorMessage(for: error)
        }
        
        isLoadingDirectory = false
    }

    private func prefetchInitialAvatars(from members: [DirectoryMember]) {
        let priorityMembers = Array(members.prefix(16))
        let service = apiService

        Task { @MainActor in
            for batchStart in stride(from: 0, to: priorityMembers.count, by: 4) {
                let batchEnd = min(batchStart + 4, priorityMembers.count)
                let batch = priorityMembers[batchStart..<batchEnd]

                await withTaskGroup(of: Void.self) { group in
                    for member in batch {
                        group.addTask { @MainActor in
                            _ = await avatarRepository.image(
                                for: member.id,
                                pointSize: 40,
                                displayScale: displayScale,
                                loadData: { try await service.fetchProfilePictureData(for: member.id) }
                            )
                        }
                    }
                }
            }
        }
    }

    private func directoryErrorMessage(for error: Error) -> String {
        if case AuthManagerError.notAuthenticated = error {
            return "Sign in with SSO to load the directory."
        }

        if case KTPAPIError.missingAccessToken = error {
            return "Sign in with SSO to load the directory."
        }

        if case KTPAPIError.badStatusCode(let statusCode, let body) = error {
            if statusCode == 401 || statusCode == 403 {
                return "Directory access was rejected by the API (\(statusCode)). Sign out and sign in again. \(body)"
            }

            return "Directory API failed with status \(statusCode). \(body)"
        }

        if case KTPAPIError.decodeFailed(let message) = error {
            return "Directory data did not match the app model. \(message)"
        }

        return "Could not load directory from the KTP API. \(error.localizedDescription)"
    }
}
    
    private struct DirectorySearchBar: View {
        @Environment(\.colorScheme) private var colorScheme
        @Binding var searchText: String
        
        var body: some View {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(DirectoryDesign.searchIcon(for: colorScheme))
                
                TextField(
                    "",
                    text: $searchText,
                    prompt: Text("Search").foregroundStyle(DirectoryDesign.placeholder(for: colorScheme))
                )
                .font(AppFont.subheadline())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(DirectoryDesign.primary(for: colorScheme))
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            .background(
                DirectoryDesign.searchBackground(for: colorScheme),
                in: RoundedRectangle(cornerRadius: 17, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .stroke(AppSystemColor.separator.opacity(0.32), lineWidth: 1)
            }
        }
    }
    
    private struct DirectoryStatusCard: View {
        @Environment(\.colorScheme) private var colorScheme
        let message: String
        
        var body: some View {
            AppStatusSurface(message: message, systemImage: "person.2.slash")
        }
    }
    
    private struct DirectoryMemberCard: View {
        @Environment(\.colorScheme) private var colorScheme
        @Environment(\.openURL) private var openURL
        let member: DirectoryMember
        let apiService: KTPAPIService
        let messageMember: (DirectoryMember) -> Void
        let selectMember: () -> Void

        private var initials: String {
            let parts = member.name
                .split(separator: " ")
                .prefix(2)
                .compactMap(\.first)

            let value = String(parts).uppercased()
            return value.isEmpty ? "KT" : value
        }

        private var detailLine: String {
            guard let year = member.year?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !year.isEmpty else {
                return member.role
            }

            return "\(member.role) '\(year.suffix(2))"
        }

        private var groupLine: String {
            "\(member.group.shortTitle.lowercased()) | member"
        }
        
        var body: some View {
            HStack(alignment: .center, spacing: 12) {
                Button(action: selectMember) {
                    HStack(alignment: .center, spacing: 12) {
                        DirectoryProfilePictureView(member: member, apiService: apiService, initials: initials, size: 46)
                            .frame(width: 46, height: 46)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(member.name)
                                .font(AppFont.headline())
                                .foregroundStyle(DirectoryDesign.name(for: colorScheme))
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)

                            Text(detailLine)
                                .font(AppFont.footnote())
                                .foregroundStyle(DirectoryDesign.primary(for: colorScheme))
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)

                            Text(groupLine)
                                .font(AppFont.footnote())
                                .foregroundStyle(DirectoryDesign.primary(for: colorScheme))
                                .lineLimit(1)
                        }

                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())

                HStack(spacing: 14) {
                    DirectoryMemberActionButton(
                        systemImage: "message.fill",
                        label: "Message \(member.name)",
                        action: { messageMember(member) }
                    )

                    DirectoryMemberActionButton(
                        systemImage: "envelope.fill",
                        label: "Email \(member.name)",
                        isEnabled: mailURL != nil,
                        action: {
                            if let mailURL {
                                openURL(mailURL)
                            }
                        }
                    )

                    DirectoryMemberActionButton(
                        assetName: "Linkedin",
                        label: "Open \(member.name)'s LinkedIn",
                        isEnabled: member.linkedInProfileURL != nil,
                        action: {
                            if let linkedInURL = member.linkedInProfileURL {
                                openURL(linkedInURL)
                            }
                        }
                    )
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
        }

        private var mailURL: URL? {
            guard let email = member.email?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !email.isEmpty else {
                return nil
            }

            return URL(string: "mailto:\(email.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? email)")
        }
    }

    private struct DirectoryMemberActionButton: View {
        @Environment(\.colorScheme) private var colorScheme
        var systemImage: String? = nil
        var assetName: String? = nil
        let label: String
        var isEnabled = true
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                Group {
                    if let assetName {
                        Image(assetName)
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .foregroundStyle(DirectoryDesign.actionIcon(for: colorScheme))
                            .padding(9)
                    } else if let systemImage {
                        Image(systemName: systemImage)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(DirectoryDesign.actionIcon(for: colorScheme))
                    }
                }
                .frame(width: 34, height: 40)
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            .opacity(isEnabled ? 1 : 0.42)
            .accessibilityLabel(label)
        }
    }

    private struct DirectoryProfilePictureView: View {
        @EnvironmentObject private var avatarRepository: AvatarRepository
        @Environment(\.displayScale) private var displayScale
        let member: DirectoryMember
        let apiService: KTPAPIService
        let initials: String
        var size: CGFloat = 40

        @State private var image: UIImage?

        var body: some View {
            ZStack {
                Circle()
                    .fill(DirectoryDesign.avatarBackground)

                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Text(initials)
                        .font(AppFont.footnote(weight: .bold))
                        .foregroundStyle(DirectoryDesign.avatarText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
            }
            .clipShape(Circle())
            .accessibilityLabel("\(member.name) profile picture")
            .task(id: "\(member.id)-\(Int(size * displayScale))") {
                await loadProfilePicture()
            }
        }

        @MainActor
        private func loadProfilePicture() async {
            let avatar = await avatarRepository.image(
                for: member.id,
                pointSize: size,
                displayScale: displayScale,
                loadData: { try await apiService.fetchProfilePictureData(for: member.id) }
            )
            guard !Task.isCancelled else { return }
            image = avatar
        }
    }

    private struct MemberProfileView: View {
        @Environment(\.openURL) private var openURL
        @Environment(\.colorScheme) private var colorScheme
        @EnvironmentObject private var authManager: AuthManager
        @State private var reportTarget: ReportTarget?
        @State private var isBlocked = false
        @State private var isUpdatingBlock = false
        @State private var showsBlockConfirmation = false
        @State private var blockErrorMessage: String?

        let member: DirectoryMember
        let apiService: KTPAPIService
        let messageMember: (DirectoryMember) -> Void

        private var mailURL: URL? {
            guard let email = (member.email ?? member.personalEmail)?.nonEmptyTrimmed else {
                return nil
            }

            return URL(string: "mailto:\(email.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? email)")
        }

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    profileHeader
                    communicationActions

                    if let aboutMe = member.aboutMe?.nonEmptyTrimmed {
                        profileSection(title: "About") {
                            Text(aboutMe)
                                .font(AppFont.subheadline())
                                .foregroundStyle(DirectoryDesign.primary(for: colorScheme))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if !details.isEmpty {
                        profileSection(title: "Details") {
                            VStack(spacing: 0) {
                                profileDetailDivider

                                ForEach(details) { detail in
                                    detailRow(detail.title, detail.value)

                                    profileDetailDivider
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(AppSystemColor.background)
                        }
                    }

                    moderationActions
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.top, 18)
                .padding(.bottom, 44)
            }
            .navigationTitle("Member Profile")
            .navigationBarTitleDisplayMode(.inline)
            .background(AppSystemColor.background)
            .sheet(item: $reportTarget) { target in
                ReportContentSheet(target: target)
            }
            .task {
                await loadBlockState()
            }
            .confirmationDialog(
                "Block \(member.name)?",
                isPresented: $showsBlockConfirmation,
                titleVisibility: .visible
            ) {
                Button("Block Member", role: .destructive) {
                    Task { await setBlocked(true) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("They will not be able to start new direct messages with you, and their messages will be hidden from your conversation and group-chat views.")
            }
        }

        private var profileHeader: some View {
            VStack(alignment: .leading, spacing: 8) {
                DirectoryProfilePictureView(member: member, apiService: apiService, initials: initials, size: 122)
                    .frame(width: 122, height: 122)

                Text(member.name)
                    .font(AppFont.largeTitle(32))
                    .foregroundStyle(DirectoryDesign.name(for: colorScheme))
                    .multilineTextAlignment(.leading)

                Text(member.role)
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(DirectoryDesign.secondary(for: colorScheme))
                    .multilineTextAlignment(.leading)

                if let username = member.username?.nonEmptyTrimmed {
                    Text("@\(username)")
                        .font(AppFont.footnote())
                        .foregroundStyle(DirectoryDesign.secondary(for: colorScheme))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        private var communicationActions: some View {
            HStack(spacing: 10) {
                profileAction("Message", systemImage: "message.fill", isEnabled: !isBlocked && !isUpdatingBlock) {
                    messageMember(member)
                }

                profileAction("Email", systemImage: "envelope.fill", isEnabled: mailURL != nil) {
                    if let mailURL { openURL(mailURL) }
                }

                profileAction("LinkedIn", assetName: "Linkedin", isEnabled: member.linkedInProfileURL != nil) {
                    if let linkedInURL = member.linkedInProfileURL { openURL(linkedInURL) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        private func profileAction(
            _ title: String,
            systemImage: String? = nil,
            assetName: String? = nil,
            isEnabled: Bool,
            action: @escaping () -> Void
        ) -> some View {
            Button(action: action) {
                VStack(spacing: 7) {
                    Group {
                        if let assetName {
                            Image(assetName)
                                .renderingMode(.template)
                                .resizable()
                                .scaledToFit()
                                .foregroundStyle(AppSystemColor.primaryLabel)
                        } else if let systemImage {
                            Image(systemName: systemImage)
                                .font(.system(size: 18, weight: .semibold))
                        }
                    }
                    .frame(width: 20, height: 20)
                    Text(title)
                        .font(AppFont.caption(weight: .bold))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 68)
                .foregroundStyle(AppSystemColor.primaryLabel)
                .background(
                    AppSystemColor.elevatedBackground,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(AppSystemColor.separator.opacity(0.4), lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            .opacity(isEnabled ? 1 : 0.42)
        }

        @ViewBuilder
        private func profileSection<Content: View>(
            title: String,
            @ViewBuilder content: () -> Content
        ) -> some View {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(AppFont.headline())
                    .foregroundStyle(DirectoryDesign.name(for: colorScheme))

                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        @ViewBuilder
        private var moderationActions: some View {
            if member.id != authManager.currentUserID {
                VStack(alignment: .leading, spacing: 12) {
                    Divider()

                    Button(isBlocked ? "Unblock Member" : "Block Member", role: isBlocked ? nil : .destructive) {
                        if isBlocked {
                            Task { await setBlocked(false) }
                        } else {
                            showsBlockConfirmation = true
                        }
                    }
                    .disabled(isUpdatingBlock)
                    .font(AppFont.footnote(weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Button("Report Member", role: .destructive) {
                        reportTarget = .user(member)
                    }
                    .font(AppFont.footnote(weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if let blockErrorMessage {
                        Text(blockErrorMessage)
                            .font(AppFont.footnote())
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }

        @MainActor
        private func loadBlockState() async {
            do {
                isBlocked = try await apiService.fetchBlockedUserIDs().contains(member.id)
            } catch is CancellationError {
                return
            } catch {
                blockErrorMessage = "Could not load block status."
            }
        }

        @MainActor
        private func setBlocked(_ shouldBlock: Bool) async {
            guard !isUpdatingBlock else { return }
            isUpdatingBlock = true
            blockErrorMessage = nil

            do {
                if shouldBlock {
                    try await apiService.blockUser(id: member.id)
                } else {
                    try await apiService.unblockUser(id: member.id)
                }
                isBlocked = shouldBlock
            } catch {
                blockErrorMessage = shouldBlock
                    ? "Could not block this member. Please try again."
                    : "Could not unblock this member. Please try again."
            }

            isUpdatingBlock = false
        }

        private var initials: String {
            let value = String(member.name.split(separator: " ").prefix(2).compactMap(\.first)).uppercased()
            return value.isEmpty ? "KT" : value
        }

        private var details: [MemberProfileDetail] {
            var values = [MemberProfileDetail(title: "Membership", value: member.group.title)]
            values.appendIfPresent(title: "Executive title", value: member.executiveTitle)
            values.appendIfPresent(
                title: "Chairs",
                value: member.chairedCommittees.isEmpty ? nil : member.chairedCommittees.joined(separator: ", ")
            )
            values.appendIfPresent(title: "Major", value: member.major)
            values.appendIfPresent(title: "Graduation", value: member.graduationDate)
            values.appendIfPresent(title: "Pledge class", value: member.pledgeClass)
            values.appendIfPresent(title: "UGA email", value: member.email)
            values.appendIfPresent(title: "Personal email", value: member.personalEmail)
            values.appendIfPresent(title: "Phone", value: member.phone)
            values.appendIfPresent(title: "Date of birth", value: member.dateOfBirth)
            return values
        }

        private func detailRow(_ title: String, _ value: String) -> some View {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(AppFont.caption(weight: .bold))
                    .foregroundStyle(DirectoryDesign.secondary(for: colorScheme))

                Text(value)
                    .font(AppFont.subheadline())
                    .foregroundStyle(DirectoryDesign.primary(for: colorScheme))
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
        }

        private var profileDetailDivider: some View {
            Rectangle()
                .fill(AppSystemColor.separator.opacity(colorScheme == .dark ? 0.72 : 0.5))
                .frame(height: 0.5)
        }
    }

private struct MemberProfileDetail: Identifiable {
    let title: String
    let value: String
    var id: String { title }
}

private extension Array where Element == MemberProfileDetail {
    mutating func appendIfPresent(title: String, value: String?) {
        guard let value = value?.nonEmptyTrimmed else { return }
        append(MemberProfileDetail(title: title, value: value))
    }
}

private enum DirectoryDesign {
    static var avatarBackground: Color { AppSystemColor.insetBackground }
    static var avatarText: Color { AppSystemColor.primaryLabel }

    static func primary(for colorScheme: ColorScheme) -> Color {
        AppSystemColor.primaryLabel
    }

    static func secondary(for colorScheme: ColorScheme) -> Color {
        primary(for: colorScheme).opacity(0.66)
    }

    static func name(for colorScheme: ColorScheme) -> Color {
        AppSystemColor.primaryLabel
    }

    static func placeholder(for colorScheme: ColorScheme) -> Color {
        primary(for: colorScheme).opacity(0.62)
    }

    static func searchIcon(for colorScheme: ColorScheme) -> Color {
        primary(for: colorScheme).opacity(0.52)
    }

    static func searchBackground(for colorScheme: ColorScheme) -> Color {
        AppSystemColor.insetBackground
    }

    static func cardBackground(for colorScheme: ColorScheme) -> Color {
        AppSystemColor.elevatedBackground
    }

    static func actionBackground(for colorScheme: ColorScheme) -> Color {
        AppSystemColor.insetBackground
    }

    static func actionIcon(for colorScheme: ColorScheme) -> Color {
        AppSurfaceColor.primaryControl
    }
}

private extension MemberGroup {
    var shortTitle: String {
        switch self {
        case .active:
            return "active"
        case .pledge:
            return "pledge"
        case .eboard:
            return "eboard"
        case .chair:
            return "chair"
        case .alumni:
            return "alumni"
        case .rush:
            return "rush"
        }
    }
}

private extension DirectoryMember {
    var linkedInProfileURL: URL? {
        guard var value = linkedinURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }

        if value.hasPrefix("@") {
            value.removeFirst()
        }

        if !value.contains("://") {
            if value.lowercased().contains("linkedin.com") {
                value = "https://\(value)"
            } else {
                let encodedHandle = value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
                value = "https://www.linkedin.com/in/\(encodedHandle)"
            }
        }

        guard let url = URL(string: value),
              let host = url.host?.lowercased(),
              host == "linkedin.com" || host.hasSuffix(".linkedin.com") else {
            return nil
        }

        return url
    }
}

#if DEBUG
#Preview("Member Directory") {
    MemberDirectoryView()
        .padding(20)
        .background(AppTab.directory.theme.previewBackground())
        .environmentObject(AuthManager.previewSignedOut)
        .environmentObject(AvatarRepository())
}
#endif
