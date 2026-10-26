# RouterWatch

A bandwidth and uptime monitor for macOS, iOS, iPadOS, and tvOS. It runs a speed test against a server outside your local network on a schedule. Every result goes into a log, including failures. Each failure is sorted into a specific error type, and a bar chart shows which errors happen and when.

The Mac version is the one that runs all day. It lives in the menu bar, can start at login, and keeps testing after you close its window.

## Build

```bash
xcodegen generate
open RouterWatch.xcodeproj
```

Schemes: `RouterWatch-macOS`, `RouterWatch-iOS`, `RouterWatch-tvOS`. Unit tests run under the macOS scheme (`⌘U`).

Settings follow the MapMe conventions: team `B8P24AZNQT`, bundle ID `com.mybrightzone.routerwatch` in `APP_BUNDLE_ID`, and version and build numbers in `project.yml`.

The icons are generated, not hand-drawn. To change the artwork, edit `Tools/GenerateIcons.swift` and run:

```bash
swift Tools/GenerateIcons.swift
```

## What a probe does

1. **Latency:** five small HTTPS round trips. The first is thrown away because it includes DNS and the TLS handshake. The app records the fastest of the rest as latency, and the average change between samples as jitter.
2. **Download:** timed from URLSession delegate callbacks, which receive whole data buffers. Anything that arrives in the first 0.3 s is ignored so TCP slow start doesn't lower the result. A response much smaller than requested is rejected as a refusal, not recorded as a slow connection — see below.
3. **Upload:** POSTs a random payload, timed from the first byte sent until the server finishes responding. Timing `didSendBodyData` instead would measure how fast the kernel accepted the bytes, not how fast they crossed the wire, which overstated a 5 MB upload on a 23 Mbps link as over 100 Mbps.
4. **Thresholds:** a download below your floor is logged as *Low Throughput*. Latency above your ceiling is logged as *High Latency*.

If the device has no network interface at all, the app logs *No Network* right away instead of waiting for a timeout. This separates "your Wi-Fi is down" from "the router can't reach the internet."

### Refusals are not measurements

A throttling endpoint can answer `200 OK` with a couple of dozen bytes. Dividing that by the elapsed time gives ~0 Mbps, which would be logged as *Low Throughput* — blaming your connection for the test server's refusal.

A download is rejected when it delivers less than 90% of the requested size (for endpoints that accept a size), or less than 100 KB (for fixed-size and custom endpoints). Rejections count as server-side errors, so the probe retries on the other test server instead.

Upload stays on the configured endpoint even when the download falls back, because throttling usually applies to download volume — a server that refuses a 25 MB download will often still accept a 5 MB POST. Without this, upload showed "—" whenever the fallback server had no upload endpoint.

Readings that older builds recorded this way — a "successful" download that moved a few dozen bytes — are removed from the log at launch. Genuinely slow results, where the whole payload arrived, are kept.

### How the numbers compare to other tools

Measured against Apple's `networkquality` on the same connection, minutes apart:

| | RouterWatch | `networkquality` |
|---|---|---|
| Download | 84.4 Mbps | 85.2 Mbps |
| Upload | 22.3 Mbps | 33.1 Mbps |
| Latency | 43 ms | 45.8 ms (idle) |

Download and latency track closely. Upload reads lower because RouterWatch uses a single connection while `networkquality` opens several in parallel to find total capacity. The single-stream number is stable — 5 MB and 25 MB payloads both measured ~22 Mbps — which is what makes it useful for spotting change over time. Latency is an HTTPS round trip, so it runs slightly above `ping`.

## Error types

| Type | Usual cause | Counts as outage |
|---|---|---|
| No Network | Device is off Wi-Fi or Ethernet | yes |
| DNS Failure | Router's DNS forwarder or ISP resolver | yes |
| Cannot Connect | Router has no working WAN link | yes |
| Connection Lost | Unstable line or router reboot during a transfer | yes |
| Timeout | Congestion or an upstream outage | yes |
| TLS Failure | Captive portal or TLS interception | yes |
| HTTP Error | The test server itself, not your connection | no |
| Rate Limited | Test server throttling this network (HTTP 429) | no |
| Low Throughput | Line is up but below your floor | no |
| High Latency | Bufferbloat or saturated uplink | no |

If the main test server refuses a request (rate limiting, an HTTP error, or an empty reply), the probe retries on the other test server and records why in the log entry. A `429` also pauses the main server for as long as its `Retry-After` header asks, capped at 2 hours. Network-level failures such as DNS errors and timeouts are never retried on the other server, because those are the outages the app is meant to record.

### Recovery detection

The app doesn't wait for the next scheduled test to notice that an outage has ended:

- **Device loses its network interface:** after 3 seconds, the outage is recorded. Waiting first means a quick Wi-Fi roam isn't logged as an outage.
- **Interface comes back:** after 5 seconds, a full test runs. The delay gives DHCP and DNS time to settle.
- **Internet is down but Wi-Fi stays connected** (for example, the router loses its WAN link): every 20 seconds, the app sends a `HEAD` request to the main test server, then the other one. As soon as either responds, a full test runs.
- **Test succeeds after an outage:** the log entry records how long the connection was down, and a "Connection restored" notification is sent.

*Availability* counts only outages. *Errors* counts everything, so a slow line lowers the error rate without lowering availability.

## Networks

Every network gets its own measurement log. Home, the office, and a phone hotspot are never averaged together, and results stay separated whether you switch networks or lose one entirely.

    Application Support/RouterWatch/
        networks.json                       the known networks
        Networks/<network id>/measurements.json

