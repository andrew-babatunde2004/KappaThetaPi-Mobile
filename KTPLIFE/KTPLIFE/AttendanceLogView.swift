import SwiftUI

struct AttendanceLogView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var authManager: AuthManager
    @State private var semester: AttendanceSemester?
    @State private var log: AttendanceLog?
    @State private var isLoading = true
    @State private var errorMessage: String?

    private var service: AttendanceLogService {
        AttendanceLogService(accessTokenProvider: { [authManager] in
            try await authManager.validAccessToken()
        })
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    AppSectionHeading(
                        eyebrow: semester?.name ?? "Chapter Resources",
                        title: "Attendance log",
                        systemImage: "checkmark.seal.fill"
                    )

                    if isLoading {
                        AttendanceLoadingView()
                    } else if let errorMessage {
                        AppStatusSurface(message: errorMessage, systemImage: "exclamationmark.circle")
                    } else if let log {
                        AttendanceScoreView(summary: log.summary)
                        AttendanceRecordList(records: log.records)
                    } else {
                        AppStatusSurface(message: "No attendance semester is active right now.", systemImage: "calendar")
                    }
                }
                .padding(20)
            }
            .background(AppSystemColor.background)
            .navigationTitle("Attendance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(AppFont.subheadline(weight: .semibold))
                }
            }
            .refreshable { await loadAttendance() }
            .task { await loadAttendance() }
        }
        .tint(AttendanceDesign.accent)
    }

    @MainActor
    private func loadAttendance() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let semesters = try await service.fetchSemesters()
            // The semester list is newest-first. Between terms, keep the last
            // available record readable instead of presenting an empty screen.
            guard let selectedSemester = semesters.first(where: { $0.contains() }) ?? semesters.first else {
                semester = nil
                log = nil
                return
            }
            semester = selectedSemester
            log = try await service.fetchLog(semesterID: selectedSemester.id)
        } catch is CancellationError {
            return
        } catch {
            log = nil
            errorMessage = attendanceErrorMessage(for: error)
        }
    }
}

private enum AttendanceDesign {
    static let accent = Color(red: 0.15, green: 0.44, blue: 0.86)
    static let positive = Color(red: 0.12, green: 0.58, blue: 0.42)
    static let warning = Color(red: 0.86, green: 0.49, blue: 0.09)
    static let negative = Color(red: 0.81, green: 0.25, blue: 0.27)
}

private struct AttendanceScoreView: View {
    let summary: AttendanceSummary

    private var pointTotal: Int { summary.credited }
    private var percentage: Double {
        guard summary.total > 0 else { return 0 }
        return min(Double(pointTotal) / Double(summary.total), 1)
    }

    var body: some View {
        VStack(spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("TERM POINTS")
                        .font(AppFont.caption(weight: .semibold))
                        .tracking(1.2)
                        .foregroundStyle(AttendanceDesign.accent)
                    Text("Your attendance standing")
                        .font(AppFont.title(21))
                        .foregroundStyle(AppSystemColor.primaryLabel)
                }
                Spacer()
                Text("\(Int((percentage * 100).rounded()))%")
                    .font(AppFont.headline())
                    .foregroundStyle(AttendanceDesign.accent)
            }

