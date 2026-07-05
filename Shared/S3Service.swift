//
//  S3Service.swift
//  ShareMaster
//
//  Created by Conor Ryan on 02/07/26.

import Foundation
import CryptoKit

actor S3Service {
    static let shared = S3Service()

    struct S3Error: Error, LocalizedError {
        let message: String
        /// The S3 error <Code> when the failure came from an S3 response
        /// (e.g. "AccessDenied"), nil for local/transport errors.
        var code: String? = nil
        var errorDescription: String? { message }

        /// True when the failure is about credentials or access policy,
        /// as opposed to a missing bucket/key or a network problem.
        var isPermissionIssue: Bool {
            guard let code else { return false }
            return ["AccessDenied", "AllAccessDisabled", "AccountProblem",
                    "InvalidAccessKeyId", "SignatureDoesNotMatch"].contains(code)
        }
    }

    /// Builds a user-facing error from an S3 error response, translating the
    /// XML <Code>/<Message> body into plain language for common failures.
    private func s3Error(_ operation: String, status: Int, body: Data) -> S3Error {
        let xml = String(data: body, encoding: .utf8) ?? ""
        let code = Self.xmlValue("Code", in: xml)
        let detail: String
        switch code {
        case "AccessDenied":
            detail = "access denied. This account doesn't have permission for this bucket — check its credentials and the bucket's policy."
        case "NoSuchBucket":
            detail = "the bucket doesn't exist. Check the bucket name and region."
        case "InvalidAccessKeyId":
            detail = "the access key ID isn't recognised. Check the account's credentials."
        case "SignatureDoesNotMatch":
            detail = "the request was rejected. Check the account's secret key."
        case "NoSuchKey":
            detail = "the file no longer exists."
        default:
            if let message = Self.xmlValue("Message", in: xml) {
                detail = message
            } else if let code {
                detail = "\(code) (HTTP \(status))"
            } else {
                detail = "HTTP \(status)"
            }
        }
        // A 403 with an unparseable body is still a permission problem.
        return S3Error(
            message: "\(operation) failed: \(detail)",
            code: code ?? (status == 403 ? "AccessDenied" : nil)
        )
    }

    private static func xmlValue(_ tag: String, in xml: String) -> String? {
        guard let start = xml.range(of: "<\(tag)>"),
              let end = xml.range(of: "</\(tag)>"),
              start.upperBound <= end.lowerBound else { return nil }
        let value = String(xml[start.upperBound..<end.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    struct UploadResult {
        let key: String
        let url: String
    }

    /// Thrown by a ranged chunk when the server ignores the Range header
    /// (HTTP 200 instead of 206) — triggers the sequential fallback.
    private struct RangeUnsupported: Error {}

    // MARK: - Transfer tuning

    /// Files at or above this size upload via multipart.
    nonisolated static let multipartThreshold: Int64 = 32 * 1024 * 1024
    /// Uniform part size (last part may be smaller) — R2 requires equal parts,
    /// S3 requires ≥ 5 MiB. Doubled as needed to stay under `maxParts`.
    nonisolated static let basePartSize: Int64 = 16 * 1024 * 1024
    /// Chunk size for concurrent ranged downloads.
    nonisolated static let downloadChunkSize: Int64 = 16 * 1024 * 1024
    nonisolated static let maxParts = 10_000

    /// Shared bandwidth caps. Each transfer sets the resolved rate for its
    /// destination on entry; overlapping transfers with different caps share
    /// the most recent one (fine for a single-user menu bar app).
    private let uploadLimiter = RateLimiter()
    private let downloadLimiter = RateLimiter()

    // MARK: - Upload

    /// - Parameter keyPrefix: overrides the destination's configured path
    ///   prefix (e.g. the folder currently open in the bucket browser).
    ///   Pass "" to upload to the bucket root; nil uses the config's prefix.
    func upload(fileURL: URL, config: S3Config, keyPrefix: String? = nil, progress: ((Double) -> Void)? = nil) async throws -> UploadResult {
        guard config.isConfigured else {
            throw S3Error(message: "Destination not configured. Please check its account and bucket in settings.")
        }

        let filename = fileURL.lastPathComponent
        let basename = NamingTemplate.expand(config.namingTemplate, filename: filename)
        let key = (keyPrefix ?? config.pathPrefix) + basename
        let contentType = mimeType(for: fileURL.pathExtension)

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0
        await uploadLimiter.setRate(bytesPerSecond: config.uploadCapMBps * 1_000_000)

        if fileSize >= Self.multipartThreshold {
            try await multipartUpload(
                fileURL: fileURL, key: key, contentType: contentType,
                fileSize: fileSize, config: config, progress: progress
            )
        } else {
            let data = try Data(contentsOf: fileURL)
            await uploadLimiter.acquire(bytes: data.count)
            try await putObject(key: key, data: data, contentType: contentType, config: config, progress: progress)
        }

        let url = try shareLink(for: key, config: config)
        return UploadResult(key: key, url: url)
    }

    // MARK: - Create Folder

    /// Hidden zero-byte object that makes an empty "folder" show up in
    /// delimiter listings. A bare "name/" marker (the AWS-console style)
    /// doesn't work on R2 — it comes back in Contents instead of
    /// CommonPrefixes — but any key *under* the prefix forces every S3
    /// implementation to report the folder. Listings hide this key.
    static let folderPlaceholderName = ".folder_placeholder"

    /// Creates an S3 "folder" by writing a hidden placeholder object at
    /// "<prefix><name>/.folder_placeholder".
    func createFolder(named name: String, under prefix: String, config: S3Config) async throws {
        guard config.isConfigured else {
            throw S3Error(message: "Destination not configured. Please check its account and bucket in settings.")
        }

        let trimmed = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else {
            throw S3Error(message: "Folder name can't be empty")
        }

        let key = prefix + trimmed + "/" + Self.folderPlaceholderName
        try await putObject(
            key: key, data: Data(),
            contentType: "application/octet-stream",
            config: config, progress: nil
        )
    }

    // MARK: - List Objects

    func listObjects(config: S3Config) async throws -> [S3Object] {
        guard config.isConfigured else {
            throw S3Error(message: "Destination not configured")
        }

        let host = buildHost(config)
        let endpoint = buildEndpoint(config)
        let signingPath = buildSigningPath(config, objectKey: nil)

        var query = "list-type=2&max-keys=50"
        if !config.pathPrefix.isEmpty {
            query += "&prefix=\(awsURLEncodeQuery(config.pathPrefix))"
        }

        guard let url = URL(string: "\(endpoint)/?\(query)") else {
            throw S3Error(message: "Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let headers = try signRequest(
            method: "GET",
            path: signingPath,
            query: query,
            headers: ["host": host],
            payload: Data(),
            config: config
        )

        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw S3Error(message: "Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            throw s3Error("List", status: httpResponse.statusCode, body: data)
        }

        return parseListResponse(data)
    }

    /// Lists one "directory" level under `prefix` using the delimiter so S3
    /// groups deeper keys into CommonPrefixes (folders) server-side. Pages
    /// through results `pageSize` at a time — pass the returned continuation
    /// token to fetch the next page. Each call is a single LIST request.
    func listDirectory(
        config: S3Config,
        prefix: String,
        continuationToken: String? = nil,
        pageSize: Int = 10
    ) async throws -> S3DirectoryPage {
        guard config.isConfigured else {
            throw S3Error(message: "Destination not configured")
        }

        let host = buildHost(config)
        let endpoint = buildEndpoint(config)
        let signingPath = buildSigningPath(config, objectKey: nil)

        // Params must stay in alphabetical order — the query string is signed verbatim.
        var query = ""
        if let continuationToken {
            query += "continuation-token=\(awsURLEncodeQuery(continuationToken))&"
        }
        query += "delimiter=%2F&list-type=2&max-keys=\(pageSize)"
        if !prefix.isEmpty {
            query += "&prefix=\(awsURLEncodeQuery(prefix))"
        }

        guard let url = URL(string: "\(endpoint)/?\(query)") else {
            throw S3Error(message: "Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let headers = try signRequest(
            method: "GET",
            path: signingPath,
            query: query,
            headers: ["host": host],
            payload: Data(),
            config: config
        )

        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw S3Error(message: "Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            throw s3Error("List", status: httpResponse.statusCode, body: data)
        }

        return parseDirectoryResponse(data)
    }

    // MARK: - Download Object

    /// Downloads a file from S3
    /// - Parameters:
    ///   - key: The S3 object key
    ///   - destination: Where to save the file
    ///   - overwrite: If true, overwrites existing file. If false, generates unique name.
    ///   - progress: Progress callback (0.0 to 1.0)
    /// - Returns: The actual URL where the file was saved (may differ from destination if not overwriting)
    @discardableResult
    func download(key: String, to destination: URL, config: S3Config, overwrite: Bool = false, progress: ((Double) -> Void)? = nil) async throws -> URL {
        guard config.isConfigured else {
            throw S3Error(message: "Destination not configured")
        }

        await downloadLimiter.setRate(bytesPerSecond: config.downloadCapMBps * 1_000_000)

        // Resolve the final path up front (unique-name logic), then stream
        // into a .partial file next to it and rename on success.
        let fileManager = FileManager.default
        var finalDestination = destination
        if fileManager.fileExists(atPath: destination.path), !overwrite {
            let directory = destination.deletingLastPathComponent()
            let filename = destination.deletingPathExtension().lastPathComponent
            let ext = destination.pathExtension
            var counter = 1
            repeat {
                let newName = ext.isEmpty ? "\(filename) (\(counter))" : "\(filename) (\(counter)).\(ext)"
                finalDestination = directory.appendingPathComponent(newName)
                counter += 1
            } while fileManager.fileExists(atPath: finalDestination.path)
        }
        let partialURL = finalDestination.appendingPathExtension("partial")
        try? fileManager.removeItem(at: partialURL)

        do {
            let size = (try? await headObject(key: key, config: config)) ?? -1
            if size >= Self.downloadChunkSize * 2 {
                do {
                    try await rangedDownload(key: key, size: size, to: partialURL, config: config, progress: progress)
                } catch is RangeUnsupported {
                    // Server ignored the Range header — start over sequentially.
                    try? fileManager.removeItem(at: partialURL)
                    try await sequentialDownload(key: key, to: partialURL, config: config, progress: progress)
                }
            } else {
                try await sequentialDownload(key: key, to: partialURL, config: config, progress: progress)
            }
        } catch {
            try? fileManager.removeItem(at: partialURL)
            throw error
        }

        if fileManager.fileExists(atPath: finalDestination.path) {
            try fileManager.removeItem(at: finalDestination)   // overwrite case
        }
        try fileManager.moveItem(at: partialURL, to: finalDestination)
        progress?(1.0)
        return finalDestination
    }

    /// Signed HEAD returning the object's Content-Length.
    private func headObject(key: String, config: S3Config) async throws -> Int64 {
        let host = buildHost(config)
        let endpoint = buildEndpoint(config)
        let encodedKey = awsURLEncodePath(key)
        let signingPath = buildSigningPath(config, objectKey: key)

        guard let url = URL(string: "\(endpoint)/\(encodedKey)") else {
            throw S3Error(message: "Invalid URL")
        }

        let headers = try signRequest(
            method: "HEAD", path: signingPath, query: "",
            headers: ["host": host], payload: Data(), config: config
        )

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
              httpResponse.expectedContentLength >= 0 else {
            throw S3Error(message: "HEAD failed: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        return httpResponse.expectedContentLength
    }

    private func signedGETRequest(key: String, range: (Int64, Int64)?, config: S3Config) throws -> URLRequest {
        let host = buildHost(config)
        let endpoint = buildEndpoint(config)
        let encodedKey = awsURLEncodePath(key)
        let signingPath = buildSigningPath(config, objectKey: key)

        guard let url = URL(string: "\(endpoint)/\(encodedKey)") else {
            throw S3Error(message: "Invalid URL")
        }

        var signedHeaders = ["host": host]
        if let range {
            signedHeaders["range"] = "bytes=\(range.0)-\(range.1)"
        }
        let headers = try signRequest(
            method: "GET", path: signingPath, query: "",
            headers: signedHeaders, payload: Data(), config: config
        )

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        return request
    }

    /// Single-request download streamed to disk in 64 KiB batches (also the
    /// fallback when a provider doesn't honor Range requests).
    private func sequentialDownload(key: String, to fileURL: URL, config: S3Config, progress: ((Double) -> Void)?) async throws {
        let request = try signedGETRequest(key: key, range: nil, config: config)
        let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw S3Error(message: "Download failed: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        let expected = httpResponse.expectedContentLength

        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }

        var buffer = Data(capacity: 65_536)
        var received: Int64 = 0
        for try await byte in asyncBytes {
            buffer.append(byte)
            if buffer.count >= 65_536 {
                await downloadLimiter.acquire(bytes: buffer.count)
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if expected > 0 { progress?(min(1, Double(received) / Double(expected))) }
            }
        }
        if !buffer.isEmpty {
            await downloadLimiter.acquire(bytes: buffer.count)
            try handle.write(contentsOf: buffer)
        }
    }

    /// Concurrent ranged download: the file is preallocated and each chunk
    /// writes at its own offset through its own FileHandle.
    private func rangedDownload(key: String, size: Int64, to fileURL: URL, config: S3Config, progress: ((Double) -> Void)?) async throws {
        let chunkSize = Self.downloadChunkSize
        let chunkCount = Int((size + chunkSize - 1) / chunkSize)
        let tracker = TransferProgress(total: size, onProgress: progress)

        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        let prealloc = try FileHandle(forWritingTo: fileURL)
        try prealloc.truncate(atOffset: UInt64(size))
        try prealloc.close()

        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = 0
            while next < min(config.maxConcurrentParts, chunkCount) {
                let i = next
                group.addTask {
                    try await self.downloadOneChunk(
                        i: i, chunkSize: chunkSize, size: size, key: key,
                        fileURL: fileURL, config: config, tracker: tracker
                    )
                }
                next += 1
            }
            while try await group.next() != nil {
                if next < chunkCount {
                    let i = next
                    group.addTask {
                        try await self.downloadOneChunk(
                            i: i, chunkSize: chunkSize, size: size, key: key,
                            fileURL: fileURL, config: config, tracker: tracker
                        )
                    }
                    next += 1
                }
            }
        }
    }

    private func downloadOneChunk(
        i: Int,
        chunkSize: Int64,
        size: Int64,
        key: String,
        fileURL: URL,
        config: S3Config,
        tracker: TransferProgress
    ) async throws {
        let start = Int64(i) * chunkSize
        let end = min(start + chunkSize, size) - 1
        let request = try signedGETRequest(key: key, range: (start, end), config: config)

        let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw S3Error(message: "Invalid response")
        }
        guard httpResponse.statusCode == 206 else {
            if httpResponse.statusCode == 200 { throw RangeUnsupported() }
            throw S3Error(message: "Download chunk failed: \(httpResponse.statusCode)")
        }

        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(start))

        var buffer = Data(capacity: 65_536)
        var written: Int64 = 0
        for try await byte in asyncBytes {
            buffer.append(byte)
            if buffer.count >= 65_536 {
                await downloadLimiter.acquire(bytes: buffer.count)
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
                await tracker.report(part: i, bytes: written)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if !buffer.isEmpty {
            await downloadLimiter.acquire(bytes: buffer.count)
            try handle.write(contentsOf: buffer)
            written += Int64(buffer.count)
            await tracker.report(part: i, bytes: written)
        }
    }

    // MARK: - Delete Object

    func deleteObject(key: String, config: S3Config) async throws {
        guard config.isConfigured else {
            throw S3Error(message: "Destination not configured")
        }

        let host = buildHost(config)
        let endpoint = buildEndpoint(config)
        let encodedKey = awsURLEncodePath(key)
        let signingPath = buildSigningPath(config, objectKey: key)

        guard let url = URL(string: "\(endpoint)/\(encodedKey)") else {
            throw S3Error(message: "Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"

        let headers = try signRequest(
            method: "DELETE",
            path: signingPath,
            query: "",
            headers: ["host": host],
            payload: Data(),
            config: config
        )

        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw S3Error(message: "Invalid response")
        }

        guard httpResponse.statusCode == 204 || httpResponse.statusCode == 200 else {
            throw s3Error("Delete", status: httpResponse.statusCode, body: data)
        }
    }

    // MARK: - Share Link

    /// Returns the link to share for an object, honoring the destination's link mode.
    func shareLink(for key: String, config: S3Config) throws -> String {
        switch config.linkMode {
        case .publicUrl:
            return buildPublicURL(key: key, config: config)
        case .presigned:
            return try presignedURL(for: key, config: config)
        }
    }

    // MARK: - Private Methods

    private func putObject(
        key: String,
        data: Data,
        contentType: String,
        config: S3Config,
        progress: ((Double) -> Void)?
    ) async throws {
        let host = buildHost(config)
        let endpoint = buildEndpoint(config)
        let encodedKey = awsURLEncodePath(key)
        let signingPath = buildSigningPath(config, objectKey: key)

        guard let url = URL(string: "\(endpoint)/\(encodedKey)") else {
            throw S3Error(message: "Invalid URL")
        }

        // Body is supplied by upload(for:from:) below — setting httpBody too
        // makes CFNetwork warn and would race two body sources.
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.allowsCellularAccess = config.allowsCellular

        var signedHeaders: [String: String] = [
            "host": host,
            "content-type": contentType
        ]
        if config.makePublic {
            signedHeaders["x-amz-acl"] = "public-read"
        }

        let headers = try signRequest(
            method: "PUT",
            path: signingPath,
            query: "",
            headers: signedHeaders,
            payload: data,
            config: config
        )

        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let progressDelegate = UploadProgressDelegate { sent, expected in
            guard expected > 0 else { return }
            progress?(min(1, Double(sent) / Double(expected)))
        }

        let (responseData, response) = try await URLSession.shared.upload(
            for: request,
            from: data,
            delegate: progressDelegate
        )

        guard let httpResponse = response as? HTTPURLResponse else {
            throw S3Error(message: "Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            throw s3Error("Upload", status: httpResponse.statusCode, body: responseData)
        }

        progress?(1)
    }

    // MARK: - Multipart upload

    /// Reads one part from disk. Each part task opens its own FileHandle so
    /// concurrent reads never race on a shared descriptor, and the whole file
    /// is never resident in memory at once.
    nonisolated private static func readPart(fileURL: URL, offset: Int64, length: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        return try handle.read(upToCount: length) ?? Data()
    }

    private func multipartUpload(
        fileURL: URL,
        key: String,
        contentType: String,
        fileSize: Int64,
        config: S3Config,
        progress: ((Double) -> Void)?
    ) async throws {
        // Uniform part size (R2 requirement), grown to respect the part cap.
        var partSize = Self.basePartSize
        while (fileSize + partSize - 1) / partSize > Int64(Self.maxParts) {
            partSize *= 2
        }
        let partCount = Int((fileSize + partSize - 1) / partSize)

        let uploadId = try await createMultipartUpload(key: key, contentType: contentType, config: config)
        let tracker = TransferProgress(total: fileSize, onProgress: progress)

        do {
            var etags: [(Int, String)] = []
            etags.reserveCapacity(partCount)

            try await withThrowingTaskGroup(of: (Int, String).self) { group in
                var nextPart = 1

                // Sliding window: keep at most maxConcurrentParts in flight.
                while nextPart <= min(config.maxConcurrentParts, partCount) {
                    let n = nextPart
                    group.addTask {
                        try await self.uploadOnePart(
                            n: n, partSize: partSize, fileSize: fileSize, fileURL: fileURL,
                            key: key, uploadId: uploadId, config: config, tracker: tracker
                        )
                    }
                    nextPart += 1
                }

                while let (n, etag) = try await group.next() {
                    etags.append((n, etag))
                    if nextPart <= partCount {
                        let m = nextPart
                        group.addTask {
                            try await self.uploadOnePart(
                                n: m, partSize: partSize, fileSize: fileSize, fileURL: fileURL,
                                key: key, uploadId: uploadId, config: config, tracker: tracker
                            )
                        }
                        nextPart += 1
                    }
                }
            }

            try await completeMultipartUpload(key: key, uploadId: uploadId, etags: etags, config: config)
            progress?(1)
        } catch {
            await abortMultipartUpload(key: key, uploadId: uploadId, config: config)
            throw error
        }
    }

    private func uploadOnePart(
        n: Int,
        partSize: Int64,
        fileSize: Int64,
        fileURL: URL,
        key: String,
        uploadId: String,
        config: S3Config,
        tracker: TransferProgress
    ) async throws -> (Int, String) {
        let offset = Int64(n - 1) * partSize
        let length = Int(min(partSize, fileSize - offset))
        let data = try Self.readPart(fileURL: fileURL, offset: offset, length: length)
        guard data.count == length else {
            throw S3Error(message: "Short read for part \(n) (file changed during upload?)")
        }

        // Bandwidth cap: uploads pace at part granularity — the whole part's
        // budget is acquired before the request goes out.
        await uploadLimiter.acquire(bytes: data.count)

        let etag = try await uploadPart(
            key: key, uploadId: uploadId, partNumber: n, data: data, config: config
        ) { sent in
            Task { await tracker.report(part: n, bytes: sent) }
        }
        await tracker.report(part: n, bytes: Int64(length))
        return (n, etag)
    }

    private func createMultipartUpload(key: String, contentType: String, config: S3Config) async throws -> String {
        let host = buildHost(config)
        let endpoint = buildEndpoint(config)
        let encodedKey = awsURLEncodePath(key)
        let signingPath = buildSigningPath(config, objectKey: key)
        let query = "uploads="

        guard let url = URL(string: "\(endpoint)/\(encodedKey)?\(query)") else {
            throw S3Error(message: "Invalid URL")
        }

        var signedHeaders: [String: String] = [
            "host": host,
            "content-type": contentType
        ]
        if config.makePublic {
            signedHeaders["x-amz-acl"] = "public-read"
        }

        let headers = try signRequest(
            method: "POST", path: signingPath, query: query,
            headers: signedHeaders, payload: Data(), config: config
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.allowsCellularAccess = config.allowsCellular
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw s3Error("Create multipart upload", status: code, body: data)
        }

        guard let xml = String(data: data, encoding: .utf8),
              let start = xml.range(of: "<UploadId>"),
              let end = xml.range(of: "</UploadId>") else {
            throw S3Error(message: "Create multipart upload: missing UploadId in response")
        }
        return String(xml[start.upperBound..<end.lowerBound])
    }

    /// Uploads one part and returns its ETag (kept quoted, as required by
    /// CompleteMultipartUpload on R2).
    private func uploadPart(
        key: String,
        uploadId: String,
        partNumber: Int,
        data: Data,
        config: S3Config,
        onBytesSent: ((Int64) -> Void)?
    ) async throws -> String {
        let host = buildHost(config)
        let endpoint = buildEndpoint(config)
        let encodedKey = awsURLEncodePath(key)
        let signingPath = buildSigningPath(config, objectKey: key)
        // Already in canonical (alphabetical) order: partNumber < uploadId.
        let query = "partNumber=\(partNumber)&uploadId=\(awsURLEncodeQuery(uploadId))"

        guard let url = URL(string: "\(endpoint)/\(encodedKey)?\(query)") else {
            throw S3Error(message: "Invalid URL")
        }

        let headers = try signRequest(
            method: "PUT", path: signingPath, query: query,
            headers: ["host": host], payload: data, config: config
        )

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.allowsCellularAccess = config.allowsCellular
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }

        let progressDelegate = UploadProgressDelegate { sent, _ in
            onBytesSent?(sent)
        }

        let (responseData, response) = try await URLSession.shared.upload(
            for: request, from: data, delegate: progressDelegate
        )

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw s3Error("Upload part \(partNumber)", status: code, body: responseData)
        }
        guard let etag = httpResponse.value(forHTTPHeaderField: "ETag"), !etag.isEmpty else {
            throw S3Error(message: "Upload part \(partNumber): missing ETag")
        }
        return etag
    }

    private func completeMultipartUpload(
        key: String,
        uploadId: String,
        etags: [(Int, String)],
        config: S3Config
    ) async throws {
        let host = buildHost(config)
        let endpoint = buildEndpoint(config)
        let encodedKey = awsURLEncodePath(key)
        let signingPath = buildSigningPath(config, objectKey: key)
        let query = "uploadId=\(awsURLEncodeQuery(uploadId))"

        guard let url = URL(string: "\(endpoint)/\(encodedKey)?\(query)") else {
            throw S3Error(message: "Invalid URL")
        }

        var xml = "<CompleteMultipartUpload>"
        for (n, etag) in etags.sorted(by: { $0.0 < $1.0 }) {
            xml += "<Part><PartNumber>\(n)</PartNumber><ETag>\(etag)</ETag></Part>"
        }
        xml += "</CompleteMultipartUpload>"
        let payload = Data(xml.utf8)

        let headers = try signRequest(
            method: "POST", path: signingPath, query: query,
            headers: ["host": host, "content-type": "application/xml"],
            payload: payload, config: config
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.allowsCellularAccess = config.allowsCellular
        request.httpBody = payload
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }

        let (data, response) = try await URLSession.shared.data(for: request)
        let body = String(data: data, encoding: .utf8) ?? ""
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
              !body.contains("<Error>") else {
            // S3 can return 200 with an <Error> body for Complete.
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw s3Error("Complete multipart upload", status: code, body: data)
        }
    }

    /// Best-effort cleanup so failed uploads don't leave billable orphaned
    /// parts behind. Never throws.
    private func abortMultipartUpload(key: String, uploadId: String, config: S3Config) async {
        let host = buildHost(config)
        let endpoint = buildEndpoint(config)
        let encodedKey = awsURLEncodePath(key)
        let signingPath = buildSigningPath(config, objectKey: key)
        let query = "uploadId=\(awsURLEncodeQuery(uploadId))"

        guard let url = URL(string: "\(endpoint)/\(encodedKey)?\(query)"),
              let headers = try? signRequest(
                method: "DELETE", path: signingPath, query: query,
                headers: ["host": host], payload: Data(), config: config
              ) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.allowsCellularAccess = config.allowsCellular
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        _ = try? await URLSession.shared.data(for: request)
    }

    private func isCustomEndpoint(_ config: S3Config) -> Bool {
        return !config.endpoint.isEmpty
    }

    private func buildHost(_ config: S3Config) -> String {
        if isCustomEndpoint(config) {
            // Custom endpoint (like Cloudflare R2, MinIO, etc.)
            // R2 and most S3-compatible services use path-style, so host is just the endpoint host
            if let url = URL(string: config.endpoint), let host = url.host {
                return host
            }
        }

        return "\(config.bucket).s3.\(config.region).amazonaws.com"
    }

    private func buildEndpoint(_ config: S3Config) -> String {
        if isCustomEndpoint(config) {
            // Custom endpoint (R2, MinIO, etc.) - use path-style: endpoint/bucket
            let base = config.endpoint.hasSuffix("/") ? String(config.endpoint.dropLast()) : config.endpoint
            return "\(base)/\(config.bucket)"
        }

        return "https://\(config.bucket).s3.\(config.region).amazonaws.com"
    }

    private func buildSigningPath(_ config: S3Config, objectKey: String?) -> String {
        if isCustomEndpoint(config) {
            // Path-style: /bucket or /bucket/key
            if let key = objectKey {
                let encodedKey = awsURLEncodePath(key)
                return "/\(config.bucket)/\(encodedKey)"
            }
            return "/\(config.bucket)/"
        }

        // Virtual-hosted style: / or /key
        if let key = objectKey {
            let encodedKey = awsURLEncodePath(key)
            return "/\(encodedKey)"
        }
        return "/"
    }

    private func buildPublicURL(key: String, config: S3Config) -> String {
        let encodedKey = awsURLEncodePath(key)

        if !config.publicUrlBase.isEmpty {
            let base = config.publicUrlBase.hasSuffix("/") ? String(config.publicUrlBase.dropLast()) : config.publicUrlBase
            return "\(base)/\(encodedKey)"
        }

        return "\(buildEndpoint(config))/\(encodedKey)"
    }

    // MARK: - AWS Signature V4 (header signing)

    private func amzDates(_ now: Date = Date()) -> (amzDate: String, dateStamp: String) {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withTimeZone]
        dateFormatter.timeZone = TimeZone(identifier: "UTC")

        let amzDate = dateFormatter.string(from: now)
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ":", with: "")
        let dateStamp = String(amzDate.prefix(8))
        return (amzDate, dateStamp)
    }

    private func signRequest(
        method: String,
        path: String,
        query: String,
        headers: [String: String],
        payload: Data,
        config: S3Config
    ) throws -> [String: String] {
        let accessKey = config.accessKeyId
        let secretKey = config.secretAccessKey
        let region = config.region
        let service = "s3"

        let (amzDate, dateStamp) = amzDates()

        // Create payload hash
        let payloadHash = SHA256.hash(data: payload).hexString

        // Build canonical headers
        var allHeaders = headers
        allHeaders["x-amz-date"] = amzDate
        allHeaders["x-amz-content-sha256"] = payloadHash

        let sortedHeaders = allHeaders.sorted { $0.key.lowercased() < $1.key.lowercased() }
        let canonicalHeaders = sortedHeaders.map { "\($0.key.lowercased()):\($0.value.trimmingCharacters(in: .whitespaces))" }.joined(separator: "\n") + "\n"
        let signedHeaders = sortedHeaders.map { $0.key.lowercased() }.joined(separator: ";")

        // Create canonical request
        let canonicalRequest = [
            method,
            path,
            query,
            canonicalHeaders,
            signedHeaders,
            payloadHash
        ].joined(separator: "\n")

        let canonicalRequestHash = SHA256.hash(data: Data(canonicalRequest.utf8)).hexString

        // Create string to sign
        let credentialScope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            credentialScope,
            canonicalRequestHash
        ].joined(separator: "\n")

        let signature = signature(stringToSign: stringToSign, secretKey: secretKey, dateStamp: dateStamp, region: region, service: service)

        // Build authorization header
        let authorization = "AWS4-HMAC-SHA256 Credential=\(accessKey)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"

        var result = allHeaders
        result["authorization"] = authorization

        return result
    }

    // MARK: - AWS Signature V4 (query presigning)

    /// Builds a presigned GET URL valid for `config.presignExpirySeconds`.
    private func presignedURL(for key: String, config: S3Config) throws -> String {
        let region = config.region
        let service = "s3"
        let host = buildHost(config)
        let endpoint = buildEndpoint(config)
        let encodedKey = awsURLEncodePath(key)
        let signingPath = buildSigningPath(config, objectKey: key)

        let (amzDate, dateStamp) = amzDates()
        let credentialScope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let credential = "\(config.accessKeyId)/\(credentialScope)"

        // Presigned URLs are capped by AWS at 7 days.
        let expires = max(1, min(config.presignExpirySeconds, 604_800))

        // Canonical query params (sorted by key), keys + values percent-encoded.
        let params: [(String, String)] = [
            ("X-Amz-Algorithm", "AWS4-HMAC-SHA256"),
            ("X-Amz-Credential", credential),
            ("X-Amz-Date", amzDate),
            ("X-Amz-Expires", String(expires)),
            ("X-Amz-SignedHeaders", "host")
        ]
        let canonicalQuery = params
            .sorted { $0.0 < $1.0 }
            .map { "\(awsURLEncodeQuery($0.0))=\(awsURLEncodeQuery($0.1))" }
            .joined(separator: "&")

        let canonicalHeaders = "host:\(host)\n"
        let signedHeaders = "host"

        let canonicalRequest = [
            "GET",
            signingPath,
            canonicalQuery,
            canonicalHeaders,
            signedHeaders,
            "UNSIGNED-PAYLOAD"
        ].joined(separator: "\n")

        let canonicalRequestHash = SHA256.hash(data: Data(canonicalRequest.utf8)).hexString
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            credentialScope,
            canonicalRequestHash
        ].joined(separator: "\n")

        let sig = signature(stringToSign: stringToSign, secretKey: config.secretAccessKey, dateStamp: dateStamp, region: region, service: service)

        return "\(endpoint)/\(encodedKey)?\(canonicalQuery)&X-Amz-Signature=\(sig)"
    }

    private func signature(stringToSign: String, secretKey: String, dateStamp: String, region: String, service: String) -> String {
        let kDate = hmacSHA256(key: Data("AWS4\(secretKey)".utf8), data: Data(dateStamp.utf8))
        let kRegion = hmacSHA256(key: kDate, data: Data(region.utf8))
        let kService = hmacSHA256(key: kRegion, data: Data(service.utf8))
        let kSigning = hmacSHA256(key: kService, data: Data("aws4_request".utf8))
        return hmacSHA256(key: kSigning, data: Data(stringToSign.utf8)).hexString
    }

    private func hmacSHA256(key: Data, data: Data) -> Data {
        let key = SymmetricKey(data: key)
        let signature = HMAC<SHA256>.authenticationCode(for: data, using: key)
        return Data(signature)
    }

    private func mimeType(for ext: String) -> String {
        let mimeTypes: [String: String] = [
            "jpg": "image/jpeg",
            "jpeg": "image/jpeg",
            "png": "image/png",
            "gif": "image/gif",
            "webp": "image/webp",
            "svg": "image/svg+xml",
            "pdf": "application/pdf",
            "zip": "application/zip",
            "mp4": "video/mp4",
            "mov": "video/quicktime",
            "mp3": "audio/mpeg",
            "txt": "text/plain",
            "html": "text/html",
            "css": "text/css",
            "js": "application/javascript",
            "json": "application/json"
        ]
        return mimeTypes[ext.lowercased()] ?? "application/octet-stream"
    }

    private func parseListResponse(_ data: Data) -> [S3Object] {
        // Simple XML parsing for S3 list response
        guard let xml = String(data: data, encoding: .utf8) else { return [] }

        var objects: [S3Object] = []
        let contents = xml.components(separatedBy: "<Contents>")

        for content in contents.dropFirst() {
            guard let keyEnd = content.range(of: "</Key>"),
                  let keyStart = content.range(of: "<Key>") else { continue }

            let key = String(content[keyStart.upperBound..<keyEnd.lowerBound])

            // Skip folder-marker objects (zero-byte keys ending in "/"), e.g.
            // the "steven/shots/" placeholder that represents the prefix itself,
            // and the hidden placeholders createFolder writes for empty folders.
            if key.hasSuffix("/") { continue }
            if key.hasSuffix("/" + Self.folderPlaceholderName) || key == Self.folderPlaceholderName { continue }

            var size: Int64 = 0
            if let sizeStart = content.range(of: "<Size>"),
               let sizeEnd = content.range(of: "</Size>") {
                size = Int64(content[sizeStart.upperBound..<sizeEnd.lowerBound]) ?? 0
            }

            var lastModified: Date?
            if let dateStart = content.range(of: "<LastModified>"),
               let dateEnd = content.range(of: "</LastModified>") {
                let dateString = String(content[dateStart.upperBound..<dateEnd.lowerBound])
                lastModified = parseLastModified(dateString)
            }

            objects.append(S3Object(key: key, size: size, lastModified: lastModified ?? Date()))
        }

        return objects.sorted { $0.lastModified > $1.lastModified }
    }

    private func parseDirectoryResponse(_ data: Data) -> S3DirectoryPage {
        guard let xml = String(data: data, encoding: .utf8) else {
            return S3DirectoryPage(folders: [], objects: [], nextContinuationToken: nil)
        }

        var folders: [S3Folder] = []
        for chunk in xml.components(separatedBy: "<CommonPrefixes>").dropFirst() {
            guard let start = chunk.range(of: "<Prefix>"),
                  let end = chunk.range(of: "</Prefix>") else { continue }
            folders.append(S3Folder(prefix: String(chunk[start.upperBound..<end.lowerBound])))
        }

        var objects: [S3Object] = []
        for content in xml.components(separatedBy: "<Contents>").dropFirst() {
            guard let keyStart = content.range(of: "<Key>"),
                  let keyEnd = content.range(of: "</Key>") else { continue }

            let key = String(content[keyStart.upperBound..<keyEnd.lowerBound])

            // Skip folder-marker objects (zero-byte keys ending in "/"),
            // including the placeholder for the prefix being listed, and
            // the hidden placeholders createFolder writes for empty folders.
            if key.hasSuffix("/") { continue }
            if key.hasSuffix("/" + Self.folderPlaceholderName) || key == Self.folderPlaceholderName { continue }

            var size: Int64 = 0
            if let sizeStart = content.range(of: "<Size>"),
               let sizeEnd = content.range(of: "</Size>") {
                size = Int64(content[sizeStart.upperBound..<sizeEnd.lowerBound]) ?? 0
            }

            var lastModified: Date?
            if let dateStart = content.range(of: "<LastModified>"),
               let dateEnd = content.range(of: "</LastModified>") {
                lastModified = parseLastModified(String(content[dateStart.upperBound..<dateEnd.lowerBound]))
            }

            objects.append(S3Object(key: key, size: size, lastModified: lastModified ?? Date()))
        }

        // NextContinuationToken is only present when the listing is truncated.
        var nextToken: String?
        if let tokenStart = xml.range(of: "<NextContinuationToken>"),
           let tokenEnd = xml.range(of: "</NextContinuationToken>") {
            nextToken = String(xml[tokenStart.upperBound..<tokenEnd.lowerBound])
        }

        // Keep S3's lexicographic order — pagination depends on it staying stable.
        return S3DirectoryPage(folders: folders, objects: objects, nextContinuationToken: nextToken)
    }

    private func parseLastModified(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }

        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        return fallback.date(from: value)
    }

    private func awsURLEncodePath(_ path: String) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        return path
            .split(separator: "/")
            .map { segment in
                segment.addingPercentEncoding(withAllowedCharacters: unreserved) ?? String(segment)
            }
            .joined(separator: "/")
    }

    /// Percent-encodes a single query-string token per AWS rules (encodes "/"
    /// and every reserved character; only unreserved chars pass through).
    private func awsURLEncodeQuery(_ value: String) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }
}

