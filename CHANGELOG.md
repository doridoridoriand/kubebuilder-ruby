# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
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
