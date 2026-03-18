# Pin npm packages by running ./bin/importmap

pin "application"
pin "@hotwired/turbo-rails", to: "turbo.min.js"
pin "@hotwired/stimulus", to: "stimulus.min.js"
pin "@hotwired/stimulus-loading", to: "stimulus-loading.js"
pin_all_from "app/javascript/controllers", under: "controllers"

# RapidRailsUI Controllers
pin_all_from "app/javascript/controllers/rapid_rails_ui", under: "controllers/rapid_rails_ui"
pin_all_from "app/javascript/controllers/rapid_rails_ui/shared", under: "controllers/rapid_rails_ui/shared"