/// Aggregates per-part byte counts from concurrent transfers into the single
/// 0...1 progress Double the UI expects. Retried parts overwrite their own
/// entry, so bytes are never double-counted.
actor TransferProgress {
    private let total: Int64
    private var perPart: [Int: Int64] = [:]
    private let onProgress: ((Double) -> Void)?

    init(total: Int64, onProgress: ((Double) -> Void)?) {
        self.total = total
        self.onProgress = onProgress
    }

    func report(part: Int, bytes: Int64) {
        perPart[part] = bytes
        guard total > 0, let onProgress else { return }
        let sent = perPart.values.reduce(0, +)
        onProgress(min(1, Double(sent) / Double(total)))
    }
}

final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate {
    private let onProgress: (Int64, Int64) -> Void

    init(onProgress: @escaping (Int64, Int64) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        onProgress(totalBytesSent, totalBytesExpectedToSend)
    }
}

final class DownloadProgressDelegate: NSObject, URLSessionTaskDelegate {
    private let onProgress: (Int64, Int64) -> Void

    init(onProgress: @escaping (Int64, Int64) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceiveInformationalResponse response: HTTPURLResponse
    ) {
        // Optional: handle informational responses
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        // Optional: handle metrics
    }
}

extension DownloadProgressDelegate: URLSessionDownloadDelegate {
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Required by protocol but handled by async/await
    }
}

