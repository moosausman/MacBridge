// MacBridge/Sources/MacBridge/Modules/Documents.swift
// Owns: reading PDFs (PDFKit). Other formats (docx, rtf, html, pptx, xlsx)
// are handled by the Python side with textutil / zip parsing.
//
//   /documents/pdf-info  { path }
//   /documents/pdf-text  { path, startPage?: Int (1-based), endPage?: Int, maxChars?: Int }
//   /documents/create-pdf { path, html: String, overwrite?: Bool }
//       Renders HTML (headings, lists, bold, links, code) to a paginated
//       Letter-size PDF with AppKit's text system -- the same engine
//       TextEdit prints with. No network, no external converters.
//
// Scanned PDFs have no text layer; for those the result says so, and the
// caller can fall back to /ocr/image on exported pages.

import Foundation
import AppKit
import PDFKit

enum DocumentsModule {

    private static func open(_ args: [String: Any]) throws -> (PDFDocument, String) {
        let raw = try PowerSupport.text(args, "path", max: 4096)
        let path = (raw as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else { throw PowerError.message("No file at \(path)") }
        guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else {
            throw PowerError.message("\(path) isn't a readable PDF")
        }
        if doc.isLocked { throw PowerError.message("The PDF is password-protected") }
        return (doc, path)
    }

    static func createPDF(args: [String: Any]) -> [String: Any] {
        PowerSupport.result {
            let raw = try PowerSupport.text(args, "path", max: 4096)
            let html = try PowerSupport.text(args, "html", max: 5_000_000)
            let path = (raw as NSString).expandingTildeInPath
            let overwrite = args["overwrite"] as? Bool ?? false
            if FileManager.default.fileExists(atPath: path) && !overwrite {
                throw PowerError.message("\(path) already exists (pass overwrite to replace it)")
            }
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            var failure: String?
            PowerSupport.main {
                guard let data = html.data(using: .utf8),
                      let attributed = try? NSAttributedString(
                        data: data,
                        options: [.documentType: NSAttributedString.DocumentType.html,
                                  .characterEncoding: String.Encoding.utf8.rawValue],
                        documentAttributes: nil) else {
                    failure = "Couldn't lay out the document"
                    return
                }
                let info = NSPrintInfo(dictionary: [
                    NSPrintInfo.AttributeKey.jobDisposition: NSPrintInfo.JobDisposition.save,
                    NSPrintInfo.AttributeKey.jobSavingURL: URL(fileURLWithPath: path),
                ])
                info.paperSize = NSSize(width: 612, height: 792)
                info.topMargin = 54; info.bottomMargin = 54; info.leftMargin = 54; info.rightMargin = 54
                info.horizontalPagination = .fit
                info.verticalPagination = .automatic
                info.isVerticallyCentered = false
                let width = info.paperSize.width - info.leftMargin - info.rightMargin
                let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
                view.textStorage?.setAttributedString(attributed)
                view.sizeToFit()
                let op = NSPrintOperation(view: view, printInfo: info)
                op.showsPrintPanel = false
                op.showsProgressPanel = false
                if !op.run() { failure = "PDF rendering failed" }
            }
            if let failure { throw PowerError.message(failure) }
            guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else {
                throw PowerError.message("The PDF wasn't written")
            }
            return ["ok": true, "path": path, "pageCount": doc.pageCount]
        }
    }

    static func info(args: [String: Any]) -> [String: Any] {
        PowerSupport.result {
            let (doc, path) = try open(args)
            let attrs = doc.documentAttributes ?? [:]
            return ["ok": true, "path": path, "pageCount": doc.pageCount,
                    "title": attrs[PDFDocumentAttribute.titleAttribute] as? String ?? "",
                    "author": attrs[PDFDocumentAttribute.authorAttribute] as? String ?? "",
                    "subject": attrs[PDFDocumentAttribute.subjectAttribute] as? String ?? ""]
        }
    }

    static func text(args: [String: Any]) -> [String: Any] {
        PowerSupport.result {
            let (doc, path) = try open(args)
            guard doc.pageCount > 0 else { return ["ok": true, "path": path, "pageCount": 0, "text": "", "pages": []] }
            let start = try PowerSupport.integer(args, "startPage", default: 1, range: 1...max(1, doc.pageCount))
            let end = try PowerSupport.integer(args, "endPage", default: doc.pageCount, range: start...max(start, doc.pageCount))
            let maxChars = try PowerSupport.integer(args, "maxChars", default: 60000, range: 1000...500000)
            var pages: [[String: Any]] = []
            var total = 0, truncated = false, emptyPages = 0
            for i in (start - 1)..<end {
                guard let page = doc.page(at: i) else { continue }
                var text = page.string ?? ""
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { emptyPages += 1 }
                if total + text.count > maxChars {
                    text = String(text.prefix(max(0, maxChars - total)))
                    truncated = true
                }
                total += text.count
                pages.append(["page": i + 1, "text": text])
                if truncated { break }
            }
            let joined = pages.map { "--- page \($0["page"]!) ---\n\($0["text"]!)" }.joined(separator: "\n")
            var result: [String: Any] = ["ok": true, "path": path, "pageCount": doc.pageCount,
                                         "startPage": start, "endPage": end, "text": joined,
                                         "characters": total, "truncated": truncated]
            if emptyPages == pages.count {
                result["note"] = "No text layer found -- this looks like a scanned PDF. Use OCR on the pages instead."
            }
            return result
        }
    }
}
