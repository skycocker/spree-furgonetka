require "ostruct"
require "monitor"

# Minimal stand-in for a Spree::Store row, so the OAuth/token logic is testable
# without a database. Like ActiveRecord, every instance holds its own snapshot
# of the row: an instance loaded earlier (think Spree::Store.default, cached)
# keeps its old private_metadata until reloaded, while `find` and `with_lock`
# see the current row. `with_lock` is a real (re-entrant) lock per row, so
# concurrent refreshes can be exercised with threads.
class FakeStore
  ROWS = {}
  LOCKS = Hash.new { |hash, id| hash[id] = Monitor.new }
  CACHE_CLEARS = Hash.new(0)

  class << self
    def create(metadata = {})
      id = (ROWS.keys.max || 0) + 1
      ROWS[id] = deep_copy(metadata)
      new(id)
    end

    def find(id)
      raise KeyError, "no FakeStore #{id}" unless ROWS.key?(id)

      new(id)
    end

    def reset!
      ROWS.clear
      LOCKS.clear
      CACHE_CLEARS.clear
    end

    def deep_copy(value)
      Marshal.load(Marshal.dump(value))
    end
  end

  attr_reader :id, :private_metadata

  def initialize(id)
    @id = id
    reload
  end

  def persisted?
    true
  end

  def reload
    @private_metadata = self.class.deep_copy(ROWS.fetch(id))
    self
  end

  def with_lock
    LOCKS[id].synchronize do
      reload
      yield
    end
  end

  def update_column(column, value)
    raise ArgumentError, "unexpected column #{column}" unless column == :private_metadata

    ROWS[id] = self.class.deep_copy(value)
    @private_metadata = self.class.deep_copy(value)
    true
  end

  # The current row, bypassing any instance snapshot.
  def row
    ROWS.fetch(id)
  end

  def cache_clears
    CACHE_CLEARS[id]
  end

  private

  # Spree::Store#clear_cache (private there too) expires Rails.cache's default_store.
  def clear_cache
    CACHE_CLEARS[id] += 1
  end
end

# Builds an order double shaped like the bits PackageBuilder reads.
def build_fake_order(point: "KRA01M", code: "INPOST", weight: 0.3, qty: 2)
  country = OpenStruct.new(iso: "PL")
  address = OpenStruct.new(full_name: "Jan Kowalski", phone: "+48600100200",
                           address1: "Example St 1", zipcode: "00-001",
                           city: "Warsaw", country: country)
  variant = OpenStruct.new(weight: weight, depth: 8, width: 23, height: 14)
  line_item = OpenStruct.new(variant: variant, quantity: qty)
  method = OpenStruct.new(code: code)
  rate = OpenStruct.new(selected: true, shipping_method: method)
  shipment = OpenStruct.new(shipping_rates: [rate], shipping_method: method)
  OpenStruct.new(
    public_metadata: { "furgonetka_point" => point }.compact,
    email: "jan@example.com",
    ship_address: address,
    line_items: [line_item],
    shipments: [shipment]
  )
end
