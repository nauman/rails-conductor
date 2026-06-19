# Local Tailwind reimplementation of the handful of RapidRailsUI view helpers
# the app uses. Replaces the private `rapid_rails_ui` gem so the app builds
# without an external (paid/private) source. Class strings are literal so
# Tailwind's automatic content detection picks them up.
module RuiComponentsHelper
  # rui_badge(text:, color:, size:, class:)
  def rui_badge(text:, color: :slate, size: :sm, **opts)
    content_tag(:span, text, class: [ rui_badge_classes(color, size), opts[:class] ].compact.join(" "))
  end

  # rui_button("Label", url:, variant:, color:, size:, class:) — link styled as a button
  def rui_button(label = nil, url:, variant: :solid, color: :primary, size: :md, **opts, &block)
    content = block ? capture(&block) : label
    classes = rui_btn_classes(variant: variant, color: color, size: size, extra: opts[:class])
    link_to(content, url, **opts.except(:class), class: classes)
  end

  # rui_button_to("Label", path, method:, ...) OR rui_button_to(path, ...) { block }
  def rui_button_to(*args, method: :post, variant: :solid, color: :slate, size: :md, title: nil, data: {}, **opts, &block)
    if block
      path  = args.first
      label = capture(&block)
    else
      label, path = args
    end
    classes = rui_btn_classes(variant: variant, color: color, size: size, extra: opts[:class])
    button_to(label, path, method: method, title: title, data: data, class: classes, form: { class: "inline-block" })
  end

  # rui_link("Text", url:, external:)
  def rui_link(text, url:, external: false, **opts)
    html = opts.except(:class)
    html[:class] = [ "text-primary hover:text-primary-strong hover:underline", opts[:class] ].compact.join(" ")
    html.merge!(target: "_blank", rel: "noopener") if external
    link_to(text, url, **html)
  end

  # rui_alert(type:, class:) do ... end
  def rui_alert(type: :info, **opts, &block)
    content_tag(:div, capture(&block), class: [ rui_alert_classes(type), opts[:class] ].compact.join(" "))
  end

  # ---- class builders (also used by the form-builder extension) ----

  def rui_btn_classes(variant: :solid, color: :primary, size: :md, extra: nil)
    sizes = { sm: "text-xs px-2.5 py-1 gap-1", md: "text-sm px-3.5 py-2 gap-1.5", lg: "text-base px-4 py-2.5 gap-2" }

    if variant.to_sym == :link
      link_colors = {
        primary: "text-primary hover:text-primary-strong",
        success: "text-primary-strong hover:text-primary",
        danger:  "text-danger hover:text-danger-deep",
        warning: "text-warning hover:text-warning",
        slate:   "text-muted hover:text-ink"
      }
      return [ "inline-flex items-center gap-1 font-medium hover:underline", link_colors[color] || link_colors[:primary], extra ].compact.join(" ")
    end

    variants = {
      solid: {
        primary: "bg-primary hover:bg-primary-strong text-white",
        success: "bg-primary-strong hover:bg-primary text-white",
        danger:  "bg-danger hover:bg-danger-deep text-white",
        warning: "bg-warning-bright hover:bg-warning text-white",
        slate:   "bg-ink hover:bg-body text-white"
      },
      outline: {
        primary: "border border-primary/40 text-primary hover:bg-primary-tint",
        success: "border border-primary/40 text-primary-strong hover:bg-primary-tint",
        danger:  "border border-danger/40 text-danger hover:bg-danger-tint",
        warning: "border border-warning/40 text-warning hover:bg-warning-tint",
        slate:   "border border-border-strong text-body hover:bg-fill"
      },
      ghost: {
        primary: "text-primary hover:bg-primary-tint",
        success: "text-primary-strong hover:bg-primary-tint",
        danger:  "text-danger hover:bg-danger-tint",
        warning: "text-warning hover:bg-warning-tint",
        slate:   "text-muted hover:bg-fill-strong"
      }
    }
    vmap = variants[variant.to_sym] || variants[:solid]
    base = "inline-flex items-center justify-center font-medium rounded-md transition-colors"
    [ base, sizes[size.to_sym] || sizes[:md], vmap[color] || vmap[:slate], extra ].compact.join(" ")
  end

  def rui_badge_classes(color, size)
    soft = {
      primary: "bg-primary-tint text-primary",
      success: "bg-primary-tint text-primary",
      danger:  "bg-danger-tint text-danger-deep",
      warning: "bg-warning-tint text-warning",
      slate:   "bg-fill text-muted"
    }
    sizes = { sm: "text-xs px-2 py-0.5", md: "text-xs px-2.5 py-0.5", lg: "text-sm px-3 py-1" }
    [ "inline-flex items-center font-medium rounded-full", soft[color] || soft[:slate], sizes[size] || sizes[:md] ].join(" ")
  end

  def rui_alert_classes(type)
    styles = {
      info:    "bg-info-tint border-info/30 text-info",
      success: "bg-primary-tint border-primary/30 text-primary",
      danger:  "bg-danger-tint border-danger/30 text-danger-deep",
      warning: "bg-warning-tint border-warning/30 text-warning"
    }
    [ "rounded-md border px-4 py-3 text-sm", styles[type] || styles[:info] ].join(" ")
  end

  module_function :rui_btn_classes
end
