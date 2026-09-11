# Where an app's files live inside its checkout.
#
# Git operates on the REPOSITORY; Kamal and every config read operate on the APP
# inside it. For a single-app repo those are the same directory, which is why
# they were conflated for so long. For a monorepo they are not.
#
# The containment rule lives here rather than in each caller because it is a
# security control, not a convenience: `app_root` is config-supplied, and
# File.directory? follows symlinks, so a repository shipping
# `alfaaz-rails -> ../other-app` would otherwise let one app read another app's
# .kamal/secrets. Two callers copying this check is two places for it to rot.
module RepoCheckout
  # The resolved app directory inside checkout_dir, or nil when app_root is
  # missing, escapes the checkout, or cannot be resolved. Never raises: callers
  # decide how to report it, and nil always means "do not proceed".
  def contained_app_dir(checkout_dir, app_root)
    return checkout_dir if app_root.blank?

    candidate = File.join(checkout_dir, app_root)
    return nil unless File.directory?(candidate)

    root = File.realpath(checkout_dir)
    resolved = File.realpath(candidate)
    return resolved if resolved == root || resolved.start_with?(root + File::SEPARATOR)

    nil
  rescue StandardError
    nil
  end
end
