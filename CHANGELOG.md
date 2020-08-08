# Changelog

Breaking changes are prefixed with a "[BREAKING]" label.

## master (unreleased)

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
