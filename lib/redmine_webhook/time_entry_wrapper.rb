module RedmineWebhook
  class TimeEntryWrapper
    def initialize(time_entry)
      @time_entry = time_entry
    end

    def to_hash
      {
        :id => @time_entry.id,
        :hours => @time_entry.hours,
        :comments => @time_entry.comments,
        :spent_on => @time_entry.spent_on,
        :created_on => @time_entry.created_on,
        :updated_on => @time_entry.updated_on,
        :activity => activity_hash,
        :user => user_hash,
        :project => project_hash,
        :issue => issue_hash,
        :custom_field_values => custom_field_values_hash
      }
    end

    private

    def activity_hash
      return nil unless @time_entry.activity
      {
        :id => @time_entry.activity.id,
        :name => @time_entry.activity.name
      }
    end

    def user_hash
      return nil unless @time_entry.user
      {
        :id => @time_entry.user.id,
        :login => @time_entry.user.login,
        :firstname => @time_entry.user.firstname,
        :lastname => @time_entry.user.lastname,
        :mail => @time_entry.user.mail
      }
    end

    def project_hash
      return nil unless @time_entry.project
      {
        :id => @time_entry.project.id,
        :identifier => @time_entry.project.identifier,
        :name => @time_entry.project.name
      }
    end

    def issue_hash
      return nil unless @time_entry.issue
      {
        :id => @time_entry.issue.id,
        :subject => @time_entry.issue.subject,
        :tracker => @time_entry.issue.tracker&.name
      }
    end

    def custom_field_values_hash
      return [] unless @time_entry.custom_field_values
      @time_entry.custom_field_values.collect do |value|
        RedmineWebhook::CustomFieldValueWrapper.new(value).to_hash
      end
    end
  end
end
