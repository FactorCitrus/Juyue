import Foundation

public struct NetworkResponse {
    public let statusCode: Int
    public let bodyString: String
    public let data: Data
    public let headers: [String: String]

    public init(statusCode: Int, bodyString: String, data: Data, headers: [String: String]) {
        self.statusCode = statusCode
        self.bodyString = bodyString
        self.data = data
        self.headers = headers
    }
}

public class NetworkClient {
    public static let shared = NetworkClient()
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public struct ParsedRequest {
        public let url: URL
        public let method: String
        public let headers: [String: String]
        public let body: Data?
    }

    /// Parses Legado's custom URL syntax:
    /// e.g. "https://domain.com/search,{\"method\":\"POST\",\"body\":{\"key\":\"val\"},\"headers\":{\"X\":\"Y\"}}"
    public static func parseLegadoUrl(_ rawUrl: String, defaultHeader: String? = nil, baseUrl: String? = nil) -> ParsedRequest? {
        var cleanUrl = rawUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        var method = "GET"
        var headers: [String: String] = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1"
        ]
        var bodyData: Data? = nil

        // Merge default headers from book source if present
        if let defaultHeader = defaultHeader?.trimmingCharacters(in: .whitespacesAndNewlines), !defaultHeader.isEmpty {
            if let headerData = defaultHeader.data(using: .utf8),
               let headerDict = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any] {
                for (k, v) in headerDict {
                    headers[k] = "\(v)"
                }
            } else if defaultHeader.hasPrefix("Cookie:") {
                let cookieVal = String(defaultHeader.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                headers["Cookie"] = cookieVal
            } else if defaultHeader.contains("=") && !defaultHeader.contains("{") {
                headers["Cookie"] = defaultHeader
            } else if defaultHeader.contains(":") {
                let lines = defaultHeader.components(separatedBy: .newlines)
                for line in lines {
                    let parts = line.split(separator: ":", maxSplits: 1)
                    if parts.count == 2 {
                        let k = parts[0].trimmingCharacters(in: .whitespaces)
                        let v = parts[1].trimmingCharacters(in: .whitespaces)
                        headers[k] = v
                    }
                }
            }
        }

        // Check if there is an options JSON appended with a comma
        if let commaIndex = cleanUrl.firstIndex(of: ","),
           cleanUrl[cleanUrl.index(after: commaIndex)...].trimmingCharacters(in: .whitespaces).starts(with: "{") {
            let urlPart = String(cleanUrl[..<commaIndex]).trimmingCharacters(in: .whitespaces)
            let jsonPart = String(cleanUrl[cleanUrl.index(after: commaIndex)...]).trimmingCharacters(in: .whitespaces)
            cleanUrl = urlPart

            if let jsonData = jsonPart.data(using: .utf8),
               let options = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                if let m = options["method"] as? String {
                    method = m.uppercased()
                }
                if let h = options["headers"] as? [String: Any] {
                    for (k, v) in h {
                        headers[k] = "\(v)"
                    }
                }
                if let b = options["body"] {
                    if let strBody = b as? String {
                        bodyData = strBody.data(using: .utf8)
                    } else if let jsonBody = try? JSONSerialization.data(withJSONObject: b) {
                        bodyData = jsonBody
                        if headers["Content-Type"] == nil {
                            headers["Content-Type"] = "application/json; charset=utf-8"
                        }
                    }
                }
            }
        }

        // Resolve relative URL against baseUrl
        if cleanUrl.starts(with: "/"), let base = baseUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !base.isEmpty {
            let trimmedBase = base.hasSuffix("/") ? String(base.dropLast()) : base
            cleanUrl = "\(trimmedBase)\(cleanUrl)"
        }

        var targetUrl = URL(string: cleanUrl)
        if targetUrl == nil {
            if let encoded = cleanUrl.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                targetUrl = URL(string: encoded)
            }
        }
        guard let url = targetUrl else { return nil }
        return ParsedRequest(url: url, method: method, headers: headers, body: bodyData)
    }

    /// Performs an asynchronous HTTP request
    public func request(parsed: ParsedRequest) async throws -> NetworkResponse {
        var req = URLRequest(url: parsed.url)
        req.httpMethod = parsed.method
        req.httpBody = parsed.body
        for (k, v) in parsed.headers {
            req.setValue(v, forHTTPHeaderField: k)
        }

        let (data, response) = try await session.data(for: req)
        let httpResponse = response as? HTTPURLResponse
        let statusCode = httpResponse?.statusCode ?? 200

        var respHeaders: [String: String] = [:]
        if let allHeaderFields = httpResponse?.allHeaderFields {
            for (k, v) in allHeaderFields {
                respHeaders["\(k)"] = "\(v)"
            }
        }

        let bodyStr = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return NetworkResponse(statusCode: statusCode, bodyString: bodyStr, data: data, headers: respHeaders)
    }

    /// Performs a synchronous HTTP request (useful for JS rule evaluation)
    public func requestSync(parsed: ParsedRequest, timeout: TimeInterval = 15.0) -> NetworkResponse? {
        var req = URLRequest(url: parsed.url)
        req.httpMethod = parsed.method
        req.httpBody = parsed.body
        req.timeoutInterval = timeout
        for (k, v) in parsed.headers {
            req.setValue(v, forHTTPHeaderField: k)
        }

        var result: NetworkResponse?
        let semaphore = DispatchSemaphore(value: 0)

        let task = session.dataTask(with: req) { data, response, error in
            defer { semaphore.signal() }
            guard let data = data else { return }
            let httpResponse = response as? HTTPURLResponse
            let statusCode = httpResponse?.statusCode ?? 200

            var respHeaders: [String: String] = [:]
            if let allHeaderFields = httpResponse?.allHeaderFields {
                for (k, v) in allHeaderFields {
                    respHeaders["\(k)"] = "\(v)"
                }
            }

            let bodyStr = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            result = NetworkResponse(statusCode: statusCode, bodyString: bodyStr, data: data, headers: respHeaders)
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + timeout)
        return result
    }
}
