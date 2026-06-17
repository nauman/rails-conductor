require "tmpdir"
require "open3"

# Generates an ed25519 SSH keypair for cloning a private repo. The public key is
# added (read-only) to the repo's GitHub deploy keys; the private key is stored
# (encrypted) and used by the deployers at clone time.
class DeployKeyGenerator
  class Error < StandardError; end

  # Returns { private_key:, public_key:, fingerprint: }.
  def self.generate(comment: "conductor")
    Dir.mktmpdir("deploykey") do |dir|
      path = File.join(dir, "id_ed25519")
      _out, err, status = Open3.capture3(
        "ssh-keygen", "-t", "ed25519", "-C", comment, "-f", path, "-N", "", "-q"
      )
      raise Error, "ssh-keygen failed: #{err}" unless status.success?

      pub = File.read("#{path}.pub").strip
      {
        private_key: File.read(path),
        public_key:  pub,
        fingerprint: fingerprint_for(pub)
      }
    end
  end

  # "<type> <base64> <comment>" → SHA256 fingerprint, best-effort.
  def self.fingerprint_for(public_key)
    blob = public_key.split(/\s+/)[1]
    return nil if blob.blank?

    require "digest"
    "SHA256:#{Digest::SHA256.base64digest(Base64.decode64(blob)).delete("=")}"
  rescue StandardError
    nil
  end
end
