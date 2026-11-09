// SPDX-License-Identifier: GPL-2.0-or-later
import Combine
import Foundation
import Network
import UIKit

/// Sends the log to a computer on the same network, line by line, so a session can be watched
/// live instead of copied off the device afterwards.
///
/// The app is the client: `tools/henge-log-listen.py` listens on the computer, prints what
/// arrives and appends it to a file. Lines are queued while the computer is away, and the queue
/// is bounded, so a session that runs for hours without a listener cannot grow without limit.
final class LogStream: ObservableObject {
    static let shared = LogStream()

    static let enabledKey = "henge.logstream.enabled"
    static let hostKey = "henge.logstream.host"
    static let portKey = "henge.logstream.port"
    static let defaultPort = 7777

    enum State: Equatable {
        case off
        case connecting
        case connected
        case waiting(String)
    }

    @Published private(set) var state: State = .off
    @Published private(set) var sent = 0
    @Published private(set) var dropped = 0

    private struct Target: Equatable {
        var host: String
        var port: UInt16
    }

    /// How many lines are held while the computer is not listening: a few MB at most.
    private static let queueLimit = 20_000
    /// Lines per send. Enough to keep up with a boot's flood, small enough not to stall.
    private static let batchLimit = 256

    private let queue = DispatchQueue(label: "com.henge.logstream")
    private let lock = NSLock()

    // Guarded by `lock`: what the settings say and what is waiting to go out.
    private var enabled = false
    private var target: Target?
    private var pending: [String] = []
    private var scheduled = false
    private var unsentDropped = 0
    /// True while there is no connection to send on: lines are held, and nothing is woken per
    /// line. `handle(.ready)` clears it and pumps.
    private var held = false

    // Confined to `queue`.
    private var connection: NWConnection?
    private var ready = false
    private var batchInFlight = false
    private var attempt = 0
    private var retry: DispatchWorkItem?
    private var publishedSent = 0
    private var publishedDropped = 0

    /// What the Settings screen says.
    var statusText: String {
        switch state {
        case .off: return "Off"
        case .connecting: return "Connecting…"
        case .connected: return sent > 0 ? "Connected — \(sent) lines sent" : "Connected"
        case .waiting(let why): return "Waiting — \(why)"
        }
    }

    // MARK: - Settings

    /// Reads the settings and connects, reconnects or stops. Called at launch and whenever a
    /// setting changes; safe from any thread.
    func applySettings() {
        let d = UserDefaults.standard
        let on = d.bool(forKey: Self.enabledKey)
        let host = (d.string(forKey: Self.hostKey) ?? "").trimmingCharacters(in: .whitespaces)
        let raw = d.integer(forKey: Self.portKey)
        let port = raw > 0 && raw < 65_536 ? UInt16(raw) : UInt16(Self.defaultPort)
        lock.lock()
        enabled = on && !host.isEmpty
        let want = enabled ? Target(host: host, port: port) : nil
        let changed = want != target
        target = want
        if want == nil { pending.removeAll() } // nothing to send to: do not hold it
        lock.unlock()
        queue.async { self.reconcile(changed: changed) }
    }

    // MARK: - Lines

    /// A line for the computer. Called for every line the log writes, from any thread.
    func offer(_ line: String) {
        lock.lock()
        guard enabled else { lock.unlock(); return }
        pending.append(line)
        if pending.count > Self.queueLimit {
            let drop = pending.count - Self.queueLimit
            pending.removeFirst(drop)
            unsentDropped += drop
        }
        let wake = !scheduled && !held
        if wake { scheduled = true }
        lock.unlock()
        if wake { queue.async { self.step() } }
    }

    // MARK: - Connection (on `queue`)

    private func reconcile(changed: Bool) {
        retry?.cancel()
        retry = nil
        guard let want = currentTarget() else {
            close()
            publish(.off)
            return
        }
        if changed || connection == nil {
            close()
            attempt = 0
            connect(to: want)
        }
    }

