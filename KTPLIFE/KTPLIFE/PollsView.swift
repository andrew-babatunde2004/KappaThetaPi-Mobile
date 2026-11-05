import SwiftUI

struct PollsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var authManager: AuthManager
    @State private var polls: [Poll] = []
    @State private var selectionsByPollID: [String: Set<String>] = [:]
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var votingPollIDs: Set<String> = []
    @State private var voteError: PollError?

    private var apiService: KTPAPIService {
        KTPAPIService(accessTokenProvider: { [authManager] in
            try await authManager.validAccessToken()
        })
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 14) {
                    AppSectionHeading(
                        eyebrow: "Chapter Input",
                        title: "Polls",
                        systemImage: "chart.bar.fill"
                    )
                    .padding(.bottom, 6)

                    if isLoading {
                        PollStatusView(message: "Loading polls...")
                    } else if let loadError {
                        PollStatusView(message: loadError)
                    } else if polls.isEmpty {
                        PollStatusView(message: "There are no polls available right now.")
                    } else {
                        pollSection(title: "Active Polls", polls: activePolls)

                        if !activePolls.isEmpty, !closedPolls.isEmpty {
                            Divider()
                                .padding(.vertical, 8)
                        }

                        pollSection(title: "Poll History", polls: closedPolls)
                    }
                }
                .padding(20)
            }
            .background(AppSystemColor.background)
            .navigationTitle("Polls")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(AppFont.subheadline(weight: .semibold))
                }
            }
            .task { await loadPolls() }
            .refreshable { await loadPolls() }
            .alert(item: $voteError) { error in
                Alert(
                    title: Text("Couldn’t Save Vote"),
                    message: Text(error.message),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
        .background(AppSystemColor.background.ignoresSafeArea())
    }

    private var activePolls: [Poll] {
        polls.filter { !$0.isCurrentlyClosed }
    }

    private var closedPolls: [Poll] {
        polls.filter(\.isCurrentlyClosed)
    }

    @ViewBuilder
    private func pollSection(title: String, polls: [Poll]) -> some View {
        if !polls.isEmpty {
            Text(title)
                .font(AppFont.title(20))
                .foregroundStyle(AppSystemColor.primaryLabel)
                .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(polls) { poll in
                PollCard(
                    poll: poll,
                    selectedOptionIDs: selection(for: poll),
                    isVoting: votingPollIDs.contains(poll.id),
                    apiService: apiService,
                    selectOption: { select($0, on: poll) },
                    submitMultiSelection: { submitVote(for: poll) }
                )
            }
        }
    }

    private func selection(for poll: Poll) -> Set<String> {
        selectionsByPollID[poll.id] ?? poll.myOptionIDs
    }

    private func select(_ optionID: String, on poll: Poll) {
        guard !poll.isCurrentlyClosed, !votingPollIDs.contains(poll.id) else { return }

        var selection = selection(for: poll)
        if poll.allowsMultipleSelections {
            if selection.contains(optionID) {
                selection.remove(optionID)
            } else {
                selection.insert(optionID)
            }
            selectionsByPollID[poll.id] = selection
        } else {
            selection = [optionID]
            selectionsByPollID[poll.id] = selection
            submitVote(for: poll)
        }
    }

    private func submitVote(for poll: Poll) {
        let optionIDs = Array(selection(for: poll))
        guard !optionIDs.isEmpty, !poll.isCurrentlyClosed, !votingPollIDs.contains(poll.id) else { return }

        votingPollIDs.insert(poll.id)
        Task { @MainActor in
            defer { votingPollIDs.remove(poll.id) }

            do {
                try await apiService.vote(on: poll.id, optionIDs: optionIDs)
                await loadPolls(showsLoadingState: false)
            } catch is CancellationError {
                return
            } catch {
                voteError = PollError(message: pollErrorMessage(for: error))
            }
        }
    }

    @MainActor
    private func loadPolls(showsLoadingState: Bool = true) async {
        if showsLoadingState {
            isLoading = true
        }
        loadError = nil

        do {
            let fetchedPolls = try await apiService.fetchPolls()
            polls = fetchedPolls.sorted { left, right in
                switch (left.isCurrentlyClosed, right.isCurrentlyClosed) {
                case (false, true): return true
                case (true, false): return false
                default: return left.question.localizedCaseInsensitiveCompare(right.question) == .orderedAscending
                }
            }
            selectionsByPollID = Dictionary(uniqueKeysWithValues: polls.map { ($0.id, $0.myOptionIDs) })
        } catch is CancellationError {
            return
        } catch {
            if polls.isEmpty {
                loadError = pollErrorMessage(for: error)
            }
        }

        isLoading = false
    }
}

private struct PollCard: View {
    let poll: Poll
    let selectedOptionIDs: Set<String>
    let isVoting: Bool
    let apiService: KTPAPIService
    let selectOption: (String) -> Void
    let submitMultiSelection: () -> Void
    @State private var votersByOptionID: [String: [PollVoter]] = [:]
    @State private var isLoadingVoters = false
    @State private var showVoters = false
    @State private var voterLoadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(poll.question)
                        .font(AppFont.headline())
                        .foregroundStyle(AppSystemColor.primaryLabel)

