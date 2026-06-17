require "kramdown"
require "kramdown-parser-gfm"

# A documentation guide backed by a markdown file in docs/guides/. Rendered at
# /docs (public). Files carry simple YAML frontmatter (title, description, order).
class Guide
  GUIDES_DIR = Rails.root.join("docs", "guides")
  SLUG = /\A[a-z0-9][a-z0-9-]*\z/

  attr_reader :slug, :title, :description, :order, :body

  def initialize(slug:, title:, description:, order:, body:)
    @slug = slug
    @title = title.presence || slug.titleize
    @description = description
    @order = order || 99
    @body = body
  end

  def self.all
    return [] unless Dir.exist?(GUIDES_DIR)

    Dir.glob(GUIDES_DIR.join("*.md")).map { |f| from_file(f) }.sort_by { |g| [g.order, g.title] }
  end

  def self.find(slug)
    return nil unless slug.to_s.match?(SLUG)

    path = GUIDES_DIR.join("#{slug}.md")
    return nil unless File.file?(path) && path.to_s.start_with?(GUIDES_DIR.to_s)

    from_file(path)
  end

  def self.from_file(path)
    front, body = split_frontmatter(File.read(path))
    new(slug: File.basename(path, ".md"),
        title: front["title"], description: front["description"], order: front["order"], body: body)
  end

  # Renders the markdown body to HTML (GitHub-flavored: fenced code + tables).
  def html
    Kramdown::Document.new(@body, input: "GFM", auto_ids: true, hard_wrap: false).to_html.html_safe
  end

  def self.split_frontmatter(raw)
    if raw =~ /\A---\s*\n(.*?)\n---\s*\n(.*)\z/m
      front = YAML.safe_load($1) || {}
      [front, $2]
    else
      [{}, raw]
    end
  rescue Psych::SyntaxError
    [{}, raw]
  end
  private_class_method :split_frontmatter, :from_file
end
