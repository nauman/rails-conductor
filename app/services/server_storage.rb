# Read-only storage detail for a server, over SSH: filesystem usage per mount,
# swap + memory, inode pressure, and the biggest directories (where the space
# actually went). Complements ServerMetrics' single disk % gauge with a
# drill-down. Nothing is changed. One SSH round-trip, `du` bounded by timeout.
class ServerStorage
  Mount = Struct.new(:filesystem, :size, :used, :avail, :percent, :mount, keyword_init: true)
  Dir   = Struct.new(:path, :bytes, keyword_init: true)
  Result = Struct.new(:mounts, :inodes, :swap, :memory, :top_dirs, :error, keyword_init: true) do
    def ok? = error.nil?
  end

  # Sections are delimited so parsing stays robust. `du -x` stays on the root
  # filesystem; --max-depth=1 + a short timeout keep the whole probe well under the
  # HTTP request budget so a slow disk can't hang the frame into "Content missing".
  PROBE = <<~BASH.freeze
    echo "===DF==="
    df -PB1 -x tmpfs -x devtmpfs -x overlay -x squashfs 2>/dev/null | tail -n +2
    echo "===INODES==="
    df -PiB1 -x tmpfs -x devtmpfs -x overlay -x squashfs 2>/dev/null | tail -n +2
    echo "===SWAP==="
    free -b | awk '/Swap/{print $2, $3, $4}'
    echo "===MEM==="
    free -b | awk '/Mem/{print $2, $3, $7}'
    echo "===TOPDIRS==="
    timeout 8 du -x -B1 --max-depth=1 / 2>/dev/null | sort -rn | head -15
  BASH

  attr_reader :server, :error

  def initialize(server, ssh: nil)
    @server = server
    @ssh = ssh || SshConnection.new(server)
    @error = nil
  end

  def load
    return failure("SSH not configured") unless server.ssh_configured?

    output = @ssh.execute(PROBE)
    return failure(@ssh.error.presence || "No response from server") unless @ssh.success?

    from_output(output)
  end

  # Parse a PROBE's raw output without running SSH — for a batched single-session
  # read. Never lets a parse hiccup 500 the turbo-frame; degrades to an error.
  def from_output(output)
    parse(sections(output))
  rescue => e
    failure("Couldn't read storage detail: #{e.message}")
  end

  private

  # Split the delimited probe output into { "DF" => [lines], ... }.
  def sections(output)
    current = nil
    output.to_s.lines.each_with_object(Hash.new { |h, k| h[k] = [] }) do |line, acc|
      line = line.chomp
      if (m = line.match(/\A===(\w+)===\z/))
        current = m[1]
      elsif current && !line.strip.empty?
        acc[current] << line
      end
    end
  end

  def parse(s)
    Result.new(
      mounts:   s["DF"].map { |l| mount_from(l) }.compact,
      inodes:   s["INODES"].map { |l| mount_from(l) }.compact,
      swap:     usage_triple(s["SWAP"].first),
      memory:   usage_triple(s["MEM"].first),
      top_dirs: s["TOPDIRS"].map { |l| dir_from(l) }.compact,
      error:    nil
    )
  end

  # "filesystem size used avail pcent mount" (df -P is single-space stable).
  def mount_from(line)
    f = line.split(/\s+/)
    return nil if f.size < 6
    Mount.new(filesystem: f[0], size: f[1].to_i, used: f[2].to_i, avail: f[3].to_i,
              percent: f[4].to_i, mount: f[5..].join(" "))
  end

  # "total used free" in bytes.
  def usage_triple(line)
    return nil if line.blank?
    t, u, _f = line.split(/\s+/).map(&:to_i)
    return nil if t.to_i.zero?
    { total: t, used: u, percent: ((u.to_f / t) * 100).round }
  end

  def dir_from(line)
    bytes, _, path = line.strip.partition(/\s+/)
    return nil if path.blank? || bytes.to_i.zero?
    Dir.new(path: path.strip, bytes: bytes.to_i)
  end

  def failure(message)
    @error = message
    Result.new(mounts: [], inodes: [], swap: nil, memory: nil, top_dirs: [], error: message)
  end
end
