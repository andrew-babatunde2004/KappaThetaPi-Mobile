import SwiftUI

struct OpportunitiesView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var authManager: AuthManager
    @State private var companies: [CareerCompany] = []
    @State private var searchText = ""
    @State private var isLoading = false
    @State private var loadError: String?

    let showsDismissButton: Bool

    init(showsDismissButton: Bool = false) {
        self.showsDismissButton = showsDismissButton
    }

    private var apiService: KTPAPIService {
        KTPAPIService(accessTokenProvider: { [authManager] in
            try await authManager.validAccessToken()
        })
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 14) {
                    AppSectionHeading(
                        eyebrow: "Career Resources",
                        title: "Company insights",
                        systemImage: "briefcase.fill"
                    )

                    if isLoading && companies.isEmpty {
                        CareerStatusView(message: "Loading company insights...", showsProgress: true)
                    } else if let loadError, companies.isEmpty {
                        CareerStatusView(message: loadError, showsProgress: false)
                    } else if companies.isEmpty {
                        CareerStatusView(message: "No company insights match your search.", showsProgress: false)
                    } else {
                        ForEach(companies) { company in
                            NavigationLink {
                                CareerCompanyView(company: company, apiService: apiService)
                            } label: {
                                CareerCompanyRow(company: company)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(20)
            }
            .background(AppSystemColor.background)
            .navigationTitle("Career Resources")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search companies")
            .toolbar {
                if showsDismissButton {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                            .font(AppFont.subheadline(weight: .semibold))
                    }
                }
            }
            .task(id: searchText) {
                if !searchText.isEmpty {
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled else { return }
                }
                await loadCompanies()
            }
            .refreshable {
                await loadCompanies()
            }
        }
        .tint(AppSurfaceColor.primaryControl)
    }

    @MainActor
    private func loadCompanies() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        do {
            companies = try await apiService.fetchCareerCompanies(search: searchText)
        } catch is CancellationError {
            return
        } catch {
            if companies.isEmpty {
                loadError = "Company insights could not be loaded. Pull to refresh and try again."
            }
        }
    }
}

private struct CareerCompanyRow: View {
    let company: CareerCompany

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(company.name)
                    .font(AppFont.headline())
                    .foregroundStyle(AppSystemColor.primaryLabel)

                Text(company.insightCount == 1 ? "1 shared experience" : "\(company.insightCount) shared experiences")
                    .font(AppFont.caption())
                    .foregroundStyle(AppSystemColor.secondaryLabel)
            }

            Spacer(minLength: 10)

            Image(systemName: "chevron.right")
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(AppSystemColor.secondaryLabel)
        }
        .padding(16)
        .appElevatedSurface()
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private struct CareerCompanyView: View {
    let company: CareerCompany
    let apiService: KTPAPIService

    @State private var insights: [CareerInsight] = []
    @State private var isLoading = true
    @State private var loadError: String?

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 14) {
                AppSectionHeading(
                    eyebrow: "Company Insights",
                    title: company.name,
                    systemImage: "building.2.fill"
                )

                if isLoading {
                    CareerStatusView(message: "Loading experiences...", showsProgress: true)
                } else if let loadError {
                    CareerStatusView(message: loadError, showsProgress: false)
                } else if insights.isEmpty {
                    CareerStatusView(message: "No experiences have been shared yet.", showsProgress: false)
                } else {
                    ForEach(insights) { insight in
                        CareerInsightCard(insight: insight)
                    }
                }
            }
            .padding(20)
        }
        .background(AppSystemColor.background)
        .navigationTitle(company.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: company.id) {
            await loadInsights()
        }
        .refreshable {
            await loadInsights()
        }
    }

    @MainActor
    private func loadInsights() async {
        isLoading = insights.isEmpty
        loadError = nil
        do {
            insights = try await apiService.fetchCareerCompany(id: company.id).insights
        } catch is CancellationError {
            return
        } catch {
            if insights.isEmpty {
                loadError = "Experiences could not be loaded. Pull to refresh and try again."
            }
        }
        isLoading = false
    }
}

private struct CareerInsightCard: View {
    let insight: CareerInsight
    @State private var isExpanded = false

    private var metadata: String {
        [insight.employmentType?.replacingOccurrences(of: "_", with: " ").capitalized, insight.term]
            .compactMap { $0?.nonEmptyTrimmed }
            .joined(separator: " • ")
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                if !insight.summary.isEmpty {
                    Text(insight.summary)
                        .font(AppFont.subheadline())
                        .foregroundStyle(AppSystemColor.primaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let rounds = insight.rounds?.nonEmptyTrimmed {
                    Label(rounds, systemImage: "list.number")
                        .font(AppFont.footnote())
                        .foregroundStyle(AppSystemColor.secondaryLabel)
                }

                let outcome = insight.outcome?.replacingOccurrences(of: "_", with: " ").capitalized
                let difficulty = insight.difficulty?.capitalized
                if outcome != nil || difficulty != nil {
                    Text([outcome, difficulty].compactMap { $0 }.joined(separator: " • "))
                        .font(AppFont.caption(weight: .semibold))
                        .foregroundStyle(AppSurfaceColor.primaryControl)
                }
            }
            .padding(.top, 12)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                Text(insight.roleTitle)
                    .font(AppFont.headline())
                    .foregroundStyle(AppSystemColor.primaryLabel)

                if !metadata.isEmpty {
                    Text(metadata)
                        .font(AppFont.caption())
                        .foregroundStyle(AppSystemColor.secondaryLabel)
                }

                Text("Shared by \(insight.authorName?.nonEmptyTrimmed ?? "Former member")")
                    .font(AppFont.caption())
                    .foregroundStyle(AppSystemColor.secondaryLabel)
            }
        }
        .tint(AppSurfaceColor.primaryControl)
        .padding(16)
        .appElevatedSurface()
    }
}

private struct CareerStatusView: View {
    let message: String
    let showsProgress: Bool

    var body: some View {
        HStack(spacing: 12) {
            if showsProgress {
                ProgressView()
            } else {
                Image(systemName: "briefcase")
                    .foregroundStyle(AppSystemColor.secondaryLabel)
            }
            Text(message)
                .font(AppFont.subheadline())
                .foregroundStyle(AppSystemColor.secondaryLabel)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .appElevatedSurface()
    }
}

#if DEBUG
#Preview("Career Resources") {
    OpportunitiesView()
        .environmentObject(AuthManager.previewSignedOut)
}
#endif
