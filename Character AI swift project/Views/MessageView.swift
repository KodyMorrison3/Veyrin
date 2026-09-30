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
            
            if let candidate = turn.candidates.first {
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
                
                if !turn.isHuman {
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

