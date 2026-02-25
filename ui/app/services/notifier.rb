require 'net/http'
require 'json'

class Notifier
  def self.notify(msg, migration = nil)
    slack_notify(msg, migration)
    Rails.logger.info("[AUDIT] #{msg}")
  end

  private

  def self.slack_notify(msg, migration = nil)
    bot_token = ENV['SLACK_BOT_TOKEN']
    channel   = ENV['SLACK_CHANNEL_ID']

    if bot_token.present? && channel.present?
      post_via_bot(msg, migration, bot_token, channel)
    else
      post_via_webhook(msg, migration)
    end
  end

  # --- Bot Token API (preferred: supports rich blocks + buttons) ---

  def self.post_via_bot(msg, migration, token, channel)
    uri = URI.parse("https://slack.com/api/chat.postMessage")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 5
    http.read_timeout = 5

    blocks = build_blocks(msg, migration)
    payload = { channel: channel, blocks: blocks, text: msg }

    request = Net::HTTP::Post.new(uri.request_uri, {
      'Content-Type'  => 'application/json; charset=utf-8',
      'Authorization' => "Bearer #{token}"
    })
    request.body = payload.to_json

    begin
      response = http.request(request)
      body = JSON.parse(response.body) rescue {}
      unless body["ok"]
        Rails.logger.warn("[Slack Bot] API error: #{body['error']}")
      end
    rescue StandardError => e
      Rails.logger.warn("[Slack Bot] Error: #{e.message}")
    end
  end

  # --- Incoming Webhook fallback ---

  def self.post_via_webhook(msg, migration)
    webhook_url = ENV['SLACK_WEBHOOK_URL']
    return if webhook_url.blank?
    return unless webhook_url =~ /\Ahttps?:\/\//

    blocks = build_blocks(msg, migration)
    payload = { blocks: blocks, text: msg }

    begin
      uri = URI.parse(webhook_url)
    rescue URI::InvalidURIError => e
      Rails.logger.warn("[Slack Webhook] Invalid URL: #{e.message}")
      return
    end

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.open_timeout = 5
    http.read_timeout = 5

    request = Net::HTTP::Post.new(uri.request_uri, {'Content-Type' => 'application/json'})
    request.body = payload.to_json

    begin
      response = http.request(request)
      unless response.is_a?(Net::HTTPSuccess)
        Rails.logger.warn("[Slack Webhook] Failed: #{response.code} #{response.body}")
      end
    rescue StandardError => e
      Rails.logger.warn("[Slack Webhook] Error: #{e.message}")
    end
  end

  # --- Shared Block Kit builder ---

  def self.build_blocks(msg, migration)
    host = Rails.application.config.action_mailer.default_url_options[:host] rescue '127.0.0.1:3000'
    base_url = "http://#{host}"
    icon, _color = status_decoration(msg)
    mig_id = extract_migration_id(msg)
    mig_url = mig_id ? "#{base_url}/migrations/#{mig_id}" : nil

    blocks = []

    blocks << {
      type: "header",
      text: { type: "plain_text", text: "#{icon} Shift Migration Update", emoji: true }
    }

    blocks << { type: "section", text: { type: "mrkdwn", text: msg } }

    if migration
      fields = []
      fields << { type: "mrkdwn", text: "*ID:* #{migration.id}" }
      fields << { type: "mrkdwn", text: "*Status:* #{status_label(migration)}" }
      fields << { type: "mrkdwn", text: "*Cluster:* #{migration.cluster_name}" } if migration.respond_to?(:cluster_name)
      fields << { type: "mrkdwn", text: "*Database:* #{migration.database}" } if migration.respond_to?(:database)
      fields << { type: "mrkdwn", text: "*Requestor:* #{migration.requestor}" } if migration.respond_to?(:requestor)
      if migration.respond_to?(:approved_by) && migration.approved_by.present?
        fields << { type: "mrkdwn", text: "*Approved by:* #{migration.approved_by}" }
      end
      if migration.respond_to?(:copy_percentage) && migration.copy_percentage.present?
        fields << { type: "mrkdwn", text: "*Copy:* #{migration.copy_percentage}%" }
      end
      fields << { type: "mrkdwn", text: "*DDL:* `#{migration.ddl_statement.to_s.truncate(60)}`" } if migration.respond_to?(:ddl_statement)

      blocks << { type: "section", fields: fields.first(10) }
    end

    if mig_url
      actions = []
      actions << { type: "button", text: { type: "plain_text", text: ":link: View Migration", emoji: true }, url: mig_url }

      if migration
        action_base = "#{base_url}/slack_actions"

        if migration.status == 1  # awaiting_approval
          actions << {
            type: "button",
            text: { type: "plain_text", text: ":white_check_mark: Approve", emoji: true },
            url: "#{action_base}/approve?id=#{migration.id}&lock_version=#{migration.lock_version}",
            style: "primary"
          }
        end

        if migration.status == 2  # awaiting_start
          actions << {
            type: "button",
            text: { type: "plain_text", text: ":rocket: Start Migration", emoji: true },
            url: "#{action_base}/start?id=#{migration.id}&lock_version=#{migration.lock_version}",
            style: "primary"
          }
        end

        if migration.status == 4  # awaiting_rename
          actions << {
            type: "button",
            text: { type: "plain_text", text: ":arrows_counterclockwise: Rename Tables", emoji: true },
            url: "#{action_base}/rename?id=#{migration.id}&lock_version=#{migration.lock_version}",
            style: "primary"
          }
        end
      end

      blocks << { type: "actions", elements: actions } if actions.any?
    end

    blocks << { type: "divider" }
    blocks
  end

  def self.extract_migration_id(msg)
    $1 if msg =~ /migration id (\d+)/
  end

  def self.status_decoration(msg)
    case msg
    when /completed/     then [":white_check_mark:", "#36a64f"]
    when /failed|error/  then [":x:", "#ff0000"]
    when /approv/        then [":eyes:", "#2196f3"]
    when /cancel/        then [":no_entry_sign:", "#ff9800"]
    when /start|running/ then [":rocket:", "#ff9800"]
    when /preparing/     then [":hourglass_flowing_sand:", "#9e9e9e"]
    when /paused/        then [":double_vertical_bar:", "#ff9800"]
    when /created/       then [":new:", "#2196f3"]
    when /rename/        then [":arrows_counterclockwise:", "#9c27b0"]
    else                      [":database:", "#439fe0"]
    end
  end

  def self.status_label(migration)
    Statuses.find_by_status(migration.status).try(:description) || "status #{migration.status}"
  rescue
    "status #{migration.status}"
  end
end
