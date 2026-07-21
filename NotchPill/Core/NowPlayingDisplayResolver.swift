import Foundation

/// Normalizes MediaRemote metadata so movies and TV episodes from browsers and
/// streaming sites show meaningful titles instead of site domains or tab chrome.
enum NowPlayingDisplayResolver {
    static func resolve(
        title: String?,
        artist: String?,
        album: String?,
        mediaType: String? = nil,
        bundleIdentifier: String? = nil
    ) -> (title: String, artist: String)? {
        let rawTitle = clean(title)
        let rawArtist = clean(artist)
        let rawAlbum = clean(album)

        guard !rawTitle.isEmpty || !rawArtist.isEmpty || !rawAlbum.isEmpty else { return nil }

        if isVideoLike(
            title: rawTitle,
            artist: rawArtist,
            album: rawAlbum,
            mediaType: mediaType,
            bundleIdentifier: bundleIdentifier
        ) {
            return resolveVideo(title: rawTitle, artist: rawArtist, album: rawAlbum)
        }
        return resolveMusic(title: rawTitle, artist: rawArtist, album: rawAlbum)
    }

    // MARK: - Music

    private static func resolveMusic(title: String, artist: String, album: String) -> (title: String, artist: String)? {
        var primary = title
        if primary.isEmpty { primary = album }
        guard !primary.isEmpty else { return nil }

        var secondary = artist
        if isNoiseSecondary(secondary) { secondary = "" }
        return (primary, secondary)
    }

    // MARK: - Video

    private static func resolveVideo(title: String, artist: String, album: String) -> (title: String, artist: String) {
        var primary = stripStreamingDecorations(title)
        var secondary = isNoiseSecondary(artist) ? "" : artist

        // Some players put the real name in artist while title is a site/domain.
        if (primary.isEmpty || isNoisePrimary(primary)) && !secondary.isEmpty {
            // keep secondary as primary below via swap logic
        } else if isNoisePrimary(primary), !secondary.isEmpty {
            swap(&primary, &secondary)
        }

        let showFromAlbum = showName(from: album)

        if primary.isEmpty || isNoisePrimary(primary) {
            if let showFromAlbum, !showFromAlbum.isEmpty {
                primary = showFromAlbum
            } else if !secondary.isEmpty {
                primary = secondary
                secondary = ""
            } else if !album.isEmpty {
                primary = stripStreamingDecorations(album)
            }
        }

        if secondary.isEmpty, let showFromAlbum, !showFromAlbum.isEmpty, showFromAlbum != primary {
            secondary = showFromAlbum
        }

        if let parsed = parseCombinedTitle(primary) {
            if secondary.isEmpty || secondary.caseInsensitiveCompare(parsed.show) == .orderedSame {
                return (parsed.detail, parsed.show)
            }
            return (parsed.detail, secondary)
        }

        if secondary.caseInsensitiveCompare(primary) == .orderedSame {
            secondary = ""
        }

        return (primary, secondary)
    }

    // MARK: - Classification

    private static func isVideoLike(
        title: String,
        artist: String,
        album: String,
        mediaType: String?,
        bundleIdentifier: String?
    ) -> Bool {
        if let mediaType = mediaType?.lowercased() {
            if mediaType.contains("video") || mediaType.contains("movie") || mediaType.contains("tv") {
                return true
            }
            if mediaType.contains("music") || mediaType.contains("audio") {
                return false
            }
        }

        if containsSeasonEpisode(title) || containsSeasonEpisode(album) { return true }
        if isNoisePrimary(title) || isNoiseSecondary(artist) { return true }
        if album.lowercased().contains("season") { return true }

        if let bundleIdentifier, isBrowserBundle(bundleIdentifier) {
            if isNoisePrimary(title) || isNoiseSecondary(artist) || !album.isEmpty {
                return true
            }
        }

        // Show in artist with a distinct title is typical for episodic video.
        if !artist.isEmpty, !title.isEmpty,
           artist.caseInsensitiveCompare(title) != .orderedSame,
           !isNoiseSecondary(artist),
           album.lowercased().contains("season") {
            return true
        }

        return false
    }

