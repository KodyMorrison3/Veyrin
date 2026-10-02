//
//  MessageView.swift
//  Character AI swift project
//
//  Created by Kody Morrison on 26/09/2026.
//

import SwiftUI

struct MessageView: View {
    let turn: Turn
    let character: Character?
    let onRegenerate: (() -> Void)?
    let onEdit: ((String) -> Void)?
    let isPinning: Bool
    let onPin: (() -> Void)?
    let isRewinding: Bool
    let onRewind: (() -> Void)?
    let onStartNewConversation: (() -> Void)?

    @State private var isEditing = false
    @State private var editedText = ""
    
    private func copyMessage(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            text,
            forType: .string
        )
    }
    
    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if turn.isHuman {
                Spacer(minLength: 0)
            }
            
            if !turn.isHuman {
                avatar
            }
            
            messageContent
            
            if !turn.isHuman {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }
    
    private var messageContent: some View {
        VStack(
            alignment: turn.isHuman ? .trailing : .leading,
            spacing: 4
        ) {
            if !turn.isHuman {
                Text(turn.authorName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

                                onEdit?(newText)
                                isEditing = false
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .frame(maxWidth: 500)
                } else {
                    CharacterMessageFormattingView(content: candidate.rawContent)
                        .font(.body)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            turn.isHuman
                                ? Color.accentColor
                                : Color.secondary.opacity(0.12)
                        )
                        .foregroundStyle(
                            turn.isHuman
                                ? .white
                                : .primary
                        )
                        .clipShape(
                            RoundedRectangle(
                                cornerRadius: 16,
                                style: .continuous
                            )
                        )
                }

                Menu {
                    Button {
                        onPin?()
                    } label: {
                        Label(
                            turn.isPinned ? "Unpin message" : "Pin message",
                            systemImage: turn.isPinned ? "pin.slash" : "pin"
                        )
                    }
                    .disabled(onPin == nil || isPinning || isRewinding)

                    Button {
                        copyMessage(candidate.rawContent)
                    } label: {
                        Label(
                            "Copy",
                            systemImage: "doc.on.doc"
                        )
                    }

                    Button {
                        editedText = candidate.rawContent
                        isEditing = true
                    } label: {
                        Label(
                            "Edit message",
                            systemImage: "pencil"
                        )
                    }
                    .disabled(onEdit == nil || isRewinding)

                    if !turn.isHuman {
                        Divider()

                        Button {
                            onRegenerate?()
                        } label: {
                            Label(
                                "Regenerate",
                                systemImage: "arrow.clockwise"
                            )
                        }
                        .disabled(onRegenerate == nil || isRewinding)
                    }

                    Divider()

                    Button(role: .destructive) {
                        onRewind?()
                    } label: {
                        Label(
                            "Rewind from here…",
                            systemImage: "backward.end"
                        )
                    }
                    .disabled(onRewind == nil || isRewinding)

                    Button {
                        onStartNewConversation?()
                    } label: {
                        Label(
                            "Start new conversation from here…",
                            systemImage: "plus.message"
                        )
                    }
                    .disabled(onStartNewConversation == nil || isRewinding)
                } label: {
                    HStack(spacing: 4) {
                        if turn.isPinned {
                            Image(systemName: "pin.fill")
                                .font(.caption2)
                        }

                        Image(systemName: "ellipsis")
                            .font(.caption.weight(.semibold))
                    }
                    .frame(
                        width: turn.isPinned ? 36 : 28,
                        height: 28
                    )
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
            }
        }
    }
        
        private var avatar: some View {
            Group {
                if let character,
                   let avatarURL = CharacterImageURL.makeURL(
                    avatarFileName: character.avatarFileName
                   ) {
                    AsyncImage(url: avatarURL) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFill()
                            
                        case .failure:
                            fallbackAvatar
                            
                        case .empty:
                            ProgressView()
                            
                        @unknown default:
                            fallbackAvatar
                        }
                    }
                } else {
                    fallbackAvatar
                }
            }
            .frame(width: 30, height: 30)
            .clipShape(Circle())
        }
        
        private var fallbackAvatar: some View {
            ZStack {
                Circle()
                    .fill(.secondary.opacity(0.15))
                
                Text(turn.authorName.prefix(1))
                    .font(.caption)
                    .fontWeight(.semibold)
            }
        }
    }

