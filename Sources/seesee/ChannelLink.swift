import Foundation

enum ChannelLink {
    static func isSubscription(_ url: URL) -> Bool {
        let host = (url.host ?? "").lowercased()
        let parts = pathParts(url)

        if isYouTube(host) {
            if host == "youtu.be" || host.hasSuffix(".youtu.be") {
                return false
            }
            if parts.first == "playlist" { return true }
            if parts.first == "channel", parts.count >= 2 { return true }
            if parts.first == "c", parts.count >= 2 { return true }
            if parts.first == "user", parts.count >= 2 { return true }
            if parts.first?.hasPrefix("@") == true { return true }
            if parts.first == "watch" {
                let items = queryItems(url)
                let hasVideo = items.contains { $0.name == "v" && !($0.value ?? "").isEmpty }
                let hasList = items.contains { $0.name == "list" && !($0.value ?? "").isEmpty }
                return hasList && !hasVideo
            }
            return false
        }

        if host.contains("bilibili.com") {
            if host.hasPrefix("space.") { return true }
            if parts.contains("medialist") || parts.contains("favlist") { return true }
            return false
        }

        if parts.contains("playlist") || parts.contains("channel") { return true }
        if parts.first?.hasPrefix("@") == true { return true }
        return false
    }

    static func canonicalString(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.fragment = nil
        components.scheme = "https"
        let host = (components.host ?? "").lowercased()
        let parts = pathParts(url)

        if isYouTube(host) {
            components.host = "www.youtube.com"
            if parts.first == "playlist" {
                let list = queryItems(url).first(where: { $0.name == "list" })?.value
                components.queryItems = list.map { [URLQueryItem(name: "list", value: $0)] }
                components.path = "/playlist"
                return components.url?.absoluteString ?? url.absoluteString
            }
            components.queryItems = nil
            if let handle = parts.first, handle.hasPrefix("@") {
                components.path = "/\(handle)"
            } else if parts.count >= 2, ["channel", "c", "user"].contains(parts[0]) {
                components.path = "/\(parts[0])/\(parts[1])"
            }
            return components.url?.absoluteString ?? url.absoluteString
        }

        if host.contains("bilibili.com") {
            components.queryItems = nil
            if host.hasPrefix("space.") {
                let userID = parts.first ?? ""
                components.path = userID.isEmpty ? "" : "/\(userID)"
            }
            return components.url?.absoluteString ?? url.absoluteString
        }

        components.queryItems = nil
        return components.url?.absoluteString ?? url.absoluteString
    }

    static func usesPlaylistOrder(_ url: URL) -> Bool {
        pathParts(url).first == "playlist"
    }

    static func displayTitle(for url: URL) -> String {
        let parts = pathParts(url)
        if let handle = parts.first(where: { $0.hasPrefix("@") }) {
            return handle
        }
        if parts.first == "playlist" {
            return queryItems(url).first(where: { $0.name == "list" })?.value ?? "播放列表"
        }
        if parts.count >= 2, ["channel", "c", "user"].contains(parts[0]) {
            return parts[1]
        }
        if let last = parts.last, !last.isEmpty {
            return last
        }
        return url.host ?? "频道"
    }

    static func videoURL(id: String, webpageURL: String, sourceURL: URL) -> URL {
        let page = webpageURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if page.lowercased() != "na",
           let url = URL(string: page),
           url.scheme?.lowercased() == "http" || url.scheme?.lowercased() == "https" {
            return URL(string: URLIntake.canonicalString(for: url)) ?? url
        }
        let host = (sourceURL.host ?? "").lowercased()
        if host.contains("bilibili") {
            return URL(string: "https://www.bilibili.com/video/\(id)") ?? sourceURL
        }
        return URL(string: "https://www.youtube.com/watch?v=\(id)") ?? sourceURL
    }

    private static func isYouTube(_ host: String) -> Bool {
        host == "youtu.be"
            || host.hasSuffix(".youtu.be")
            || host == "youtube.com"
            || host.hasSuffix(".youtube.com")
    }

    private static func pathParts(_ url: URL) -> [String] {
        url.path.split(separator: "/").map(String.init)
    }

    private static func queryItems(_ url: URL) -> [URLQueryItem] {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    }
}
