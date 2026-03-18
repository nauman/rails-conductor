# frozen_string_literal: true

# ==============================================================================
# RapidRailsUI Configuration
# ==============================================================================
# This file allows you to customize RapidRailsUI component defaults and behavior.
#
# For full documentation, see: lib/rapid_rails_ui/configuration.rb in the gem
# Or visit: https://github.com/Rapid-Rails/rapid_rails_ui
#
# Most developers can use the built-in defaults and only customize colors.
# ==============================================================================

RapidRailsUI.configure do |config|
  # ==========================================================================
  # LICENSE KEY
  # ==========================================================================
  # Set via environment variable RAPID_RAILS_UI_LICENSE_KEY in production
  # License key: RRUI-PRO-NAUMANTARIQ-S1-D10-20270104-02CF11FC33
  # ==========================================================================
  # COLOR CONFIGURATION
  # ==========================================================================
  # Maps semantic color names to Tailwind color families
  # Change these to customize your app's color scheme
  #
  # Available Tailwind colors:
  # - Neutrals: zinc, gray, neutral, stone, slate
  # - Colors: red, orange, amber, yellow, lime, green, emerald, teal, cyan,
  #           sky, blue, indigo, violet, purple, fuchsia, pink, rose
  #
  # config.colors = {
  #   primary: 'zinc',      # Main brand color
  #   secondary: 'sky',     # Secondary actions
  #   accent: 'violet'      # Special highlights
  # }

  # ==========================================================================
  # COMPONENT DEFAULTS (Optional)
  # ==========================================================================
  # Override default properties for components
  # If not specified, sensible defaults are used
  #
  # Size Naming (Tailwind v4):
  # - Uses :base instead of :md (Tailwind v4 standard)
  # - Available: :xs, :sm, :base, :lg, :xl
  #
  # config.defaults = {
  #   button: {
  #     variant: :solid,    # solid, outline, ghost, soft, link
  #     size: :base,        # xs, sm, base, lg, xl
  #     shape: :rounded,    # rounded, pill, square, circle
  #     color: :primary     # primary, secondary, or any Tailwind color
  #   },
  #   badge: {
  #     variant: :solid,    # solid, outline, soft
  #     size: :sm,          # xs, sm, base, lg
  #     shape: :rounded,    # rounded, pill, square
  #     color: :primary     # primary, secondary, or any Tailwind color
  #   }
  # }
  #
  # For other component defaults (icon, typography, image, card),
  # see lib/rapid_rails_ui/configuration.rb in the gem

  # ==========================================================================
  # DARK MODE (Using Tailwind's dark: prefix)
  # ==========================================================================
  # RapidRailsUI uses Tailwind's built-in dark mode support.
  # No additional configuration needed here.
  #
  # To enable dark mode in your app:
  # 1. Add to tailwind.config.js: darkMode: 'class'
  # 2. Toggle dark mode by adding 'dark' class to <html> tag
  #
  # Example:
  #   <html class="dark">
  #
  # Components will automatically use appropriate dark mode colors.
end
