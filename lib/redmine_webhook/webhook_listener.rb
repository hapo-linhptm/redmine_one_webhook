require 'net/http'
require 'uri'
require 'json'
require 'openssl'

module RedmineWebhook
  class WebhookListener < Redmine::Hook::Listener
    # Configurable overtime activity names (case-insensitive)
    OVERTIME_ACTIVITIES = ['overtime', 'ot', 'tăng ca'].freeze
    def skip_webhooks(context)
      return true unless context[:request]
      return true if context[:request].headers['X-Skip-Webhooks']
      false
    end

    def controller_issues_new_after_save(context = {})
      return if skip_webhooks(context)
      issue = context[:issue]
      controller = context[:controller]
      project = issue.project
      webhooks = Webhook.where(:project_id => project.project.id)
      webhooks = Webhook.where(:project_id => 0) unless webhooks && webhooks.length > 0
      return unless webhooks
      post(webhooks, issue_to_json(issue, controller))
    end

    def controller_issues_edit_after_save(context = {})
      return if skip_webhooks(context)
      journal = context[:journal]
      controller = context[:controller]
      issue = context[:issue]
      project = issue.project
      webhooks = Webhook.where(:project_id => project.project.id)
      webhooks = Webhook.where(:project_id => 0) unless webhooks && webhooks.length > 0
      return unless webhooks
      post(webhooks, journal_to_json(issue, journal, controller))
    end

    def controller_issues_bulk_edit_after_save(context = {})
      return if skip_webhooks(context)
      journal = context[:journal]
      controller = context[:controller]
      issue = context[:issue]
      project = issue.project
      webhooks = Webhook.where(:project_id => project.project.id)
      webhooks = Webhook.where(:project_id => 0) unless webhooks && webhooks.length > 0
      return unless webhooks
      post(webhooks, journal_to_json(issue, journal, controller))
    end

    def model_changeset_scan_commit_for_issue_ids_pre_issue_update(context = {})
      issue = context[:issue]
      journal = issue.current_journal
      webhooks = Webhook.where(:project_id => issue.project.project.id)
      webhooks = Webhook.where(:project_id => 0) unless webhooks && webhooks.length > 0
      return unless webhooks
      post(webhooks, journal_to_json(issue, journal, nil))
    end

    # ============================================
    # TIME ENTRY HOOKS (for Overtime sync to ONE)
    # ============================================

    # Hook triggered BEFORE time entry is saved (create or update)
    # Note: Redmine only provides 'before_save' hook, not 'after_save'
    # We use after_commit callback via the time_entry object instead
    def controller_timelog_edit_before_save(context = {})
      time_entry = context[:time_entry]
      return unless time_entry
      return unless overtime_activity?(time_entry)

      Rails.logger.info "[Webhook] Overtime time entry detected (before_save): hours: #{time_entry.hours}"

      # Schedule webhook to be sent after the transaction commits
      # Using Thread to ensure it runs after the save completes
      project = time_entry.project
      webhooks = find_webhooks_for_project(project)
      return if webhooks.empty?

      # Store data for sending after save completes
      # The time_entry.id may not be set yet for new records
      Thread.new do
        # Small delay to ensure the transaction has committed
        sleep(0.5)

        # Reload to get the saved data with ID
        begin
          saved_entry = TimeEntry.find_by(
            user_id: time_entry.user_id,
            spent_on: time_entry.spent_on,
            hours: time_entry.hours,
            activity_id: time_entry.activity_id,
            project_id: time_entry.project_id
          )

          if saved_entry
            Rails.logger.info "[Webhook] Overtime time entry saved: ##{saved_entry.id}, hours: #{saved_entry.hours}"
            payload = build_overtime_payload(saved_entry, 'overtime_logged')
            send_webhook_with_signature(webhooks, payload)
          else
            Rails.logger.warn "[Webhook] Could not find saved time entry"
          end
        rescue => e
          Rails.logger.error "[Webhook] Error finding saved entry: #{e.message}"
        end
      end
    end

    private

    def issue_to_json(issue, controller)
      {
        title: "Redmine Issue ##{issue.id}",
        body: {
          text: "New issue created: #{issue.subject}\n\nDescription:\n#{issue.description}"
        },
        button: {
          label: "View Issue",
          url: controller.issue_url(issue)
        }
      }.to_json
    end
   
    def journal_to_json(issue, journal, controller)
      notes = journal.notes.present? ? "\n\nNotes:\n#{journal.notes}" : ""
      {
        title: "Redmine Issue ##{issue.id} Updated",
        body: {
          text: "Issue updated: #{issue.subject}#{notes}"
        },
        button: {
          label: "View Issue",
          url: controller.nil? ? issue.project.url : controller.issue_url(issue)
        }
      }.to_json
    end

    def post(webhooks, request_body)
      Thread.start do
        webhooks.each do |webhook|
          begin
            uri = URI.parse(webhook.url)
            http = Net::HTTP.new(uri.host, uri.port)
            http.use_ssl = (uri.scheme == 'https')
            http.open_timeout = 10
            http.read_timeout = 30

            request = Net::HTTP::Post.new(uri.request_uri)
            request['Content-Type'] = 'application/json'
            request.body = request_body

            response = http.request(request)
            Rails.logger.info "[Webhook] Sent to #{webhook.url}, status: #{response.code}"
          rescue => e
            Rails.logger.error "[Webhook] Failed to send to #{webhook.url}: #{e.message}"
            Rails.logger.error e.backtrace.join("\n")
          end
        end
      end
    end

    # ============================================
    # OVERTIME WEBHOOK HELPERS
    # ============================================

    # Check if time entry activity is Overtime
    def overtime_activity?(time_entry)
      return false unless time_entry.activity
      activity_name = time_entry.activity.name.to_s.downcase.strip
      OVERTIME_ACTIVITIES.any? { |ot| activity_name.include?(ot) }
    end

    # Find webhooks for a project (fallback to global if none)
    def find_webhooks_for_project(project)
      return [] unless project
      webhooks = Webhook.where(project_id: project.id)
      webhooks = Webhook.where(project_id: 0) if webhooks.empty?
      webhooks
    end

    # Build overtime payload for ONE system
    def build_overtime_payload(time_entry, event_type)
      {
        event: event_type,
        timestamp: Time.now.iso8601,
        time_entry: RedmineWebhook::TimeEntryWrapper.new(time_entry).to_hash
      }
    end

    # Generate HMAC-SHA256 signature
    def generate_signature(payload_string)
      secret = webhook_secret
      OpenSSL::HMAC.hexdigest('SHA256', secret, payload_string)
    end

    # Get webhook secret from settings or environment
    def webhook_secret
      # Try plugin settings first, then environment variable, then default
      Setting.plugin_redmine_one_webhook['webhook_secret'] rescue nil ||
        ENV['WEBHOOK_SECRET'] ||
        'one_webhook_secret_key_2024'
    end

    # Send webhook with HMAC signature
    def send_webhook_with_signature(webhooks, payload)
      Thread.start do
        request_body = payload.to_json
        signature = generate_signature(request_body)

        webhooks.each do |webhook|
          begin
            uri = URI.parse(webhook.url)
            http = Net::HTTP.new(uri.host, uri.port)
            http.use_ssl = (uri.scheme == 'https')
            http.open_timeout = 10
            http.read_timeout = 30

            request = Net::HTTP::Post.new(uri.request_uri)
            request['Content-Type'] = 'application/json'
            request['X-Webhook-Signature'] = signature
            request['X-Webhook-Event'] = payload[:event]
            request.body = request_body

            response = http.request(request)
            Rails.logger.info "[Webhook] Overtime sent to #{webhook.url}, status: #{response.code}"

            if response.code.to_i >= 400
              Rails.logger.warn "[Webhook] Response body: #{response.body}"
            end
          rescue => e
            Rails.logger.error "[Webhook] Failed to send overtime to #{webhook.url}: #{e.message}"
            Rails.logger.error e.backtrace.first(5).join("\n")
          end
        end
      end
    end
  end
end