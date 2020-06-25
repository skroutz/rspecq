# RSpecQ

RSpecQ (`rspecq`) distributes and executes an RSpec suite over many workers,
using a centralized queue backed by Redis.

RSpecQ is heavily inspired by [test-queue](https://github.com/tmm1/test-queue)
and [ci-queue](https://github.com/Shopify/ci-queue).

## Why don't you just use ci-queue?

While evaluating ci-queue for our RSpec suite, we observed slow boot times
in the workers (up to 3 minutes), increased memory consumption and too much
disk I/O on boot. This is due to the fact that a worker in ci-queue has to
load every spec file on boot. This can be problematic for applications with
a large number of spec files.

RSpecQ works with spec files as its unit of work (as opposed to ci-queue which
works with individual examples). This means that an RSpecQ worker does not
have to load all spec files at once and so it doesn't have the aforementioned
problems. It also allows suites to keep using `before(:all)` hooks
(which ci-queue explicitly rejects). (Note: RSpecQ also schedules individual
examples, but only when this is deemed necessary, see section
"Spec file splitting").

We also observed faster build times by scheduling spec files instead of
individual examples, due to way less Redis operations.

The downside of this design is that it's more complicated, since the scheduling
of spec files happens based on timings calculated from previous runs. This
means that RSpecQ maintains a key with the timing of each job and updates it
on every run (if the `--timings` option was used). Also, RSpecQ has a "slow
file threshold" which, currently has to be set manually (but this can be
improved).

*Update*: ci-queue deprecated support for RSpec, so there's that.

## Usage

Each worker needs to know the build it will participate in, its name and where
Redis is located. To start a worker:

```shell
$ rspecq --build-id=foo --worker-id=worker1 --redis=redis://localhost
```

To view the progress of the build print use `--report`:

```shell
$ rspecq --build-id=foo --worker-id=reporter --redis=redis://localhost --report
```

For detailed info use `--help`.


## How it works

The basic idea is identical to ci-queue so please refer to its README

### Terminology

- Job: the smallest unit of work, which is usually a spec file
  (e.g. `./spec/models/foo_spec.rb`) but can also be an individual example
  (e.g. `./spec/models/foo_spec.rb[1:2:1]`) if the file is too slow
- Queue: a collection of Redis-backed structures that hold all the necessary
  information for RSpecQ to function. This includes timing statistics, jobs to
  be executed, the failure reports, requeueing statistics and more.
- Worker: a process that, given a build id, pops up jobs of that build and
  executes them using RSpec
- Reporter: a process that, given a build id, waits for the build to finish
  and prints the summary report (examples executed, build result, failures etc.)

### Spec file splitting

Very slow files may put a limit to how fast the suite can execute. For example,
a worker may spend 10 minutes running a single slow file, while all the other
workers finish after 8 minutes. To overcome this issue, rspecq splits
files that their execution time is above a certain threshold
(set with the `--file-split-threshold` option) and will instead schedule them as
individual examples.

In the future, we'd like for the slow threshold to be calculated and set
dynamically.

### Requeues

As a mitigation measure for flaky tests, if an example fails it will be put
back to the queue to be picked up by
another worker. This will be repeated up to a certain number of times before,
after which the example will be considered a legit failure and will be printed
in the final report (`--report`).

### Worker failures

Workers emit a timestamp after each example, as a heartbeat, to denote
that they're fine and performing jobs. If a worker hasn't reported for
a given amount of time (see `WORKER_LIVENESS_SEC`) it is considered dead
and the job it reserved will be requeued, so that it is picked up by another worker.

This protects us against unrecoverable worker failures (e.g. segfault).

## License

RSpecQ is licensed under MIT. See [LICENSE](LICENSE).
