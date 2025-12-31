# Redmine ONE Webhook Plugin

A Redmine plugin that sends webhooks when overtime time entries are created, updated, or deleted. Designed for integration with the ONE system for overtime management.

## Features

- **Overtime Sync**: Automatically sends webhook when users log overtime hours
- **CRUD Operations**: Supports create, update, and delete actions
- **HMAC-SHA256 Security**: All webhooks are signed for secure verification
- **Global Configuration**: Admin-only settings apply to all projects
- **Multiple Entry Points**: Captures time entries from all Redmine interfaces

## Requirements

- Redmine 4.0 or later
- Ruby 2.5 or later

## Installation

```bash
cd $REDMINE_ROOT/plugins
git clone https://github.com/hapo/redmine_one_webhook.git
bundle install
rake redmine:plugins:migrate RAILS_ENV=production
```

Then restart your Redmine server.

## Configuration

1. Login as **Admin**
2. Go to **Administration** → **Plugins**
3. Find **Redmine ONE Webhook Plugin** → Click **Configure**
4. Fill in the settings:

| Setting | Description | Default |
|---------|-------------|---------|
| Enable Webhook | Turn webhook on/off | Enabled |
| Webhook URL | URL to receive webhooks | (empty) |
| Webhook Secret | Secret key for HMAC signature | `one_webhook_secret_key_2026` |

## When Webhooks Are Sent

Webhooks are sent only when **ALL** conditions are met:

1. Plugin is enabled
2. Activity is "Overtime" or "OT" (case-insensitive)
3. Webhook URL is configured
4. Hours > 0
5. Start time custom field has value
6. End time custom field has value

### Supported Entry Points

| # | Action | Hook/Callback |
|---|--------|---------------|
| 1 | Edit task → Log time | `controller_issues_edit_after_save` |
| 2 | Click "Log time" button | `controller_timelog_edit_before_save` |
| 3 | Spent time → Edit entry | `controller_timelog_edit_after_save` |
| 4 | Spent time → Delete entry | `TimeEntry#before_destroy` (Model Callback) |
| 5 | Bulk edit time entries | `controller_timelog_bulk_edit_after_save` |

> **Note**: Redmine doesn't have a controller hook for deleting time entries. This plugin uses an ActiveRecord model callback (`before_destroy`) to capture delete events.

## Webhook Payload

### HTTP Headers

```
POST /api/pms/update-logtime HTTP/1.1
Content-Type: application/json
X-Webhook-Signature: <HMAC-SHA256 signature>
X-Webhook-Event: overtime_sync
X-Webhook-Action: create | update | delete
```

### JSON Body

```json
{
  "event": "overtime_sync",
  "action": "create",
  "timestamp": "2025-12-31T17:00:00+07:00",
  "time_entry": {
    "id": 12345,
    "hours": 2.5,
    "comments": "Fix urgent bug",
    "spent_on": "2025-12-31",
    "created_on": "2025-12-31T17:00:00+07:00",
    "updated_on": "2025-12-31T17:00:00+07:00",
    "activity": {
      "id": 17,
      "name": "Overtime"
    },
    "user": {
      "id": 42,
      "login": "nguyenvana",
      "firstname": "Nguyen",
      "lastname": "Van A",
      "mail": "nguyenvana@example.com"
    },
    "project": {
      "id": 100,
      "identifier": "client-project",
      "name": "Client Project"
    },
    "issue": {
      "id": 5678,
      "subject": "Fix payment bug",
      "tracker": "Bug"
    },
    "custom_field_values": [
      {
        "custom_field_id": 16,
        "custom_field_name": "Start time",
        "value": "17:30"
      },
      {
        "custom_field_id": 17,
        "custom_field_name": "End time",
        "value": "20:00"
      }
    ]
  }
}
```

### Action Types

| Action | When | Backend Action |
|--------|------|----------------|
| `create` | New overtime entry created | INSERT new record |
| `update` | Existing entry modified | UPDATE by `time_entry.id` |
| `delete` | Entry deleted | DELETE by `time_entry.id` |

## Verifying Webhook Signature

The webhook signature is generated using HMAC-SHA256:

```ruby
# Ruby
signature = OpenSSL::HMAC.hexdigest('SHA256', secret, request_body)
```

```php
// PHP (Laravel)
$signature = hash_hmac('sha256', $request->getContent(), $secret);
if (!hash_equals($signature, $request->header('X-Webhook-Signature'))) {
    return response()->json(['error' => 'Invalid signature'], 401);
}
```

## Custom Fields Setup

For the plugin to work properly, you need to create these custom fields for Time Entry:

1. Go to **Administration** → **Custom fields** → **Time entries**
2. Create two fields:
   - **Start time** (Text or Time format)
   - **End time** (Text or Time format)

## Troubleshooting

### Webhook not sending

1. Check if plugin is enabled in settings
2. Verify Activity name contains "Overtime" or "OT"
3. Ensure Webhook URL is configured
4. Check Redmine logs: `tail -f log/production.log | grep Webhook`

### Connection errors

```
[Webhook] Failed to send overtime to http://...: Connection refused
```

- Verify the webhook URL is accessible from Redmine server
- Check firewall settings
- For Docker: use `host.docker.internal` or host IP instead of `localhost`

### Signature verification failed

- Ensure both Redmine and receiving server use the same secret key
- Check for whitespace or encoding issues in the secret

## Logs

The plugin logs all webhook activities:

```
[Webhook] Overtime time entry detected (create): hours: 2.0
[Webhook] Valid payload: hours=2.0, start=17:30, end=20:00
[Webhook] Sending create webhook for entry #12345
[Webhook] Overtime sent to http://example.com/api/webhook, status: 200, action: create
```

For delete operations:
```
[Webhook] TimeEntry#before_destroy - Overtime entry #12345 being deleted
[Webhook] Sending delete webhook for entry #12345
[Webhook] Delete sent to http://example.com/api/webhook, status: 200
```

## Version History

| Version | Changes |
|---------|---------|
| 0.0.4 | Fix delete webhook using model callback |
| 0.0.3 | Add multi-hook support, validation, action types |
| 0.0.2 | Switch to global settings (Admin only) |
| 0.0.1 | Initial release with basic webhook support |

## License

The MIT License (MIT)

## Author

HAPO Team - https://haposoft.com
