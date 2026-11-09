// SPDX-License-Identifier: GPL-2.0-or-later
import Combine
import Foundation

/// A measured window around something expensive: tap the flag before, tap it again after.
///
/// "Mission Control stutters" is a feeling; the log needs numbers. While a mark runs the engine
/// prints its detailed stats lines every second, and at the end the log gets the difference
/// across the window: blocks, slow memory, interrupts and TLB flushes; GPU execs, draws and
/// passes; the time spent encoding commands, waiting for the GPU, presenting and waiting for a
/// drawable; and the intervals between the frames the screen actually showed.
final class PerfMark: ObservableObject {
    static let shared = PerfMark()

    @Published private(set) var active = false
    @Published private(set) var count = 0
    /// What the session screen says for a few seconds after a mark starts or ends.
    @Published private(set) var note: String?
    @Published private(set) var noteID = 0

    private var start: HengePerf?
    private var startedAt: Date?

    func toggle() {
        if active { end() } else { begin() }
    }

    func begin() {
        guard henge_vm_state() == 1 else {
            HengeLog.log("mark", "no Mac is running: nothing to measure")
            say("Start a Mac first")
            return
        }
        var snapshot = HengePerf()
        guard henge_vm_perf(&snapshot, 1) == 0 else {
            HengeLog.log("mark", "could not read the engine's counters")
            say("Could not read the counters")
            return
        }
        count += 1
        start = snapshot
        startedAt = Date()
        active = true
        // The engine's detailed stats lines every second, for as long as the mark runs.
        henge_vm_stats_interval(1)
        HengeLog.log("mark", "#\(count) begin: \(Self.brief(snapshot)), thermal \(Self.thermal)")
        say("Mark \(count) started — do it, then tap again")
    }

    func end() {
        guard let before = start, let began = startedAt else {
            active = false
            return
        }
        let seconds = Date().timeIntervalSince(began)
        active = false
        start = nil
        startedAt = nil
        henge_vm_stats_interval(EngineTuning.statsInterval)
        var after = HengePerf()
        guard henge_vm_perf(&after, 0) == 0 else {
            HengeLog.log("mark", "#\(count) end: could not read the engine's counters")
            say("Mark \(count) ended")
            return
        }
        HengeLog.log("mark", "#\(count) end after \(Self.duration(seconds)) s: \(Self.brief(after)), thermal \(Self.thermal)")
        for line in Self.report(before, after, seconds: seconds) {
            HengeLog.log("mark", "#\(count) \(line)")
        }
        say("Mark \(count): \(Self.duration(seconds)) s")
    }

    /// The Mac went away with a mark still running: drop it, and put the stats interval back.
    func reset() {
        guard active else { return }
        active = false
        start = nil
        startedAt = nil
        henge_vm_stats_interval(EngineTuning.statsInterval)
    }

    private func say(_ text: String) {
        note = text
        noteID += 1
    }

    // MARK: - What the log says

    private static func report(_ a: HengePerf, _ b: HengePerf, seconds: Double) -> [String] {
        var out: [String] = []
        let cpus = Double(max(b.ncpus, 1))
        let asleep = Double(b.wfi_us &- a.wfi_us) / 1e6
        let translating = Double(b.translate_us &- a.translate_us) / 1e6
        out.append("cpu: \(number(rate(b.blocks, a.blocks, seconds)))/s blocks, "
                   + "\(number(rate(b.translations, a.translations, seconds)))/s translated "
                   + "(\(share(translating, seconds)) of the time), "
                   + "\(number(rate(b.slow_mem, a.slow_mem, seconds)))/s slow memory, "
                   + "\(number(rate(b.interrupts, a.interrupts, seconds)))/s interrupts, "
                   + "\(number(rate(b.exceptions, a.exceptions, seconds)))/s exceptions, "
                   + "\(number(rate(b.tlb_flushes, a.tlb_flushes, seconds)))/s TLB flushes, "
                   + "asleep \(share(asleep, seconds * cpus)) of the CPU time")
        let execs = rate(b.gpu_execs, a.gpu_execs, seconds)
        let draws = rate(b.gpu_draws, a.gpu_draws, seconds)
        let passes = rate(b.gpu_passes, a.gpu_passes, seconds)
        let frames = rate(b.gpu_frames, a.gpu_frames, seconds)
        out.append("gpu: \(number(execs))/s execs, \(number(draws))/s draws, \(number(passes))/s passes, "
                   + "\(number(frames))/s frames, \(b.gpu_surfaces) surfaces, "
                   + "queue \(b.gpu_inflight) deep (peak \(b.gpu_inflight_peak)), "
                   + "\(number(rate(b.gpu_remaps, a.gpu_remaps, seconds)))/s remapped")
        let encode = Double(b.gpu_encode_us &- a.gpu_encode_us) / 1e6
        let wait = Double(b.gpu_wait_us &- a.gpu_wait_us) / 1e6
        let present = Double(b.gpu_present_us &- a.gpu_present_us) / 1e6
        let drawable = Double(b.gpu_drawable_wait_us &- a.gpu_drawable_wait_us) / 1e6
        out.append("gpu time: encoding \(duration(encode)) s (\(share(encode, seconds))), "
                   + "committing \(duration(wait)) s (\(share(wait, seconds))), "
                   + "presenting \(duration(present)) s (\(share(present, seconds))), "
                   + "waiting for a drawable \(duration(drawable)) s (\(share(drawable, seconds)))")
        if b.gpu_gaps > 0 {
            out.append("frame gaps: p50 \(interval(b.gpu_gap_p50)), p95 \(interval(b.gpu_gap_p95)), "
                       + "max \(interval(b.gpu_gap_max)) over \(b.gpu_gaps) frames, "
                       + "\(b.gpu_slow_gaps) over 50 ms")
        } else {
            out.append("frame gaps: no frame was presented in this window")
        }
        let flushes = b.flush_full &- a.flush_full
        out.append("engine: \(number(Double(b.blocks_held))) blocks held, "
                   + "JIT \((b.jit_words * 4) >> 20) MB, "
                   + "\(flushes) full flush\(flushes == 1 ? "" : "es") in this window (\(b.flush_full) since boot), "
                   + "\(b.cpus_on)/\(b.ncpus) CPUs on, net \(b.net_tx) tx \(b.net_rx) rx")
        return out
    }

    private static func brief(_ p: HengePerf) -> String {
        "blocks \(number(Double(p.blocks))), frames \(p.gpu_frames), execs \(p.gpu_execs), \(p.cpus_on)/\(p.ncpus) CPUs"
    }

    private static var thermal: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "normal"
        case .fair: return "warm"
        case .serious: return "hot"
        case .critical: return "critical"
        @unknown default: return "?"
        }
    }

    /// A counter's change over the window, per second.
    private static func rate(_ now: UInt64, _ then: UInt64, _ seconds: Double) -> Double {
        Double(now &- then) / max(seconds, 0.001)
    }

    private static func number(_ n: Double) -> String {
        if n >= 1e6 { return String(format: "%.2fM", n / 1e6) }
        if n >= 1e3 { return String(format: "%.1fK", n / 1e3) }
        return String(format: "%.0f", n)
    }

    private static func share(_ part: Double, _ whole: Double) -> String {
        String(format: "%.0f%%", whole > 0 ? 100 * part / whole : 0)
    }

    private static func duration(_ s: Double) -> String {
        s >= 10 ? String(format: "%.1f", s) : String(format: "%.2f", s)
    }

    private static func interval(_ s: Double) -> String {
        s >= 1 ? String(format: "%.0f ms", s * 1000) : String(format: "%.1f ms", s * 1000)
    }
}
