#if canImport(Network)
import Foundation
import Network

/// The mail connection used on the phone: TCP wrapped in TLS from the first byte (port 465).
public final class NetworkSMTPTransport: SMTPTransport, @unchecked Sendable {
    private let host: String
    private let port: Int
    private let useTLS: Bool
    private let timeout: TimeInterval
    private let queue = DispatchQueue(label: "minutes.smtp")
    private var connection: NWConnection?

    public init(host: String, port: Int = 465, useTLS: Bool = true, timeout: TimeInterval = 30) {
        self.host = host
        self.port = port
        self.useTLS = useTLS
        self.timeout = timeout
    }

    /// Resumes a continuation at most once, whichever of several callbacks fires first.
    private final class Once<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?
        init(_ c: CheckedContinuation<T, Error>) { continuation = c }
        func resume(_ result: Result<T, Error>) {
            lock.lock()
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.resume(with: result)
        }
    }

    public func connect() async throws {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else {
            throw SMTPError.connection("port \(port) is not valid")
        }
        let parameters: NWParameters = useTLS ? .tls : .tcp
        let c = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)
        connection = c
        let deadline = timeout
        let hostName = host

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = Once(continuation)
            c.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.resume(.success(()))
                case .failed(let error):
                    once.resume(.failure(SMTPError.connection(error.localizedDescription)))
                case .waiting(let error):
                    // No route yet (offline, captive network). Fail now; the caller retries later.
                    c.cancel()
                    once.resume(.failure(SMTPError.connection(error.localizedDescription)))
                case .cancelled:
                    once.resume(.failure(SMTPError.connection("the connection was cancelled")))
                default:
                    break
                }
            }
            c.start(queue: queue)
            queue.asyncAfter(deadline: .now() + deadline) {
                once.resume(.failure(SMTPError.timedOut("connecting to \(hostName)")))
            }
        }
        c.stateUpdateHandler = nil
    }

    public func send(_ data: Data) async throws {
        guard let c = connection else { throw SMTPError.connection("not connected") }
        let deadline = timeout
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = Once(continuation)
            c.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    once.resume(.failure(SMTPError.connection(error.localizedDescription)))
                } else {
                    once.resume(.success(()))
                }
            })
            queue.asyncAfter(deadline: .now() + deadline) {
                once.resume(.failure(SMTPError.timedOut("sending")))
            }
        }
    }

    public func receive() async throws -> Data {
        guard let c = connection else { throw SMTPError.connection("not connected") }
        let deadline = timeout
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            let once = Once(continuation)
            c.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let data = data, !data.isEmpty {
                    once.resume(.success(data))
                } else if let error = error {
                    once.resume(.failure(SMTPError.connection(error.localizedDescription)))
                } else if isComplete {
                    once.resume(.success(Data()))
                } else {
                    once.resume(.success(Data()))
                }
            }
            queue.asyncAfter(deadline: .now() + deadline) {
                once.resume(.failure(SMTPError.timedOut("waiting for the server")))
            }
        }
    }

    public func close() {
        connection?.cancel()
        connection = nil
    }
}
#endif
