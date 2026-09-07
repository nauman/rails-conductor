require "test_helper"

# The rendered shell, run against real files. Every defect this exercises passed
# code review and a green suite first — see test/support/shell_behaviour.rb.
class AuthorizedKeysShellTest < ActiveSupport::TestCase
  setup do
    user = User.create!(email: "aks@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @key = @org.ssh_keys.create!(name: "k", private_key: OpenSSL::PKey::RSA.new(2048).to_pem)
    @line = @key.authorized_keys_line(comment: "conductor@box")
    @blob = @line.split[1]
  end

  # The presence check, rendered exactly as ServerIdentity builds it.
  def presence_check(path)
    <<~SH
      if awk -v k=#{Shellwords.escape(@blob)} '{ gsub(/\\r/, "") } $1 !~ /^#/ { for (i = 2; i <= NF; i++) if ($i == k && $(i-1) ~ /^(ssh-|ecdsa-|sk-)/) f = 1 } END { exit !f }' #{path}; then
        echo PRESENT
      else
        echo ABSENT
      fi
    SH
  end

  test "the key match answers correctly across the shapes an authorized_keys file takes" do
    cases = {
      "#{@line}\n"                                  => "PRESENT",  # ordinary
      "from=\"10.0.0.1\" #{@line}\n"                 => "PRESENT",  # options push the key to field 3
      "ssh-rsa OTHERBLOB copied #{@blob}\n"          => "ABSENT",   # blob only in another key's comment
      "# #{@line}\n"                                 => "ABSENT",   # commented out
      "ssh-rsa #{@blob}\r\n"                         => "PRESENT",  # CRLF, key as the last field
      "from=\"10.0.0.1\" ssh-rsa #{@blob}\r\n"       => "PRESENT"   # both at once
    }

    in_a_sandbox do |dir|
      cases.each do |content, expected|
        path = File.join(dir, "ak")
        File.write(path, content)
        stdout, _stderr, status = run_shell(presence_check(path))

        assert_equal 0, status
        assert_equal expected, stdout.strip, "for #{content.inspect}"
      end
    end
  end

  # The merge that replaced `cp`. `cp` deleted whatever deploy already authorized.
  test "the merge adds only what is missing and never reorders" do
    in_a_sandbox(
      files: {
        "deploy" => "restrict,pty ssh-rsa KEYA op\nssh-rsa CONDUCTOR c\n",
        "root"   => "no-pty ssh-rsa KEYA op\nssh-ed25519 KEYB root\nssh-rsa CONDUCTOR c\n"
      }
    ) do |dir|
      deploy = File.join(dir, "deploy")
      script = "echo >> #{deploy}; grep -Fxv -f #{deploy} #{File.join(dir, 'root')} >> #{deploy}; [ $? -le 1 ]"

      _out, _err, status = run_shell(script)
      lines = File.read(deploy).lines.map(&:chomp).reject(&:empty?)

      assert_equal 0, status
      # sshd uses the FIRST matching entry, so the restricted line must stay ahead of
      # the permissive one — this is what `sort -u` got wrong.
      assert_equal "restrict,pty ssh-rsa KEYA op", lines.first
      assert_operator lines.index("restrict,pty ssh-rsa KEYA op"), :<, lines.index("no-pty ssh-rsa KEYA op")
      assert_equal 1, lines.count("ssh-rsa CONDUCTOR c"), "an existing key must not be duplicated"
    end
  end

  test "the merge is idempotent and handles an empty target" do
    in_a_sandbox(files: { "deploy" => "", "root" => "ssh-rsa K1 a\nssh-ed25519 K2 b\n" }) do |dir|
      deploy = File.join(dir, "deploy")
      script = "echo >> #{deploy}; grep -Fxv -f #{deploy} #{File.join(dir, 'root')} >> #{deploy}; [ $? -le 1 ]"

      2.times { run_shell(script) }

      assert_equal 2, File.read(deploy).lines.count { |l| l.strip.present? }
    end
  end

  # A guard that fails OPEN is the worst kind: it misbehaves only once something
  # else has gone wrong. This one skipped the separator when `tail` failed, splicing
  # the new key onto the previous entry and breaking both.
  test "the newline guard refuses to append when it cannot read the file's last byte" do
    in_a_sandbox(files: { "ak" => "ssh-rsa EXISTING nonewline" }) do |dir|
      path = File.join(dir, "ak")
      script = <<~SH
        last=$(tail -c 1 #{path}); rc=$?
        [ $rc -eq 0 ] || { echo GUARD_ABORTED; exit 1; }
        if [ -s #{path} ] && [ -n "$last" ]; then echo >> #{path}; fi
        printf "%s\\n" "ssh-rsa NEW c" >> #{path}
      SH

      stdout, _err, status = run_shell_with_empty_path(script)

      assert_equal 1, status
      assert_match(/GUARD_ABORTED/, stdout)
      assert_equal "ssh-rsa EXISTING nonewline", File.read(path), "the file must be untouched"
    end
  end
end
