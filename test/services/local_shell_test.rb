require "test_helper"

class LocalShellTest < ActiveSupport::TestCase
  test "runs a command, streams output lines, and reports success" do
    lines = []
    result = LocalShell.new.run("bash", "-lc", "echo one; echo two") { |l| lines << l }

    assert result.success?
    assert_equal 0, result.exit_code
    assert_equal %w[one two], lines
    assert_includes result.output, "one"
  end

  test "reports failure with the exit code" do
    result = LocalShell.new.run("bash", "-lc", "exit 3")
    refute result.success?
    assert_equal 3, result.exit_code
  end

  # docker build output can carry raw binary bytes; a single unscrubbed line
  # poisons the accumulated log and Postgres rejects it on append_log.
  test "output with invalid UTF-8 bytes is scrubbed, accumulated, and yielded as valid UTF-8" do
    lines = []
    result = LocalShell.new.run("bash", "-lc", %q(printf 'ok\n\xff\xfe bad\n')) { |l| lines << l }

    assert result.success?
    assert result.output.valid_encoding?, "accumulated output must be valid UTF-8"
    assert_equal Encoding::UTF_8, result.output.encoding
    assert lines.all?(&:valid_encoding?), "yielded lines must be valid UTF-8"
    assert_includes lines, "ok"
    assert_nothing_raised { "prefix #{result.output}" }
  end

  test "runs in the given directory with the given env" do
    Dir.mktmpdir do |dir|
      out = []
      LocalShell.new.run("bash", "-lc", "pwd; echo $FOO", chdir: dir, env: { "FOO" => "bar" }) { |l| out << l }
      assert_includes out.join("\n"), File.realpath(dir)
      assert_includes out, "bar"
    end
  end
end
