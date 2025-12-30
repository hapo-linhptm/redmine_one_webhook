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
  version '0.1.0'
  url 'https://github.com/hapo/redmine_one_webhook'
  author_url ''
  project_module :webhooks do
    permission :manage_hook, {:webhook_settings => [:index, :show, :update, :create, :destroy]}, :require => :member
  end
end
