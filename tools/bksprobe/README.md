# BKSProbe

A diagnostic dylib for LiveContainer's TweakLoader, built here so the
GitHub-hosted macOS runner can produce it without a Mac.

It answers one question:

> On an iPhone with **AssistiveTouch off**, can a sandboxed app still reach
> `BackBoardServices`' private `BKSMousePointerService`, see the attached mouse,
> and read its global pointer position?

If yes, a no-AssistiveTouch mouse path for Henge (or any GCMouse app) is
possible. If no, AssistiveTouch is the only route on iPhone and the fallback is
to make it less janky.

The probe only reads and logs. It does not change the guest's behaviour.

## Build

Run **Actions → Build BKSProbe → Run workflow**, or push to `ios-cursor`.
Download the `BKSProbe` artifact; it contains `BKSProbe.dylib`.

Locally (macOS + Xcode):

```bash
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
xcrun --sdk iphoneos clang -arch arm64 -dynamiclib -fobjc-arc -fmodules \
  -isysroot "$SDK" \
  -framework Foundation -framework UIKit -framework GameController -framework QuartzCore \
  -miphoneos-version-min=15.0 -o BKSProbe.dylib tools/bksprobe/BKSProbe.m
```

LiveContainer signs tweaks itself before launch, so no `ldid` step.

## Install in LiveContainer

1. LC → **Tweaks** → `+` → **New Folder** → `HengeProbe`.
2. Open it → `+` → **Import Tweak** → `BKSProbe.dylib`.
3. Henge → app settings → **Tweak Folder** → `HengeProbe`.
4. Make sure **Don't Load TweakLoader** is off for Henge.

## Test

1. Settings → Accessibility → Touch → **AssistiveTouch: OFF**.
2. Launch Henge from LiveContainer.
3. Wait for the green overlay (up to ~10 s).
4. Move the mouse, click both buttons, scroll.
5. Screenshot the overlay; copy `BKSProbe.log` out via the Files app
   (`LiveContainer` → `Data/Application/<container>/Documents/BKSProbe.log`).
6. Optional second run with AssistiveTouch **ON**, for comparison.

## Reading the result

| Log line | Meaning |
| --- | --- |
| `BKSMousePointerService class = (null)` / `dlopen ... FAILED` | Dead end; service not reachable in this process. |
| `sharedInstance = (null)` | Service exists but the XPC connection was refused. |
| `devices(0): (none)` with AT off | Service does not see the mouse without AT. AT is the only route. |
| `devices(N): ...` with N > 0, AT off | Service **does** see the mouse. Promising. |
| `globalPointerPosition = (...)` changing, AT off | Jackpot: backboardd tracks the pointer without AT. |
| Position static but `devices > 0` | Next step is `requestGlobalMouseEventsForDisplay:targetContextID:options:`; the `sig ...` line gives its ABI. |
| `GCMouse.mice.count = 0` | Expected without AT; confirms why Henge is silent. |

The `M ...` lines (full method list with type encodings) are the most useful
part if we need to go further.
