# Executive Summary

We surveyed leading Flutter packages for durable event delivery and analytics.  Key candidates include **Evently/Evently Plus**, **FlexTrack**, **Flutter Analytics Manager**, and **Baseerh SDK**.  Each provides some form of persistent queueing, batching, and offline support, though with varying scope and maturity.  For example, *Evently Plus* (MIT-licensed) uses a file-backed queue (via `SharedPreferences`) and Android WorkManager/iOS background tasks for “background-only” uploads. *FlexTrack* (also MIT) is an analytics orchestrator that lets you supply a `FileEventQueue`; it assigns each event a UUID and queues failures for later retry. *Flutter Analytics Manager* provides offline queuing and sync-on-reconnect for Firebase/Mixpanel targets. *Baseerh SDK* (MIT) is a full analytics/engagement SDK that buffers events (in `SharedPreferences`), batches to its backend, uses exponential backoff, drops oldest on overflow, and automatically pauses/resumes with connectivity. We compare these and other solutions below.

Overall, **gaps remain**. Most packages lack end-to-end background scheduling on both platforms and fine-grained control (e.g. immediate vs batched priorities).  None offer built-in encryption or comprehensive consent/opt-out APIs.  We propose our library address these gaps with features like native WorkManager/BGTask integration, configurable encryption-at-rest, user opt-in/out toggles, priority tiers, pluggable transports, and diagnostic tooling.  A conceptual sequence of our event flow (generate ➔ persist ➔ (immediate/upload or queue) ➔ native flush ➔ ACK ➔ delete) is shown in the Mermaid diagram at the end. 

# Packages Overview

- **Evently Plus** (v2.1.1, 2026-08-01) – Flutter event-tracking SDK with persistent local queue and *background-only* uploads.  Supports Android WorkManager and iOS BG processing. (Likes: 1; Pub points: 150; MIT license; 39 weekly downloads).  
- **Evently** (v2.0.1, 2026) – The precursor to Evently Plus. Provides offline queueing, automatic batching, exponential retry logic, and error handling. (MIT; GitHub-driven, not on pub.dev; older but foundational).  
- **FlexTrack** (v2.2.0, 2026-09-05) – Analytics orchestration library. Centralizes event routing to multiple trackers; supports file-based event queuing and selective retry. (Likes: 7; Pub points: 150; MIT; 181 downloads).  
- **Flutter Analytics Manager** (v1.0.1, 2025-10-10) – Multi-service analytics wrapper for Firebase, Mixpanel, etc.  Features offline queuing (holds events offline, syncs on reconnect) and efficient batching. (Likes: 0; Pub points: 150; MIT; 30 downloads).  
- **Baseerh SDK** (v0.1.0, 2025) – Flutter SDK for product analytics & engagement (analytics, feature flags, push, consent). Buffers events in `SharedPreferences`, batches to `/v1/batch`, auto-retries with backoff, drops oldest on overflow, pauses offline. (Likes: 0; Pub points: 150; MIT; 52 downloads).  
- **Flutter Umami Integration** (v0.x, 2024) – Widgets/Credentials for Umami analytics. Tracks pageviews and custom events. *(No built-in offline queue; purely HTTP API usage.)*  
- **Firebase Analytics** (Google’s) – Built-in offline buffering by the SDK, but not a Flutter-managed queue package. Used as a tracking backend (beyond our library’s scope).

Each package varies in scope: some (Evently, Baseerh) are full-featured analytics SDKs, others (FlexTrack) focus on orchestration.  Almost all use `SharedPreferences` or file storage for queues and claim offline persistence.  None natively encrypt stored events or provide user opt-out toggles; these are responsibilities of the host app or higher-level logic.

# Feature Support per Package

