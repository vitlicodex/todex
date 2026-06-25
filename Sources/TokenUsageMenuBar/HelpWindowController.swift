import AppKit
import Foundation
import WebKit

@MainActor
final class HelpWindowController: NSObject {
    private var window: NSWindow?
    private var webView: WKWebView?
    private var helpDirectory: URL?

    func show() {
        do {
            let helpURL = try findHelpURL()
            helpDirectory = helpURL.deletingLastPathComponent().standardizedFileURL
            let markdown = try String(contentsOf: helpURL, encoding: .utf8)
            let html = renderHTML(from: markdown)

            let webView = webView ?? WKWebView(frame: .zero)
            webView.navigationDelegate = self
            webView.loadHTMLString(html, baseURL: helpURL.deletingLastPathComponent())
            self.webView = webView

            let window = window ?? makeWindow(webView: webView)
            self.window = window
            NSApp.activate(ignoringOtherApps: true)
            window.center()
            window.makeKeyAndOrderFront(nil)
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func makeWindow(webView: WKWebView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 760),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "TODEX Help"
        window.contentView = webView
        return window
    }

    private func findHelpURL() throws -> URL {
        let candidates: [URL] = [
            Bundle.main.resourceURL?
                .appendingPathComponent("Help", isDirectory: true)
                .appendingPathComponent("HELP.md"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Documentation", isDirectory: true)
                .appendingPathComponent("Help", isDirectory: true)
                .appendingPathComponent("HELP.md")
        ].compactMap { $0 }

        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }

        throw NSError(
            domain: "HelpWindowController",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "HELP.md was not found in app resources."]
        )
    }

    private func renderHTML(from markdown: String) -> String {
        let body = markdownToHTML(markdown)
        return """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <style>
            :root {
              color-scheme: light dark;
              font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
              font-size: 15px;
              line-height: 1.55;
            }
            body {
              margin: 0;
              padding: 34px 42px 56px;
              color: CanvasText;
              background: Canvas;
            }
            main { max-width: 820px; margin: 0 auto; }
            h1 { font-size: 30px; line-height: 1.15; margin: 0 0 18px; }
            h2 { font-size: 22px; margin: 34px 0 12px; padding-top: 8px; }
            h3 { font-size: 17px; margin: 26px 0 8px; }
            p { margin: 10px 0; }
            ul, ol { padding-left: 24px; }
            li { margin: 5px 0; }
            code {
              font-family: "SF Mono", Menlo, monospace;
              font-size: 0.92em;
              background: color-mix(in srgb, CanvasText 10%, transparent);
              border-radius: 5px;
              padding: 1px 5px;
            }
            pre {
              overflow: auto;
              padding: 14px 16px;
              border-radius: 8px;
              background: color-mix(in srgb, CanvasText 9%, transparent);
            }
            pre code { background: transparent; padding: 0; }
            img {
              max-width: 100%;
              border-radius: 10px;
              border: 1px solid color-mix(in srgb, CanvasText 16%, transparent);
              box-shadow: 0 8px 28px rgba(0,0,0,.16);
            }
            figure { margin: 18px 0 24px; }
            figcaption {
              color: color-mix(in srgb, CanvasText 65%, transparent);
              font-size: 13px;
              margin-top: 8px;
            }
            blockquote {
              margin: 16px 0;
              padding: 10px 14px;
              border-left: 4px solid #0a84ff;
              background: color-mix(in srgb, #0a84ff 10%, transparent);
              border-radius: 6px;
            }
            .hr { height: 1px; background: color-mix(in srgb, CanvasText 14%, transparent); margin: 28px 0; }
          </style>
        </head>
        <body><main>\(body)</main></body>
        </html>
        """
    }

    private func markdownToHTML(_ markdown: String) -> String {
        var html: [String] = []
        var inCodeBlock = false
        var inList = false
        var paragraph: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            html.append("<p>\(paragraph.joined(separator: " "))</p>")
            paragraph.removeAll()
        }

        func closeListIfNeeded() {
            if inList {
                html.append("</ul>")
                inList = false
            }
        }

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("```") {
                flushParagraph()
                closeListIfNeeded()
                if inCodeBlock {
                    html.append("</code></pre>")
                    inCodeBlock = false
                } else {
                    html.append("<pre><code>")
                    inCodeBlock = true
                }
                continue
            }

