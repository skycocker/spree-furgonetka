module SpreeFurgonetka
  # Persists the OAuth session obtained via the authorization-code flow. We never
  # store the user's account password — only the refresh token (plus the access
  # token, its expiry and a little bookkeeping), kept in the default store's
  # private_metadata (server-side only, never rendered).
  #
  # Furgonetka refresh tokens are single-use: every refresh returns a new pair
  # and revokes the old one. That makes three things non-negotiable:
  #
  # * Reads go to the database. Spree::Store.default is a Rails.cache copy of
  #   the row (Solid Cache in production, shared by every process), so reading
  #   through it hands out tokens that were already rotated → invalid_grant.
  # * Writes lock the row, merge only our keys into the freshest metadata and
  #   then expire Spree's cached copy. Merging into a stale copy used to write
  #   back old values of unrelated keys (Stripe, storefront password, …), and a
  #   stale cached store saved elsewhere could put back the revoked tokens.
  # * #synchronize holds that same row lock across a refresh, so when two
  #   processes (Puma workers, Solid Queue) need one at the same time the second
  #   waits and then finds the rotated tokens instead of spending a revoked one.
  class TokenStore
    ACCESS_TOKEN = "furgonetka_access_token".freeze
    REFRESH_TOKEN = "furgonetka_refresh_token".freeze
    EXPIRES_AT = "furgonetka_token_expires_at".freeze
    REFRESHED_AT = "furgonetka_token_refreshed_at".freeze
    AUTHORIZED_AT = "furgonetka_authorized_at".freeze
    RECONNECT_REASON = "furgonetka_reconnect_reason".freeze
    KEYS = [ACCESS_TOKEN, REFRESH_TOKEN, EXPIRES_AT, REFRESHED_AT, AUTHORIZED_AT, RECONNECT_REASON].freeze

    # Raised when tokens would be written inside the caller's database
    # transaction: rolling it back would undo a rotation Furgonetka has already
    # applied and resurrect the revoked refresh token (→ invalid_grant).
    class TransactionError < StandardError; end

    # A snapshot of the stored session, read in one go.
    Session = Struct.new(:access_token, :refresh_token, :expires_at, :refreshed_at,
                         :authorized_at, :reconnect_reason, keyword_init: true) do
      def connected?
        refresh_token.present?
      end

      # Furgonetka rejected the refresh token; only a new consent brings it back.
      def reconnect_required?
        !connected? && reconnect_reason.present?
      end

      def access_token_valid?(margin: 60)
        access_token.present? && !expires_at.nil? && expires_at > Time.now + margin
      end
    end

    def initialize(store: nil)
      @store = store
    end

    def session
      build_session(fresh_record.private_metadata)
    end

    def access_token
      session.access_token
    end

    def refresh_token
      session.refresh_token
    end

    def expires_at
      session.expires_at
    end

    # Yields the session as read under the row lock and keeps the lock until the
    # block returns, so a refresh inside it can't race another one.
    def synchronize
      record = fresh_record
      ensure_own_transaction!(record)
      record.with_lock do
        @synchronizing = true
        yield build_session(record.private_metadata)
      ensure
        @synchronizing = false
      end
    end

    # `authorized: true` marks a fresh consent (the callback), as opposed to a
    # refresh; either way a previous "reconnect required" mark is cleared.
    def save(access_token:, refresh_token:, expires_in:, authorized: false)
      now = Time.now
      pairs = {
        ACCESS_TOKEN => access_token,
        REFRESH_TOKEN => refresh_token,
        EXPIRES_AT => (now + expires_in.to_i).to_f,
        REFRESHED_AT => now.to_f,
        RECONNECT_REASON => nil
      }
      pairs[AUTHORIZED_AT] = now.to_f if authorized
      write(pairs)
    end

    # Drops a session Furgonetka refused to refresh and records why, so the admin
    # can offer "Połącz ponownie". Skipped when the stored refresh token is no
    # longer the rejected one — another process has replaced it meanwhile.
    def mark_reconnect_required(reason, refresh_token:)
      write(KEYS.index_with { nil }.merge(RECONNECT_REASON => reason.to_s.presence || "invalid_grant")) do |meta|
        meta[REFRESH_TOKEN] == refresh_token
      end
    end

    def clear
      write(KEYS.index_with { nil })
    end

    private

    def store_record
      @store || Spree::Store.default
    end

    def fresh_record
      record = store_record
      raise ArgumentError, "Furgonetka tokens need a persisted default Spree::Store" unless record&.persisted?

      # A new instance rather than #reload: the default store is a cached object
      # other code holds on to, and this one gets locked.
      record.class.find(record.id)
    end

    def build_session(meta)
      meta ||= {}
      Session.new(
        access_token: meta[ACCESS_TOKEN].presence,
        refresh_token: meta[REFRESH_TOKEN].presence,
        expires_at: time_at(meta[EXPIRES_AT]),
        refreshed_at: time_at(meta[REFRESHED_AT]),
        authorized_at: time_at(meta[AUTHORIZED_AT]),
        reconnect_reason: meta[RECONNECT_REASON].presence
      )
    end

    def time_at(value)
      value.present? ? Time.at(value.to_f) : nil
    end

    # Nil values remove the key rather than leaving `"key": null` behind.
    def write(pairs)
      record = fresh_record
      ensure_own_transaction!(record) unless @synchronizing
      written = record.with_lock do
        meta = (record.private_metadata || {}).to_h.stringify_keys
        next false if block_given? && !yield(meta)

        merged = meta.merge(pairs).reject { |key, value| KEYS.include?(key) && value.nil? }
        record.update_column(:private_metadata, merged)
        true
      end
      expire_cached_store(record) if written
      written
    end

    # Test fixtures wrap examples in a non-joinable transaction, which commits
    # nothing either way, so only a joinable one counts as the caller's.
    def ensure_own_transaction!(record)
      return unless record.class.respond_to?(:connection)

      transaction = record.class.connection.current_transaction
      return unless transaction.open? && transaction.joinable?

      raise TransactionError, "Furgonetka tokens can't be written inside a database transaction " \
                              "(a rollback would restore a refresh token Furgonetka has already revoked)"
    end

    # update_column skips the store's after_commit :clear_cache, so expire
    # Spree's cached default store ourselves — once the write is committed, or a
    # concurrent request could cache the old row again in between.
    def expire_cached_store(record)
      return unless record.respond_to?(:clear_cache, true)

      if defined?(ActiveRecord) && ActiveRecord.respond_to?(:after_all_transactions_commit)
        ActiveRecord.after_all_transactions_commit { record.send(:clear_cache) }
      else
        record.send(:clear_cache)
      end
    end
  end
end