### How a network is identified

Using only what an App Store app can read without extra permissions:

- **Internet provider** — name and AS number, from Cloudflare's speed-test metadata. Public IP and city are stored too; the coordinates and postal code the endpoint returns are discarded.
- **Router address** — the gateway IP, from `NWPath`. Known even during an outage, which is what lets a dropped connection be filed under the right network.

Two networks are treated as the same one when they share a provider and a router address. Wi-Fi and Ethernet on the same router are one network; the connection type is recorded per result instead.

What is deliberately *not* used:

- **Wi-Fi network names (SSID)** need Location permission on both macOS and iOS. RouterWatch does not ask for location, so it does not read them.
- **Router hardware (MAC) addresses** are hidden from third-party apps. `netstat` can show them only through a private Apple entitlement.

The practical limit: two different networks that use the same provider *and* the same router address — 192.168.1.1 is very common — look identical. Rename networks in the Networks tab to tell them apart; the name you give sticks.

During an outage the provider cannot be looked up, so the router address alone decides. With no network at all, the result is filed under the network the device was last on.

### Keeping networks from overwriting each other

A result is only ever written to the log of the network it was measured on:

- **Network is identified at the start of a test and checked again at the end.** A test can take a minute. If the device moved to a different router in between, even briefly (home to a phone hotspot and back), the result is thrown away and the new network is tested cleanly. Dropping off and rejoining the *same* router does not count as a change.
- **Deleting a network mid-test** discards that test rather than writing into a folder that was just removed.
- **The first test at launch waits for the router to be known.** Earlier builds could identify the network a moment too early and create a duplicate with no router address. Such duplicates are merged back into the real network at launch, but only when exactly one network shares their ISP; ambiguous cases are left for you to sort out.
- **One test at a time.** A second request (the iOS background task firing mid-test, say) waits for the test already running.
- **One copy of the app at a time (Mac).** Two copies would each hold a network's log in memory and overwrite each other's saves. A second copy hands over to the one already running and exits before loading anything.
- **Unit tests don't touch real data.** The app skips monitoring when it is hosting tests.

### Earlier results

Measurements recorded before networks were tracked move into a separate "Earlier results" network. They are never merged into a live network by guesswork. If an older build recreates the single log, its rows are merged in rather than replacing what was already migrated.

## Platform behaviour

| | macOS | iOS / iPadOS | tvOS |
|---|---|---|---|
| Continuous schedule | Yes, all day | While open | While open |
| Background tests | Keeps running with window closed | Best effort (`BGProcessingTask`) | No |
| Menu bar item | Yes | — | — |
| Launch at login | Yes (`SMAppService`) | — | — |
| Failure notifications | Yes | Yes | No (tvOS has no local notifications) |
| Export CSV | Save panel | Share sheet | — |
| Per-network logs | Yes | Yes | Yes |

iOS doesn't let apps run a speed test every 15 minutes in the background. The system decides when background tasks run, usually while the device is charging. The app explains this in its Settings.

## Code layout

```
RouterWatch/
  App/           App entry point, scenes, AppDelegate, object graph
  Models/        ErrorKind (classification), ProbeResult, TestEndpoint, MonitorStats,
                 NetworkProfile + NetworkMatcher (which network is this?)
  Services/      TransferMeter, SpeedTestEngine, MonitorController (schedule),
                 NetworkPathMonitor, NotificationService, ExportService,
                 LoginItemManager (macOS), BackgroundRefreshCoordinator (iOS),
                 NetworkIdentifier (ISP lookup)
  Persistence/   SettingsStore (UserDefaults), MeasurementStore (one network's log),
                 NetworkLibrary (the networks and their separate logs)
  Views/         Dashboard, ErrorBreakdown (bar chart), Log, Networks, Settings,
                 MenuBarContent
  Resources/     Info.plists, entitlements, PrivacyInfo.xcprivacy, Assets.xcassets
RouterWatchTests/
Tools/GenerateIcons.swift
```

## Before submitting to the App Store

Already handled in the project:

- App Sandbox with network-client and user-selected-file entitlements, plus hardened runtime (macOS)
- `PrivacyInfo.xcprivacy`: no tracking, no data collected, and a declared reason for using UserDefaults
- Launch at login is off until the user turns it on (guideline 2.4.5)
- HTTPS only, with no App Transport Security exceptions
- Icons for all three platforms, including the tvOS layered icon, Top Shelf images, and launch image. The artwork is original because Apple's license doesn't allow SF Symbols in app icons.
- The build number comes from `CURRENT_PROJECT_VERSION`

Still to do:

1. **Test endpoint.** The default uses Cloudflare's public speed-test paths (`speed.cloudflare.com/__down` and `__up`). Many tools use them, but they aren't a documented or supported API. For a paid or widely used app, host your own endpoint (a Cloudflare Worker or any CDN-backed file) and add it to `TestEndpoint.presets`.
2. **App Store Connect:** create the app record and select macOS, iOS, and tvOS so all three share one bundle ID. The privacy label is **Data Not Collected**.
3. **Review notes:** explain that the app deliberately uses bandwidth for speed tests, and that background use on iOS is limited to `BGProcessingTask`.
4. **Screenshots** for each platform.
5. **Real-device testing** on iPhone and Apple TV. The simulator has no background task scheduler.
6. **Final artwork** if you want something more polished than the generated icon.
