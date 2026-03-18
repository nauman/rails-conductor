// Import and register all your controllers from the importmap via controllers/**/*_controller
import { application } from "controllers/application"
import { eagerLoadControllersFrom } from "@hotwired/stimulus-loading"
eagerLoadControllersFrom("controllers", application)


// ==========================================================================
// RapidRailsUI Controllers
// ==========================================================================

import AccordionController from "controllers/rapid_rails_ui/accordion_controller"
import AlertController from "controllers/rapid_rails_ui/alert_controller"
import BadgeController from "controllers/rapid_rails_ui/badge_controller"
import CheckboxController from "controllers/rapid_rails_ui/checkbox_controller"
import CheckboxSwitchController from "controllers/rapid_rails_ui/checkbox_switch_controller"
import ClipboardController from "controllers/rapid_rails_ui/clipboard_controller"
import ComboboxController from "controllers/rapid_rails_ui/combobox_controller"
import DatePickerController from "controllers/rapid_rails_ui/date_picker_controller"
import DialogController from "controllers/rapid_rails_ui/dialog_controller"
import EditableController from "controllers/rapid_rails_ui/editable_controller"
import InputValidationController from "controllers/rapid_rails_ui/input_validation_controller"
import LiveSearchController from "controllers/rapid_rails_ui/live_search_controller"
import MenuController from "controllers/rapid_rails_ui/menu_controller"
import PaginationJumperController from "controllers/rapid_rails_ui/pagination_jumper_controller"
import StepsController from "controllers/rapid_rails_ui/steps_controller"
import SubmenuController from "controllers/rapid_rails_ui/submenu_controller"
import TableController from "controllers/rapid_rails_ui/table_controller"
import TextareaValidationController from "controllers/rapid_rails_ui/textarea_validation_controller"
import TimePickerController from "controllers/rapid_rails_ui/time_picker_controller"
import UploadController from "controllers/rapid_rails_ui/upload_controller"
import CssHighlightNavController from "controllers/rapid_rails_ui/shared/css_highlight_nav_controller"
import KeyboardController from "controllers/rapid_rails_ui/shared/keyboard_controller"
import PopupController from "controllers/rapid_rails_ui/shared/popup_controller"
import RecentSearchesController from "controllers/rapid_rails_ui/shared/recent_searches_controller"
import SearchController from "controllers/rapid_rails_ui/shared/search_controller"
import SwitchController from "controllers/rapid_rails_ui/shared/switch_controller"
import VoiceSearchController from "controllers/rapid_rails_ui/shared/voice_search_controller"

application.register("accordion", AccordionController)
application.register("alert", AlertController)
application.register("badge", BadgeController)
application.register("checkbox", CheckboxController)
application.register("checkbox-switch", CheckboxSwitchController)
application.register("clipboard", ClipboardController)
application.register("combobox", ComboboxController)
application.register("date-picker", DatePickerController)
application.register("dialog", DialogController)
application.register("editable", EditableController)
application.register("input-validation", InputValidationController)
application.register("live-search", LiveSearchController)
application.register("menu", MenuController)
application.register("rapid-rails-ui--pagination-jumper", PaginationJumperController)
application.register("steps", StepsController)
application.register("submenu", SubmenuController)
application.register("table", TableController)
application.register("textarea-validation", TextareaValidationController)
application.register("time-picker", TimePickerController)
application.register("upload", UploadController)
application.register("css-highlight-nav", CssHighlightNavController)
application.register("keyboard", KeyboardController)
application.register("popup", PopupController)
application.register("recent-searches", RecentSearchesController)
application.register("search", SearchController)
application.register("switch", SwitchController)
application.register("voice-search", VoiceSearchController)
