import AIUsageBarCore
import AppKit
import SwiftUI

struct UsagePopoverView: View {
    @ObservedObject var model: UsageModel

    private var language: AppLanguage { model.language }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(language.text(.usage))
                        .font(.system(size: 18, weight: .bold))
                    Text(language.text(.weeklyUsage))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    model.refreshManually()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(model.isRefreshing)
                .help(language.text(.refresh))
            }

            settingRow(title: language.text(.primaryDisplay)) {
                Picker("", selection: $model.primaryProvider) {
                    ForEach(ProviderID.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 220)
            }

            ScrollView {
                VStack(spacing: 10) {
                    ProviderCard(provider: .codex, state: model.state(for: .codex), language: language)
                    ProviderCard(provider: .claude, state: model.state(for: .claude), language: language)
                }
            }

            Divider()

            settingRow(title: language.text(.language)) {
                Picker("", selection: $model.language) {
                    ForEach(AppLanguage.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 180)
            }

            HStack {
                Button(language.text(.refresh)) { model.refreshManually() }
                    .disabled(model.isRefreshing)
                Spacer()
                Button(language.text(.quit)) { NSApplication.shared.terminate(nil) }
            }
            .controlSize(.small)
        }
        .padding(16)
        .frame(width: 370, height: 610)
    }

    private func settingRow<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title)
                .font(.subheadline.weight(.medium))
            Spacer()
            content()
        }
    }
}

private struct ProviderCard: View {
    let provider: ProviderID
    let state: ProviderState
    let language: AppLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                ZStack {
                    Circle().fill(provider.swiftUIAccent.opacity(0.15))
                    Text(provider.menuInitial)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(provider.swiftUIAccent)
                }
                .frame(width: 24, height: 24)
                Text(provider.displayName)
                    .font(.headline)
                Spacer()
                if state.isLoading {
                    ProgressView().controlSize(.small)
                } else if state.snapshot != nil {
                    Text(remainingPercentageText)
                        .font(.system(.body, design: .rounded, weight: .semibold))
                }
            }

            ProgressView(value: state.snapshot?.weekly.remainingPercent ?? 0, total: 100)
                .tint(provider.swiftUIAccent)
                .opacity(state.snapshot == nil ? 0.4 : 1)

            metricRow(
                language.text(.remaining),
                remainingPercentageText
            )
            metricRow(language.text(.resets), formattedReset(state.snapshot?.weekly.resetAt))
            metricRow(language.text(.localTokens), formattedTokens(state.localTokens))

            if let snapshot = state.snapshot {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.shield")
                    Text(language.text(.providerData))
                    Spacer()
                    Text(formattedUpdated(snapshot.fetchedAt))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            } else if state.isLoading {
                Text(language.text(.loading))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if let failureText {
                Label(failureText, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(13)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 0.5)
        )
    }

    private var remainingPercentageText: String {
        state.snapshot.map { "\(Int($0.weekly.remainingPercent.rounded()))%" } ?? "—"
    }

    private var failureText: String? {
        switch state.failure {
        case .codexLoginExpired:
            language.text(.reconnectCodex)
        case .loginExpired:
            language.text(.reconnectClaude)
        case .codexUnavailable:
            language.text(.codexUnavailable)
        case .claudeUnavailable:
            nil
        case nil:
            nil
        }
    }

    private func metricRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(.subheadline, design: .rounded, weight: .medium))
        }
        .font(.subheadline)
    }

    private func formattedReset(_ date: Date?) -> String {
        guard let date else { return "—" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language == .chinese ? "zh_CN" : "en_US")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func formattedUpdated(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language == .chinese ? "zh_CN" : "en_US")
        formatter.timeStyle = .short
        return "\(language.text(.lastUpdated)) \(formatter.string(from: date))"
    }

    private func formattedTokens(_ tokens: Int?) -> String {
        guard let tokens else { return "—" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: tokens)) ?? "\(tokens)"
    }
}
