# Watching a slow Mac

Two things, both in Settings › Log stream: the log goes to a computer on the same network
as it is written, and the session's controls gain a flag that marks the start and the end of
something slow. Between the marks the log says what the engine and the GPU did, so "Mission
Control stutters" becomes numbers.

## Steps

1. **Listen on the computer.** `python3 tools/henge-log-listen.py` prints the addresses to
   type into Henge and appends every line to `henge-stream.log` (raw, the same format as
   `Documents/henge.log`). `--port`, `--out` and `--quiet` change that; Ctrl-C stops it.
   Done when the listener is running.
2. **Point Henge at it.** Settings › Log stream: turn *Send the log to a computer* on, type
   the address and port, and wait for *State: Connected*. iOS asks for local network access
   the first time, and the connection is retried every few seconds while the listener is
   away. Done when the listener prints the `---- Henge log from …` header.
3. **Mark the action.** In a running Mac, tap the flag in the controls, do the slow thing,
   tap it again. The flag is only there while the log is being streamed. Done when the log
   has a `[mark] #N begin` and a `[mark] #N end` line.
4. **Read it.** The lines after `end` are the window's numbers (below). Done when one of them
   names the bottleneck.

## What the marks add to the log

While a mark runs, the engine's detailed `stats` lines come every second instead of every
ten (`henge_vm_stats_interval`), so a short window still gets samples. At the end, the log
gets the difference across the window:

- `cpu:` blocks, translations, slow-memory accesses, interrupts, exceptions and TLB flushes
  per second, and how much of the CPU time was spent asleep.
- `gpu:` execs, draws, **passes** (render and compute encoders begun), frames presented,
  surfaces mapped, the depth of the GPU's queue and its peak since the mark began, and
  surfaces remapped.
- `gpu time:` seconds and share of the window spent encoding commands into Metal, committing
  them, presenting a frame, and waiting for a drawable (`nextDrawable`).
- `frame gaps:` p50, p95 and max interval between presented frames, over the window. This is
  the closest thing to "it stuttered": 60 Hz is 16.7 ms.
- `engine:` blocks held, JIT code used, full flushes, CPUs on, network frames.

## Reading it

- **`gpu time: encoding` high** — the CPU is the cost: too many commands to translate into
  Metal. Fewer passes per frame or cheaper resources would help.
- **`queue … deep (peak …)` near 64** — the GPU is behind: the worker keeps committing and
  nothing is finishing. `waiting for a drawable` then rises too, because the drawable pool is
  exhausted by frames the GPU has not drawn yet.
- **`gpu time: presenting` or `waiting for a drawable` high** — the display path is the cost,
  not the guest.
- **`frame gaps` p95 far above p50** — the frames that did arrive were uneven, which is what
  the eye calls stutter, whatever the averages say.
- **`passes` per frame** — how much work one frame is. Mission Control and Spaces redraw
  every window, so this jumps even when nothing else does.
- **`slow memory` and `TLB flushes` high** — memory translation, not graphics.
- **`asleep` near 0%** — every CPU was busy; the guest was not waiting for anything.

Counters are cumulative and the report is a difference, so a mark that spans a stop or a
restart reads as nonsense: start a new mark instead.

The GPU's own line, `hengevm: pvg-metal: … execs, … draws … encoding … waiting`, still
prints every 2000 execs, and `HV_PVG_TRACE_FILE` (a file named `trace-on` in Documents)
traces every command. `HV_PROF_IOS=1` in `Documents/henge-env.txt` samples the CPU threads
and prints the hottest host functions, as offsets into the app image.
