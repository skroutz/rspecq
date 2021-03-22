# Changelog

Breaking changes are prefixed with a "[BREAKING]" label.

## master (unreleased)

- New cli parameter `seed`.
  The seed is passed to the RSpec command.

## 0.5.0 (2021-02-05)

### Added

- New cli parameter `queue_wait_timeout`.
  It configured the time a queue can wait to be ready. The env equivalent
  is `RSPECQ_QUEUE_WAIT_TIMEOUT`. [#51](https://github.com/skroutz/rspecq/pull/51)

## 0.4.0 (2020-10-07)

### Added

- Builds can be configured to terminate after a specified number of failures,
  using the `--fail-fast` option.


## 0.3.0 (2020-10-05)

### Added

- Providing a Redis URL is now possible using the `--redis-url` option
  [[#40](https://github.com/skroutz/rspecq/pull/40)]

### Changed

- [DEPRECATION] The `--redis` option is now deprecated. Use `--redis-host`
  instead [[#40](https://github.com/skroutz/rspecq/pull/40)]

## 0.2.2 (2020-09-10)

### Fixed
- Worker would fail if application code was writing to stderr
 [[#35](https://github.com/skroutz/rspecq/pull/35)]

## 0.2.1 (2020-09-09)

### Changed

- Sentry Integration: Changed the way events for flaky jobs are emitted to a
  per-flaky-job fashion. This ultimately improves grouping and filtering of the
  flaky events in Sentry [[#33](https://github.com/skroutz/rspecq/pull/33)]


## 0.2.0 (2020-08-31)

This is a feature release with no breaking changes.

### Added

- Flaky jobs are now printed by the reporter in the final build output and also
  emitted to Sentry (if the integration is enabled) [[#26](https://github.com/skroutz/rspecq/pull/26)]

## 0.1.0 (2020-08-27)

### Added

- Sentry integration for various RSpecQ-level events [[#16](https://github.com/skroutz/rspecq/pull/16)]
- CLI: Flags can now be also set environment variables [[c519230](https://github.com/skroutz/rspecq/commit/c5192303e229f361e8ac86ae449b4ea84d42e022)]
- CLI: Added shorthand specifiers versions for some flags [[df9faa8](https://github.com/skroutz/rspecq/commit/df9faa8ec6721af8357cfee4de6a2fe7b32070fc)]
- CLI: Added `--help` and `--version` flags [[df9faa8](https://github.com/skroutz/rspecq/commit/df9faa8ec6721af8357cfee4de6a2fe7b32070fc)]
- CLI: Max number of retries for failed examples is now configurable via the `--max-requeues` option [[#14](https://github.com/skroutz/rspecq/pull/14)]

### Changed

- [BREAKING] CLI: Renamed `--timings` to `--update-timings` [[c519230](https://github.com/skroutz/rspecq/commit/c5192303e229f361e8ac86ae449b4ea84d42e022)]
- [BREAKING] CLI: Renamed `--build-id` to `--build` and `--worker-id` to `--worker` [[df9faa8](https://github.com/skroutz/rspecq/commit/df9faa8ec6721af8357cfee4de6a2fe7b32070fc)]
- CLI: `--worker` is not required when `--reporter` is used [[4323a75](https://github.com/skroutz/rspecq/commit/4323a75ca357274069d02ba9fb51cdebb04e0be4)]
- CLI: Improved help output [[df9faa8](https://github.com/skroutz/rspecq/commit/df9faa8ec6721af8357cfee4de6a2fe7b32070fc)]
