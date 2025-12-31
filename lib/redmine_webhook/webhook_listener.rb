require 'net/http'
require 'uri'
require 'json'
require 'openssl'

module RedmineWebhook
  class WebhookListener < Redmine::Hook::Listener
    # Configurable overtime activity names (case-insensitive)
    OVERTIME_ACTIVITIES = ['overtime', 'ot'].freeze

    # Custom field names for Start time and End time (case-insensitive)
    START_TIME_FIELDS = ['start time', 'start_time', 'starttime'].freeze
    END_TIME_FIELDS = ['end time', 'end_time', 'endtime'].freeze

    # Action types for webhook payload
    ACTION_CREATE = 'create'.freeze
    ACTION_UPDATE = 'update'.freeze
    ACTION_DELETE = 'delete'.freeze

    # ============================================
    # TIME ENTRY HOOKS (for Overtime sync to ONE)
    # ============================================

    # Hook 1: Triggered when creating/updating time entry from Issue Edit page
    # (1: Vào edit task sau đó log time)
    def controller_issues_edit_after_save(context = {})
      process_time_entry_from_issue(context)
    end

    # Hook 2: Triggered when creating time entry from Log Time page
    # (2: Click vào Log time của 1 task)
    def controller_timelog_edit_before_save(context = {})
      time_entry = context[:time_entry]
      return unless time_entry
      return unless should_send_webhook?(time_entry)

      # Determine if this is create or update
      is_new_record = time_entry.new_record?
      action = is_new_record ? ACTION_CREATE : ACTION_UPDATE

      Rails.logger.info "[Webhook] Overtime time entry detected (#{action}): hours: #{time_entry.hours}"

      # Store original ID for update case
      original_id = time_entry.id

      Thread.new do
        sleep(0.5) # Wait for transaction to commit

        begin
          saved_entry = find_saved_time_entry(time_entry, original_id)

          if saved_entry && valid_overtime_payload?(saved_entry)
            send_overtime_webhook_with_action(saved_entry, action)
          else
            Rails.logger.warn "[Webhook] Skipped: Invalid payload or entry not found"
          end
        rescue => e
          Rails.logger.error "[Webhook] Error: #{e.message}"
        end
      end
    end

    # Hook 3: Triggered when updating time entry from Spent Time list
    # (3: Sửa logtime từ danh sách Spent time)
    def controller_timelog_edit_after_save(context = {})
      time_entry = context[:time_entry]
      return unless time_entry
      return unless should_send_webhook?(time_entry)

      action = ACTION_UPDATE
      Rails.logger.info "[Webhook] Overtime time entry updated from list: ##{time_entry.id}"

      Thread.new do
        sleep(0.3)
        begin
          # Reload to get fresh data
          saved_entry = TimeEntry.find_by(id: time_entry.id)
          if saved_entry && valid_overtime_payload?(saved_entry)
            send_overtime_webhook_with_action(saved_entry, action)
          end
        rescue => e
          Rails.logger.error "[Webhook] Error: #{e.message}"
        end
      end
    end

    # NOTE: Hook for DELETE is handled via TimeEntry model callback (before_destroy)
    # See: lib/redmine_webhook/time_entry_patch.rb
    # Reason: Redmine does NOT have a controller hook for time entry deletion
    # Available Redmine timelog hooks are only:
    #   - controller_timelog_edit_before_save
    #   - controller_time_entries_bulk_edit_before_save
    # Reference: https://www.redmine.org/projects/redmine/wiki/Hooks_List

    # Hook 4: Bulk edit time entries
    def controller_timelog_bulk_edit_after_save(context = {})
      time_entries = context[:time_entries] || []
      time_entries.each do |time_entry|
        next unless should_send_webhook?(time_entry)

        Thread.new do
          sleep(0.3)
          begin
            saved_entry = TimeEntry.find_by(id: time_entry.id)
            if saved_entry && valid_overtime_payload?(saved_entry)
              send_overtime_webhook_with_action(saved_entry, ACTION_UPDATE)
            end
          rescue => e
            Rails.logger.error "[Webhook] Bulk edit error: #{e.message}"
          end
        end
      end
    end

    private

    # ============================================
    # PLUGIN SETTINGS HELPERS (Global Config)
    # ============================================

    # Check if plugin is enabled (from Admin settings)
    def plugin_enabled?
      settings = Setting.plugin_redmine_one_webhook rescue {}
      settings['enabled'] == '1'
    end

    # Get global webhook URL from plugin settings
    def global_webhook_url
      settings = Setting.plugin_redmine_one_webhook rescue {}
      settings['webhook_url'].to_s.strip
    end

    # Get webhook secret from plugin settings
    def webhook_secret
      settings = Setting.plugin_redmine_one_webhook rescue {}
      secret = settings['webhook_secret'].to_s.strip
      secret.present? ? secret : 'one_webhook_secret_key_2026'
    end

    # ============================================
    # VALIDATION HELPERS
    # ============================================

    # Check all conditions before sending webhook
    def should_send_webhook?(time_entry)
      return false unless time_entry
      return false unless plugin_enabled?
      return false unless overtime_activity?(time_entry)
      return false if global_webhook_url.blank?
      true
    end

    # Check if time entry activity is Overtime
    def overtime_activity?(time_entry)
      return false unless time_entry.activity
      activity_name = time_entry.activity.name.to_s.downcase.strip
      OVERTIME_ACTIVITIES.any? { |ot| activity_name.include?(ot) }
    end

    # Validate payload has all required fields for overtime
    # Required: hours > 0, Start time, End time, activity = Overtime
    def valid_overtime_payload?(time_entry)
      return false unless time_entry

      # Check hours
      unless time_entry.hours.present? && time_entry.hours.to_f > 0
        Rails.logger.warn "[Webhook] Invalid: hours is empty or zero"
        return false
      end

      # Check activity is Overtime
      unless overtime_activity?(time_entry)
        Rails.logger.warn "[Webhook] Invalid: activity is not Overtime"
        return false
      end

      # Check Start time and End time custom fields
      start_time = get_custom_field_value(time_entry, START_TIME_FIELDS)
      end_time = get_custom_field_value(time_entry, END_TIME_FIELDS)

      unless start_time.present?
        Rails.logger.warn "[Webhook] Invalid: Start time is empty"
        return false
      end

      unless end_time.present?
        Rails.logger.warn "[Webhook] Invalid: End time is empty"
        return false
      end

      Rails.logger.info "[Webhook] Valid payload: hours=#{time_entry.hours}, start=#{start_time}, end=#{end_time}"
      true
    end

    # Get custom field value by field name (case-insensitive)
    def get_custom_field_value(time_entry, field_names)
      return nil unless time_entry.custom_field_values

      time_entry.custom_field_values.each do |cfv|
        field_name = cfv.custom_field.name.to_s.downcase.strip
        if field_names.any? { |fn| field_name.include?(fn) }
          return cfv.value
        end
      end
      nil
    end

    # ============================================
    # TIME ENTRY FINDER HELPERS
    # ============================================

    # Find saved time entry after transaction commits
    def find_saved_time_entry(time_entry, original_id = nil)
      # If we have original ID (update case), use it
      if original_id.present?
        return TimeEntry.find_by(id: original_id)
      end

      # For new records, find by attributes
      TimeEntry.where(
        user_id: time_entry.user_id,
        spent_on: time_entry.spent_on,
        activity_id: time_entry.activity_id,
        project_id: time_entry.project_id
      ).order(created_on: :desc).first
    end

    # Process time entry from issue edit (when logging time from issue form)
    def process_time_entry_from_issue(context)
      # Check if time entry was logged along with issue edit
      time_entry = context[:time_entry]
      return unless time_entry
      return unless should_send_webhook?(time_entry)

      action = time_entry.new_record? ? ACTION_CREATE : ACTION_UPDATE

      Thread.new do
        sleep(0.5)
        begin
          saved_entry = find_saved_time_entry(time_entry, time_entry.id)
          if saved_entry && valid_overtime_payload?(saved_entry)
            send_overtime_webhook_with_action(saved_entry, action)
          end
        rescue => e
          Rails.logger.error "[Webhook] Error from issue edit: #{e.message}"
        end
      end
    end

    # ============================================
    # PAYLOAD & WEBHOOK HELPERS
    # ============================================

    # Build overtime payload for ONE system with action type
    def build_overtime_payload(time_entry, action)
      {
        event: 'overtime_sync',
        action: action,
        timestamp: Time.now.iso8601,
        time_entry: RedmineWebhook::TimeEntryWrapper.new(time_entry).to_hash
      }
    end

    # Generate HMAC-SHA256 signature
    def generate_signature(payload_string)
      secret = webhook_secret
      OpenSSL::HMAC.hexdigest('SHA256', secret, payload_string)
    end

    # Send webhook with action type
    def send_overtime_webhook_with_action(time_entry, action)
      webhook_url = global_webhook_url
      return if webhook_url.blank?

      payload = build_overtime_payload(time_entry, action)
      Rails.logger.info "[Webhook] Sending #{action} webhook for entry ##{time_entry.id}"
      Rails.logger.info "[Webhook] Payload: #{payload.to_json}"

      send_overtime_webhook(webhook_url, payload)
    end

    # Send overtime webhook to global URL
    def send_overtime_webhook(webhook_url, payload)
      request_body = payload.to_json
      signature = generate_signature(request_body)

      begin
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
        Rails.logger.info "[Webhook] Overtime sent to #{webhook_url}, status: #{response.code}, action: #{payload[:action]}"

        if response.code.to_i >= 400
          Rails.logger.warn "[Webhook] Response body: #{response.body}"
        end
      rescue => e
        Rails.logger.error "[Webhook] Failed to send overtime to #{webhook_url}: #{e.message}"
        Rails.logger.error e.backtrace.first(5).join("\n")
      end
    end
  end
end