| Feature                        | Evently / Evently Plus              | FlexTrack                           | Flutter Analytics Mgr      | Baseerh SDK                   | Our Planned Library (proposal) |
|--------------------------------|-------------------------------------|-------------------------------------|----------------------------|-------------------------------|--------------------------------|
| **Persistent Storage**         | Yes; uses `SharedPreferences` (or file)  | Yes; supports file-backed queue (e.g. JSON file)  | Yes; queues events (likely in memory or simple store)  | Yes; uses `SharedPreferences` for event buffer  | Yes; abstracted store (e.g. SQLite/Realm/Hive)                |
| **Batching**                   | Configurable batch size/interval  | Manual or bound batching via `flush()` (limit)  | Likely yes; “throttling mechanisms” noted  | Configurable `flushAt` (20) and `flushInterval` (30s) | Yes; configurable batch-size and interval settings         |
| **Retry/Backoff**              | Exponential backoff on failures  | Yes; retries stored events on next flush  | Yes; implied by robust error handling  | Yes; exponential backoff, honors HTTP 429/Retry-After  | Yes; flexible retry policy (exponential, with backoff)     |
| **Offline Support**            | Yes; stores until network returns  | Yes; if offline, events queue up  | Yes; explicitly “queue when offline, sync on online”  | Yes; pauses on offline, resumes on reconnect  | Yes; fully offline-first with connectivity monitoring      |
| **Background Exec (Android)**  | Yes; uses WorkManager (no extra setup)  | No built-in platform scheduling (developer must flush)  | Likely not; expects foreground integration  | No explicit WorkManager (uses connectivity listener)  | Yes; fully integrated with WorkManager for flushing        |
| **Background Exec (iOS)**      | Yes; BGTask/“processing” mode (require AppDelegate config)  | No; relies on manual flush or foreground  | No; iOS flush not built-in  | No; relies on connectivity  | Yes; integrated with BGTaskScheduler (Info.plist config)  |
| **Immediate Events**           | No; all events go into queue first  | Yes; `flush()` can be called anytime  | Possibly via manual `flush()`  | Yes; app can call `flush()` manually  | Yes; support high/normal priorities: immediate vs queued   |
| **Idempotency/Event IDs**      | Yes; each event has UUID; backend dedupe expected  | Yes; assigns immutable UUID per event  | Not explicit; likely not (depends on trackers)  | Implicit – events have unique IDs in queue  | Yes; assign event IDs and encourage idempotent API design |
| **Pluggable Transport**        | Consumer provides endpoint/headers  | Yes; you write tracker strategies for different backends  | Yes; supports multiple services via DI  | No; fixed to Baseerh APIs  | Yes; abstract `EventTransport` (user-provided backend)    |
| **Encryption at Rest**         | No; data in SharedPrefs (unencrypted)  | Not built-in  | Not mentioned; likely no  | Not mentioned  | Optional; support encrypting local queue if configured     |
| **Configurable Retention/TTL**| No (other than dropping overflow)  | No (only flush thresholds)  | No  | Drop-oldest on overflow; no TTL  | Yes; configurable max queue size/age, purge policies       |
| **Max Queue Size**             | Configurable `maxOfflineEvents` (1000)  | Limited by storage (no explicit cap)  | Not obvious  | Configurable (`maxQueueSize`)  | Yes; configurable cap with drop-oldest or block options   |
| **API (Track/Flush/Init)**     | Simple: `initialize()`, `logEvent()`, `flush()`, etc.  | Via `FlexTrackClient.track()` and `flush()`  | Via dependency-injected `trackEvent()` calls  | Methods: `setup()`, `capture()/identify()`, `flush()`, etc.  | Simple: `initialize(config)`, `track(name, properties)`, `flush()`, etc. |
| **Consent/Opt-Out**           | No built-in; app must handle  | Yes; respects event flags (consent/Pii blocking)  | Yes; PII/GDPR filters built-in  | Yes; PDPL consent toggles (optIn/optOut) in API  | Yes; support opt-in/out toggles (consent APIs)           |
| **Diagnostics/Logging**        | Yes; structured logs available  | Yes; has debugging + inspector tools  | Yes; built-in logging (e.g. AppLogger)  | Yes; debug mode & error callbacks  | Yes; pluggable logging for verbose/tracing                |
| **Maturity / Maintenance**     | Active (new v2.x); moderate adoption (1 like)  | Actively maintained; growing adoption (7 likes)  | Initial release (v1.0); needs more attention (0 likes)  | Early stage (v0.x); in-house product  | Planned (TBD); aim for robust tests and docs             |

