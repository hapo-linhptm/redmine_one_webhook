Redmine WebHook Plugin
======================

A Redmine plugin posts webhook on creating and updating tickets.

Install
------------------------------
Type below commands:

    $ cd $RAILS_ROOT/plugins
    $ git clone https://github.com/acorns-shiraki/redmine_webhook.git
    $ rake redmine:plugins:migrate RAILS_ENV=production

Then, restart your redmine.

Post Data Example
------------------------------

### Issue opened

    {
        title: "Redmine Issue {issue.id}",
        body: {
          text: "New issue created: {issue.subject}\n\nDescription:\n{issue.description}"
        },
        button: {
          label: "View Issue",
          url: issue_url(issue)
        }
    }

### Issue updated

    {
        title: "Redmine Issue {issue.id}",
        body: {
          text: "New issue updated: {issue.subject}\n\nDescription:\n{issue.description}"
        },
        button: {
          label: "View Issue",
          url: issue_url(issue)
        }
    }

Requirements
------------------------------
* Redmine 4.0 or later


Skipping webhooks
------------------------------
When a webhook triggers a change via REST API, this would trigger another webhook.
If you need to prevent this, the API request can include the `X-Skip-Webhooks` header, which will prevent webhooks being triggered by that request.


Known Limitations
------------------------------

An update from context menu doesn't call a webhook event.
It is caused by a lack of functionality hooking in Redmine.
Please see https://github.com/suer/redmine_webhook/issues/4 for details.

This limitation has been affected on all Redmine versions includes 2.4, 2.6,
and 3.0. It is not fixed in end of April, 2015.


License
------------------------------
The MIT License (MIT)
