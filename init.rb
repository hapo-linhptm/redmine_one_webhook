if Rails.try(:autoloaders).try(:zeitwerk_enabled?)
  Rails.autoloaders.main.push_dir File.dirname(__FILE__) + '/lib/redmine_webhook'
  RedmineWebhook::ProjectsHelperPatch
  RedmineWebhook::WebhookListener
else
  require "redmine_webhook"
end

Redmine::Plugin.register :redmine_one_webhook do
  name 'Redmine ONE Webhook Plugin'
  author 'HAPO Team'
  description 'Redmine webhook plugin for ONE system integration (Overtime sync)'
  version '0.0.2'
  url 'https://github.com/hapo/redmine_one_webhook'
  author_url ''

  # Global plugin settings (Admin only)
  # Access via: Administration → Plugins → Redmine ONE Webhook → Configure
  settings :default => {
    'webhook_url' => '',
    'webhook_secret' => 'one_webhook_secret_key_2024',
    'enabled' => '1'
  }, :partial => 'settings/redmine_one_webhook_settings'
end
