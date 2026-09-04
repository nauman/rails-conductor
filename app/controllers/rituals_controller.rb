# The ritual library, for people. MCP could already read it
# (`conductor_runbook action: list_rituals`); a human could not, which meant
# "which rituals exist, and which have we customised?" was answerable by an agent
# and not by its operator.
#
# READ-ONLY, deliberately. Editing a ritual is editing the procedure Conductor
# hands to agents mid-incident, and seeding is create-if-missing — so an edit made
# here is permanent and silent, and it deserves a considered surface rather than
# an inline field added because the page already existed.
class RitualsController < ApplicationController
  def index
    @rituals = Jazari::RecipeRecord.where(recipe_id: FleetRecipes.recipe_ids).order(:recipe_id).map do |record|
      { record: record, custom: FleetRecipes.diverged?(record) }
    end
  end

  def show
    # Canon only — the recipes table is shared, so an arbitrary id would render a row
    # this repo never shipped as though it were a fleet ritual.
    @recipe = FleetRecipes.canonical?(params[:id]) && Jazari::RecipeRecord.find_by(recipe_id: params[:id])
    # jazari answers an unknown id with a content-free EMPTY recipe rather than
    # raising, so rendering whatever it returns would show a typo as a real ritual
    # with no steps.
    return head :not_found unless @recipe

    @custom = FleetRecipes.diverged?(@recipe)
  end
end
