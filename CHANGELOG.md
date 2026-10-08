# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
