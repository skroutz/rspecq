require "test_helpers"

class TestTags < RSpecQTest
  def test_inclusion_filter
    queue = exec_build("tagged_suite", "--tag=slow")

    assert_processed_jobs [
      "./spec/tagged_spec.rb",
    ], queue

    assert_equal 1, queue.example_count
  end

  def test_exclusion_filter
    queue = exec_build("tagged_suite", "--tag=~slow")

    assert_equal 2, queue.example_count
  end

  def test_mixed_filter
    queue = exec_build("tagged_suite", "--tag=~slow --tag=~fast")

    assert_equal 1, queue.example_count
  end
end
