unless Rails.try(:autoloaders).try(:zeitwerk_enabled?)
  require 'redmine_webhook/issue_wrapper'
  require 'redmine_webhook/time_entry_wrapper'
  require 'redmine_webhook/webhook_listener'
  # Note: time_entry_patch is loaded from init.rb after Rails is ready
end

module RedmineWebhook
end
