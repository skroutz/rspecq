# RSpecQ

RSpecQ (RSpec Queue) distributes and executes RSpec suites among parallel
workers. It uses a centralized queue that workers connect to and pop off
tests from. It ensures optimal scheduling of tests based on their run time,
facilitating faster CI builds.

RSpecQ is heavily inspired by [test-queue](https://github.com/tmm1/test-queue)
and even more by [ci-queue](https://github.com/Shopify/ci-queue).

## Usage

Each worker needs to be given the build it will participate in, a name and the
Redis hostname. To start a worker:

```shell
$ rspecq --build=123 --worker=foo1 --redis=localhost spec
```

To view the progress of the build use `--report`:

```shell
$ rspecq --build=123 --redis=localhost --report
```

For detailed info use `--help`:

```
NAME:
    rspecq - Optimally distribute and run RSpec suites among parallel workers

USAGE:
    rspecq [<options>] [spec files or directories]

OPTIONS:
    -b, --build ID                   A unique identifier denoting the CI build
    -w, --worker ID                  A unique identifier for this worker
    -r, --redis HOST                 Redis host to connect to (default: 127.0.0.1)
        --update-timings             Update the global job timings key based on the timings of this build
        --file-split-threshold N     Split spec files slower than N seconds and schedule them as individual examples
        --report                     Enable reporter mode: do not pull tests off the queue; instead print build progress and exit when it's finished.
                                     Exits with a non-zero status code if there were any failures
        --report-timeout N           Fail if build is not finished after N seconds. Only applicable if --report is enabled (default: 3600)
    -h, --help                       Show this message
    -v, --version                    Print the version and exit
```


## How it works

The core design is identical to ci-queue so please refer to its
[README](https://github.com/Shopify/ci-queue/blob/master/README.md) instead.

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
and the job it reserved will be requeued, so that it is picked up by another
worker.

This protects us against unrecoverable worker failures
(e.g. a segmentation fault in MRI).

## Rationale

### Why didn't you use ci-queue?

**Update**: ci-queue [deprecated support for RSpec](https://github.com/Shopify/ci-queue/pull/149).

While evaluating ci-queue for our RSpec suite, we experienced slow worker boot
times (up to 3 minutes in some cases) combined with disk saturation and
increased memory consumption. This is due to the fact that a worker in
ci-queue has to
load every spec file on boot. In applications with large number of spec
files this may result in a significant performance hit and, in case of cloud
environments, increased usage billings.

RSpecQ works with spec files as its unit of work (as opposed to ci-queue which
works with individual examples). This means that an RSpecQ worker only loads a
file when it's needed and each worker only loads a subset of all files.
Additionally this allows suites to keep using `before(:all)` hooks
(which ci-queue explicitly rejects). (Note: RSpecQ also schedules individual
examples, but only when this is deemed necessary, see section
"Spec file splitting").

We also observed faster build times by scheduling spec files instead of
individual examples, probably due to decreased Redis operations.

The downside of this design is that it's more complicated, since the scheduling
of spec files happens based on timings calculated from previous runs. This
means that RSpecQ maintains a key with the timing of each job and updates it
on every run (if the `--timings` option was used). Also, RSpecQ has a "slow
file threshold" which, currently has to be set manually (but this can be
improved).


## Development

First install the required development/runtime dependencies:

```
$ bundle install
```

Then you can execute the tests after spinning up a Redis instance at
127.0.0.1:6379:

```
$ bundle exec rake
```


## License

RSpecQ is licensed under MIT. See [LICENSE](LICENSE).
