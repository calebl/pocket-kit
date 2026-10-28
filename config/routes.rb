PocketKit::Engine.routes.draw do
  post "feedback", to: "feedback#create", as: :feedback
  post "errors", to: "errors#create", as: :errors
end