                    if let description = poll.description {
                        Text(description)
                            .font(AppFont.footnote())
                            .foregroundStyle(AppSystemColor.secondaryLabel)
                    }
                }

                Spacer(minLength: 8)

                Text(poll.isCurrentlyClosed ? "Closed" : "Open")
                    .font(AppFont.caption(weight: .bold))
                    .foregroundStyle(poll.isCurrentlyClosed ? AppSystemColor.secondaryLabel : AppSurfaceColor.primaryControl)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(AppSystemColor.insetBackground, in: Capsule())
            }

            VStack(spacing: 8) {
                ForEach(poll.options) { option in
                    Button {
                        selectOption(option.id)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: selectionSymbol(for: option))
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(isSelected(option) ? AppSurfaceColor.primaryControl : AppSystemColor.secondaryLabel)

                            Text(option.title)
                                .font(AppFont.subheadline(weight: .medium))
                                .foregroundStyle(AppSystemColor.primaryLabel)
                                .multilineTextAlignment(.leading)

                            Spacer(minLength: 8)

                            Text("\(option.voteCount)")
                                .font(AppFont.caption(weight: .semibold))
                                .foregroundStyle(AppSystemColor.secondaryLabel)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 11)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            isSelected(option) ? AppSurfaceColor.primaryControl.opacity(0.12) : AppSystemColor.insetBackground,
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(poll.isCurrentlyClosed || isVoting)
                    .accessibilityLabel("\(option.title), \(option.voteCount) votes")
                    .accessibilityAddTraits(isSelected(option) ? .isSelected : [])
                }
            }

            HStack(spacing: 10) {
                Text(voteSummary)
                    .font(AppFont.caption())
                    .foregroundStyle(AppSystemColor.secondaryLabel)

                Spacer(minLength: 8)

                if poll.allowsMultipleSelections, !poll.isCurrentlyClosed {
                    Button("Save Vote") {
                        submitMultiSelection()
                    }
                    .font(AppFont.footnote(weight: .semibold))
                    .buttonStyle(.glassProminent)
                    .disabled(selectedOptionIDs.isEmpty || isVoting)
                }
            }

            if poll.votersVisible {
                Button {
                    if showVoters {
                        showVoters = false
                    } else {
                        Task { await loadVoters() }
                    }
                } label: {
                    Label(showVoters ? "Hide voters" : "See who voted", systemImage: showVoters ? "person.2.slash" : "person.2")
                        .font(AppFont.footnote(weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppSurfaceColor.primaryControl)

                if isLoadingVoters { ProgressView().controlSize(.small) }
                if let voterLoadError {
                    Text(voterLoadError).font(AppFont.caption()).foregroundStyle(AppSystemColor.secondaryLabel)
                }
                if showVoters {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(poll.options) { option in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(option.title).font(AppFont.caption(weight: .semibold)).foregroundStyle(AppSystemColor.secondaryLabel)
                                let voters = votersByOptionID[option.id] ?? []
                                if voters.isEmpty {
                                    Text("No votes yet").font(AppFont.caption()).foregroundStyle(AppSystemColor.secondaryLabel)
                                } else {
                                    Text(voters.map(\.displayName).joined(separator: ", "))
                                        .font(AppFont.footnote()).foregroundStyle(AppSystemColor.primaryLabel)
                                }
                            }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppSystemColor.insetBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
        .padding(18)
        .appElevatedSurface(radius: 24)
        .accessibilityElement(children: .contain)
    }

    private func isSelected(_ option: PollOption) -> Bool {
        selectedOptionIDs.contains(option.id)
    }

    private func selectionSymbol(for option: PollOption) -> String {
        let selected = isSelected(option)
        if poll.allowsMultipleSelections {
            return selected ? "checkmark.square.fill" : "square"
        }
        return selected ? "largecircle.fill.circle" : "circle"
    }

    private var voteSummary: String {
        let voteText = poll.totalVotes == 1 ? "1 vote" : "\(poll.totalVotes) votes"
        if let expiresAt = poll.expiresAt, !poll.isCurrentlyClosed {
            return "\(voteText) · Closes \(expiresAt.formatted(date: .abbreviated, time: .shortened))"
        }
        return poll.allowsMultipleSelections ? "\(voteText) · Select all that apply" : voteText
    }

    @MainActor
    private func loadVoters() async {
        isLoadingVoters = true
        voterLoadError = nil
        defer { isLoadingVoters = false }
        do {
            let options = try await apiService.fetchPollStats(pollID: poll.id)
            votersByOptionID = Dictionary(uniqueKeysWithValues: options.map { ($0.id, $0.voters) })
            showVoters = true
        } catch {
            voterLoadError = "Voter details are unavailable right now."
        }
    }
}

private struct PollStatusView: View {
    let message: String

    var body: some View {
        Text(message)
            .font(AppFont.subheadline())
            .foregroundStyle(AppSystemColor.secondaryLabel)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .appElevatedSurface(radius: 20)
    }
}

private struct PollError: Identifiable {
    let id = UUID()
    let message: String
}

private func pollErrorMessage(for error: Error) -> String {
    if case AuthManagerError.notAuthenticated = error {
        return "Sign in with SSO to view polls."
    }
    if case KTPAPIError.missingAccessToken = error {
        return "Sign in with SSO to view polls."
    }
    if case KTPAPIError.badStatusCode(let statusCode, _) = error, statusCode == 401 || statusCode == 403 {
        return "You do not have access to this poll."
    }
    return "Polls are temporarily unavailable. Please try again."
}
