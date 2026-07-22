require "test_helper"
require "json"

class PrinterStateTest < Minitest::Test
  def fixture(name)
    JSON.parse(File.read(File.expand_path("fixtures/#{name}.json", __dir__)))
  end

  def printing
    Chituview::PrinterState.from_status(fixture("status_printing"))
  end

  def test_parses_core_fields
    s = printing
    assert_equal "bison - rays.ctb", s.filename
    assert_equal 1514, s.current_layer
    assert_equal 1697, s.total_layer
    assert_equal 0, s.error_number
    refute s.error?
    assert s.active?
    assert s.printing?
  end

  def test_progress_is_layer_ratio
    assert_in_delta 1514.0 / 1697.0, printing.progress, 0.0001
  end

  def test_time_from_ticks_in_milliseconds
    s = printing
    assert_equal 16852, s.elapsed_seconds
    assert_equal (18818950 - 16852229) / 1000, s.remaining_seconds
    assert_equal "4h 40m", s.elapsed_human
    assert_equal "32m", s.remaining_human
  end

  def test_status_label_printing
    assert_equal "printing", printing.status_label
  end

  def test_complete_fixture
    s = Chituview::PrinterState.from_status(fixture("status_complete"))
    assert_equal "complete", s.status_label
    assert_in_delta 1.0, s.progress, 0.0001
    refute s.printing?
  end

  def test_error_state
    raw = fixture("status_printing")
    raw["Status"]["PrintInfo"]["ErrorNumber"] = 5
    s = Chituview::PrinterState.from_status(raw)
    assert s.error?
    assert_equal 5, s.error_number
    assert_equal "error", s.status_label
  end

  def test_empty_state_is_idle_and_safe
    s = Chituview::PrinterState.empty
    refute s.active?
    assert_equal "idle", s.status_label
    assert_equal 0.0, s.progress
    assert_equal "", s.filename
    assert_equal "0m", s.elapsed_human
  end
end
