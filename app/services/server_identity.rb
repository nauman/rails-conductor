require "shellwords"

# Conductor's OWN key on the box, installed by Conductor.
#
# Until now it generated a keypair and — per its own tool description — handed the
# operator the public half "to add to your servers' authorized_keys". So the
# automated identity was never installed by the automation. It was a manual errand
# documented as a feature, and it is why a cross-box deploy failed until a human
# edited a file.
#
# TWO CONNECTIONS, deliberately, because they answer different questions:
#
#   writer   — may be privileged (root during provisioning). Puts the key in place.
#   verifier — connects AS THE TARGET USER USING ONLY THE STORED KEY. Proves the
#              thing we just did actually works.
#
# Verifying over the writer's connection would prove nothing: it is already
# authenticated, by whatever credential got it in. Net::SSH will also offer agent
# identities and ~/.ssh/config keys unless told not to, so an ordinary connection
# can succeed on the OPERATOR's key while Conductor's own is absent — a check that
# passes exactly when it should fail.
class ServerIdentity
  Result = Struct.new(:ok, :action, :reason, keyword_init: true) do
    def ok? = ok
  end

  PROBE = "echo CONDUCTOR_IDENTITY_OK".freeze

  def initialize(server, ssh: nil, verifier: nil, target_user: nil)
    @server = server
    @target_user = target_user.presence || server.ssh_user_or_default
    @ssh = ssh || SshConnection.new(server, user: @target_user)
    @verifier = verifier || SshConnection.new(server, user: @target_user)
  end

  def ensure!
    key = @server.ssh_key
    # The OPENSSH LINE, not the PEM in `public_key`: sshd reads
    # `<type> <blob> [comment]` and silently ignores anything else, so installing the
    # PEM would authorize nothing and report nothing.
    line = key&.authorized_keys_line(comment: comment)
    if line.blank?
      return Result.new(ok: false, reason: "no ssh key is stored for #{@server.name}, so there is " \
                                           "no identity to install")
    end

    # MATCH ON THE KEY ITSELF, never the whole line. The comment carries a server
    # name, so matching the line would append a duplicate every time a server is
    # renamed — and would also match an entry someone had commented out.
    blob = line.split[1]
    # A two-value return: [action, error]. An earlier version returned the ACTION as
    # a String on success and the ERROR as a String on failure, then treated "any
    # String" as failure — so every successful install was read as an error. Two
    # meanings on one type is how that happens.
    action, error = install!(line, blob)
    return Result.new(ok: false, reason: error) if error

    verify(action)
  end

  private

  # Single line, always. A server name is operator-supplied and may contain a
  # newline; Shellwords preserves it inside the argument, so an unsanitised comment
  # can introduce ENTIRE EXTRA authorized_keys lines — an injection into the one file
  # that decides who may log in.
  def comment
    "conductor@#{@server.name.to_s.gsub(/[^A-Za-z0-9_.\-]/, '-')[0, 64]}"
  end

  # The target user's file by absolute path: the writer may be root, in which case
  # `~` is root's home and not the account being authorized.
  def authorized_keys_path
    home = @target_user == "root" ? "/root" : "/home/#{@target_user}"
    "#{home}/.ssh/authorized_keys"
  end

  # Returns [action, nil] on success, or [nil, reason] on failure.
  #
  # Permissions are repaired on EVERY run, present key or not: sshd silently ignores
  # an authorized_keys file it considers too open, which is a failure with no error
  # message anywhere.
  def install!(line, blob)
    path = Shellwords.escape(authorized_keys_path)
    dir = Shellwords.escape(File.dirname(authorized_keys_path))
    escaped_line = Shellwords.escape(line)
    escaped_blob = Shellwords.escape(blob)
    owner = Shellwords.escape(@target_user)

    # THE CHECK AND THE WRITE ARE ONE OPERATION, under one lock. Checking outside it
    # lets two concurrent repairs both see "absent" and both append.
    #
    # THE KEY IS THE FIELD AFTER THE TYPE. An entry may carry options —
    # `from="10.0.0.1" ssh-ed25519 BLOB` — which pushes the blob to field 3, so
    # matching field 2 alone read that as absent and would have appended an
    # UNRESTRICTED copy of the same key, defeating the operator's restriction.
    #
    # But scanning every field is wrong in the other direction: the same blob
    # appearing in ANOTHER key's trailing comment would read as present and skip an
    # install that was needed. Requiring the preceding field to be a key type pins
    # the match to the position sshd actually reads.
    #
    # CR is stripped first. A file with CRLF endings — one edited on Windows, or
    # pasted through something that converted them — leaves \r attached to the LAST
    # field, so a key with no comment read as absent and every repair appended
    # another copy of it. Not a security hole, but idempotency lost and a file that
    # grows without bound.
    #
    # THE TRAILING-NEWLINE GUARD MUST NOT FAIL OPEN. Appending to a file whose last
    # line has no newline splices the new key onto it, invalidating the existing
    # credential AND failing to install the new one — with no rollback, and
    # verification only noticing after access is already broken.
    #
    # `[ -n "$(tail -c 1 F)" ]` treated a FAILED tail (missing binary, unreadable
    # file) as "already ends in a newline" and skipped the separator, which is
    # exactly the case that breaks the file. tail's status is now checked, and every
    # write is checked, so a failure stops before it can splice.
    script = <<~SH
      set -e
      install -d -m 700 -o #{owner} -g #{owner} #{dir} 2>/dev/null || install -d -m 700 #{dir}
      touch #{path}
      # OWNERSHIP FIRST, AND IT MUST SUCCEED. `chown user:user` fails on a system
      # where the account has no same-named group, and swallowing that failure then
      # running `chmod 600` turned a working root-owned 0644 file into one the user
      # cannot read — disabling existing key access for Conductor AND the operator.
      # Verification would notice afterwards and could not undo it.
      #
      # `chown user` (no group) works regardless of group naming. If even that fails
      # we are not in a position to manage this file, so we stop BEFORE narrowing its
      # permissions rather than after.
      chown #{owner} #{path} || { echo CONDUCTOR_CHOWN_FAILED >&2; exit 1; }
      chmod 600 #{path}
      flock #{path} sh -c 'if awk -v k=#{escaped_blob} '"'"'{ gsub(/\r/, "") } $1 !~ /^#/ { for (i = 2; i <= NF; i++) if ($i == k && $(i-1) ~ /^(ssh-|ecdsa-|sk-)/) f = 1 } END { exit !f }'"'"' #{path}; then
        echo CONDUCTOR_KEY_PRESENT
      else
        last=$(tail -c 1 #{path}); tail_rc=$?
        [ $tail_rc -eq 0 ] || { echo CONDUCTOR_TAIL_FAILED >&2; exit 1; }
        if [ -s #{path} ] && [ -n "$last" ]; then
          echo >> #{path} || { echo CONDUCTOR_APPEND_FAILED >&2; exit 1; }
        fi
        printf "%s\\n" #{escaped_line} >> #{path} || { echo CONDUCTOR_APPEND_FAILED >&2; exit 1; }
        echo CONDUCTOR_KEY_ADDED
      fi'
    SH

    result = @ssh.execute_with_status(script)
    unless result[:success]
      if result[:stderr].to_s.match?(/CONDUCTOR_(TAIL|APPEND)_FAILED/)
        return [ nil, "could not safely append to #{authorized_keys_path} on #{@server.name} — " \
                      "stopped without writing, because appending to a file whose last line has no " \
                      "newline would splice the new key onto the existing one and break both" ]
      end

      if result[:stderr].to_s.include?("CONDUCTOR_CHOWN_FAILED")
        return [ nil, "could not take ownership of #{authorized_keys_path} on #{@server.name} for " \
                      "#{@target_user} — stopped without changing its permissions, because " \
                      "narrowing them without owning the file would remove that account's " \
                      "existing access" ]
      end

      return [ nil, "could not write #{authorized_keys_path} on #{@server.name}: " \
                    "#{(result[:stderr].presence || result[:stdout]).to_s.strip[0, 200]}" ]
    end

    [ result[:stdout].to_s.include?("CONDUCTOR_KEY_PRESENT") ? "already-authorized" : "installed", nil ]
  end

  # VERIFY BY USING IT, on a connection restricted to the stored key. A write that
  # returned zero proves the file was edited, not that the key authenticates.
  def verify(action)
    result = @verifier.with_only_stored_key { |ssh| ssh.execute_with_status(PROBE) }
    if result[:success] && result[:stdout].to_s.include?("CONDUCTOR_IDENTITY_OK")
      return Result.new(ok: true, action: action)
    end

    Result.new(ok: false, action: action,
               reason: "wrote the key to #{@server.name} but could not authenticate as " \
                       "#{@target_user} using it" \
                       "#{" (#{@verifier.error})" if @verifier.error.present?}")
  end
end
