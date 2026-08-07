# Is this box able to upload a backup at all?
#
# R2 has no native CLI — it is S3-compatible, so uploads go through `aws s3 cp
# --endpoint-url https://<account>.r2.cloudflarestorage.com`. The AWS CLI is
# therefore a hard prerequisite on EVERY box that holds a database, and it is not
# installed by default anywhere.
#
# railslink's box found this the expensive way: the backup ran nightly, dumped the
# database, gzipped it, and only then failed with `aws: command not found` — after
# all the work, at 3am, on a box nobody was watching.
#
# So: check FIRST, and offer to fix it rather than just reporting it. Conductor
# already installs packages (PackageInstaller / InstallPackagesJob); this makes a
# backup able to use that instead of leaving the operator to discover the missing
# binary from a stack trace.
class BackupPrerequisites
  PACKAGE = "awscli".freeze

  Result = Struct.new(:ok, :installed, :detail, keyword_init: true) do
    def ok? = ok
    # True when this call had to install the CLI to make the box ready — worth
    # recording in the run log, because a backup that quietly changes the box is
    # exactly the kind of surprise operators are right to dislike.
    def installed? = installed
  end

  def initialize(server, ssh: nil, installer: nil)
    @server = server
    @ssh = ssh || SshConnection.new(server)
    @installer = installer
  end

  # `command -v` is POSIX and works under dash, which is what the SSH exec shell
  # actually is — `which` is not guaranteed to be present on a slim box.
  def aws_cli?
    @ssh.execute_with_status("command -v aws >/dev/null 2>&1")[:success]
  end

  # Check, then install if missing — apt first, then AWS's own v2 installer.
  #
  # Two routes are needed because apt is not enough: Ubuntu 24.04 (noble) ships
  # NO awscli package at all (`apt-cache policy awscli` → `Candidate: (none)`),
  # which is exactly why railslink's box could never satisfy this. apt is still
  # tried first where it works — a distro package is patched by the distro.
  #
  # Neither route is retried. If the CLI is still absent after an installer
  # reported success, that is a real problem (no sudo, no network, wrong arch)
  # and looping on it only delays an honest failure.
  def ensure!
    return Result.new(ok: true, installed: false, detail: "aws CLI present") if aws_cli?

    apt = installer.install
    return Result.new(ok: true, installed: true, detail: "installed #{PACKAGE} via apt") if apt.success? && aws_cli?

    official = install_official_v2
    return Result.new(ok: true, installed: true, detail: "installed AWS CLI v2 from awscli.amazonaws.com") if official[:success] && aws_cli?

    Result.new(ok: false, installed: false, detail: <<~DETAIL.squish)
      aws CLI missing. apt: #{apt.success? ? 'reported success but aws is still not on PATH' : apt.error};
      AWS CLI v2 installer: #{official[:success] ? 'reported success but aws is still not on PATH' : (official[:stderr].presence || official[:output]).to_s.strip[0, 160]}
    DETAIL
  end

  private

  # AWS's supported install for distros without a package. `uname -m` picks the
  # arch (x86_64 / aarch64) rather than assuming Intel — the fleet has both.
  # `--update` makes a re-run harmless. The download and unzip need no
  # privileges; only the final install step does.
  def install_official_v2
    @ssh.execute_with_status(<<~SH.strip)
      set -e
      command -v curl >/dev/null 2>&1 || sudo -n DEBIAN_FRONTEND=noninteractive apt-get install -y curl
      command -v unzip >/dev/null 2>&1 || sudo -n DEBIAN_FRONTEND=noninteractive apt-get install -y unzip
      cd /tmp
      curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o /tmp/awscliv2.zip
      unzip -q -o /tmp/awscliv2.zip -d /tmp
      sudo -n /tmp/aws/install --update
      rm -rf /tmp/awscliv2.zip /tmp/aws
    SH
  end

  def installer
    @installer ||= PackageInstaller.new(@server, [ PACKAGE ], ssh: @ssh)
  end
end