            ZStack {
                // A subtle lower ellipse gives the progress ring a cylindrical base.
                Ellipse()
                    .fill(AttendanceDesign.accent.opacity(0.13))
                    .frame(width: 142, height: 18)
                    .offset(y: 62)

                Circle()
                    .stroke(AppSystemColor.insetBackground, lineWidth: 16)
                    .frame(width: 142, height: 142)

                Circle()
                    .trim(from: 0, to: percentage)
                    .stroke(
                        AttendanceDesign.accent,
                        style: StrokeStyle(lineWidth: 16, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .frame(width: 142, height: 142)
                    .animation(.smooth(duration: 0.65), value: percentage)

                VStack(spacing: 2) {
                    Text("\(pointTotal)")
                        .font(AppFont.largeTitle(38))
                        .foregroundStyle(AppSystemColor.primaryLabel)
                    Text("of \(summary.total) points")
                        .font(AppFont.caption(weight: .semibold))
                        .foregroundStyle(AppSystemColor.secondaryLabel)
                }
            }
            .frame(height: 158)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(pointTotal) of \(summary.total) attendance points earned")

            HStack(spacing: 0) {
                AttendanceMetric(value: summary.attended, label: "Present", color: AttendanceDesign.positive)
                AttendanceMetric(value: summary.excused, label: "Excused", color: AttendanceDesign.accent)
                AttendanceMetric(value: summary.absences, label: "Absent", color: summary.absences > 0 ? AttendanceDesign.negative : AppSystemColor.secondaryLabel)
            }
            .padding(.top, 2)

            if summary.remaining > 0 {
                Text("\(summary.remaining) absence \(summary.remaining == 1 ? "point" : "points") remaining before the chapter limit.")
                    .font(AppFont.footnote())
                    .foregroundStyle(AppSystemColor.secondaryLabel)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if summary.overLimit > 0 {
                Text("You are \(summary.overLimit) point\(summary.overLimit == 1 ? "" : "s") over the chapter absence limit.")
                    .font(AppFont.footnote(weight: .semibold))
                    .foregroundStyle(AttendanceDesign.negative)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .appElevatedSurface(radius: 26)
    }
}

private struct AttendanceMetric: View {
    let value: Int
    let label: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Text("\(value)")
                .font(AppFont.title(20))
                .foregroundStyle(color)
            Text(label)
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(AppSystemColor.secondaryLabel)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct AttendanceRecordList: View {
    let records: [AttendanceRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Attendance history")
                    .font(AppFont.title(21))
                    .foregroundStyle(AppSystemColor.primaryLabel)
                Spacer()
                Text("\(records.count) EVENTS")
                    .font(AppFont.caption(weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(AppSystemColor.secondaryLabel)
            }

            if records.isEmpty {
                AppStatusSurface(message: "Attendance will appear here after your first required event.", systemImage: "calendar.badge.clock")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                        AttendanceRecordRow(record: record)
                        if index < records.count - 1 {
                            Divider().padding(.leading, 52)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .appElevatedSurface()
            }
        }
    }
}

private struct AttendanceRecordRow: View {
    let record: AttendanceRecord

    private var statusColor: Color {
        switch record.displayStatus {
        case .present: AttendanceDesign.positive
        case .excused, .waived: AttendanceDesign.accent
        case .pending: AttendanceDesign.warning
        case .absent: AttendanceDesign.negative
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: record.displayStatus.systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(statusColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 5) {
                Text(record.title)
                    .font(AppFont.subheadline(weight: .semibold))
                    .foregroundStyle(AppSystemColor.primaryLabel)
                    .lineLimit(2)
                Text(record.startDate.formatted(.dateTime.month(.abbreviated).day().year()))
                    .font(AppFont.caption())
                    .foregroundStyle(AppSystemColor.secondaryLabel)
            }

            Spacer(minLength: 8)

            Text(record.displayStatus.label)
                .font(AppFont.caption(weight: .semibold))
                .foregroundStyle(statusColor)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 14)
        .accessibilityElement(children: .combine)
    }
}

private struct AttendanceLoadingView: View {
    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("Loading attendance...")
                .font(AppFont.subheadline())
                .foregroundStyle(AppSystemColor.secondaryLabel)
        }
        .frame(maxWidth: .infinity, minHeight: 190)
        .appElevatedSurface(radius: 26)
    }
}

private func attendanceErrorMessage(for error: Error) -> String {
    if case AuthManagerError.notAuthenticated = error { return "Sign in with SSO to load attendance." }
    if case KTPAPIError.missingAccessToken = error { return "Sign in with SSO to load attendance." }
    if case KTPAPIError.badStatusCode(let statusCode, _) = error, statusCode == 401 || statusCode == 403 {
        return "Your account does not have access to attendance records."
    }
    return "Could not load attendance. Pull down to try again."
}
