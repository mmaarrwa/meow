import Foundation
import Network

// Kept exactly as the working SurveyorApp version.
// No changes to connection logic — if it works, don't touch it.

final class NetworkManager {
    static let shared = NetworkManager()
    private let portNumber: UInt16 = 5005
    private var connection: NWConnection?
    var onCommandReceived: ((String) -> Void)?

    private init() {}

    func start(ipAddress: String) {
        if connection != nil { stop() }

        let host = NWEndpoint.Host(ipAddress)
        guard let port = NWEndpoint.Port(rawValue: portNumber) else { return }

        connection = NWConnection(host: host, port: port, using: .udp)

        connection?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                print("✅ Connected to \(ipAddress):\(self?.portNumber ?? 0)")
                // Handshake punch — tells laptop the iPhone's ephemeral port
                self?.sendPose(["type": "handshake", "message": "iOS Ready"])
                // Start listening for START/STOP commands
                self?.receiveIncomingData()
            case .failed(let error):
                print("❌ Connection failed: \(error)")
            default:
                break
            }
        }

        connection?.start(queue: .global())
    }

    func stop() {
        connection?.cancel()
        connection = nil
        onCommandReceived = nil
    }

    func sendPose(_ pose: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: pose,
                                                     options: []) else { return }
        connection?.send(content: data,
                         completion: .contentProcessed({ _ in }))
    }

    /// Sends a log string to the Python terminal on the laptop.
    /// Lets you debug without a Mac / Xcode connection.
    func sendLog(_ message: String) {
        sendPose(["type": "log", "message": message])
    }

    // Listens continuously for START / STOP commands from laptop
    private func receiveIncomingData() {
        connection?.receive(
            minimumIncompleteLength: 1,
            maximumLength: 65536
        ) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if let error = error {
                print("Receive error: \(error)")
                return
            }

            if let data = data,
               !data.isEmpty,
               let message = String(data: data, encoding: .utf8) {
                DispatchQueue.main.async {
                    self.onCommandReceived?(
                        message.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                }
            }

            // Always re-arm so we never go deaf
            self.receiveIncomingData()
        }
    }
}