# frozen_string_literal: true

class ApplicationController < ActionController::API
  # Use the per-request id as the Three.dev session id so all LLM calls in this request
  # are grouped into one conversation. session_id is OPAQUE — swap this for current_user.id,
  # a conversation record id, or any stable identifier that should group a conversation.
  before_action { Current.session_id = request.request_id }
end