    private func connect(to want: Target) {
        guard let port = NWEndpoint.Port(rawValue: want.port) else {
            publish(.waiting("the port is not a port"))
            return
        }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = true
        let c = NWConnection(host: NWEndpoint.Host(want.host), port: port, using: params)
        connection = c
        ready = false
        lock.lock()
        held = true
        lock.unlock()
        publish(.connecting)
        c.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.queue.async { self.handle(state, from: c, want: want) }
        }
        c.start(queue: queue)
    }

    private func handle(_ state: NWConnection.State, from c: NWConnection, want: Target) {
        guard connection === c else { return }
        switch state {
        case .ready:
            attempt = 0
            ready = true
            let first = header(want)
            lock.lock()
            held = false
            pending.insert(first, at: 0)
            lock.unlock()
            publish(.connected)
            // Through the log, so the stream carries its own beginning (and proves the round trip).
            HengeLog.log("stream", "connected to \(want.host):\(want.port)")
            pump()
        case .waiting(let error), .failed(let error):
            close()
            scheduleRetry(want, why: Self.describe(error))
        case .cancelled:
            close()
        default:
            break
        }
    }

    private func scheduleRetry(_ want: Target, why: String) {
        guard currentTarget() == want else { return }
        attempt += 1
        let delay = min(2.0 * Double(attempt), 10.0)
        publish(.waiting(why))
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.currentTarget() == want else { return }
            self.connect(to: want)
        }
        retry = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func close() {
        let c = connection
        connection = nil
        ready = false
        batchInFlight = false
        lock.lock()
        held = true
        lock.unlock()
        c?.stateUpdateHandler = nil
        c?.cancel()
    }

    // MARK: - Sending (on `queue`)

    private func pump() {
        lock.lock()
        if scheduled { lock.unlock(); return }
        scheduled = true
        lock.unlock()
        queue.async { self.step() }
    }

    private func step() {
        lock.lock()
        scheduled = false
        var batch: [String] = []
        let canSend = ready && !batchInFlight && connection != nil
        if canSend {
            if unsentDropped > 0 {
                batch.append("---- \(unsentDropped) lines dropped: the computer was not listening ----")
                dropped += unsentDropped
                unsentDropped = 0
            }
            let n = min(pending.count, Self.batchLimit - batch.count)
            if n > 0 {
                batch.append(contentsOf: pending.prefix(n))
                pending.removeFirst(n)
            }
        }
        lock.unlock()
        publishCounts()
        guard canSend, let c = connection, !batch.isEmpty else { return }
        batchInFlight = true
        let data = Data((batch.joined(separator: "\n") + "\n").utf8)
        let lines = batch.count
        c.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.queue.async {
                self.batchInFlight = false
                if let error {
                    self.close()
                    if let want = self.currentTarget() { self.scheduleRetry(want, why: Self.describe(error)) }
                    return
                }
                self.lock.lock()
                self.sent += lines
                let more = !self.pending.isEmpty
                self.lock.unlock()
                self.publishCounts()
                if more { self.pump() }
            }
        })
    }

    // MARK: - Odds and ends

    private func currentTarget() -> Target? {
        lock.lock(); defer { lock.unlock() }
        return enabled ? target : nil
    }

    private func publish(_ state: State) {
        DispatchQueue.main.async {
            if self.state != state { self.state = state }
        }
    }

    private func publishCounts() {
        lock.lock()
        let sent = self.sent, dropped = self.dropped
        lock.unlock()
        guard sent != publishedSent || dropped != publishedDropped else { return }
        publishedSent = sent
        publishedDropped = dropped
        DispatchQueue.main.async {
            if self.sent != sent { self.sent = sent }
            if self.dropped != dropped { self.dropped = dropped }
        }
    }

    /// The first line of a connection: whose log this is, and which build wrote it.
    private func header(_ want: Target) -> String {
        let d = UIDevice.current
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "---- Henge log from \(HengeLog.deviceModel) (\(d.systemName) \(d.systemVersion)), "
             + "Henge \(version) (\(build)), to \(want.host):\(want.port) ----"
    }

    private static func describe(_ error: NWError) -> String {
        switch error {
        case .posix(.ECONNREFUSED): return "nothing is listening there"
        case .posix(.EHOSTUNREACH), .posix(.ENETUNREACH): return "that address is not reachable"
        case .posix(.ETIMEDOUT): return "no answer"
        case .dns(let code): return "the address does not resolve (\(code))"
        default: return error.localizedDescription
        }
    }
}
