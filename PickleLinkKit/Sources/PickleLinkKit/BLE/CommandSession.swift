import Foundation

/// Request/response correlation with fragment reassembly.
/// Owns the seq counter and outstanding-request table.
public actor CommandSession {
    private weak var transport: CommandTransport?
    private var seqCounter: UInt8 = 0
    private var outstanding: [UInt8: Pending] = [:]
    private let defaultTimeout: TimeInterval

    public init(transport: CommandTransport, defaultTimeout: TimeInterval = 10.0) {
        self.transport = transport
        self.defaultTimeout = defaultTimeout
    }

    private struct Pending {
        let command: SCMD
        let continuation: CheckedContinuation<Data, Error>
        var buffer: Data
        let started: Date
    }

    private func nextSeq() -> UInt8 {
        let s = seqCounter
        seqCounter = seqCounter &+ 1
        return s
    }

    /// Send a command, await full (reassembled) response payload bytes.
    public func send(
        _ cmd: SCMD,
        params: Data = Data(),
        timeout: TimeInterval? = nil
    ) async throws -> Data
    {
        guard let transport = transport else { throw SmartBridgeError.notConnected }
        let seq = nextSeq()
        let frame = CommandFrame(seq: seq, command: cmd, params: params).encode()
        let to = timeout ?? defaultTimeout

        return try await withThrowingTaskGroup(of: Data.self) { group in
            // Producer: await response
            group.addTask {
                try await self.awaitResponse(seq: seq, command: cmd)
            }
            // Timeout
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(to * 1_000_000_000))
                await self.cancel(seq: seq, with: .timeout)
                throw SmartBridgeError.timeout
            }
            // Fire write
            try await transport.sendCommand(frame)
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    /// Convenience: send + decode.
    public func send<T>(
        _ cmd: SCMD,
        params: Data = Data(),
        timeout: TimeInterval? = nil,
        decode: (Data) throws -> T
    ) async throws -> T
    {
        let payload = try await send(cmd, params: params, timeout: timeout)
        return try decode(payload)
    }

    private func awaitResponse(seq: UInt8, command: SCMD) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            outstanding[seq] = Pending(command: command, continuation: cont, buffer: Data(), started: Date())
        }
    }

    private func cancel(seq: UInt8, with err: SmartBridgeError) {
        guard let p = outstanding.removeValue(forKey: seq) else { return }
        p.continuation.resume(throwing: err)
    }

    /// Called by transport when a Response notify arrives.
    public func handleResponseBytes(_ raw: Data) {
        guard let frame = ResponseFrame(raw: raw) else { return }
        guard var p = outstanding[frame.seq] else {
            // Stale / unsolicited — ignore.
            return
        }

        // Status check on the FIRST fragment only (frag index 0).
        if frame.frag.index == 0 {
            if let sstat = frame.sstat, sstat != .success {
                outstanding.removeValue(forKey: frame.seq)
                p.continuation.resume(throwing: SmartBridgeError.statusError(sstat, command: p.command))
                return
            }
            if frame.sstat == nil {
                outstanding.removeValue(forKey: frame.seq)
                p.continuation.resume(throwing: SmartBridgeError.unknownStatus(frame.status))
                return
            }
        }

        // Accumulate
        p.buffer.append(frame.payload)

        if frame.frag.moreFragments {
            outstanding[frame.seq] = p
        } else {
            outstanding.removeValue(forKey: frame.seq)
            p.continuation.resume(returning: p.buffer)
        }
    }

    /// Drop all in-flight requests (e.g. on disconnect).
    public func failAll(with err: SmartBridgeError) {
        let snapshot = outstanding
        outstanding.removeAll()
        for (_, p) in snapshot {
            p.continuation.resume(throwing: err)
        }
    }
}
