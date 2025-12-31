module RedmineWebhook
  module TimeEntryPatch
    extend ActiveSupport::Concern

    included do
      before_destroy :send_delete_webhook
    end

    private

    # Send webhook when time entry is deleted
    # This is needed because Redmine doesn't have a controller hook for delete
    def send_delete_webhook
      return unless overtime_activity?
      return unless plugin_enabled?

      webhook_url = global_webhook_url
      return if webhook_url.blank?

      Rails.logger.info "[Webhook] TimeEntry#before_destroy - Overtime entry ##{id} being deleted"

      # Build and send payload before destruction
      begin
        payload = build_delete_payload
        send_webhook(webhook_url, payload)
      rescue => e
        Rails.logger.error "[Webhook] Delete webhook error: #{e.message}"
      end

      # Don't block deletion - return true
      true
    end

    # Check if activity is Overtime
    def overtime_activity?
      return false unless activity
      activity_name = activity.name.to_s.downcase.strip
      ['overtime', 'ot'].any? { |ot| activity_name.include?(ot) }
    end

    # Check if plugin is enabled
    def plugin_enabled?
      settings = Setting.plugin_redmine_one_webhook rescue {}
      settings['enabled'] == '1'
    end

    # Get global webhook URL
    def global_webhook_url
      settings = Setting.plugin_redmine_one_webhook rescue {}
      settings['webhook_url'].to_s.strip
    end

    # Get webhook secret
    def webhook_secret
      settings = Setting.plugin_redmine_one_webhook rescue {}
      secret = settings['webhook_secret'].to_s.strip
      secret.present? ? secret : 'one_webhook_secret_key_2026'
    end

    # Build delete payload
    def build_delete_payload
      {
        event: 'overtime_sync',
        action: 'delete',
        timestamp: Time.now.iso8601,
        time_entry: RedmineWebhook::TimeEntryWrapper.new(self).to_hash
      }
    end

    # Generate HMAC-SHA256 signature
    def generate_signature(payload_string)
      OpenSSL::HMAC.hexdigest('SHA256', webhook_secret, payload_string)
    end

    # Send webhook to URL
    def send_webhook(webhook_url, payload)
      require 'net/http'
      require 'uri'
      require 'json'
      require 'openssl'

      request_body = payload.to_json
      signature = generate_signature(request_body)

      Rails.logger.info "[Webhook] Sending delete webhook for entry ##{id}"
      Rails.logger.info "[Webhook] Payload: #{request_body}"

      uri = URI.parse(webhook_url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == 'https')
      http.open_timeout = 10
      http.read_timeout = 30

      request = Net::HTTP::Post.new(uri.request_uri)
      request['Content-Type'] = 'application/json'
      request['X-Webhook-Signature'] = signature
      request['X-Webhook-Event'] = payload[:event]
      request['X-Webhook-Action'] = payload[:action]
      request.body = request_body

      response = http.request(request)
      Rails.logger.info "[Webhook] Delete sent to #{webhook_url}, status: #{response.code}"

      if response.code.to_i >= 400
        Rails.logger.warn "[Webhook] Response body: #{response.body}"
      end
    rescue => e
      Rails.logger.error "[Webhook] Failed to send delete to #{webhook_url}: #{e.message}"
      Rails.logger.error e.backtrace.first(5).join("\n")
    end
  end
end

# Apply patch to TimeEntry model
# Use multiple approaches to ensure patch is applied in Redmine environment
if defined?(TimeEntry)
  unless TimeEntry.included_modules.include?(RedmineWebhook::TimeEntryPatch)
    TimeEntry.include(RedmineWebhook::TimeEntryPatch)
    Rails.logger.info "[Webhook] TimeEntryPatch applied successfully (immediate)"
  end
else
  # Fallback: Use to_prepare for deferred loading
  Rails.configuration.to_prepare do
    unless TimeEntry.included_modules.include?(RedmineWebhook::TimeEntryPatch)
      TimeEntry.include(RedmineWebhook::TimeEntryPatch)
      Rails.logger.info "[Webhook] TimeEntryPatch applied successfully (deferred)"
    end
  end
end
