# Defense-in-depth against cross-tenant association: a record must not reference
# a belongs_to that lives in a different organization (e.g. an app pointing at
# another org's server, or a backup at another org's credential). Controllers
# should already scope by org; this closes the gap when a raw foreign id slips
# through strong params.
#
# Skipped when this record has no organization (legacy / global records), and when
# the related record has none but this org is one the operator vetted — so it
# never breaks existing data. An org the operator did not vet (open sign-up) never
# gets an org-less, i.e. operator-owned, record.
module OrganizationConsistency
  extend ActiveSupport::Concern

  class_methods do
    def validate_same_organization(*associations)
      validate do
        associations.each do |assoc|
          related = public_send(assoc)
          next if related.nil? || organization_id.nil?
          next if related.organization_id.nil? && !Organization.find_by(id: organization_id)&.untrusted_network_origin?
          next if related.organization_id == organization_id

          errors.add(assoc, "must belong to the same organization")
        end
      end
    end
  end
end
