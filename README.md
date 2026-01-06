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

### Step 1: Copy plugin to Redmine plugins directory

```bash
cd $REDMINE_ROOT/plugins
git clone https://github.com/haposoft/redmine_one_webhook
```

Or manually copy the `redmine_one_webhook` folder into `$REDMINE_ROOT/plugins/`.

### Step 2: Restart Redmine server

The restart command depends on your deployment method, example:

| Deployment | Restart Command |
|------------|-----------------|
| Docker Compose | `docker-compose restart redmine` |
| Docker | `docker restart <container_name>` |
| Systemd | `sudo systemctl restart redmine` |

### Step 3: Verify installation

1. Login as **Admin**
2. Go to **Administration** → **Plugins**
3. You should see **Redmine ONE Webhook Plugin** in the list

> **Note**: This plugin does not require `bundle install` (no additional gems needed) and does not require database migration. Configuration is stored in Redmine's global settings.

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

## Important Limitations

### Deleting Issues with Overtime Time Entries

When you delete an issue (task) that has overtime time entries, Redmine shows a confirmation dialog with 3 options:

| Option | Webhook Behavior | ONE System Impact |
|--------|------------------|-------------------|
| **Delete reported hours** | Webhook is sent with `action: delete` | ONE system is updated correctly |
| **Assign reported hours to the project** | **NO webhook sent** | ONE system is NOT updated |
| **Reassign reported hours to another issue** | **NO webhook sent** | ONE system is NOT updated |

#### Why This Happens

When you choose "Assign to project" or "Reassign to another issue", Redmine does not actually delete the time entries - it only removes the association with the deleted issue. Since the time entry record still exists (just with `issue_id = NULL` or a new issue ID), the `before_destroy` callback is never triggered.

#### Recommended Action

If you need to delete an issue that has overtime time entries:

1. **Before deleting the issue**, go to **Spent time** and manually delete all overtime entries associated with that issue
2. Then delete the issue

This ensures the ONE system receives the delete webhook and stays in sync.

#### Alternative Workaround

If you already deleted an issue using "Assign to project" or "Reassign to another issue":

1. Find the orphaned overtime entries in **Spent time** (filter by project, no issue)
2. Manually delete them to trigger the webhook
3. Or contact your administrator to manually sync the ONE system

---

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

## Version

Current version: **1.0.0**

Features:
- Global settings (Admin-only configuration)
- CRUD webhook support (create, update, delete)
- HMAC-SHA256 signature verification
- Multiple entry point hooks
- Model callback for delete events

## License

The MIT License (MIT)

## Author

HAPO Team - https://haposoft.com
