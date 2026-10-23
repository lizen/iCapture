import Foundation
import os

/// 네트워크 없이 `URLSession`에 미리 정한 응답을 돌려주는 프로토콜.
/// 같은 테스트 클래스 안의 테스트는 순서대로 돌기 때문에 공유 상태 하나로 충분하다.
final class StubURLProtocol: URLProtocol {
    private enum Canned {
        case response(status: Int, body: Data)
        case failure(URLError)
    }

    private static let canned = OSAllocatedUnfairLock<Canned?>(initialState: nil)

    static func respond(status: Int, body: String) {
        canned.withLock { $0 = .response(status: status, body: Data(body.utf8)) }
    }

    static func fail(_ error: URLError) {
        canned.withLock { $0 = .failure(error) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        switch Self.canned.withLock({ $0 }) {
        case .response(let status, let body):
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": status == 200 ? "text/event-stream" : "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case nil:
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
        }
    }

    override func stopLoading() {}
}

extension URLSession {
    static let stubbed: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }()
}