**Per-package notes:**

- **Evently/Evently Plus**: Mature SDK (v2.x) with clear architecture. Offers batching and offline queueing with Good defaults and background scheduling built in. Lacks encryption and consent features out of box. MIT license, good test coverage. 

- **FlexTrack**: Emphasizes *flexible routing* to multiple trackers (Firebase, Mixpanel, etc.). Provides offline persistence via a file queue you supply. Strong on analytics policy (consent flags, high-volume flags), but *no built-in background scheduler*. More for advanced use (you write adapter strategies).

- **Flutter Analytics Manager**: Focused on abstracting Firebase/Mixpanel. Promises offline queueing and throttling. Its config API (builders, DI) is modern, but it’s new and unproven in the wild (just v1.0, 0 likes). Does include PII filtering and logging.

- **Baseerh SDK**: A vertical product SDK (like Braze). It has a robust queueing system: shared_prefs buffer, batch POSTs, backoff, overflow policies, connectivity handling. Also supports PDPL-compliant consent (opt-in/out) in code. Not open-source (closed repo) but pub-listed.

- **Umami Integration**: Simple analytics connector. Auto-captures navigation, sends events. *No offline buffering or background scheduling* – it calls Umami’s REST API immediately. Good for websites, but limited for mobile reliability.

- **Firebase Analytics**: The gold standard mobile analytics. The Flutter plugin does queue events offline internally and send in bursts, but it’s fully managed by Firebase; you have no control over batch size or manual flush. We include it for context (many apps use it), but it doesn’t meet our “durable client-side queue” criteria.

# Comparison Table

| **Feature**               | **Proposed Library**    | **Evently Plus**            | **FlexTrack**           | **Flutter Anlg Mgr.**        | **Baseerh SDK**           |
|---------------------------|-------------------------|-----------------------------|-------------------------|-----------------------------|--------------------------|
| **Storage Backend**       | Configurable (Hive/SQLite) | SharedPreferences            | File (JSON via dart:io) | (Not specified)            | SharedPreferences       |
| **Batching**              | Yes (size & time)       | Yes (configured batchInterval) | Yes (manual flush)     | Yes                        | Yes (flushAt, interval)  |
| **Retry Policy**          | Customizable (exp backoff) | Exponential backoff         | FIFO retry per flush   | Implicit (retry logic)     | Exponential backoff      |
| **Offline Support**       | Full offline-first      | Yes                        | Yes                     | Yes                        | Yes                      |
| **Android Background**    | WorkManager (network-bound) | Yes (WorkManager)           | No (manual/app-trigger) | No automatic              | No (depends on app)      |
| **iOS Background**        | BGTaskScheduler         | Yes (BG Processing)        | No                      | No                        | No                       |
| **Immediate Priority**    | Yes (priority queue)    | No (queue-only)            | No (only flush)        | No (queue only)           | No (queue only)         |
| **Event IDs**             | Yes (UUIDs)            | Yes (UUID)                 | Yes (UUID)              | No explicit               | Implicit (no UI)        |
| **Pluggable Destinations**| Fully (custom transports) | Yes (endpoint & headers)    | Yes (tracker adapters)  | Yes (multi-service DI)     | No (fixed API)          |
| **Encryption at Rest**    | Optional (configurable)  | No (plain SharedPrefs)      | No                       | No                        | No                       |
| **Retention / TTL**       | Yes (configurable)      | No                         | No                      | No                        | Drop-oldest overflow     |
| **Max Queue Size**        | Yes (configurable cap)  | Configurable cap           | Limited by disk         | Not specified             | Yes (default 1000)      |
| **Consent / Opt-Out**     | Yes (built-in API)      | No (app-level)             | Yes (event flags)       | Yes (GDPR/PII filters)     | Yes (optIn/optOut APIs)  |
| **Logging / Debug**       | Yes (pluggable logger)  | Yes (structured logging)   | Yes (debug tools)       | Yes (logging integration)  | Yes (debug mode flag)    |
| **Testing**               | Planned (mockable)      | Yes (unit tests)           | Partial                 | Yes (test-friendly design) | Yes (some tests)        |
| **License**               | MIT or BSD             | MIT                        | MIT                     | MIT                       | MIT                      |
| **Maintenance**           | N/A (new project)      | Active (v2.x)             | Active (v2.x)          | New (v1.0)               | Early (v0.x)           |

