Spree::Core::Engine.add_routes do
  namespace :admin do
    get "furgonetka/connect", to: "furgonetka#connect", as: :furgonetka_connect
    get "furgonetka/callback", to: "furgonetka#callback", as: :furgonetka_callback
    post "orders/:order_id/furgonetka/label", to: "furgonetka#create_label", as: :furgonetka_create_label
  end
end
