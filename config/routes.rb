Spree::Core::Engine.add_routes do
  namespace :admin do
    get "furgonetka/connect", to: "furgonetka#connect", as: :furgonetka_connect
    # Registered as the redirect URI of the Furgonetka OAuth app — don't move it.
    get "furgonetka/callback", to: "furgonetka#callback", as: :furgonetka_callback
    post "furgonetka/refresh", to: "furgonetka#refresh", as: :furgonetka_refresh
    delete "furgonetka/disconnect", to: "furgonetka#disconnect", as: :furgonetka_disconnect
    post "orders/:order_id/furgonetka/label", to: "furgonetka#create_label", as: :furgonetka_create_label
  end
end
