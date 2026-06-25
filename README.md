# spree_furgonetka

Furgonetka shipping integration for [Spree](https://spreecommerce.org) (5.x).

Two features, usable independently:

1. **Checkout point-picker** — when the customer chooses a point-based method
   (InPost Paczkomat by default), the official **Furgonetka Map** widget lets
   them pick a locker on a real map. It covers InPost (and other carriers')
   points **through your Furgonetka account — no InPost contract or NIP needed**.
   The chosen point is saved on the order and shown to staff in the admin.
2. **OAuth auto-labels** — connect your Furgonetka account once (OAuth2
   authorization-code, **no stored password**) and create the shipment + pull
   the label/tracking straight from the Spree admin order page.

No secrets live in this gem — it reads them from the **host app's Rails
credentials**.

## Requirements

- Spree 5.x (`spree_core`, `spree_storefront`, `spree_admin`)
- A Furgonetka account
  - a **Map API key** (domain-bound) — for the picker
  - an **OAuth app** (Client ID + Secret) — for auto-labels

## Installation

```ruby
# Gemfile
gem "spree_furgonetka", git: "https://github.com/skycocker/spree-furgonetka.git"
```

```sh
bundle install
```

## Configuration

Add your Furgonetka secrets to the **host app's** credentials
(`bin/rails credentials:edit`):

```yaml
furgonetka:
  map_api_key: "<Furgonetka Map widget JWT, bound to your domain>"
  api_client_id: "<OAuth app Client ID>"
  api_client_secret: "<OAuth app Client Secret>"
  sender:                                # label "from" address; required for auto-labels
    name: "Jane Doe"
    company: "Your Shop"
    email: "shop@example.com"
    phone: "600100200"
    street: "Example St 1"
    postcode: "00-001"
    city: "Warsaw"
    country_code: "PL"
```

The Furgonetka "create package" endpoint requires the sender's `name`,
`company`, `email`, `phone`, `street`, `postcode` and `city`.

Optionally tune behaviour in an initializer (all values have sane defaults):

```ruby
# config/initializers/spree_furgonetka.rb
SpreeFurgonetka.configure do |c|
  c.courier_service_code = "INPOST"          # shipping-method code that shows the picker
  # Spree shipping-method code => Furgonetka service string (resolved to the
  # account-specific numeric service_id at send time). Map every code you use:
  c.service_map = { "INPOST" => "inpost", "Kurier" => "inpost", "DPD" => "dpd", "POCZTA" => "poczta" }
  # c.sender can also be set here instead of in credentials.
end
```

## How it works

### Point picker (storefront)

`app/views/spree/checkout/_delivery.html.erb` is overridden to render the
Furgonetka Map when a rate whose shipping-method `code` equals
`courier_service_code` is selected. The widget's callback fills hidden fields;
`Spree::CheckoutControllerDecorator` saves `furgonetka_point` (+ name) to the
order's `public_metadata` and **requires** it before the order can advance.

### Auto-labels (admin)

1. **Connect once:** visit `/admin/furgonetka/connect` (or click *Connect
   Furgonetka* on an order). You're sent to Furgonetka to log in + consent, then
   redirected back to `/admin/furgonetka/callback`, which stores a **refresh
   token** in the default store's `private_metadata` (no password kept).
   - Register the redirect URI on your OAuth app as
     `https://YOUR-DOMAIN/admin/furgonetka/callback`.
2. **Create a label:** on an order with a chosen point, click *Create Furgonetka
   label*. The gem builds the package (`SpreeFurgonetka::PackageBuilder`), calls
   the API, and stores the package id + tracking number on the order.

Tokens auto-refresh; the access token is never persisted longer than its 60-min
life.

## Testing

The library suite (OAuth client, package builder, configuration, token store)
runs standalone — no database — with Furgonetka HTTP stubbed by WebMock:

```sh
gem install rspec webmock      # or: bundle install
rspec
```

Request/feature specs that exercise the Spree controllers and views require a
Spree dummy app (`spree_dev_tools` → `bundle exec rake test_app`); the storefront
picker and admin partial are also verified against a live store.

## The label payload

`PackageBuilder` produces the flat body the `/packages` endpoint expects
(verified field-by-field against the live REST API):

```jsonc
{
  "service_id": 12345678,        // resolved from the method code via GET /account/services
  "sender":   { "name": "...", "company": "...", "email": "...", "phone": "...",
                "street": "...", "postcode": "...", "city": "...", "country_code": "PL" },
  "pickup":   { /* same shape — the label's collection / sender address */ },
  "receiver": { "name": "...", "email": "...", "phone": "...", "street": "...",
                "postcode": "...", "city": "...", "country_code": "PL",
                "point": "KRA01M" },   // the Paczkomat chosen at checkout (omit for courier)
  "parcels":  [ { "width": 23, "height": 14, "depth": 8, "weight": 0.6 } ]
}
```

The numeric `service_id` is account-specific, so it's looked up live and cached
(`Client#services` / `#service_id_for`) rather than hard-coded. The label PDF is
fetched from `GET /packages/:id/label`. Any API error is surfaced in the admin
flash.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
