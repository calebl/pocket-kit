Rails.application.routes.draw do
  mount PocketKit::Engine, at: "/pocket-kit"

  root "pages#home"
  get "notes/:id", to: "pages#note", as: :note
  get "broken/:id", to: "pages#broken", as: :broken
end
