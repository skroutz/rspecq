require "test_helpers"

class TestReporter < RSpecQTest
  def test_passing_suite
    build_id = rand_id
    exec_build("passing_suite", "", build_id: build_id)
    output = exec_reporter(build_id: build_id)

    assert_match "Total results", output
    assert_match "1 examples (1 jobs)", output
    assert_match "0 failures", output
    assert_match "Spec time", output
    refute_match "Failed examples", output
    refute_match "Flaky", output
  end

  def test_failing_suite
    build_id = rand_id
    exec_build("failing_suite", "--seed 1234", build_id: build_id)
    output = exec_reporter(build_id: build_id)

    assert_match "Failed examples", output
    assert_match "bin/rspec --seed 1234 ./spec/fail_1_spec.rb:3", output
    refute_match "Flaky", output
  end

  def test_flakey_suite
    build_id = rand_id
    worker_id = rand_id
    exec_build("flakey_suite", "--seed 1234", build_id: build_id, worker_id: worker_id)
    output = exec_reporter(build_id: build_id)

    assert_match "Flaky jobs detected", output
    assert_match "./spec/foo_spec.rb:2 @ #{worker_id}", output
    assert_match "DISABLE_SPRING=1 DISABLE_BOOTSNAP=1 bin/rspecq --build 1 " \
        "--worker foo --seed 1234 --max-requeues 0 --fail-fast 1 --reproduction " \
        "./spec/foo_spec.rb ./spec/foo_spec.rb[1:1] ./spec/foo_spec.rb[1:1]", output
    refute_match "Failed examples", output
  end
end
