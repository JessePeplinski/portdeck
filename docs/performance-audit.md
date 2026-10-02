# Local performance investigation

Investigation date: October 2, 2026. Changes are local source changes, not a published release.

## Confirmed issues and fixes

| Path | Reproduction before the fix | Result after the fix |
| --- | --- | --- |
| Provider tab scrolling | Resolving the same scroll view 100 times published 200 unchanged-property notifications. SwiftUI's resolver runs after redraws, completing a feedback loop. | Unchanged scroll state publishes zero notifications. Real scroll changes still update the arrows. |
| Local helper output | A 256 KiB JSON fixture filled the stdout pipe while the parent waited for exit. The fixture failed to finish before its two-second safety alarm. | Private output files avoid pipe backpressure; the complete fixture loads successfully. |
| Local refresh cancellation | Cancelling a running fixture waited approximately one second and returned a successful snapshot. | Cancellation terminates the helper and throws `CancellationError`; the focused fixture completes in milliseconds. |
| Endpoint probes | A streaming HTTP response stayed connected after the health result was returned. Trickled incomplete headers bypassed the socket inactivity timeout. | Probes close responses after headers and enforce a total deadline. Both socket regressions pass. |
| Discovery fan-out | A 40-listener fixture launched 40 concurrent process/Git inspections. | Four concurrent inspections discover all 40 services and Git contexts. |

The Mac helper additionally has a 30-second deadline, a 500 ms termination grace period before force-killing an unresponsive helper, and an 8 MiB output read limit per stream. Discovery subprocesses have five-second timeouts, 500 ms force-kill grace periods, and 8 MiB per-stream output limits. A timed-out local refresh retains its previous successful snapshot and reports a degraded state.

## Live observations and limits

The installed beta.17 process was observed at 73.4% CPU. A three-second stack sample showed repeated SwiftUI/AppKit layout and rendering. Its physical memory footprint was about 49.9 MiB (53 MiB peak); a restricted `leaks` scan reported one 48-byte leak. Those observations support the redraw-loop diagnosis but do not establish a sizable memory leak.

The final development build launched through the documented launcher. An idle sample showed 0% CPU and a 17.7 MiB physical footprint (18.3 MiB peak). Its restricted leak scan reported 14,400 bytes in three `NSXPCConnection` cycles with the `LNDaemonApplicationInterface` protocol. This is a different build and UI workload from the installed-app sample; these figures are not a controlled before/after benchmark, and the cycles were not attributed to PortDeck source.

Four idle observations over one minute stayed at 0% CPU with RSS between 77,984 and 78,160 KiB. A later leak scan reported the same 288 allocations and 14,400 bytes, with a 17.8 MiB physical footprint. No continuing idle growth was observed in this short interval; that does not rule out an interaction-dependent leak.

Native UI automation repeatedly timed out when accessing the menu-bar app. Menu-open provider switching, filtering, long-running provider sessions, and the reported intermittent large memory increase still need live verification. The remaining older provider command runners also warrant a separate cancellation/deadline investigation; the Local helper changes do not alter those runners.

Code inspection and existing model tests confirm that Local rejects overlapping refreshes and waits five seconds after each completed poll while selected. Remote providers refresh once on selection/reopening; typing into filters does not launch discovery. Provider models intentionally live at app scope to preserve their last successful snapshots.

## Validation

- `npm run verify`: builds passed; 74 helper tests, 245 Swift tests, and six update-tool tests passed.
- `npm run typecheck`: passed.
- `git diff --check`: passed.
- `portdeck-mac/scripts/run-dev-app.sh`: development bundle built, signed locally, and launched.

Focused regression commands:

```bash
swift test --package-path portdeck-mac --filter providerTabRail
swift test --package-path portdeck-mac --filter localHelper
npm run test -w portdeck-app -- src/probes.test.ts src/discovery-performance.test.ts
```

For any remaining high-CPU incident, capture `sample <PortDeckMac PID> 3 -file <local-output-path>` while it is happening, plus the selected provider, whether the menu is open, CPU, and physical footprint. Keep raw stack/leak reports local: they may contain monitored-project paths or account information. Repeated measurements during the same workload are necessary to distinguish retained objects, caches, transient allocation, and a growing leak.
