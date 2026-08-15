# frozen_string_literal: true

# Compatibility placeholder because the uploaded program referenced this file,
# but the original FCX policy implementation was not included in the upload.
# NVDA and DELL simulations do not use the FCX-specific branch.
module SymbolPolicies
  module FCXVolatilityPolicy
    module_function

    def apply(data, context: {})
      symbol = data[:symbol].to_s

      if symbol.include?("FCX")
        raise LoadError,
              "The original lib/symbol_policies/fcx_volatility_policy.rb " \
              "is required before enabling FCX policies."
      end

      { size_multiplier: 1.0, context: context }
    end
  end
end
