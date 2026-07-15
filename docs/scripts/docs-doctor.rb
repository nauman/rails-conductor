#!/usr/bin/env ruby
# frozen_string_literal: true

# Canonical docs doctor.
#
# Validates the delivery-sequence artifact against the contract that
# docs/roadmap/00-delivery-sequence.md advertises ("interactive: foundation-audit
# donut, wave gantt, per-wave bar chart, dependency graph, filterable table") and
# that specification.agent.md promises is mirrored to docs/plans/. Previously this
# gate lived only in an out-of-repo auditor, so CI could stay green while the page
# silently missed required components. Now it runs in CI (see .github/workflows/ci.yml).
#
# Exit 0 = all checks pass. Exit 1 = at least one failure (details printed).
#
# This script is the AUTHORITATIVE, in-repo definition of the docs contract:
# the component identifiers and checks below ARE the canonical gate. If an
# external harness disagrees, reconcile it to this file (or replace this file
# wholesale) — the contract must have a single source of truth, and per the
# decision to bring the gate in-repo, that source is here + CI, not an
# out-of-repo tool.
#
# Usage: ruby docs/scripts/docs-doctor.rb

DOCS_ROOT = File.expand_path("..", __dir__)

# The two mirrored copies of the delivery-sequence page.
TARGETS = [
  "roadmap/00-delivery-sequence.html",
  "plans/00-delivery-sequence.html"
].freeze

# Required interactive components — each is (label => matcher). A matcher is a
# Regexp (must match) or an Array of Regexps (all must match).
REQUIRED_COMPONENTS = {
  "foundation donut"           => [ /id="foundation-donut"/, /stroke-dasharray=/ ],
  "graph filters"              => /id="graph-filters"/,
  "table filters"              => /id="table-filters"/,
  "slot-row target"            => [ /id="slot-row-/, /data-slot=/ ],
  "detail dialog"              => /<dialog[^>]*id="detail-dialog"/,
  "SVG edge construction"      => [ /class="edges"/, /M\$\{x2\},\$\{y2\} C/ ]
}.freeze

failures = []

def read(rel)
  File.read(File.join(DOCS_ROOT, rel))
end

TARGETS.each do |rel|
  path = File.join(DOCS_ROOT, rel)
  unless File.exist?(path)
    failures << "#{rel}: file is missing"
    next
  end
  html = read(rel)

  # 1. Required interactive components
  REQUIRED_COMPONENTS.each do |label, matcher|
    ok = Array(matcher).all? { |re| html.match?(re) }
    failures << "#{rel}: missing required component — #{label}" unless ok
  end

  # 2. Slot/wave count consistency (title vs. data)
  if (m = html.match(/—\s*(\d+)\s+slots,\s*(\d+)\s+waves/))
    declared_slots = m[1].to_i
    declared_waves = m[2].to_i
    actual_slots = html.scan(/\{id:"\d+"/).size
    actual_waves = html.scan(/\btheme:"/).size
    failures << "#{rel}: title says #{declared_slots} slots but data has #{actual_slots}" if declared_slots != actual_slots
    failures << "#{rel}: title says #{declared_waves} waves but data has #{actual_waves}" if declared_waves != actual_waves
  else
    failures << "#{rel}: title is missing the 'N slots, M waves' summary"
  end

  # 3. Internal link integrity — every relative file link must resolve on disk.
  #    Covers static href="…" links AND the plan:'…' paths in the ITEMS data
  #    (the slot/node links are built from those at runtime).
  dir = File.dirname(path)
  static_links = html.scan(/href="([^"]+)"/).flatten
  data_links   = html.scan(/\bplan:'([^']+)'/).flatten
  (static_links + data_links).each do |href|
    next if href.include?("${")                          # JS template placeholder, not a real link
    next if href.start_with?("#", "http://", "https://", "mailto:", "data:")

    target = href.split("#").first.split("?").first
    next if target.nil? || target.empty?

    resolved = File.expand_path(target, dir)
    failures << "#{rel}: broken link -> #{href}" unless File.exist?(resolved)
  end
end

# 5. Mirrored copies must be identical once the link-path prefix is normalized.
#    plans/ sits one directory up from roadmap/, so its intra-doc links carry a
#    "../roadmap/" prefix; strip that and the two files must be byte-for-byte
#    equal. This catches ALL drift — title, status, wave, deps, markup, and
#    script — not just the slot-ID set.
if TARGETS.all? { |t| File.exist?(File.join(DOCS_ROOT, t)) }
  roadmap = read("roadmap/00-delivery-sequence.html")
  plans   = read("plans/00-delivery-sequence.html")
  normalized_plans = plans.gsub("../roadmap/", "")
  if normalized_plans != roadmap
    # Surface the first differing line so drift is actionable, not just flagged.
    r_lines = roadmap.lines
    diff_at = normalized_plans.lines.each_with_index.find { |line, i| line != r_lines[i] }
    where = diff_at ? " (first diff near line #{diff_at[1] + 1})" : ""
    failures << "mirror drift: plans and roadmap copies differ beyond the link prefix#{where}"
  end
end

puts "Canonical docs doctor — #{TARGETS.size} target(s), #{REQUIRED_COMPONENTS.size} components each"
if failures.empty?
  puts "✓ all checks passed"
  exit 0
else
  puts "✗ #{failures.size} failure(s):"
  failures.each { |f| puts "  - #{f}" }
  exit 1
end
