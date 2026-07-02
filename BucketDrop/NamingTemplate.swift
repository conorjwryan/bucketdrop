//
//  NamingTemplate.swift
//  BucketDrop
//
//  Expands a per-destination naming template into an object key basename.
//  Supported tokens:
//    {uuid}     - 8-char random hex prefix
//    {name}     - original filename without extension
//    {ext}      - lowercased extension (without the dot)
//    {date}     - yyyy-MM-dd
//    {time}     - HHmmss
//    {datetime} - yyyy-MM-dd-HHmmss
//  A trailing ".{ext}" is appended automatically when the template does not
//  already reference {ext} and the file has an extension.
//

import Foundation

// Pure string helpers with no shared state, so exempt from the project's
// default MainActor isolation (S3Service's actor calls expand()).
nonisolated enum NamingTemplate {
    static let allTokens = ["{uuid}", "{name}", "{ext}", "{date}", "{time}", "{datetime}"]
    static let `default` = "{uuid}-{name}"

    /// Expands `template` for `filename`, returning the object key basename
    /// (no path prefix). `now` is injectable for previews/tests.
    nonisolated static func expand(_ template: String, filename: String, now: Date = Date()) -> String {
        let base = template.isEmpty ? NamingTemplate.default : template
        let nsName = filename as NSString
        let ext = nsName.pathExtension.lowercased()
        let nameNoExt = nsName.deletingPathExtension

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = .current

        dateFormatter.dateFormat = "yyyy-MM-dd"
        let date = dateFormatter.string(from: now)
        dateFormatter.dateFormat = "HHmmss"
        let time = dateFormatter.string(from: now)

        var result = base
        result = result.replacingOccurrences(of: "{uuid}", with: String(UUID().uuidString.prefix(8)).lowercased())
        result = result.replacingOccurrences(of: "{datetime}", with: "\(date)-\(time)")
        result = result.replacingOccurrences(of: "{date}", with: date)
        result = result.replacingOccurrences(of: "{time}", with: time)
        result = result.replacingOccurrences(of: "{name}", with: nameNoExt)
        result = result.replacingOccurrences(of: "{ext}", with: ext)

        // Ensure the extension is preserved when the template didn't include it.
        if !base.contains("{ext}"), !ext.isEmpty {
            result += ".\(ext)"
        }
        return result
    }

    /// Preview for the settings UI using a fixed sample filename and time so it
    /// reads deterministically.
    static func preview(_ template: String, sample: String = "photo.png") -> String {
        expand(template, filename: sample)
    }
}
