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
    html[:class] = [ "text-indigo-600 hover:text-indigo-700 hover:underline dark:text-indigo-400", opts[:class] ].compact.join(" ")
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
        primary: "text-indigo-600 hover:text-indigo-700 dark:text-indigo-400",
        success: "text-green-600 hover:text-green-700",
        danger:  "text-red-600 hover:text-red-700",
        warning: "text-amber-600 hover:text-amber-700",
        slate:   "text-slate-600 hover:text-slate-900 dark:text-slate-300 dark:hover:text-white"
      }
      return [ "inline-flex items-center gap-1 font-medium hover:underline", link_colors[color] || link_colors[:primary], extra ].compact.join(" ")
    end

    variants = {
      solid: {
        primary: "bg-indigo-600 hover:bg-indigo-700 text-white",
        success: "bg-green-600 hover:bg-green-700 text-white",
        danger:  "bg-red-600 hover:bg-red-700 text-white",
        warning: "bg-amber-500 hover:bg-amber-600 text-white",
        slate:   "bg-slate-700 hover:bg-slate-800 text-white"
      },
      outline: {
        primary: "border border-indigo-300 text-indigo-700 hover:bg-indigo-50 dark:border-indigo-500 dark:text-indigo-300 dark:hover:bg-indigo-950",
        success: "border border-green-300 text-green-700 hover:bg-green-50",
        danger:  "border border-red-300 text-red-700 hover:bg-red-50",
        warning: "border border-amber-300 text-amber-700 hover:bg-amber-50",
        slate:   "border border-slate-300 text-slate-700 hover:bg-slate-50 dark:border-slate-600 dark:text-slate-200 dark:hover:bg-slate-800"
      },
      ghost: {
        primary: "text-indigo-700 hover:bg-indigo-50 dark:text-indigo-300 dark:hover:bg-indigo-950",
        success: "text-green-700 hover:bg-green-50",
        danger:  "text-red-700 hover:bg-red-50",
        warning: "text-amber-700 hover:bg-amber-50",
        slate:   "text-slate-600 hover:bg-slate-100 dark:text-slate-300 dark:hover:bg-slate-800"
      }
    }
    vmap = variants[variant.to_sym] || variants[:solid]
    base = "inline-flex items-center justify-center font-medium rounded-md transition-colors"
    [ base, sizes[size.to_sym] || sizes[:md], vmap[color] || vmap[:slate], extra ].compact.join(" ")
  end

  def rui_badge_classes(color, size)
    soft = {
      primary: "bg-indigo-100 text-indigo-800",
      success: "bg-green-100 text-green-800",
      danger:  "bg-red-100 text-red-800",
      warning: "bg-amber-100 text-amber-800",
      slate:   "bg-slate-100 text-slate-700 dark:bg-slate-700 dark:text-slate-200"
    }
    sizes = { sm: "text-xs px-2 py-0.5", md: "text-xs px-2.5 py-0.5", lg: "text-sm px-3 py-1" }
    [ "inline-flex items-center font-medium rounded-full", soft[color] || soft[:slate], sizes[size] || sizes[:md] ].join(" ")
  end

  def rui_alert_classes(type)
    styles = {
      info:    "bg-blue-50 border-blue-200 text-blue-800 dark:bg-blue-950 dark:border-blue-900 dark:text-blue-200",
      success: "bg-green-50 border-green-200 text-green-800",
      danger:  "bg-red-50 border-red-200 text-red-800 dark:bg-red-950 dark:border-red-900 dark:text-red-200",
      warning: "bg-amber-50 border-amber-200 text-amber-800"
    }
    [ "rounded-md border px-4 py-3 text-sm", styles[type] || styles[:info] ].join(" ")
  end

  module_function :rui_btn_classes
end
