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

  test "runs in the given directory with the given env" do
    Dir.mktmpdir do |dir|
      out = []
      LocalShell.new.run("bash", "-lc", "pwd; echo $FOO", chdir: dir, env: { "FOO" => "bar" }) { |l| out << l }
      assert_includes out.join("\n"), File.realpath(dir)
      assert_includes out, "bar"
    end
  end
end