/// One page of a delimiter-based directory listing.
struct S3DirectoryPage {
    let folders: [S3Folder]
    let objects: [S3Object]
    let nextContinuationToken: String?
}

/// A CommonPrefix returned by a delimiter listing — a virtual folder.
struct S3Folder: Identifiable {
    let id = UUID()
    /// Full key prefix, always ending in "/".
    let prefix: String

    var name: String {
        let trimmed = prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix
        return (trimmed as NSString).lastPathComponent
    }
}

struct S3Object: Identifiable {
    let id = UUID()
    let key: String
    let size: Int64
    let lastModified: Date

    var filename: String {
        // Display name: drop the path prefix, then strip an 8-char UUID prefix if present.
        let last = (key as NSString).lastPathComponent
        let components = last.components(separatedBy: "-")
        if components.count > 1 && components[0].count == 8 {
            return components.dropFirst().joined(separator: "-")
        }
        return last
    }
}

extension SHA256Digest {
    nonisolated var hexString: String {
        self.map { String(format: "%02x", $0) }.joined()
    }
}

extension Data {
    nonisolated var hexString: String {
        self.map { String(format: "%02x", $0) }.joined()
    }
}

extension S3Config {
    nonisolated var isConfigured: Bool {
        !accessKeyId.isEmpty && !secretAccessKey.isEmpty && !bucket.isEmpty
    }
}
