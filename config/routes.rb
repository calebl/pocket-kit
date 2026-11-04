PocketKit::Engine.routes.draw do
  post "feedback", to: "feedback#create", as: :feedback
  post "errors", to: "errors#create", as: :errors
  get "replays/:id", to: "replays#show", as: :replay, constraints: { id: /[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/ }
end
