import Foundation
import Network

/// Minimal WebSocket framing on top of an already-upgraded NWConnection.
/// Server side: outbound frames are never masked; inbound frames from a browser
/// are always masked (RFC 6455 §5.3) and we unmask on receive.
final class WebSocketConnection {
    var onText: ((String) -> Void)?
    var onBinary: ((Data) -> Void)?
    var onClose: (() -> Void)?

    private let conn: NWConnection
    private var closed = false
    private var fragmentBuffer = Data()
    private var fragmentOpcode: UInt8 = 0

    init(connection: NWConnection) {
        self.conn = connection
    }

    func start() {
        readFrame()
    }

    func sendText(_ text: String) {
        sendFrame(opcode: 0x1, payload: Data(text.utf8))
    }

    func sendBinary(_ data: Data) {
        sendFrame(opcode: 0x2, payload: data)
    }

    func close() {
        if closed { return }
        closed = true
        sendFrame(opcode: 0x8, payload: Data())
        conn.cancel()
        onClose?()
    }

    // MARK: - Send

    private func sendFrame(opcode: UInt8, payload: Data) {
        if closed { return }
        var frame = Data()
        frame.append(0x80 | opcode)       // FIN=1
        let len = payload.count
        if len < 126 {
            frame.append(UInt8(len))
        } else if len <= 0xFFFF {
            frame.append(126)
            frame.append(UInt8((len >> 8) & 0xff))
            frame.append(UInt8(len & 0xff))
        } else {
            frame.append(127)
            var u64 = UInt64(len).bigEndian
            withUnsafeBytes(of: &u64) { frame.append(contentsOf: $0) }
        }
        frame.append(payload)
        conn.send(content: frame, completion: .idempotent)
    }

    // MARK: - Receive

    private func readExactly(_ n: Int, _ handler: @escaping (Data) -> Void) {
        if n == 0 { handler(Data()); return }
        conn.receive(minimumIncompleteLength: n, maximumLength: n) { [weak self] data, _, _, error in
            guard let self = self else { return }
            if let error = error {
                print("[WS] receive error: \(error)")
                self.close()
                return
            }
            guard let data = data, data.count == n else {
                self.close()
                return
            }
            handler(data)
        }
    }

    private func readFrame() {
        readExactly(2) { [weak self] header in
            guard let self = self else { return }
            let b0 = header[0]
            let b1 = header[1]
            let fin = (b0 & 0x80) != 0
            let opcode = b0 & 0x0f
            let masked = (b1 & 0x80) != 0
            let short = Int(b1 & 0x7f)

            let continueWithLength: (Int) -> Void = { len in
                let afterMask: (Data?) -> Void = { maskKey in
                    self.readExactly(len) { payload in
                        var unmasked = payload
                        if let m = maskKey, m.count == 4 {
                            for i in 0..<unmasked.count { unmasked[i] ^= m[i % 4] }
                        }
                        self.handleFrame(opcode: opcode, fin: fin, payload: unmasked)
                    }
                }
                if masked {
                    self.readExactly(4) { afterMask($0) }
                } else {
                    afterMask(nil)
                }
            }

            if short == 126 {
                self.readExactly(2) { ext in
                    let len = (Int(ext[0]) << 8) | Int(ext[1])
                    continueWithLength(len)
                }
            } else if short == 127 {
                self.readExactly(8) { ext in
                    var len: UInt64 = 0
                    for i in 0..<8 { len = (len << 8) | UInt64(ext[i]) }
                    continueWithLength(Int(len))
                }
            } else {
                continueWithLength(short)
            }
        }
    }

    private func handleFrame(opcode: UInt8, fin: Bool, payload: Data) {
        switch opcode {
        case 0x0: // continuation
            fragmentBuffer.append(payload)
            if fin { deliver(opcode: fragmentOpcode, payload: fragmentBuffer); fragmentBuffer.removeAll(keepingCapacity: false) }
        case 0x1, 0x2: // text / binary
            if fin {
                deliver(opcode: opcode, payload: payload)
            } else {
                fragmentOpcode = opcode
                fragmentBuffer = payload
            }
        case 0x8: // close
            close()
            return
        case 0x9: // ping → pong
            sendFrame(opcode: 0xA, payload: payload)
        case 0xA: // pong
            break
        default:
            break
        }
        if !closed { readFrame() }
    }

    private func deliver(opcode: UInt8, payload: Data) {
        switch opcode {
        case 0x1:
            if let s = String(data: payload, encoding: .utf8) { onText?(s) }
        case 0x2:
            onBinary?(payload)
        default:
            break
        }
    }
}
