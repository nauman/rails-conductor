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

  # Check, and install once if missing. Never installs twice: if the CLI is still
  # absent after apt reports success, that is a real problem (no sudo, held
  # packages, no network) and looping on it just delays an honest failure.
  def ensure!
    return Result.new(ok: true, installed: false, detail: "aws CLI present") if aws_cli?

    res = installer.install

    unless res.success?
      return Result.new(ok: false, installed: false,
                        detail: "aws CLI missing and `apt-get install #{PACKAGE}` failed: #{res.error}")
    end

    if aws_cli?
      Result.new(ok: true, installed: true, detail: "installed #{PACKAGE}")
    else
      Result.new(ok: false, installed: false,
                 detail: "apt reported success but `aws` is still not on PATH")
    end
  end

  private

  def installer
    @installer ||= PackageInstaller.new(@server, [ PACKAGE ], ssh: @ssh)
  end
end
