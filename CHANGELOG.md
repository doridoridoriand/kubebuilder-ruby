# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- Informer: watch events are classified — only ADDED/MODIFIED/DELETED reach the store and handlers, BOOKMARK only advances the resourceVersion, a 410 Gone ERROR relists immediately (no backoff) and other ERROR/unknown events never corrupt the RV; the watch stream is now the framework's own `WatchStream` (no automatic reconnection, so a 410 can no longer silently drop the missed event window as kruby's Watch does); failed responses surface Retry-After for the backoff (#45)
- Informer: LIST follows `metadata.continue` across all pages, collecting the whole snapshot before an atomic apply — a mid-page failure leaves the store untouched and the retry starts from page 1; a missing snapshot resourceVersion is rejected instead of blinding the watch; `list_page_size` optionally sets the per-page limit (#45)
- Informer/WatchStream hardened edge cases (#45): a malformed data event (null object, or a nameless payload carrying only a resourceVersion) is logged and ignored instead of advancing the RV to an unkeyable object or crashing in the store; a streamed 429/5xx ERROR carries its `details.retryAfterSeconds` into the backoff (the HTTP Retry-After header is absent on a 200 watch); a body transfer that fails after a 200 response is surfaced as an error rather than a clean close; HTTP 410 responses (not only streamed ERROR events) take the immediate-relist path; and Retry-After accepts both delta-seconds and HTTP-date forms
- Manager: `start` blocks until stop in both leader-election modes; SIGTERM/SIGINT are handled safely (trap handlers only set a flag) and `stop(timeout:)` bounds the reconcile drain evenly across controllers — including the leader-election stop path — returning even when a reconcile does not respond; the thread running `start` returns only after the drain completes (#53)
- Controller: a worker abandoned by a timed-out stop is removed from the worker list and cannot resume on a later generation's reopened queue (per-generation token in the worker loop) (#53)
- WorkQueue: delayed-retry registration validates the closed state and retry lifecycle in the same critical section as the insertion (a shutdown can no longer leave a scheduler thread running on a closed queue or hang its own join); shutdown/reset retire the current scheduler via a per-scheduler stop flag; at most one pending delayed entry per key survives registration, so a superseded deadline never produces a second copy (#57)

### Changed
- Packaging: the gemspec now packages only runtime files (the file glob no longer bundles dotfiles or directories), the redundant `source_code_uri` metadata (identical to the homepage) was removed to drop a `gem build` warning, and a `.ruby-version` (3.4.4) pins the development Ruby for reproducible local/CI runs
- Cache: the store owns an independent deep copy of every object — ingest (add/replace) and outbound (`get`/`list`/handler delivery) both cross a copy boundary, so caller or handler mutations can never rewrite the cache before an API write; `copy: false` opts out per read for hot paths that only inspect the object (#46)
- WorkQueue: delayed retries (`add_after` / `add_rate_limited`) run through a shared per-queue scheduler thread instead of one thread per retry; shutdown/reset free the thread and purge pending entries (#47)
- Manager: reconcile workers start only after the cache is fully synced; handlers register first and initial events replay from the queue (FR-03) (#52)
- Controller: `register` reopens a work queue closed by a previous lifecycle before resync, so the changes observed while leaderless are buffered on reacquisition (#52)

### Added
- Initial project skeleton
- Specification and design documents
- Core types: Request, Result, Reconciler
- WorkQueue (deduplicating FIFO queue)
- SharedCache, Informer, Store (skeleton)
- Event Handlers: EnqueuedObject, EnqueuedOwner
- Controller (reconcile loop skeleton)
- Manager (skeleton)
- Leader Election (skeleton)
- Finalizer, OwnerReference, Status helpers (skeleton)
- CRD Generator (skeleton)
- CLI: `init` and `create api` scaffolding (Phase 3)
