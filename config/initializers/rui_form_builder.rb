# Adds `f.rui_button` to the default form builder, replacing the equivalent
# helper from the removed rapid_rails_ui gem. Renders a styled submit button.
module RuiFormBuilderExtension
  def rui_button(label = "Save", color: :primary, size: :md, **opts)
    @template.button_tag(
      label,
      type: "submit",
      class: RuiComponentsHelper.rui_btn_classes(variant: :solid, color: color, size: size, extra: opts[:class])
    )
  end
end

ActiveSupport.on_load(:action_view) do
  ActionView::Helpers::FormBuilder.include(RuiFormBuilderExtension)
end
