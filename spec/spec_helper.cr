require "spec"
require "../src/cr-coalesce"

# Ensure every example starts with an empty registry so specs are isolated
Spec.before_each do
  Coalesce.reset
end
