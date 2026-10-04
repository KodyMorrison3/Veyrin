//
//  CharmsView.swift
//  Character AI swift project
//
//  Read-only transaction and quest history. The captured read endpoints do not
//  expose a balance, so this view deliberately does not synthesize one.
//

import SwiftUI

struct CharmsView: View {
    @StateObject private var viewModel: CharmsViewModel

    init(authStore: AuthStore) {
        _viewModel = StateObject(
            wrappedValue: CharmsViewModel(authStore: authStore)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Charms")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await viewModel.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading)
                .help("Refresh Charms")
            }
            Group {
            switch viewModel.state {
            case .idle, .loading:
                ProgressView("Loading Charms…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .empty:
                ContentUnavailableView(
                    "No Charms Activity",
                    systemImage: "sparkles",
                    description: Text("No transactions or quests were returned.")
                )
            case .failed(let message):
                VStack(spacing: 12) {
                    ContentUnavailableView(
                        "Charms Unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text(message)
                    )
                    Button("Retry") {
                        Task { await viewModel.refresh() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded(let transactions, let quests):
                activity(transactions: transactions, quests: quests)
            }
        }
        }
        .frame(minWidth: 440, minHeight: 320)
        .background { ShellEnvironmentalBackground() }
        .presentationBackground(.regularMaterial)
        .task {
            if case .idle = viewModel.state {
                await viewModel.load()
            }
        }
    }

    private var isLoading: Bool {
        if case .loading = viewModel.state { return true }
        return false
    }

    private func activity(
        transactions: [CharmTransaction],
        quests: [CharmQuest]
    ) -> some View {
        Form {
            Section("Balance") {
                Text("A current balance is not included in the confirmed read responses.")
                    .foregroundStyle(.secondary)
            }

            Section("Transactions") {
                if transactions.isEmpty {
                    Text("No transactions.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(transactions) { transaction in
                        transactionRow(transaction)
                    }
                }
            }

            Section("Quests") {
                if quests.isEmpty {
                    Text("No quests.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(quests) { quest in
                        questRow(quest)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private func transactionRow(_ transaction: CharmTransaction) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(transaction.productID)
                    .font(.headline)
                Spacer()
                Text(transaction.amount)
                    .font(.headline.monospacedDigit())
            }
            Text(transaction.description)
                .font(.callout)
            Text(formattedTime(transaction.createTime))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }

    private func questRow(_ quest: CharmQuest) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(quest.questTitle)
                    .font(.headline)
                Spacer()
                Text("\(quest.questProgressAmount) / \(quest.questObjectiveAmount)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text(readable(quest.questProgressStatus))
                Text("·")
                Text(quest.rewardClaimed ? "Claimed" : "Not claimed")
                Text("·")
                Text("Reward: \(quest.questRewardAmount) charms")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Text(readable(quest.questType))
                Text("·")
                Text(readable(quest.questInterval))
                if let expiry = quest.questExpireTime {
                    Text("·")
                    Text("Expires \(formattedTime(expiry))")
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    private func readable(_ value: String) -> String {
        value
            .replacingOccurrences(of: "QUEST_PROGRESS_STATUS_", with: "")
            .replacingOccurrences(of: "_", with: " ")
            .lowercased()
            .capitalized
    }

    private func formattedTime(_ value: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: value)
            ?? ISO8601DateFormatter().date(from: value)
        return date?.formatted(date: .abbreviated, time: .shortened) ?? value
    }
}
