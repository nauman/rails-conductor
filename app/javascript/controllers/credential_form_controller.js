import { Controller } from "@hotwired/stimulus"

// Dynamic credential form: shows only the fields the selected provider needs, and
// relabels the key/secret to that provider's terminology (SMTP username, API token,
// access key id…). Progressive enhancement — without JS every field just shows.
export default class extends Controller {
  static targets = [
    "provider", "apiKeyLabel", "apiSecretGroup", "apiSecretLabel",
    "accountIdGroup", "regionGroup", "regionLabel", "regionInput", "regionHint", "endpointGroup"
  ]

  // per-provider field config. regionRequired: SES SMTP passwords are region-specific,
  // so a blank region silently defaults to us-east-1 and 535s — force it there.
  static CONFIG = {
    cloudflare:   { accountId: true,  region: true,  endpoint: false, apiKey: "API token (or R2 access key id)", apiSecret: "R2 secret access key (for R2 backups)" },
    amazon_ses:   { accountId: false, region: true,  regionRequired: true, endpoint: true, apiKey: "SMTP username", apiSecret: "SMTP password" },
    aws:          { accountId: false, region: true,  endpoint: true,  apiKey: "Access key id",   apiSecret: "Secret access key" },
    digitalocean: { accountId: false, region: true,  endpoint: true,  apiKey: "Spaces key",      apiSecret: "Spaces secret" },
    hetzner:      { accountId: false, region: false, endpoint: false, apiKey: "API token",       apiSecret: "" },
    stripe:       { accountId: false, region: false, endpoint: false, apiKey: "Secret key",      apiSecret: "" },
    sendgrid:     { accountId: false, region: false, endpoint: false, apiKey: "API key",         apiSecret: "" },
    github:       { accountId: false, region: false, endpoint: false, apiKey: "Token",           apiSecret: "" },
    github_app:   { accountId: false, region: false, endpoint: false, apiKey: "App id",          apiSecret: "Private key" }
  }

  connect() { this.update() }

  update() {
    const cfg = this.constructor.CONFIG[this.providerTarget.value] ||
      { accountId: false, region: false, endpoint: false, apiKey: "API key", apiSecret: "API secret (optional)" }

    this.#toggle(this.accountIdGroupTarget, cfg.accountId)
    this.#toggle(this.regionGroupTarget, cfg.region)
    this.#toggle(this.endpointGroupTarget, cfg.endpoint)
    this.#toggle(this.apiSecretGroupTarget, cfg.apiSecret !== "")

    if (this.hasApiKeyLabelTarget) this.apiKeyLabelTarget.textContent = cfg.apiKey
    if (this.hasApiSecretLabelTarget && cfg.apiSecret) this.apiSecretLabelTarget.textContent = cfg.apiSecret

    // Region required-ness (SES): flip the label, the `required` attribute, and a hint.
    const required = !!cfg.regionRequired
    if (this.hasRegionLabelTarget) this.regionLabelTarget.textContent = required ? "Region (required)" : "Region (optional)"
    if (this.hasRegionInputTarget) this.regionInputTarget.required = required
    if (this.hasRegionHintTarget) this.regionHintTarget.textContent = required ? "Must match the AWS region where the SMTP credentials were created." : ""
  }

  #toggle(el, show) { el.classList.toggle("hidden", !show) }
}
