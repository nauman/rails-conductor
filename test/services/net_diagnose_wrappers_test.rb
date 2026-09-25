require "test_helper"
require "tmpdir"

# RENDER THE WRAPPERS AND RUN THEM.
#
# These two scripts are the only place Conductor can see host firewall state, and
# one of them releases firewall bans. Asserting on the rendered string would have
# missed both defects found while writing them:
#
#   * a multi-line python block at column 0 dropped the Ruby heredoc's minimum
#     indentation to zero, so <<~ stripped nothing and EVERY wrapper's CONDUCTOR
#     terminator rendered indented — which sh does not recognise. The file looked
#     perfect and grant_command was broken for all seven wrappers.
#   * an empty `docker ps` printed nothing at all, so a box whose edge container
#     had died looked identical to one that was never checked.
class NetDiagnoseWrappersTest < ActiveSupport::TestCase
  DEPLOY = Struct.new(:ssh_user_or_default)

  def grant = ServerSudo.grant_command(DEPLOY.new("deploy"))

  # A wrapper HELD pending audit is not written by grant_command, so it is fetched
  # from its own accessor. The tests must keep running it: holding a capability
  # back is not a reason to stop exercising it, and the audit needs it working.
  def wrapper(name)
    return ServerSudo.pending_wrapper_script(name) if ServerSudo::WRAPPERS_PENDING_AUDIT.include?(name)

    body = grant[/#{Regexp.escape(name)} >\/dev\/null <<.CONDUCTOR.\n(.*?)\nCONDUCTOR\n/m, 1]
    assert body, "could not extract #{name} from the grant command"
    body
  end

  # The heredoc invariant. Ruby's <<~ strips the SMALLEST indentation in the
  # block, so one flush-left line anywhere silently un-indents the terminators and
  # breaks every wrapper at once.
  # The held wrapper must not reach a host: not written, not named in sudoers.
  # Hiding only the MCP action would leave it installed root-owned everywhere.
  test "a wrapper held pending audit is never installed or granted" do
    script = grant
    ServerSudo::WRAPPERS_PENDING_AUDIT.each do |path|
      assert_not_includes script, path,
                          "#{path} is held pending audit and must not be written or granted"
    end
    assert ServerSudo.pending_wrapper_script(ServerSudo::UNBAN_CLOUDFLARE).present?,
           "the held script must still be renderable for the audit and these tests"
  end

  test "every wrapper heredoc terminator renders flush left" do
    script = grant
    indented = script.lines.select { |l| l.rstrip.end_with?("CONDUCTOR") && l.start_with?(" ") }
    assert_empty indented,
                 "indented CONDUCTOR terminators will not close a heredoc under sh: #{indented.inspect}"
    assert_equal ServerSudo::WRAPPERS.count, script.lines.count { |l| l.chomp == "CONDUCTOR" },
                 "expected one closing terminator per wrapper"
  end

  test "both wrappers are valid POSIX sh" do
    [ ServerSudo::NET_DIAGNOSE, ServerSudo::UNBAN_CLOUDFLARE ].each do |path|
      in_a_sandbox do |dir|
        file = File.join(dir, "w.sh")
        File.write(file, wrapper(path))
        _out, err, status = run_shell("sh -n #{file}")
        assert_equal 0, status, "#{path} is not valid sh: #{err}"
      end
    end
  end

  # An incident is the worst time for a diagnostic to abort because one tool is
  # absent. Every section must degrade to a sentence.
  test "net-diagnose reports rather than fails when no tool is installed" do
    in_a_sandbox do |dir|
      file = File.join(dir, "net.sh")
      File.write(file, wrapper(ServerSudo::NET_DIAGNOSE))
      out, _err, status = run_shell_with_empty_path("/bin/sh #{file}")

      assert_equal 0, status, "a missing tool must not fail the whole report"
      %w[fail2ban ufw conntrack].each { |section| assert_includes out, "=== #{section}", "missing #{section} section" }
      assert_match(/not installed|not available/, out)
    end
  end

  test "net-diagnose emits one parseable BANNED line per address, including IPv6" do
    with_fake_fail2ban do |dir|
      out, _err, status = run_shell("PATH=#{dir}/bin:$PATH sh #{dir}/net.sh")

      assert_equal 0, status
      assert_includes out, "JAIL sshd currently_banned=3"
      assert_includes out, "BANNED sshd 173.245.48.12"
      assert_includes out, "BANNED sshd 2400:cb00::5", "IPv6 bans must be reported too"
      assert_includes out, "BANNED sshd 198.51.100.7"
      # A jail with nothing banned must produce a JAIL line and no BANNED lines.
      assert_includes out, "JAIL empty-jail currently_banned=0"
      assert_not_includes out, "BANNED empty-jail"
    end
  end

  # The security property. Everything else about this wrapper is convenience.
  test "unban releases Cloudflare addresses and leaves every other ban in place" do
    with_fake_fail2ban do |dir|
      _out, _err, status = run_shell("PATH=#{dir}/bin:$PATH FAKE_CURL_MODE=ok sh #{dir}/unban.sh")
      calls = File.read("#{dir}/calls.txt")

      assert_equal 0, status
      assert_includes calls, "UNBAN set sshd unbanip 173.245.48.12\n", "a Cloudflare IPv4 ban should be released"
      assert_includes calls, "UNBAN set sshd unbanip 2400:cb00::5\n", "a Cloudflare IPv6 ban should be released"
      assert_not_includes calls, "UNBAN set sshd unbanip 198.51.100.7\n",
                          "198.51.100.7 is not Cloudflare — releasing it would unban an actual attacker"
      assert_includes calls, "IGNORE set sshd addignoreip 173.245.48.0/20\n", "the ranges should be added to ignoreip"
    end
  end

  # A list that cannot be fetched must never widen to "unban everything".
  test "unban releases nothing when the range list cannot be fetched" do
    with_fake_fail2ban do |dir|
      _out, err, status = run_shell("PATH=#{dir}/bin:$PATH FAKE_CURL_MODE=fail sh #{dir}/unban.sh")

      assert_equal 5, status
      assert_match(/refusing to unban/, err)
      assert_not File.exist?("#{dir}/calls.txt"), "nothing may be unbanned when the ranges are unknown"
    end
  end

  # A captive portal or an error page answers 200 with HTML. "Every line is a
  # CIDR" is the cheapest way to notice before acting on it.
  test "unban releases nothing when the range list is not CIDRs" do
    with_fake_fail2ban do |dir|
      _out, err, status = run_shell("PATH=#{dir}/bin:$PATH FAKE_CURL_MODE=html sh #{dir}/unban.sh")

      assert_equal 5, status
      assert_match(/did not return a CIDR list/, err)
      assert_not File.exist?("#{dir}/calls.txt")
    end
  end



  # The endpoint serves bare LF today. Depending on that is a silent dependency on
  # a third party's whitespace: a switch to CRLF would fail every CIDR match and
  # the wrapper would refuse forever, which is safe and useless. Normalising must
  # NOT loosen what is validated — the malicious cases above still refuse.
  test "unban tolerates benign formatting without accepting bad content" do
    %w[crlf commented].each do |mode|
      with_fake_fail2ban do |dir|
        _out, err, status = run_shell("PATH=#{dir}/bin:$PATH FAKE_CURL_MODE=#{mode} sh #{dir}/unban.sh")

        assert_equal 0, status, "#{mode} formatting should be accepted, got: #{err}"
        calls = File.read("#{dir}/calls.txt")
        assert_includes calls, "UNBAN set sshd unbanip 173.245.48.12\n"
        assert_not_includes calls, "UNBAN set sshd unbanip 198.51.100.7\n",
                            "normalising formatting must not widen what is unbanned"
      end
    end
  end

  # THE REVIEW FOUND THIS BY RUNNING IT. The validation checked only that every
  # line LOOKED like a CIDR, so a response of 0.0.0.0/0 passed — and unbanned
  # every address on the box, including the one this suite calls an attacker,
  # then told fail2ban to ignore all of IPv4. Shape is not plausibility.
  test "unban refuses a range list broad enough to cover the internet" do
    %w[wildcard_v4 wildcard_v6].each do |mode|
      with_fake_fail2ban do |dir|
        _out, err, status = run_shell("PATH=#{dir}/bin:$PATH FAKE_CURL_MODE=#{mode} sh #{dir}/unban.sh")

        assert_equal 5, status, "#{mode} should refuse"
        assert_match(/broader than Cloudflare publishes/, err)
        assert_not File.exist?("#{dir}/calls.txt"), "#{mode} must unban nothing"
      end
    end
  end

  # THE ONE TEST THAT PROVES THE CHECKS DO NOT REFUSE CLOUDFLARE. Note the v6
  # body deliberately ends WITHOUT a trailing newline, because the endpoint does.
  test "unban accepts the range lists Cloudflare actually publishes" do
    with_fake_fail2ban do |dir|
      _out, err, status = run_shell("PATH=#{dir}/bin:$PATH FAKE_CURL_MODE=published sh #{dir}/unban.sh")

      assert_equal 0, status, "the genuine list must be accepted, got: #{err}"
      calls = File.read("#{dir}/calls.txt")
      assert_includes calls, "unbanip 173.245.48.12"
      assert_includes calls, "unbanip 2400:cb00::5"
      assert_not_includes calls, "unbanip 198.51.100.7"
    end
  end

  # AUDIT ROUND 2. Each of these passed every check the wrapper had, and each
  # ends with a non-Cloudflare address being released or the list being trusted.
  test "unban refuses a range list padded out with duplicates" do
    with_fake_fail2ban do |dir|
      _out, err, status = run_shell("PATH=#{dir}/bin:$PATH FAKE_CURL_MODE=duplicates sh #{dir}/unban.sh")

      assert_equal 5, status
      assert_match(/distinct prefixes/, err)
      assert_not File.exist?("#{dir}/calls.txt"),
                 "four copies of one prefix is one prefix, and 198.51.100.7 is the attacker"
    end
  end

  test "unban refuses four spellings of one network" do
    with_fake_fail2ban do |dir|
      _out, err, status = run_shell("PATH=#{dir}/bin:$PATH FAKE_CURL_MODE=hostbits sh #{dir}/unban.sh")

      assert_equal 5, status
      assert_match(/distinct networks per family/, err)
      assert_not File.exist?("#{dir}/calls.txt"),
                 "198.51.100.4/30 .. .7/30 is one network containing the attacker, not four prefixes"
    end
  end

  test "unban refuses a list whose tail is malformed, however good the head is" do
    with_fake_fail2ban do |dir|
      _out, err, status = run_shell("PATH=#{dir}/bin:$PATH FAKE_CURL_MODE=badtail sh #{dir}/unban.sh")

      assert_equal 5, status
      assert_match(/distinct networks per family/, err)
      assert_not File.exist?("#{dir}/calls.txt"),
                 "a partly-valid list is not a shorter valid list"
    end
  end

  test "unban refuses prefixes served from the wrong family's endpoint" do
    with_fake_fail2ban do |dir|
      _out, err, status = run_shell("PATH=#{dir}/bin:$PATH FAKE_CURL_MODE=crossfamily sh #{dir}/unban.sh")

      assert_equal 5, status
      assert_match(/non-IPv6 prefix/, err)
      assert_not File.exist?("#{dir}/calls.txt")
    end
  end

  # THE MOST SERIOUS FINDING OF THE AUDIT. `python3 -c` puts the CALLER'S working
  # directory first on sys.path, and sudo keeps that directory — so an
  # ipaddress.py sitting wherever the deploy user happened to be would be
  # imported and executed as root, and needed only to exit 0 to make every ban
  # on the box look like Cloudflare's. No crafted fail2ban output required.
  test "unban cannot be steered by a python module in the calling directory" do
    with_fake_fail2ban do |dir|
      File.write(File.join(dir, "ipaddress.py"), <<~PY)
        import sys
        # What an attacker would write: agree with everything, say nothing.
        def ip_address(x): return x
        def ip_network(x, strict=False): return x
        sys.exit(0)
      PY

      _out, _err, status = run_shell("cd #{dir} && PATH=#{dir}/bin:$PATH FAKE_CURL_MODE=ok sh #{dir}/unban.sh")
      calls = File.exist?("#{dir}/calls.txt") ? File.read("#{dir}/calls.txt") : ""

      assert_equal 0, status
      assert_not_includes calls, "unbanip 198.51.100.7",
                          "a module in the caller's directory must not decide what counts as Cloudflare"
      assert_includes calls, "unbanip 173.245.48.12",
                      "and the real check must still be the one running"
    end
  end

  # A truncated transfer turns 173.245.48.0/20 into 173.245.48.0/2 — still a
  # well-formed CIDR, and a quarter of IPv4.
  test "unban refuses a truncated prefix" do
    with_fake_fail2ban do |dir|
      _out, err, status = run_shell("PATH=#{dir}/bin:$PATH FAKE_CURL_MODE=truncated sh #{dir}/unban.sh")

      assert_equal 5, status
      assert_not File.exist?("#{dir}/calls.txt")
    end
  end

  # Both URLs were appended to one file and the union validated, so an empty 200
  # from one of them left a half list that still looked valid.
  test "unban refuses when one of the two range URLs comes back empty" do
    with_fake_fail2ban do |dir|
      _out, err, status = run_shell("PATH=#{dir}/bin:$PATH FAKE_CURL_MODE=v6only sh #{dir}/unban.sh")

      assert_equal 5, status
      assert_match(/too few to be the published list/, err)
      assert_not File.exist?("#{dir}/calls.txt"), "half a range list must not be acted on"
    end
  end

  # Runs as root from a wrapper the deploy user triggers: nstat without -s writes
  # /tmp/.nstat.u0, and a root-owned file is the problem this repo keeps hitting.
  test "net-diagnose reads network counters without writing an nstat history file" do
    in_a_sandbox do |dir|
      bin = File.join(dir, "bin")
      FileUtils.mkdir_p(bin)
      File.write(File.join(bin, "nstat"), "#!/bin/sh\necho \"$@\" > #{dir}/nstat-argv\nexit 0\n")
      FileUtils.chmod(0o755, File.join(bin, "nstat"))
      File.write(File.join(dir, "net.sh"), wrapper(ServerSudo::NET_DIAGNOSE))

      run_shell("PATH=#{bin}:$PATH sh #{dir}/net.sh")

      argv = File.read("#{dir}/nstat-argv")
      assert_match(/-\w*s/, argv, "nstat needs -s or it writes a root-owned history file: #{argv.inspect}")
    end
  end

  test "unban refuses when fail2ban is absent rather than reporting success" do
    in_a_sandbox do |dir|
      File.write(File.join(dir, "unban.sh"), wrapper(ServerSudo::UNBAN_CLOUDFLARE))
      _out, err, status = run_shell_with_empty_path("/bin/sh #{dir}/unban.sh")

      assert_equal 4, status
      assert_match(/fail2ban-client not installed/, err)
    end
  end

  # The wrapper PINS PATH, so an exported PATH from the test is ignored and the
  # stubs would never be reached — the suite would silently start exercising the
  # host's real curl and fail2ban-client. One line is substituted, and the
  # substitution is asserted rather than assumed: if the pin is ever removed or
  # reworded, these tests fail loudly instead of quietly testing the wrong thing.
  test "the unban wrapper pins PATH" do
    script = wrapper(ServerSudo::UNBAN_CLOUDFLARE)

    assert_match(/^PATH=\/usr\/local\/sbin:/, script,
                 "a root-owned script must not let its caller choose which binaries it runs")
    assert_match(/^export PATH$/, script)
  end

  private

  def with_stubbed_path(script, bin)
    pinned = script[/^PATH=\S+$/]
    assert pinned, "the wrapper no longer pins PATH - these tests would run the host's own binaries"
    script.sub(pinned, "PATH=#{bin}:#{pinned.delete_prefix('PATH=')}")
  end

  # A fake fail2ban-client that RECORDS what it was asked to do, and a fake curl
  # whose behaviour is switched by FAKE_CURL_MODE. Recording the calls is what
  # makes "only Cloudflare was unbanned" assertable rather than inferred.
  def with_fake_fail2ban
    in_a_sandbox do |dir|
      bin = File.join(dir, "bin")
      FileUtils.mkdir_p(bin)

      File.write(File.join(bin, "fail2ban-client"), <<~SH)
        #!/bin/sh
        [ "$1" = "ping" ] && exit 0
        if [ "$1" = "status" ] && [ -z "$2" ]; then
          printf 'Status\\n`- Jail list:\\tsshd, empty-jail\\n'; exit 0
        fi
        if [ "$1" = "status" ] && [ "$2" = "sshd" ]; then
          printf 'Status for jail: sshd\\n |- Currently banned:\\t3\\n `- Banned IP list:\\t173.245.48.12 198.51.100.7 2400:cb00::5\\n'; exit 0
        fi
        if [ "$1" = "status" ] && [ "$2" = "empty-jail" ]; then
          printf 'Status for jail: empty-jail\\n |- Currently banned:\\t0\\n `- Banned IP list:\\t\\n'; exit 0
        fi
        # THE WHOLE ARGV, not just $4. Recording one field meant a call against
        # the wrong jail, or with extra arguments appended, matched the same
        # assertion as a correct one — the test could not tell them apart.
        if [ "$1" = "set" ] && [ "$3" = "unbanip" ]; then echo "UNBAN $*" >> #{dir}/calls.txt; exit 0; fi
        if [ "$1" = "set" ] && [ "$3" = "addignoreip" ]; then echo "IGNORE $*" >> #{dir}/calls.txt; exit 0; fi
        [ "$1" = "get" ] && { echo "127.0.0.1/8"; exit 0; }
        exit 0
      SH

      File.write(File.join(bin, "curl"), <<~SH)
        #!/bin/sh
        case "$FAKE_CURL_MODE" in
          fail) exit 22 ;;
          html) echo "<!DOCTYPE html><html>nope</html>" ;;
          crlf) for a in "$@"; do case "$a" in
               *ips-v4) printf '173.245.48.0/20\\r\\n103.21.244.0/22\\r\\n103.22.200.0/22\\r\\n141.101.64.0/18\\r\\n' ;;
               *ips-v6) printf '2400:cb00::/32\\r\\n2606:4700::/32\\r\\n2803:f800::/32\\r\\n2405:b500::/32\\r\\n' ;;
             esac; done ;;
          commented) for a in "$@"; do case "$a" in
               *ips-v4) printf '# Cloudflare IPv4\\n\\n173.245.48.0/20\\n103.21.244.0/22\\n103.22.200.0/22\\n141.101.64.0/18\\n' ;;
               *ips-v6) printf '2400:cb00::/32\\n2606:4700::/32\\n2803:f800::/32\\n2405:b500::/32\\n' ;;
             esac; done ;;
          # ONE FAMILY AT A TIME. The old fixture put a forbidden prefix in BOTH
          # lists, so deleting either family's floor check still left the test
          # passing — it proved only that at least one of the two existed.
          wildcard_v4) for a in "$@"; do case "$a" in
               *ips-v4) printf '0.0.0.0/0\\n10.0.0.0/8\\n172.16.0.0/12\\n192.168.0.0/16\\n' ;;
               *ips-v6) printf '2400:cb00::/32\\n2606:4700::/32\\n2803:f800::/32\\n2405:b500::/32\\n' ;;
             esac; done ;;
          wildcard_v6) for a in "$@"; do case "$a" in
               *ips-v4) printf '173.245.48.0/20\\n103.21.244.0/22\\n103.22.200.0/22\\n141.101.64.0/18\\n' ;;
               *ips-v6) printf '::/0\\n2400:cb00::/32\\n2606:4700::/32\\n2803:f800::/32\\n' ;;
             esac; done ;;
          # THE REAL PUBLISHED LISTS, verbatim — 15 v4 prefixes and 7 v6, including
          # 2a06:98c0::/29, which the wrapper's v6 floor of /32 REFUSED. Every
          # other fixture here was written from the same assumption as the check,
          # so none of them could contradict it, and the wrapper would have
          # refused the genuine list on every server it was ever installed on.
          published) for a in "$@"; do case "$a" in
               *ips-v4) printf '173.245.48.0/20\\n103.21.244.0/22\\n103.22.200.0/22\\n103.31.4.0/22\\n141.101.64.0/18\\n108.162.192.0/18\\n190.93.240.0/20\\n188.114.96.0/20\\n197.234.240.0/22\\n198.41.128.0/17\\n162.158.0.0/15\\n104.16.0.0/13\\n104.24.0.0/14\\n172.64.0.0/13\\n131.0.72.0/22\\n' ;;
               *ips-v6) printf '2400:cb00::/32\\n2606:4700::/32\\n2803:f800::/32\\n2405:b500::/32\\n2405:8100::/32\\n2a06:98c0::/29\\n2c0f:f248::/32' ;;
             esac; done ;;
          # Four copies of one prefix: shape, count and floor all passed while the
          # list carried a single address, which the wrapper would then release.
          duplicates) for a in "$@"; do case "$a" in
               *ips-v4) printf '198.51.100.7/32\\n198.51.100.7/32\\n198.51.100.7/32\\n198.51.100.7/32\\n' ;;
               *ips-v6) printf '2400:cb00::/32\\n2606:4700::/32\\n2803:f800::/32\\n2405:b500::/32\\n' ;;
             esac; done ;;
          # FOUR DISTINCT STRINGS, ONE NETWORK. strict=False collapsed .4/30
          # through .7/30 into 198.51.100.4/30, so a `sort -u` count of four was
          # satisfied by a list covering a single /30 — and 198.51.100.7 is in it.
          hostbits) for a in "$@"; do case "$a" in
               *ips-v4) printf '198.51.100.4/30\\n198.51.100.5/30\\n198.51.100.6/30\\n198.51.100.7/30\\n' ;;
               *ips-v6) printf '2400:cb00::/32\\n2606:4700::/32\\n2803:f800::/32\\n2405:b500::/32\\n' ;;
             esac; done ;;
          # A real prefix FIRST, malformed lines after. The membership test used a
          # generator and stopped at the first match, so the tail was never parsed.
          badtail) for a in "$@"; do case "$a" in
               *ips-v4) printf '173.245.48.0/20\\n103.21.244.0/22\\n103.22.200.0/22\\n999.999.999.999/20\\n' ;;
               *ips-v6) printf '2400:cb00::/32\\n2606:4700::/32\\n2803:f800::/32\\n2405:b500::/32\\n' ;;
             esac; done ;;
          # v4 prefixes served from the v6 endpoint: each list was only ever
          # checked against its own family's floor, so this cleared /32 easily.
          crossfamily) for a in "$@"; do case "$a" in
               *ips-v4) printf '173.245.48.0/20\\n103.21.244.0/22\\n103.22.200.0/22\\n141.101.64.0/18\\n' ;;
               *ips-v6) printf '198.51.100.0/24\\n198.51.101.0/24\\n198.51.102.0/24\\n198.51.103.0/24\\n' ;;
             esac; done ;;
          truncated) for a in "$@"; do case "$a" in *ips-v4) printf '173.245.48.0/2\\n' ;; *ips-v6) printf '2400:cb00::/32\\n' ;; esac; done ;;
          v6only) for a in "$@"; do case "$a" in *ips-v4) : ;; *ips-v6) printf '2400:cb00::/32\\n2606:4700::/32\\n2803:f800::/32\\n2405:b500::/32\\n' ;; esac; done ;;
          *) for a in "$@"; do
               case "$a" in
                 *ips-v4) printf '173.245.48.0/20\\n103.21.244.0/22\\n103.22.200.0/22\\n141.101.64.0/18\\n' ;;
                 *ips-v6) printf '2400:cb00::/32\\n2606:4700::/32\\n2803:f800::/32\\n2405:b500::/32\\n' ;;
               esac
             done ;;
        esac
        exit 0
      SH

      FileUtils.chmod(0o755, [ File.join(bin, "fail2ban-client"), File.join(bin, "curl") ])
      File.write(File.join(dir, "net.sh"), wrapper(ServerSudo::NET_DIAGNOSE))
      File.write(File.join(dir, "unban.sh"), with_stubbed_path(wrapper(ServerSudo::UNBAN_CLOUDFLARE), bin))
      yield dir
    end
  end
end
