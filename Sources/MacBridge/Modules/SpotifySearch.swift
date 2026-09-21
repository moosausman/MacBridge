// MacBridge/Sources/MacBridge/Modules/SpotifySearch.swift
// Owns: turning a name ("bohemian rhapsody queen") into Spotify IDs, with no
// API key, using Spotify's own public web player.
//
//   /spotify/search { query: String, type?: "tracks"|"artists"|"albums"|"playlists", limit?: Int }
//
// WHY THIS WAY
// ------------
// Spotify's AppleScript dictionary can play a URI but can't search, and
// `play track "spotify:search:..."` is silently ignored by current Spotify
// builds (checked on 1.3.0). Everything else tried for name -> ID was
// unreliable in practice: search engines rate-limit or CAPTCHA scripted
// queries, song.link's public API is shut down, Wikidata is slow and has
// gaps, and the Spotify Web API needs a developer key.
//
// open.spotify.com/search works for logged-out visitors in any browser. This
// loads it in an invisible, off-screen WKWebView owned by MacBridge -- no
// window, nothing on screen, no focus change, no Safari involvement -- waits
// for the results to render, and reads the result links. It's Spotify's
// own search, so the ranking matches what the app would show. The web view
// is kept warm between searches, so repeat searches take about a second.

import Foundation
import AppKit
import WebKit

enum SpotifySearchModule {

    private static var webView: WKWebView?
    private static let lock = NSLock()   // one search at a time; the view is shared

    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    private static func view() -> WKWebView {
        if let webView { return webView }
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = .all   // never play audio in the web view
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 1000), configuration: config)
        view.customUserAgent = userAgent
        webView = view
        return view
    }

    /// JS that collects result links of one kind from whatever has rendered.
    private static func extractor(kind: String) -> String {
        """
        (() => {
          const kind = "\(kind)";
          const out = []; const seen = new Set();
          document.querySelectorAll('a[href*="/' + kind + '/"]').forEach(a => {
            const m = (a.getAttribute('href') || '').match(new RegExp('/' + kind + '/([A-Za-z0-9]{22})'));
            if (!m || seen.has(m[1])) return;
            const name = (a.textContent || a.getAttribute('title') || a.getAttribute('aria-label') || '').trim();
            if (!name) return;
            seen.add(m[1]);
            const card = a.closest('[role="row"]') || a.closest('[data-encore-id="card"]')
                      || (a.parentElement && a.parentElement.parentElement) || a.parentElement;
            const artists = card ? Array.from(card.querySelectorAll('a[href*="/artist/"]'))
                .map(x => x.textContent.trim()).filter(t => t && t !== name) : [];
            out.push({id: m[1], name: name, artists: Array.from(new Set(artists))});
          });
          return JSON.stringify({path: decodeURIComponent(location.pathname), items: out});
        })()
        """
    }

    static func search(args: [String: Any]) -> [String: Any] {
        PowerSupport.result {
            let query = try PowerSupport.text(args, "query", max: 300)
            let type = (args["type"] as? String ?? "tracks").lowercased()
            let kinds = ["tracks": "track", "artists": "artist", "albums": "album", "playlists": "playlist"]
            guard let kind = kinds[type] else {
                throw PowerError.message("type must be tracks, artists, albums or playlists")
            }
            let limit = try PowerSupport.integer(args, "limit", default: 5, range: 1...20)
            let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? query
            guard let url = URL(string: "https://open.spotify.com/search/\(encoded)/\(type)") else {
                throw PowerError.message("Couldn't build a search URL for that query")
            }

            guard lock.try() || lock.lock(before: Date().addingTimeInterval(20)) else {
                throw PowerError.message("Another Spotify search is still running; try again in a moment")
            }
            defer { lock.unlock() }

            let expectedPath = "/search/\(query)/\(type)"
            let started = Date()
            DispatchQueue.main.sync { _ = view().load(URLRequest(url: url, timeoutInterval: 15)) }

            // Poll the rendered page until results appear (or give up).
            let script = extractor(kind: kind)
            var results: [[String: Any]] = []
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline {
                Thread.sleep(forTimeInterval: 0.35)
                let box = PowerReplyBox()
                DispatchQueue.main.async {
                    view().evaluateJavaScript(script) { value, _ in
                        box.finish(["json": value as? String ?? "[]"])
                    }
                }
                let raw = box.wait(seconds: 5)["json"] as? String ?? "{}"
                // The view is reused: until the new page commits, it still
                // shows the PREVIOUS search (whose track rows contain album
                // and artist links too). Only accept results from this query's page.
                guard let data = raw.data(using: .utf8),
                      let page = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let path = page["path"] as? String,
                      path.lowercased() == expectedPath.lowercased() else { continue }
                if let parsed = page["items"] as? [[String: Any]], !parsed.isEmpty {
                    results = parsed
                    // Give a just-rendered page a beat to finish filling in artist names.
                    if Date().timeIntervalSince(started) < 1.2 { continue }
                    break
                }
            }
            guard !results.isEmpty else {
                throw PowerError.message("Spotify's search returned no \(type) for '\(query)' (or open.spotify.com "
                                         + "didn't load -- check the internet connection)")
            }
            let items: [[String: Any]] = results.prefix(limit).map { r in
                let id = r["id"] as? String ?? ""
                return ["uri": "spotify:\(kind):\(id)", "id": id, "name": r["name"] as? String ?? "",
                        "artist": (r["artists"] as? [String] ?? []).joined(separator: ", ")]
            }
            return ["ok": true, "query": query, "type": type, "results": items,
                    "seconds": (Date().timeIntervalSince(started) * 10).rounded() / 10]
        }
    }
}