# Gaps & Proposed Differentiators

Our planned library can stand out by addressing limitations in existing solutions:

- **Native Background Scheduling (Android & iOS):** Use Android WorkManager **and** iOS BGTaskScheduler out-of-the-box for flush jobs. Many current packages lack true background upload on one or both platforms. We’ll include sample native code and docs so tasks reliably run when connectivity allows (while respecting OS constraints).

- **Priority-Tiered Delivery:** Offer both *normal* (batched) and *immediate* (high-priority) events. Instead of a single queue, implement multi-priority queues. High-priority events (e.g. purchases) are flushed immediately after persisting, while others wait for scheduled/automatic batch flushes.

- **Configurable Encryption:** Support optional local encryption (e.g. AES) of the event queue. This is critical if events may contain sensitive info. The library can accept an encryption key/provider to secure stored payloads, something other packages do not provide.

- **Consent / Opt-Out API:** Provide built-in enable/disable toggles (e.g. `setEnabled(bool)`) and automatically purge or hold events on opt-out. Unlike others, we’ll make privacy controls first-class. The library user can disable tracking (e.g. under GDPR/ATT), which halts new event capture and optionally clears existing queue.

- **Pluggable Transports:** Design an abstract `EventTransport` interface (or plugin system). This lets developers define how events are sent (REST client, GraphQL, different analytics backends). Out-of-box we can include one for JSON/HTTP. This keeps the core agnostic.

- **Configurable Retention & Overflow Policies:** Allow setting max queue size, event TTL, and overflow behavior (drop oldest or block new). For apps that may accumulate events offline, this prevents unbounded growth.

- **Rich Diagnostics & Telemetry:** Similar to FlexTrack’s inspector or Evently’s logging, include verbose/debug logging (ideally customizable per-level), plus events like upload success/failure callbacks, and optional telemetry (e.g. total events sent, drop rate). A debug “inspector” mode could let devs see pending queue or last request.

- **Test Harness / Mocking:** Provide utilities (or docs) to simulate offline/online conditions, mock the background scheduler, and unit-test tracking flows. This ensures correctness under failure modes. We can include example tests (like Evently does) and maybe a “test mode” that disables actual network.

- **Simplicity & Minimal Footprint:** While feature-rich, the public API should remain simple (e.g. `initialize()`, `track()`, `flush()`, `setEnabled()`). We avoid heavy dependencies; for example, use a light-weight local database (Hive or SQLite) rather than forcing a large DB. 

**Proposed Event Flow (Mermaid):**

```mermaid
sequenceDiagram
    participant App as Flutter App
    participant Queue as Local Persistent Queue
    participant Android as Android WorkManager
    participant iOS as iOS BGTask
    participant Server as Backend API

    App->>Queue: track(event)
    Note right of Queue: Persist event (with id, timestamp)
    App-->>App: (immediate?) if high-priority
    alt Immediate event
        App->>Server: HTTP POST (immediate batch)
        Server-->>App: ACK
        App->>Queue: remove(event) on success
    else Queued event
        App-->>Queue: end
    end

    alt App backgrounded or periodic interval
        Note left of Android: Android Worker triggers
        Android->>Queue: read pending events batch
        Android->>Server: POST batch
        Server-->>Android: ACK
        Android->>Queue: remove(successful)
    or iOS wakes:
        iOS->>Queue: read pending events batch
        iOS->>Server: POST batch
        Server-->>iOS: ACK
        iOS->>Queue: remove(successful)
    end
```

This shows our library capturing an event, persisting it, optionally sending immediately, or batching via native schedulers, then acknowledging and cleaning up the queue.  

**Sources:** Package READMEs and documentation (Evently Plus; FlexTrack; Flutter Analytics Manager; Baseerh SDK) were used to compare features. Each quote above corresponds to those sources, illustrating their current capabilities.