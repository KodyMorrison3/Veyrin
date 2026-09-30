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

    @State private var isEditing = false
    @State private var editedText = ""
    
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
                    Text(candidate.rawContent)
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

                if turn.isHuman {
                    Button {
                        editedText = candidate.rawContent
                        isEditing = true
                    } label: {
                        Label(
                            "Edit",
                            systemImage: "pencil"
                        )
                        .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .disabled(onEdit == nil)
                } else {
                    Button {
                        onRegenerate?()
                    } label: {
                        Label(
                            "Regenerate",
                            systemImage: "arrow.clockwise"
                        )
                        .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .disabled(onRegenerate == nil)
                }
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

