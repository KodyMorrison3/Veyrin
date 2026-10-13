import Foundation

private func decodeFailureDescription<Response: Decodable & Sendable>(
    _ type: Response.Type,
    _ json: String
) async -> String {
    do {
        _ = try await HTTPResponseDecoder.decode(type, from: Data(json.utf8))
        preconditionFailure("decoding unexpectedly succeeded")
    } catch {
        return error.localizedDescription
    }
}

@main
struct DecodeDiagnosticsChecks {
    @MainActor static func main() async throws {
        // A preview chat that omits a required field must name that field.
        let previewMissingVisibility = """
        {"chats":[{"chat_id":"c1","create_time":"t","creator_id":"u","character_id":"ch",
        "state":"STATE_ACTIVE","type":"TYPE_ONE_ON_ONE","preview_turns":[]}]}
        """
        let previewMessage = await decodeFailureDescription(ChatPreviewResponse.self, previewMissingVisibility)
        precondition(previewMessage.contains("missing field 'chats[0].visibility'"), previewMessage)
        print("PASS preview chat missing visibility names chats[0].visibility")

        // The server omits `chats` when a character has no conversations; that is an empty result.
        let previewWithoutChats = try await HTTPResponseDecoder.decode(ChatPreviewResponse.self, from: Data("{}".utf8))
        precondition(previewWithoutChats.chats.isEmpty)
        print("PASS preview response without chats decodes as empty")

        // The copy-source fallback decodes /turns pages; a turn author without author_id must be named.
        let turnMissingAuthorID = """
        {"turns":[{"turn_key":{"turn_id":"t1","chat_id":"c1"},"state":"STATE_FINAL",
        "author":{"name":"Me"},"candidates":[],"primary_candidate_id":"x"}],
        "meta":{"next_token":null}}
        """
        let turnsMessage = await decodeFailureDescription(TurnsResponse.self, turnMissingAuthorID)
        precondition(turnsMessage.contains("missing field 'turns[0].author.author_id'"), turnsMessage)
        print("PASS turn author missing author_id names turns[0].author.author_id")

        // A turns page without meta is also a required-field failure and must be named.
        let turnsMissingMeta = """
        {"turns":[]}
        """
        let metaMessage = await decodeFailureDescription(TurnsResponse.self, turnsMissingMeta)
        precondition(metaMessage.contains("missing field 'meta'"), metaMessage)
        print("PASS turns page without meta names meta")

        // Valid responses still decode.
        let valid = try await HTTPResponseDecoder.decode(
            TurnsResponse.self,
            from: Data(#"{"turns":[],"meta":{"next_token":null}}"#.utf8)
        )
        precondition(valid.turns.isEmpty && valid.meta.nextToken == nil)
        print("PASS valid turns page still decodes")

        print("Decode diagnostics checks passed")
    }
}
