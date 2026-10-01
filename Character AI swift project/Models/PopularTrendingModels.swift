//
//  PopularTrendingModels.swift
//  Character AI swift project
//
//  Models for the curated popular/trending character lists
//  (`recommendation/v1/curated_character_lists`), live-verified 2026-10-01 —
//  see Docs/PopularTrendingDiscovery.md. The per-character display subset is
//  identical to the Discover feed character, so `DiscoverFeedCharacter` is
//  reused; the Int 0/1 flags and nullable voice/lorebook ids observed on this
//  endpoint are deliberately unmodeled (not displayed).
//

import Foundation

struct CuratedCharacterListsResponse: Decodable {
    /// Keyed by the requested `list_id` (e.g.
    /// `cold_start_popular_characters_l30d_v1`). A list the server omits is
    /// treated as empty by the accessor below, not an error.
    let curatedCharacterLists: [String: [DiscoverFeedCharacter]]

    enum CodingKeys: String, CodingKey {
        case curatedCharacterLists = "curated_character_lists"
    }

    func characters(forListID listID: String) -> [DiscoverFeedCharacter] {
        curatedCharacterLists[listID] ?? []
    }
}