            if inCodeBlock {
                html.append(escapeHTML(rawLine))
                continue
            }

            if line.isEmpty {
                flushParagraph()
                closeListIfNeeded()
                continue
            }

            if line == "---" {
                flushParagraph()
                closeListIfNeeded()
                html.append("<div class=\"hr\"></div>")
                continue
            }

            if line.hasPrefix("# ") {
                flushParagraph()
                closeListIfNeeded()
                html.append("<h1>\(inlineHTML(String(line.dropFirst(2))))</h1>")
                continue
            }

            if line.hasPrefix("## ") {
                flushParagraph()
                closeListIfNeeded()
                html.append("<h2>\(inlineHTML(String(line.dropFirst(3))))</h2>")
                continue
            }

            if line.hasPrefix("### ") {
                flushParagraph()
                closeListIfNeeded()
                html.append("<h3>\(inlineHTML(String(line.dropFirst(4))))</h3>")
                continue
            }

            if line.hasPrefix("![") {
                flushParagraph()
                closeListIfNeeded()
                html.append(imageHTML(from: line))
                continue
            }

            if line.hasPrefix("> ") {
                flushParagraph()
                closeListIfNeeded()
                html.append("<blockquote>\(inlineHTML(String(line.dropFirst(2))))</blockquote>")
                continue
            }

            if line.hasPrefix("- ") {
                flushParagraph()
                if !inList {
                    html.append("<ul>")
                    inList = true
                }
                html.append("<li>\(inlineHTML(String(line.dropFirst(2))))</li>")
                continue
            }

            paragraph.append(inlineHTML(line))
        }

        flushParagraph()
        closeListIfNeeded()
        if inCodeBlock {
            html.append("</code></pre>")
        }
        return html.joined(separator: "\n")
    }

    private func imageHTML(from line: String) -> String {
        guard let altStart = line.firstIndex(of: "["),
              let altEnd = line.firstIndex(of: "]"),
              let urlStart = line.firstIndex(of: "("),
              let urlEnd = line.firstIndex(of: ")"),
              altStart < altEnd,
              urlStart < urlEnd else {
            return "<p>\(inlineHTML(line))</p>"
        }

        let alt = String(line[line.index(after: altStart)..<altEnd])
        let url = String(line[line.index(after: urlStart)..<urlEnd])
        guard isSafeHelpImageURL(url) else {
            return "<p>\(inlineHTML(alt))</p>"
        }
        return """
        <figure>
          <img src="\(escapeAttribute(url))" alt="\(escapeAttribute(alt))">
          <figcaption>\(inlineHTML(alt))</figcaption>
        </figure>
        """
    }

    private func isSafeHelpImageURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value), let scheme = components.scheme else {
            return true
        }
        return scheme.lowercased() == "file"
    }

    private func inlineHTML(_ text: String) -> String {
        var output = escapeHTML(text)
        output = replaceInlineCode(in: output)
        output = replaceBold(in: output)
        return output
    }

    private func replaceInlineCode(in text: String) -> String {
        let parts = text.split(separator: "`", omittingEmptySubsequences: false)
        guard parts.count > 1 else { return text }
        return parts.enumerated().map { index, part in
            index.isMultiple(of: 2) ? String(part) : "<code>\(part)</code>"
        }.joined()
    }

    private func replaceBold(in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\*\*([^*]+)\*\*"#) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "<strong>$1</strong>")
    }

    private func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func escapeAttribute(_ text: String) -> String {
        escapeHTML(text).replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Help error"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

extension HelpWindowController: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard navigationAction.navigationType == .linkActivated else {
            decisionHandler(.allow)
            return
        }

        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }

        if isAllowedLocalHelpURL(url) {
            decisionHandler(.allow)
            return
        }

        if let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" {
            NSWorkspace.shared.open(url)
        }
        decisionHandler(.cancel)
    }

    private func isAllowedLocalHelpURL(_ url: URL) -> Bool {
        guard url.isFileURL,
              let helpDirectory else {
            return false
        }
        let targetPath = url.standardizedFileURL.path
        let helpPath = helpDirectory.path
        return targetPath == helpPath || targetPath.hasPrefix(helpPath + "/")
    }
}
