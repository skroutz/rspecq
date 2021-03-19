require "test_helpers"

class TestReporter < RSpecQTest
  def test_passing_suite
    build_id = rand_id
    exec_build("passing_suite", "", build_id: build_id)
    output = exec_reporter(build_id: build_id)

    assert_match "Total results", output
    assert_match "1 examples (1 jobs)", output
    assert_match "0 failures", output
    assert_match "execution time", output
    refute_match "Failed examples", output
    refute_match "Flaky", output
  end

  def test_failing_suite
    build_id = rand_id
    exec_build("failing_suite", "", build_id: build_id)
    output = exec_reporter(build_id: build_id)

    assert_match "Failed examples", output
    assert_match "bin/rspec ./spec/fail_1_spec.rb:3", output
    refute_match "Flaky", output
  end

  def test_flakey_suite
    build_id = rand_id
    exec_build("flakey_suite", "", build_id: build_id)
    output = exec_reporter(build_id: build_id)

    assert_match "Flaky jobs detected", output
    assert_match "./spec/foo_spec.rb[1:1]", output
    refute_match "Failed examples", output
  end
end
