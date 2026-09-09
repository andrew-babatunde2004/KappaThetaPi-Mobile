import SwiftUI

struct InterviewsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var authManager: AuthManager
    @State private var schedules: [InterviewSchedule] = []
    @State private var isLoading = false
    @State private var actionSlotID: String?
    @State private var errorMessage: String?

    private var apiService: KTPAPIService {
        KTPAPIService(accessTokenProvider: { [authManager] in try await authManager.validAccessToken() })
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    AppSectionHeading(eyebrow: "Recruitment", title: "Interviews", systemImage: "person.crop.rectangle.stack")
                    Text("Choose one available time. You can cancel a booking here if your plans change.")
                        .font(AppFont.subheadline())
                        .foregroundStyle(AppSystemColor.secondaryLabel)
                    if isLoading {
                        AppStatusSurface(message: "Loading interview times...", systemImage: "clock")
                    } else if let errorMessage {
                        AppStatusSurface(message: errorMessage, systemImage: "exclamationmark.circle")
                    } else if schedules.isEmpty {
                        AppStatusSurface(message: "No interview times are available right now.", systemImage: "calendar")
                    } else {
                        ForEach(schedules) { schedule in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(schedule.title).font(AppFont.headline()).foregroundStyle(AppSystemColor.primaryLabel)
                                if let description = schedule.description, !description.isEmpty {
                                    Text(description).font(AppFont.footnote()).foregroundStyle(AppSystemColor.secondaryLabel)
                                }
                                ForEach(schedule.slots) { slot in
                                    slotRow(for: slot, in: schedule)
                                }
                            }
                            .padding(16)
                            .appElevatedSurface(radius: 20)
                        }
                    }
                }
                .padding(20)
            }
            .background(AppSystemColor.background)
            .navigationTitle("Interviews")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .task { await loadSchedules() }
            .refreshable { await loadSchedules() }
        }
    }

    @MainActor private func loadSchedules() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do { schedules = try await apiService.fetchAvailableInterviews() }
        catch is CancellationError { return }
        catch { errorMessage = "Interview times are temporarily unavailable. Please try again." }
    }

    @MainActor private func performAction(for slot: InterviewSlot) async {
        actionSlotID = slot.id
        defer { actionSlotID = nil }
        do {
            if slot.mine, let bookingID = slot.bookingID { try await apiService.cancelInterview(bookingID: bookingID) }
            else { try await apiService.bookInterview(slotID: slot.id) }
            await loadSchedules()
        } catch { errorMessage = slot.mine ? "Your interview could not be cancelled." : "That interview time is no longer available." }
    }

    private func slotRow(for slot: InterviewSlot, in schedule: InterviewSchedule) -> some View {
        InterviewSlotRow(
            slot: slot,
            scheduleLocation: schedule.location,
            isWorking: actionSlotID == slot.id
        ) {
            Task { await performAction(for: slot) }
        }
    }
}

private struct InterviewSlotRow: View {
    let slot: InterviewSlot
    let scheduleLocation: String?
    let isWorking: Bool
    let action: () -> Void

    private var location: String? {
        let slotLocation = slot.location?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let slotLocation, !slotLocation.isEmpty { return slotLocation }

        let scheduleLocation = scheduleLocation?.trimmingCharacters(in: .whitespacesAndNewlines)
        return scheduleLocation?.isEmpty == false ? scheduleLocation : nil
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(slot.startsAt, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
                    .font(AppFont.subheadline(weight: .semibold))
                if let location {
                    Label(location, systemImage: "mappin.and.ellipse").font(AppFont.footnote()).foregroundStyle(AppSystemColor.secondaryLabel)
                }
            }
            Spacer()
            Button(slot.mine ? "Cancel" : "Book", action: action)
                .buttonStyle(.borderedProminent)
                .tint(slot.mine ? .red : AppSystemColor.primaryLabel)
                .disabled(isWorking || (!slot.mine && !slot.isAvailable))
        }
        .padding(12)
        .background(AppSystemColor.insetBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
