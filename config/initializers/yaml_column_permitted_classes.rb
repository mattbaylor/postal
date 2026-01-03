# frozen_string_literal: true

# Configure permitted classes for YAML column serialization
# This is required for Rails 7.1+ with Psych 5.x due to stricter security defaults
#
# Without this, models using `serialize :column, type: Hash` will fail to deserialize
# with: Psych::DisallowedClass (Tried to load unspecified class: ActiveSupport::HashWithIndifferentAccess)

Rails.application.config.active_record.yaml_column_permitted_classes = [
  ActiveSupport::HashWithIndifferentAccess,
  Symbol,
  Time,
  Date,
  DateTime
]
