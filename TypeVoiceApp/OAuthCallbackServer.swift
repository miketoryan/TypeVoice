import Foundation
import Network

final class OAuthCallbackServer {
    private let port: NWEndpoint.Port = 1455
    private let redirectBase = "typevoice://auth/callback"

    func start() async throws -> NWListener {
        let listener = try NWListener(using: .tcp, on: port)

        listener.newConnectionHandler = { [redirectBase] connection in
            connection.start(queue: .global(qos: .userInitiated))
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
                guard
                    let data,
                    let request = String(data: data, encoding: .utf8),
                    let firstLine = request.components(separatedBy: "\r\n").first,
                    let pathPart = firstLine.split(separator: " ").dropFirst().first,
                    let components = URLComponents(string: String(pathPart))
                else {
                    connection.cancel()
                    return
                }

                let query = components.query ?? ""
                let destination = query.isEmpty
                    ? redirectBase
                    : "\(redirectBase)?\(query)"

                let response = """
                HTTP/1.1 302 Found
                Location: \(destination)
                Connection: close
                
                """

                connection.send(
                    content: response.data(using: .utf8),
                    contentContext: .finalMessage,
                    isComplete: true,
                    completion: .contentProcessed { _ in
                        connection.cancel()
                    }
                )
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }

            listener.start(queue: .global(qos: .userInitiated))
        }
    }
}
