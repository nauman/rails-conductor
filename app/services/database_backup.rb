class DatabaseBackup
  attr_reader :backup, :error

  def initialize(backup)
    @backup = backup
  end

  def run!
    backup.update!(status: "running")

    unless backup.credential
      return fail_with("No credential configured")
    end

    server = backup.server || backup.app&.server
    unless server&.ssh_configured?
      return fail_with("No server with SSH access")
    end

    ssh = SshConnection.new(server)

    # Create backup filename
    timestamp = Time.current.strftime("%Y%m%d_%H%M%S")
    filename = "#{backup.bucket_name}_#{timestamp}.sql.gz"
    local_path = "/tmp/#{filename}"

    # Dump the database (assumes PostgreSQL - extend for MySQL)
    dump_cmd = build_dump_command(local_path)
    unless ssh.execute(dump_cmd)
      return fail_with("Database dump failed: #{ssh.error}")
    end

    # Get file size
    ssh.execute("stat -f%z #{local_path} 2>/dev/null || stat -c%s #{local_path}")
    size_bytes = ssh.output.to_s.strip.to_i

    # Upload to cloud storage
    unless upload_to_storage(ssh, local_path, filename)
      return fail_with("Upload failed: #{@error}")
    end

    # Cleanup
    ssh.execute("rm -f #{local_path}")

    # Mark completed
    backup.update!(
      status: "completed",
      size_bytes: size_bytes,
      completed_at: Time.current
    )

    true
  rescue => e
    fail_with("Unexpected error: #{e.message}")
  end

  private

  def fail_with(message)
    @error = message
    backup.update!(status: "failed", last_run_at: Time.current)
    backup.calculate_next_run if backup.enabled?
    Rails.logger.error "[Backup:#{backup.id}] #{message}"

    # Send notification
    AlertMailer.backup_failed(backup).deliver_later

    false
  end

  def build_dump_command(output_path)
    # This assumes DATABASE_URL env var is set on the server
    # Extend this to detect database type and use appropriate dump command
    "pg_dump $DATABASE_URL | gzip > #{output_path}"
  end

  def upload_to_storage(ssh, local_path, filename)
    case backup.provider
    when "cloudflare_r2"
      upload_to_r2(ssh, local_path, filename)
    when "aws_s3"
      upload_to_s3(ssh, local_path, filename)
    when "local"
      # Local backup - just keep the file
      true
    else
      @error = "Unsupported provider: #{backup.provider}"
      false
    end
  end

  def upload_to_r2(ssh, local_path, filename)
    cred = backup.credential
    # R2 is S3-compatible, use aws cli with custom endpoint
    endpoint = "https://#{cred.api_secret}.r2.cloudflarestorage.com"

    upload_cmd = <<~BASH
      AWS_ACCESS_KEY_ID=#{cred.api_key} \
      AWS_SECRET_ACCESS_KEY=#{cred.api_secret} \
      aws s3 cp #{local_path} s3://#{backup.bucket_name}/#{filename} \
        --endpoint-url #{endpoint}
    BASH

    if ssh.execute(upload_cmd)
      true
    else
      @error = ssh.error
      false
    end
  end

  def upload_to_s3(ssh, local_path, filename)
    cred = backup.credential

    upload_cmd = <<~BASH
      AWS_ACCESS_KEY_ID=#{cred.api_key} \
      AWS_SECRET_ACCESS_KEY=#{cred.api_secret} \
      aws s3 cp #{local_path} s3://#{backup.bucket_name}/#{filename}
    BASH

    if ssh.execute(upload_cmd)
      true
    else
      @error = ssh.error
      false
    end
  end
end
