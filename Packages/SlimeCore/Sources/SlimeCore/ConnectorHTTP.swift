import Foundation

public struct ConnectorResponse: Sendable {
    public let data: Data
    public let status: Int
    public init(data: Data, status: Int) { self.data = data; self.status = status }
}
public enum ConnectorError: Error, LocalizedError, Sendable {
    case http(Int)
    public var errorDescription: String? {
        switch self { case .http(let status): "Connection returned HTTP \(status). Check permissions or retry retrieval later. No write was retried." }
    }
}
public struct ConnectorHTTP: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> ConnectorResponse
    private let transport: Transport
    public init(transport: @escaping Transport = ConnectorHTTP.network) { self.transport = transport }
    public func send(_ request: URLRequest) async throws -> Data {
        let response = try await transport(request)
        guard (200..<300).contains(response.status) else {
            throw ConnectorError.http(response.status)
        }
        guard response.data.count <= 2_000_000 else { throw MochletError.message("Connected content exceeds the 2 MB retrieval limit.") }
        return response.data
    }
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 60
        return URLSession(configuration: config, delegate: NoConnectorRedirects(), delegateQueue: nil)
    }()
    public static func network(_ request: URLRequest) async throws -> ConnectorResponse {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw MochletError.message("The connection returned no HTTP response.") }
        guard response.url?.host == request.url?.host else { throw MochletError.message("The connection redirected to an unexpected host.") }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 2_000_000 else { throw MochletError.message("Connected content exceeds the 2 MB retrieval limit.") }
            data.append(byte)
        }
        return .init(data: data, status: http.statusCode)
    }
}
public enum GoogleScope {
    public static let mail = "https://www.googleapis.com/auth/gmail.readonly"
    public static let calendar = "https://www.googleapis.com/auth/calendar.readonly"
    public static let drive = "https://www.googleapis.com/auth/drive.readonly"
    public static let compose = "https://www.googleapis.com/auth/gmail.compose"
    public static let send = "https://www.googleapis.com/auth/gmail.send"
    public static let calendarWrite = "https://www.googleapis.com/auth/calendar.events"
    public static let identity: Set<String> = ["openid", "email", "profile"]
}

private final class NoConnectorRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
