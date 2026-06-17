# frozen_string_literal: true

Rails.application.routes.draw do
  # GET /weather?city=Madrid  -> runs the system-prompt + tool-call conversation and
  # reports BOTH LLM calls to Three.dev (off the request's critical path).
  get "/weather", to: "weather#show"
end
