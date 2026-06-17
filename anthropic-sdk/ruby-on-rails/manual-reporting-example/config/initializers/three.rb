# frozen_string_literal: true

# Load the Three.dev reporter (a plain lib file, not Zeitwerk-managed) and build the
# process-wide config once from the environment. dotenv-rails has already loaded .env.
require Rails.root.join("lib", "three").to_s

THREE_CONFIG = Three::Config.new(
  api_key: ENV.fetch("THREE_API_KEY"),
  use_case_slug: ENV.fetch("USE_CASE_SLUG"),
  endpoint: ENV["THREE_ENDPOINT"]
).freeze
