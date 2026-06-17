# frozen_string_literal: true

# Carries the per-request session id so reporting can read it without threading it
# through every method (the Rails analog of Go's context-based WithSessionID). Set once
# per request in ApplicationController.
class Current < ActiveSupport::CurrentAttributes
  attribute :session_id
end
