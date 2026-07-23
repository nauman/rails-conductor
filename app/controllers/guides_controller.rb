class GuidesController < ApplicationController
  # Public docs — no auth, like the landing page.
  skip_before_action :authenticate_user!
  skip_before_action :set_current_organization
  skip_before_action :require_onboarding

  # Docs now live on the kuickr hub (single source of truth). Keep the /docs routes
  # so existing links, bookmarks, and search results don't 404 — 301 them to the hub
  # instead. Permanent redirect passes SEO to kuickr and prevents a stale in-app copy
  # from drifting. Per-slug deep links land on the hub index (kuickr filenames don't
  # map 1:1 to the old slugs); add a slug→path map here if we want to preserve them.
  KUICKR_HUB = "https://kuickr.co/conductor/docs/00-index.md".freeze

  def index
    redirect_to KUICKR_HUB, allow_other_host: true, status: :moved_permanently
  end

  def show
    redirect_to KUICKR_HUB, allow_other_host: true, status: :moved_permanently
  end
end
