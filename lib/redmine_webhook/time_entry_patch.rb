module RedmineWebhook
  module TimeEntryPatch
    extend ActiveSupport::Concern

    included do
      before_destroy :send_delete_webhook
    end

    # Class methods - Override update_all to detect issue_id changes
    class_methods do
      def update_all(updates)
        # Check if this update involves issue_id (nullify or reassign case)
        new_issue_id = extract_issue_id_from_updates(updates)

        if new_issue_id != :not_updating_issue_id
          process_issue_reassignment(new_issue_id)
        end

        # Call original update_all
        super
      end

      private

      # Extract new issue_id from various update formats
      def extract_issue_id_from_updates(updates)
        case updates
        when Hash
          return updates[:issue_id] if updates.key?(:issue_id)
          return updates['issue_id'] if updates.key?('issue_id')
        when Array
          # Format: ["issue_id = ?, project_id = ?", nil, 123]
          return updates[1] if updates[0].to_s.match?(/\bissue_id\s*=/)
        when String
          # Format: "issue_id = NULL" or "issue_id = 123"
          if updates.match?(/\bissue_id\s*=\s*NULL/i)
            return nil
          elsif (match = updates.match(/\bissue_id\s*=\s*(\d+)/))
            return match[1].to_i
          end
        end
        :not_updating_issue_id
      end

      # Process overtime entries before issue_id changes
      def process_issue_reassignment(new_issue_id)
        settings = Setting.plugin_redmine_one_webhook rescue {}
        return unless settings['enabled'] == '1'

        webhook_url = settings['webhook_url'].to_s.strip
        return if webhook_url.blank?

        # Collect overtime entries that have an issue (attached to a task)
        overtime_entries = collect_overtime_entries_with_issue

        return if overtime_entries.empty?

        Rails.logger.info "[Webhook] update_all detected: issue_id changing to #{new_issue_id.inspect}"
        Rails.logger.info "[Webhook] Found #{overtime_entries.size} overtime entries to process"

        # Determine action based on new_issue_id
        action = new_issue_id.nil? ? 'delete' : 'update'
        reason = new_issue_id.nil? ? 'issue_deleted_nullify' : 'issue_deleted_reassign'

        # Get new issue info if reassigning
        new_issue = new_issue_id.present? ? Issue.find_by(id: new_issue_id) : nil

        # Send webhook for each overtime entry
        overtime_entries.each do |te|
          send_reassignment_webhook(te, action, reason, new_issue, webhook_url, settings)
        end
      rescue => e
        Rails.logger.error "[Webhook] Error in process_issue_reassignment: #{e.message}"
        Rails.logger.error e.backtrace.first(3).join("\n")
      end

      # Collect overtime entries that are attached to an issue
      def collect_overtime_entries_with_issue
        self.includes(:activity, :issue, :user, :project).select do |te|
          # Only entries with issue_id (attached to a task)
          next false if te.issue_id.blank?

          # Only Overtime activity
          next false unless te.activity
          activity_name = te.activity.name.to_s.downcase
          activity_name.include?('overtime') || activity_name.include?('ot')
        end
      end

      # Send webhook for a single time entry
      def send_reassignment_webhook(te, action, reason, new_issue, webhook_url, settings)
        Rails.logger.info "[Webhook] #{reason}: sending #{action.upcase} for entry ##{te.id}"

        payload = {
          event: 'overtime_sync',
          action: action,
          timestamp: Time.now.iso8601,
          time_entry: build_time_entry_hash(te),
          context: {
            reason: reason,
            old_issue_id: te.issue_id,
            old_issue_subject: te.issue&.subject
          }
        }

        # Add new issue info for reassign case
        if action == 'update' && new_issue
          payload[:context][:new_issue_id] = new_issue.id
          payload[:context][:new_issue_subject] = new_issue.subject
          payload[:context][:new_issue] = {
            id: new_issue.id,
            subject: new_issue.subject,
            tracker: new_issue.tracker&.name
          }
        end

        send_http_request(webhook_url, payload, settings)
      rescue => e
        Rails.logger.error "[Webhook] Error sending webhook for entry ##{te.id}: #{e.message}"
      end

      # Build time entry hash
      def build_time_entry_hash(te)
        {
          id: te.id,
          hours: te.hours,
          comments: te.comments,
          spent_on: te.spent_on,
          created_on: te.created_on,
          updated_on: te.updated_on,
          activity: te.activity ? { id: te.activity.id, name: te.activity.name } : nil,
          user: te.user ? {
            id: te.user.id,
            login: te.user.login,
            firstname: te.user.firstname,
            lastname: te.user.lastname,
            mail: te.user.mail
          } : nil,
          project: te.project ? {
            id: te.project.id,
            identifier: te.project.identifier,
            name: te.project.name
          } : nil,
          issue: te.issue ? {
            id: te.issue.id,
            subject: te.issue.subject,
            tracker: te.issue.tracker&.name
          } : nil,
          custom_field_values: te.custom_field_values.map { |cfv|
            {
              custom_field_id: cfv.custom_field.id,
              custom_field_name: cfv.custom_field.name,
              value: cfv.value
            }
          }
        }
      end

      # Send HTTP POST request
      def send_http_request(webhook_url, payload, settings)
        require 'net/http'
        require 'uri'
        require 'json'

        body = payload.to_json
        secret = settings['webhook_secret'].to_s.strip
        secret = 'one_webhook_secret_key_2026' if secret.blank?
        signature = OpenSSL::HMAC.hexdigest('SHA256', secret, body)

        Rails.logger.info "[Webhook] Sending #{payload[:action]} for entry ##{payload[:time_entry][:id]}"
        Rails.logger.info "[Webhook] Payload: #{body}"

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
        request.body = body

        response = http.request(request)
        Rails.logger.info "[Webhook] Response: #{response.code}"

        if response.code.to_i >= 400
          Rails.logger.warn "[Webhook] Response body: #{response.body[0..500]}"
        end
      rescue => e
        Rails.logger.error "[Webhook] HTTP error: #{e.message}"
      end
    end

    # Instance methods
    private

    # Send webhook when time entry is deleted (Case 1)
    def send_delete_webhook
      return unless overtime_activity?
      return unless plugin_enabled?

      webhook_url = global_webhook_url
      return if webhook_url.blank?

      Rails.logger.info "[Webhook] TimeEntry#before_destroy - Overtime entry ##{id} being deleted"

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
if defined?(TimeEntry)
  unless TimeEntry.included_modules.include?(RedmineWebhook::TimeEntryPatch)
    TimeEntry.include(RedmineWebhook::TimeEntryPatch)
    Rails.logger.info "[Webhook] TimeEntryPatch applied successfully (immediate)"
  end
else
  Rails.configuration.to_prepare do
    unless TimeEntry.included_modules.include?(RedmineWebhook::TimeEntryPatch)
      TimeEntry.include(RedmineWebhook::TimeEntryPatch)
      Rails.logger.info "[Webhook] TimeEntryPatch applied successfully (deferred)"
    end
  end
end
