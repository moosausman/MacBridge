// MacBridge/Sources/MacBridge/Modules/WebSearch.swift
// Owns: keyless web search for Jugnu's search_web tool.
//
//   /web/search { query: String, limit?: Int }  ->  { ok, results: [{title, url, snippet}], engine, seconds }
//
// WHY THIS WAY
// ------------
// Scripted HTTP requests to search engines get rate-limited or served a
// challenge page (DuckDuckGo answers them with 202s, Brave with 429s), and
// the self-hosted SearXNG Jugnu used to rely on usually isn't running. A
// real browser engine is treated like a person: DuckDuckGo's plain HTML
// results load in under a second in an off-screen WKWebView owned by
// MacBridge -- no window, nothing on screen, no focus change -- and the
// results are read straight from the page. DuckDuckGo Lite is the fallback.

import Foundation
import AppKit
import WebKit

enum WebSearchModule {

    private static var webView: WKWebView?
    private static let lock = NSLock()   // one search at a time; the view is shared

    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    private struct Engine {
        let name: String
        let base: String
        let extractor: String
    }

    private static let engines = [
        Engine(name: "duckduckgo", base: "https://html.duckduckgo.com/html/?q=", extractor: """
        (() => {
          const items = Array.from(document.querySelectorAll('.result:not(.result--ad)')).map(r => {
            const a = r.querySelector('a.result__a');
            const s = r.querySelector('.result__snippet');
            return a ? {title: a.textContent.trim(), url: a.href, snippet: s ? s.textContent.trim() : ''} : null;
          }).filter(Boolean);
          return JSON.stringify({href: location.href, items: items, done: document.readyState === 'complete'});
        })()
        """),
        Engine(name: "duckduckgo-lite", base: "https://lite.duckduckgo.com/lite/?q=", extractor: """
        (() => {
          const links = Array.from(document.querySelectorAll('a.result-link'));
          const snippets = Array.from(document.querySelectorAll('td.result-snippet'));
          const items = links.map((a, i) => ({title: a.textContent.trim(), url: a.href,
                                               snippet: snippets[i] ? snippets[i].textContent.trim() : ''}));
          return JSON.stringify({href: location.href, items: items, done: document.readyState === 'complete'});
        })()
        """),
    ]

    private static func view() -> WKWebView {
        if let webView { return webView }
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = .all
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 1000), configuration: config)
        view.customUserAgent = userAgent
        webView = view
        return view
    }

    static func search(args: [String: Any]) -> [String: Any] {
        PowerSupport.result {
            let query = try PowerSupport.text(args, "query", max: 400)
            let limit = try PowerSupport.integer(args, "limit", default: 8, range: 1...20)
            guard lock.try() || lock.lock(before: Date().addingTimeInterval(20)) else {
                throw PowerError.message("Another web search is still running; try again in a moment")
            }
            defer { lock.unlock() }

            let started = Date()
            for engine in engines {
                let results = run(engine, query: query)
                if !results.isEmpty {
                    return ["ok": true, "query": query, "engine": engine.name,
                            "results": Array(results.prefix(limit)),
                            "seconds": (Date().timeIntervalSince(started) * 10).rounded() / 10]
                }
            }
            throw PowerError.message("No web results for '\(query)' (or the search page didn't load -- check the internet connection)")
        }
    }

    private static func run(_ engine: Engine, query: String) -> [[String: Any]] {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        guard let url = URL(string: engine.base + encoded) else { return [] }
        DispatchQueue.main.sync { _ = view().load(URLRequest(url: url, timeoutInterval: 12)) }

        let begun = Date()
        let deadline = begun.addingTimeInterval(12)
        var best: [[String: Any]] = []
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.3)
            let box = PowerReplyBox()
            DispatchQueue.main.async {
                view().evaluateJavaScript(engine.extractor) { value, _ in
                    box.finish(["json": value as? String ?? "{}"])
                }
            }
            let raw = box.wait(seconds: 5)["json"] as? String ?? "{}"
            guard let data = raw.data(using: .utf8),
                  let page = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let href = page["href"] as? String,
                  // The view is reused: until the new page commits it still
                  // shows the previous search. Only read this query's page.
                  URLComponents(string: href)?.queryItems?.first(where: { $0.name == "q" })?.value == query
            else { continue }
            let items = (page["items"] as? [[String: Any]] ?? []).compactMap(clean)
            if !items.isEmpty { best = items }
            if !best.isEmpty && (page["done"] as? Bool == true) { break }
            // A fully loaded page that still has no results after a few seconds has none.
            if (page["done"] as? Bool == true) && Date().timeIntervalSince(begun) > 4 { break }
        }
        return best
    }

    /// Unwraps DuckDuckGo's redirect links to the real destination and drops
    /// anything that isn't a plain web result.
    private static func clean(_ item: [String: Any]) -> [String: Any]? {
        guard var link = item["url"] as? String, let title = item["title"] as? String, !title.isEmpty else { return nil }
        if let components = URLComponents(string: link), components.host?.hasSuffix("duckduckgo.com") == true {
            guard let target = components.queryItems?.first(where: { $0.name == "uddg" })?.value else { return nil }
            link = target
        }
        guard link.hasPrefix("http"), !link.contains("duckduckgo.com/y.js") else { return nil }
        return ["title": title, "url": link, "snippet": item["snippet"] as? String ?? ""]
    }
}
