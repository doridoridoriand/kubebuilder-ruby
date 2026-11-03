# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- Manager: `start` blocks until stop in both leader-election modes; SIGTERM/SIGINT are handled safely (trap handlers only set a flag) and `stop(timeout:)` bounds the reconcile drain evenly across controllers — including the leader-election stop path — returning even when a reconcile does not respond; the thread running `start` returns only after the drain completes (#53)
- Controller: a worker abandoned by a timed-out stop is removed from the worker list and cannot resume on a later generation's reopened queue (per-generation token in the worker loop) (#53)

### Changed
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
