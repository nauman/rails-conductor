# frozen_string_literal: true

# ==============================================================================
# RapidRailsUI FormBuilder Extension
# ==============================================================================
# Extends Rails' ActionView::Helpers::FormBuilder with RapidRailsUI component
# methods (f.rui_button, f.rui_checkbox, etc.)
#
# This allows you to use RapidRailsUI components directly within form_with/form_for:
#
#   form_with(model: @user) do |f|
#     f.rui_button  # Auto-generates "Create User" or "Update User"
#     f.rui_checkbox(:newsletter, label: "Subscribe")
#   end
#
# ==============================================================================

Rails.application.config.to_prepare do
  require "rapid_rails_ui/form_builder"
  ActionView::Helpers::FormBuilder.include RapidRailsUI::FormBuilder
end
