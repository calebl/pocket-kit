PocketKit::Engine.routes.draw do
  post "feedback", to: "feedback#create", as: :feedback
end