    private static func isBrowserBundle(_ bundleId: String) -> Bool {
        let browsers: Set<String> = [
            "com.apple.Safari",
            "com.google.Chrome",
            "com.brave.Browser",
            "company.thebrowser.Browser",
            "org.mozilla.firefox",
            "com.microsoft.edgemac",
            "com.operasoftware.Opera",
            "com.vivaldi.Vivaldi",
            "com.apple.WebKit.GPU",
        ]
        if browsers.contains(bundleId) { return true }
        return bundleId.lowercased().contains("browser")
    }

    // MARK: - Parsing helpers

    private static func clean(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func stripStreamingDecorations(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return text }

        let suffixPatterns = [
            #"\s*[\|·•]\s*[^|·•]+$"#,
            #"\s*-\s*(Netflix|Disney\+|Hulu|Max|Prime Video|YouTube|Crunchyroll)\s*$"#,
            #"\s+on\s+(Netflix|Disney\+|Hulu|Max|Prime Video|YouTube)\s*$"#,
        ]
        for pattern in suffixPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(text.startIndex..<text.endIndex, in: text)
                text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func showName(from album: String) -> String? {
        let trimmed = album.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let regex = try? NSRegularExpression(pattern: #"^(.+?)(?:,\s*Season\b.*)?$"#, options: [.caseInsensitive]) {
            let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
            if let match = regex.firstMatch(in: trimmed, range: range),
               let showRange = Range(match.range(at: 1), in: trimmed) {
                let show = String(trimmed[showRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !show.isEmpty { return show }
            }
        }
        return trimmed
    }

    private static func parseCombinedTitle(_ value: String) -> (show: String, detail: String)? {
        let separators = [" — ", " – ", " - ", " | ", ": ", " · "]
        for separator in separators {
            let parts = value.components(separatedBy: separator).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
            guard parts.count >= 2 else { continue }

            let show = parts[0]
            let detail = parts.dropFirst().joined(separator: separator.trimmingCharacters(in: .whitespaces))
            guard !isNoisePrimary(show), !detail.isEmpty else { continue }
            return (show, detail)
        }
        return nil
    }

    private static func containsSeasonEpisode(_ value: String) -> Bool {
        let lower = value.lowercased()
        if lower.contains("season") && lower.contains("episode") { return true }
        return value.range(of: #"\bS\d{1,2}\s*E\d{1,2}\b"#, options: .regularExpression) != nil
    }

    private static func looksLikeDomain(_ value: String) -> Bool {
        let lower = value.lowercased()
        if lower.contains("://") || lower.hasPrefix("www.") { return true }
        if lower.contains(" ") { return false }

        let parts = lower.split(separator: ".")
        guard parts.count >= 2 else { return false }
        guard let tld = parts.last, tld.count >= 2, tld.allSatisfy(\.isLetter) else { return false }
        return parts.dropLast().allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }
    }

    private static let serviceNoise: Set<String> = [
        "netflix", "disney+", "disney plus", "hulu", "hbo max", "max", "prime video",
        "amazon prime video", "apple tv", "apple tv+", "paramount+", "peacock",
        "youtube", "youtube music", "crunchyroll", "tubi", "pluto tv", "vimeo",
        "google chrome", "safari", "arc", "brave browser", "microsoft edge", "firefox",
    ]

    private static func isServiceNoise(_ value: String) -> Bool {
        let lower = value.lowercased()
        if serviceNoise.contains(lower) { return true }
        for service in serviceNoise where lower.hasPrefix("\(service) ") || lower.hasSuffix(" \(service)") {
            return true
        }
        return false
    }

    private static func isNoisePrimary(_ value: String) -> Bool {
        isServiceNoise(value) || looksLikeDomain(value)
    }

    private static func isNoiseSecondary(_ value: String) -> Bool {
        isNoisePrimary(value)
    }
}
