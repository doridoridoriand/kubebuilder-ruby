# frozen_string_literal: true

module KrubyController
  module Owner
    module OwnerReference
      module_function

      def set_owner(object, owner, controller: false, block_owner_deletion: false)
        ref = {
          "apiVersion" => owner["apiVersion"],
          "kind" => owner["kind"],
          "name" => owner.dig("metadata", "name"),
          "uid" => owner.dig("metadata", "uid"),
        }
        ref["controller"] = controller if controller
        ref["blockOwnerDeletion"] = block_owner_deletion if block_owner_deletion
        object["metadata"]["ownerReferences"] ||= []
        object["metadata"]["ownerReferences"] << ref
        object
      end
    end
  end
end
