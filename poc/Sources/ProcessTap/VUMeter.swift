/// VUMeter — ANSI terminal VU meter for the process-tap PoC.
///
/// Renders a two-channel (L/R) VU meter that updates in-place at ~20 fps.
/// Uses ANSI escape codes for cursor movement and colours.
///
/// Green  → below -18 dBFS
/// Yellow → -18 … -6 dBFS
/// Red    → above -6 dBFS  (likely clipping)

import Foundation

// ── VUMeter ───────────────────────────────────────────────────────────────────

final class VUMeter {

    // Atomically-updated RMS values (written from audio thread, read from timer)
    private var _leftRMS:  Float = 0
    private var _rightRMS: Float = 0
    private let lock = NSLock()

    // Peak hold
    private var peakL: Float = 0
    private var peakR: Float = 0
    private var peakHoldCounterL = 0
    private var peakHoldCounterR = 0
    private let peakHoldFrames   = 40  // ~2 s at 20 fps

    private let barWidth = 42
    private var firstRender = true

    // MARK: - Update (called from audio thread)

    func update(leftRMS: Float, rightRMS: Float) {
        lock.lock()
        _leftRMS  = leftRMS
        _rightRMS = rightRMS
        lock.unlock()
    }

    // MARK: - Render (called from main/timer thread)

    func render(appName: String, pid: pid_t) {
        lock.lock()
        let l = _leftRMS
        let r = _rightRMS
        lock.unlock()

        let dbL = rmsToDb(l)
        let dbR = rmsToDb(r)

        // Peak hold logic
        if l > peakL { peakL = l; peakHoldCounterL = peakHoldFrames }
        else if peakHoldCounterL > 0 { peakHoldCounterL -= 1 }
        else { peakL = max(peakL * 0.85, l) }

        if r > peakR { peakR = r; peakHoldCounterR = peakHoldFrames }
        else if peakHoldCounterR > 0 { peakHoldCounterR -= 1 }
        else { peakR = max(peakR * 0.85, r) }

        let peakDbL = rmsToDb(peakL)
        let peakDbR = rmsToDb(peakR)

        // Move cursor up to overwrite previous frame (skip on first render)
        if firstRender {
            firstRender = false
        } else {
            // 6 lines: header + blank + L bar + R bar + blank + footer
            print("\u{1B}[6A", terminator: "")
        }

        let header = "🎵  \(appName)  (PID \(pid))"
        print(header)
        print(String(repeating: "─", count: barWidth + 18))

        printBar(label: "L", db: dbL, peakDb: peakDbL)
        printBar(label: "R", db: dbR, peakDb: peakDbR)

        print("")
        print(String(
            format: "  Peak  L: %+.1f dBFS    R: %+.1f dBFS    [ Press Enter to stop ]",
            peakDbL, peakDbR
        ))
    }

    // MARK: - Helpers

    private func rmsToDb(_ rms: Float) -> Float {
        return max(-60.0, 20.0 * log10(max(rms, 1e-6)))
    }

    private func printBar(label: String, db: Float, peakDb: Float) {
        // Map dBFS range [-60, 0] to [0, barWidth]
        let normalized  = Double(max(0, min(1, (db + 60) / 60)))
        let filled      = Int(normalized * Double(barWidth))
        let empty       = barWidth - filled

        // Peak indicator position
        let peakPos     = Int(Double(max(0, min(1, (peakDb + 60) / 60))) * Double(barWidth))

        // Colour: green / yellow / red
        let colour: String
        switch db {
        case ..<(-18): colour = "\u{1B}[32m"   // green
        case ..<(-6):  colour = "\u{1B}[33m"   // yellow
        default:       colour = "\u{1B}[31m"   // red
        }
        let reset = "\u{1B}[0m"

        // Build bar string, inserting a peak marker (▌) at the right position
        var bar = Array(repeating: "█", count: filled)
            + Array(repeating: "░", count: empty)
        if peakPos < barWidth {
            bar[peakPos] = "▌"
        }
        let barStr = bar.joined()

        print(String(
            format: "  \(label): \(colour)[\(barStr)]\(reset)  %+6.1f dBFS",
            db
        ))
    }
}
