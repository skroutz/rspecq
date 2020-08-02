RSpec Queue
=========================================================================
[![Build Status](https://travis-ci.com/skroutz/rspecq.svg?branch=master)](https://travis-ci.com/github/skroutz/rspecq)
[![Gem Version](https://badge.fury.io/rb/rspecq.svg)](https://badge.fury.io/rb/rspecq)

RSpec Queue (RSpecQ) distributes and executes RSpec suites among parallel
workers. It uses a centralized queue that workers connect to and pop off
tests from. It ensures optimal scheduling of tests based on their run time,
facilitating faster CI builds.

RSpecQ is inspired by [test-queue](https://github.com/tmm1/test-queue)
and [ci-queue](https://github.com/Shopify/ci-queue).

## Usage

A worker needs to be given a name and the build it will participate in.
Assuming there's a Redis instance listening at `localhost`, starting a worker
is as simple as:

```shell
$ rspecq --build=123 --worker=foo1 spec/
```

To start more workers for the same build, use distinct worker IDs but the same
build ID:

```shell
$ rspecq --build=123 --worker=foo2
```

To view the progress of the build use `--report`:

```shell
$ rspecq --build=123 --report
```

For detailed info use `--help`:

```
NAME:
    rspecq - Optimally distribute and run RSpec suites among parallel workers

USAGE:
    rspecq [<options>] [spec files or directories]

OPTIONS:
    -b, --build ID                   A unique identifier for the build. Should be common among workers participating in the same build.
    -w, --worker ID                  An identifier for the worker. Workers participating in the same build should have distinct IDs.
    -r, --redis HOST                 Redis host to connect to (default: 127.0.0.1).
        --update-timings             Update the global job timings key with the timings of this build. Note: This key is used as the basis for job scheduling.
        --file-split-threshold N     Split spec files slower than N seconds and schedule them as individual examples.
        --report                     Enable reporter mode: do not pull tests off the queue; instead print build progress and exit when it's finished.
                                     Exits with a non-zero status code if there were any failures.
        --report-timeout N           Fail if build is not finished after N seconds. Only applicable if --report is enabled (default: 3600).
        --max-requeues N             Retry failed examples up to N times before considering them legit failures (default: 3).
    -h, --help                       Show this message.
    -v, --version                    Print the version and exit.
```


## How it works

The core design is almost identical to ci-queue so please refer to its
[README](https://github.com/Shopify/ci-queue/blob/master/README.md) instead.

### Terminology

- **Job**: the smallest unit of work, which is usually a spec file
  (e.g. `./spec/models/foo_spec.rb`) but can also be an individual example
  (e.g. `./spec/models/foo_spec.rb[1:2:1]`) if the file is too slow.
- **Queue**: a collection of Redis-backed structures that hold all the necessary
  information for an RSpecQ build to run. This includes timing statistics,
  jobs to be executed, the failure reports and more.
- **Build**: a particular test suite run. Each build has its own **Queue**.
- **Worker**: an `rspecq` process that, given a build id, consumes jobs off the
  build's queue and executes them using RSpec
- **Reporter**: an `rspecq` process that, given a build id, waits for the build's
  queue to be drained and prints the build summary report

### Spec file splitting

Particularly slow spec files may set a limit to how fast a build can be.
For example, a single file may need 10 minutes to run while all other
files finish after 8 minutes. This would cause all but one workers to be
sitting idle for 2 minutes.

To overcome this issue, RSpecQ can splits files which their execution time is
above a certain threshold (set with the `--file-split-threshold` option)
and instead schedule them as individual examples.

Note: In the future, we'd like for the slow threshold to be calculated and set
dynamically (see #3).

### Requeues

As a mitigation technique against flaky tests, if an example fails it will be
put back to the queue to be picked up by another worker. This will be repeated
up to a certain number of times (set with the `--max-requeues` option), after 
which the example will be considered a legit failure and printed as such in the 
final report.

### Worker failures

It's not uncommon for CI processes to encounter unrecoverable failures for
various reasons: faulty hardware, network hiccups, segmentation faults in
MRI etc.

For resiliency against such issues, workers emit a heartbeat after each
example they execute, to signal
that they're healthy and performing jobs as expected. If a worker hasn't
emitted a heartbeat for a given amount of time (set by `WORKER_LIVENESS_SEC`)
it is considered dead and its reserved job will be put back to the queue, to
be picked up by another healthy worker.


## Rationale

### Why didn't you use ci-queue?

**Update**: ci-queue [deprecated support for RSpec](https://github.com/Shopify/ci-queue/pull/149).

While evaluating ci-queue we experienced slow worker boot
times (up to 3 minutes in some cases) combined with disk IO saturation and
increased memory consumption. This is due to the fact that a worker in
ci-queue has to load every spec file on boot. In applications with a large
number of spec files this may result in a significant performance hit and
in case of cloud environments, increased costs.

We also observed slower build times compared to our previous solution which
scheduled whole spec files (as opposed to individual examples), due to
big differences in runtimes of individual examples, something common in big
RSpec suites.

We decided for RSpecQ to use whole spec files as its main unit of work (as
opposed to ci-queue which uses individual examples). This means that an RSpecQ
worker only loads the files needed and ends up with a subset of all the suite's
files.  (Note: RSpecQ also schedules individual examples, but only when this is
deemed necessary, see [Spec file splitting](#spec-file-splitting)).

This kept boot and test run times considerably fast. As a side benefit, this
allows suites to keep using `before(:all)` hooks (which ci-queue explicitly
rejects).

The downside of this design is that it's more complicated, since the scheduling
of spec files happens based on timings calculated from previous runs. This
means that RSpecQ maintains a key with the timing of each job and updates it
on every run (if the `--timings` option was used). Also, RSpecQ has a "slow
file threshold" which, currently has to be set manually (but this can be
improved in the future).


## Development

Install the required dependencies:

```
$ bundle install
```

Then you can execute the tests after spinning up a Redis instance at
`127.0.0.1:6379`:

```
$ bundle exec rake
```

To enable verbose output in the tests:

```
$ RSPECQ_DEBUG=1 bundle exec rake
```


## License

RSpecQ is licensed under MIT. See [LICENSE](LICENSE).
