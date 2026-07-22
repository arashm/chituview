require "test_helper"

class CliTest < Minitest::Test
  def test_parse_positional_ip
    opts = Chituview::CLI.parse(["192.168.50.133"])
    assert_equal "192.168.50.133", opts.ip
    refute opts.discover
  end

  def test_parse_discover_flag
    opts = Chituview::CLI.parse(["--discover"])
    assert opts.discover
    assert_nil opts.ip
  end

  def test_parse_timeout
    opts = Chituview::CLI.parse(["--timeout", "5", "10.0.0.2"])
    assert_equal 5.0, opts.timeout
    assert_equal "10.0.0.2", opts.ip
  end

  def test_parse_help_and_version
    assert Chituview::CLI.parse(["--help"]).help
    assert Chituview::CLI.parse(["--version"]).version
  end
end
