//
//  MessageView.swift
//  Character AI swift project
//
//  Created by Kody Morrison on 26/09/2026.
//

import SwiftUI

struct MessageView: View {
    @ObservedObject var turnState: TurnState
    var turn: Turn { turnState.turn }
    let character: Character?
    let palette: EnvironmentalPalette
    let onRegenerate: (() -> Void)?
    let onEdit: ((String, String) -> Void)?
    let isPinning: Bool
    let onPin: (() -> Void)?
    let isRewinding: Bool
    let onRewind: ((Turn) -> Void)?
    let onStartNewConversation: ((Turn) -> Void)?

    @State private var isEditing = false
    @State private var editedText = ""
    @State private var isShowingActions = false
    @State private var isHoveringMessage = false
    @Environment(\.colorScheme) private var colorScheme
    
    private func copyMessage(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            text,
            forType: .string
        )
    }
    
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if turn.isHuman {
                Spacer(minLength: 40)
            }
            
            if !turn.isHuman {
                avatar
            }
            
            messageContent
                .frame(maxWidth: turn.isHuman ? 480 : 520, alignment: turn.isHuman ? .trailing : .leading)
            
            if !turn.isHuman {
                Spacer(minLength: 40)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
        .transition(.opacity)
        .onHover { isHoveringMessage = $0 }
    }
    
    private var messageContent: some View {
        VStack(
            alignment: turn.isHuman ? .trailing : .leading,
            spacing: 4
        ) {
            if !turn.isHuman {
                Text(turn.authorName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.caiText)
                    .padding(.leading, 4)
            }
            
            if let candidate = turn.candidates.first(where: {
                $0.candidateId == turn.primaryCandidateID
            }) {
                if isEditing {
                    VStack(
                        alignment: .leading,
                        spacing: 8
                    ) {
                        TextEditor(
                            text: $editedText
                        )
                        .frame(minHeight: 80)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(
                            Color.secondary.opacity(0.12)
                        )
                        .clipShape(
                            RoundedRectangle(
                                cornerRadius: 12,
                                style: .continuous
                            )
                        )

                        HStack {
                            Button("Cancel") {
                                isEditing = false
                                editedText = candidate.rawContent
                            }

                            Spacer()

                            Button("Save") {
                                let newText = editedText.trimmingCharacters(
                                    in: .whitespacesAndNewlines
                                )

                                guard !newText.isEmpty else {
                                    return
                                }

                                onEdit?(candidate.candidateId, newText)
                                isEditing = false
                            }
                            .buttonStyle(GlassProminentButtonStyle())
                        }
                    }
                    .frame(maxWidth: 480)
                } else {
                    if candidate.isFiltered, !turn.isHuman {
                        VStack(alignment: .leading, spacing: 6) {
                            messageBubble(candidate: candidate)

                            // HAR: the web client renders a filter notice under a
                            // censored candidate (`safety_truncated`) while keeping the
                            // turn in place. Adapted to the existing glass message
                            // styling rather than the web's HTML block.
                            filteredNotice
                        }
                    } else {
                        messageBubble(candidate: candidate)
                    }
                }
            }
        }
    }

    /// The existing glass message bubble with its pin/action overlay. Normal
    /// messages render this directly, so their layout hierarchy is unchanged.
    private func messageBubble(candidate: Candidate) -> some View {
        ZStack(alignment: turn.isHuman ? .bottomLeading : .bottomTrailing) {
            CharacterMessageFormattingView(
                content: candidate.rawContent,
                expandsToFill: false,
                isStreaming: candidate.isFinal == false
            )
            .font(.system(size: 14))
            .textSelection(.enabled)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .glassSurface(
                turn.isHuman ? .userMessage : .characterMessage,
                cornerRadius: GlassMetrics.messageRadius
            )
            .foregroundStyle(Color.caiText)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: GlassMetrics.messageRadius,
                    style: .continuous
                )
            )
            .contextMenu {
                messageActionRows(candidate: candidate)
            }

            // The pin stays a badge on the bubble's corner; the actions
            // trigger sits just outside the bubble. Both are overlays, so
            // neither appearing nor leaving can resize the bubble and move the
            // rest of the transcript — same construction as ProviderChatView.
            if turn.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.caiPrimary)
                    .padding(4)
                    .transition(.opacity)
            }

            if isHoveringMessage || isShowingActions {
                actionsButton(candidate: candidate)
                    .offset(x: turn.isHuman ? -32 : 32)
                    .transition(.opacity)
            }
        }
    }

    private func actionsButton(candidate: Candidate) -> some View {
        Button {
            isShowingActions = true
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.caiMuted)
                .frame(width: 22, height: 22)
                .background(Circle().fill(palette.atmosphericBase.opacity(colorScheme == .dark ? 0.85 : 0.55)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Message actions")
        .popover(isPresented: $isShowingActions, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 2) {
                messageActionRows(candidate: candidate)
            }
            .padding(8)
            .frame(width: 260)
            .presentationBackground(.regularMaterial)
        }
        .padding(4)
    }

    private var filteredNotice: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.caiMuted)
            VStack(alignment: .leading, spacing: 2) {
                Text("This content has been filtered")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.caiText)
                Text("Please make sure your chats comply with our Terms and Community Guidelines. Send a new message to continue.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.caiMuted)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: 480, alignment: .leading)
        .glassSurface(.floatingControl, cornerRadius: GlassMetrics.controlRadius)
        .clipShape(RoundedRectangle(cornerRadius: GlassMetrics.controlRadius, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("This content has been filtered. Send a new message to continue the conversation.")
    }

    @ViewBuilder
    private func messageActionRows(candidate: Candidate) -> some View {
        GlassActionRow(
            title: turn.isPinned ? "Unpin message" : "Pin message",
            systemImage: turn.isPinned ? "pin.slash" : "pin",
            isDisabled: onPin == nil || isPinning || isRewinding
        ) {
            let action = onPin
            isShowingActions = false
            action?()
        }

        GlassActionRow(
            title: "Copy message",
            systemImage: "doc.on.doc"
        ) {
            copyMessage(candidate.rawContent)
            isShowingActions = false
        }

        GlassActionRow(
            title: "Edit message",
            systemImage: "pencil",
            isDisabled: onEdit == nil || isRewinding
        ) {
            editedText = candidate.rawContent
            isEditing = true
            isShowingActions = false
        }

        if !turn.isHuman {
            Divider()

            GlassActionRow(
                title: "Regenerate response",
                systemImage: "arrow.clockwise",
                isDisabled: onRegenerate == nil || isRewinding
            ) {
                let action = onRegenerate
                isShowingActions = false
                action?()
            }
        }

        Divider()

        GlassActionRow(
            title: "Rewind from here…",
            systemImage: "backward.end",
            role: .destructive,
            isDisabled: onRewind == nil || isRewinding
        ) {
            let action = onRewind
            isShowingActions = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                action?(turn)
            }
        }

        GlassActionRow(
            title: "Start new conversation from here…",
            systemImage: "plus.message",
            isDisabled: onStartNewConversation == nil || isRewinding
        ) {
            let action = onStartNewConversation
            isShowingActions = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                action?(turn)
            }
        }
    }
        
    private var avatar: some View {
        Group {
            if let character,
               let avatarURL = CharacterImageURL.makeURL(
                avatarFileName: character.avatarFileName
               ) {
                CachedAvatarView(url: avatarURL) {
                    fallbackAvatar
                }
            } else {
                fallbackAvatar
            }
        }
        .frame(width: 32, height: 32)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
    }
    
    private var fallbackAvatar: some View {
        ZStack {
            Circle()
                .fill(palette.atmosphericBase.opacity(colorScheme == .dark ? 0.85 : 0.55))
            
            Text(turn.authorName.prefix(1))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.caiText)
        }
    }
}
