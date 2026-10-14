import Foundation
import Network

/// A small MQTT 3.1.1 client: just enough for MirAIe (connect over TLS,
/// subscribe, publish and receive at QoS 0, keep-alive pings).
final class MQTTClient {
    var onConnected: (() -> Void)?
    var onDisconnected: (() -> Void)?
    var onMessage: ((String, Data) -> Void)?

    private let queue = DispatchQueue(label: "mqtt")
    private var connection: NWConnection?
    private var buffer = Data()
    private var topics: [String] = []
    private var credentials = (clientId: "", username: "", password: "")
    private var pinger: DispatchSourceTimer?
    private var nextPacketId: UInt16 = 1
    private var isUp = false

    func connect(host: String, port: UInt16, clientId: String, username: String, password: String, topics: [String]) {
        queue.async { [self] in
            teardown(notify: false)
            self.topics = topics
            credentials = (clientId, username, password)
            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port)!,
                using: NWParameters(tls: NWProtocolTLS.Options())
            )
            self.connection = connection
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready: sendConnect()
                case .failed, .cancelled: teardown(notify: true)
                default: break
                }
            }
            connection.start(queue: queue)
            receive(on: connection)
        }
    }

    func publish(topic: String, payload: Data) {
        queue.async { [self] in
            var body = encodeString(topic)
            body.append(payload)
            send(type: 0x30, body: body)
        }
    }

    func disconnect() {
        queue.async { [self] in
            send(type: 0xE0, body: Data())
            teardown(notify: false)
        }
    }

    // MARK: - Internals (all on `queue`)

    private func teardown(notify: Bool) {
        pinger?.cancel()
        pinger = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        buffer.removeAll()
        isUp = false
        if notify { onDisconnected?() }
    }

    private func sendConnect() {
        var body = encodeString("MQTT")
        body.append(4)            // protocol level 3.1.1
        body.append(0xC2)         // username + password + clean session
        body.append(contentsOf: [0, 60]) // keep-alive seconds
        body.append(encodeString(credentials.clientId))
        body.append(encodeString(credentials.username))
        body.append(encodeString(credentials.password))
        send(type: 0x10, body: body)
    }

    private func subscribe() {
        var body = Data()
        body.append(UInt8(nextPacketId >> 8))
        body.append(UInt8(nextPacketId & 0xFF))
        nextPacketId &+= 1
        for topic in topics {
            body.append(encodeString(topic))
            body.append(0) // QoS 0
        }
        send(type: 0x82, body: body)
    }

    private func startPinging() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in self?.send(type: 0xC0, body: Data()) }
        timer.resume()
        pinger = timer
    }

    private func send(type: UInt8, body: Data) {
        guard let connection else { return }
        var packet = Data([type])
        packet.append(encodeLength(body.count))
        packet.append(body)
        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            if error != nil { self?.queue.async { self?.teardown(notify: true) } }
        })
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, error in
            guard let self, connection === self.connection else { return }
            if let data { buffer.append(data); drainPackets() }
            if done || error != nil { teardown(notify: true) } else { receive(on: connection) }
        }
    }

    private func drainPackets() {
        while buffer.count >= 2 {
            var multiplier = 1, length = 0, index = 1
            var complete = false
            while index < buffer.count, index <= 4 {
                let byte = Int(buffer[buffer.startIndex + index])
                length += (byte & 0x7F) * multiplier
                multiplier *= 128
                index += 1
                if byte & 0x80 == 0 { complete = true; break }
            }
            guard complete, buffer.count >= index + length else { return }
            let header = buffer[buffer.startIndex]
            let body = Data(buffer[(buffer.startIndex + index)..<(buffer.startIndex + index + length)])
            buffer.removeFirst(index + length)
            handle(type: header >> 4, flags: header & 0x0F, body: body)
        }
    }

    private func handle(type: UInt8, flags: UInt8, body: Data) {
        switch type {
        case 2: // CONNACK
            guard body.count >= 2, body[body.startIndex + 1] == 0 else { return teardown(notify: true) }
            isUp = true
            subscribe()
            startPinging()
        case 9: // SUBACK
            onConnected?()
        case 3: // PUBLISH
            guard body.count >= 2 else { return }
            let topicLength = Int(body[body.startIndex]) << 8 | Int(body[body.startIndex + 1])
            var offset = body.startIndex + 2 + topicLength
            guard body.count >= 2 + topicLength else { return }
            let topic = String(decoding: body[(body.startIndex + 2)..<offset], as: UTF8.self)
            let qos = (flags >> 1) & 0x03
            if qos > 0 {
                guard body.endIndex >= offset + 2 else { return }
                let id = body[offset..<(offset + 2)]
                offset += 2
                if qos == 1 { send(type: 0x40, body: Data(id)) }
            }
            onMessage?(topic, Data(body[offset...]))
        default:
            break // PINGRESP and anything else needs no answer
        }
    }

    private func encodeString(_ string: String) -> Data {
        let bytes = Data(string.utf8)
        var out = Data([UInt8(bytes.count >> 8), UInt8(bytes.count & 0xFF)])
        out.append(bytes)
        return out
    }

    private func encodeLength(_ length: Int) -> Data {
        var out = Data()
        var value = length
        repeat {
            var byte = UInt8(value % 128)
            value /= 128
            if value > 0 { byte |= 0x80 }
            out.append(byte)
        } while value > 0
        return out
    }
}
