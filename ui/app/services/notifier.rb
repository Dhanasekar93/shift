require 'net/http'
require 'json'

class Notifier
  def self.notify(msg, migration = nil)
    slack_notify(msg, migration)
    Rails.logger.info("[AUDIT] #{msg}")
  end

  private

  def self.slack_notify(msg, migration = nil)
    webhook_url = ENV['SLACK_WEBHOOK_URL']
    return if webhook_url.blank?
    return unless webhook_url =~ /\Ahttps?:\/\//

    payload = build_slack_payload(msg, migration)

    begin
      uri = URI.parse(webhook_url)
    rescue URI::InvalidURIError => e
      Rails.logger.warn("[Slack] Invalid webhook URL: #{e.message}")
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
        Rails.logger.warn("[Slack] Failed: #{response.code} #{response.body}")
      end
    rescue StandardError => e
      Rails.logger.warn("[Slack] Error: #{e.message}")
    end
  end

  def self.build_slack_payload(msg, migration = nil)
    host = Rails.application.config.action_mailer.default_url_options[:host] rescue '127.0.0.1:3000'
    base_url = "http://#{host}"

    icon, color = status_decoration(msg)
    mig_id = extract_migration_id(msg)
    mig_url = mig_id ? "#{base_url}/migrations/#{mig_id}" : nil

    blocks = []

    blocks << {
      type: "section",
      text: { type: "mrkdwn", text: "#{icon} *Shift Migration Update*" }
    }

    blocks << {
      type: "section",
      text: { type: "mrkdwn", text: msg }
    }

    if migration
      details = []
      details << "*ID:* #{migration.id}"
      details << "*Cluster:* #{migration.cluster_name}" if migration.respond_to?(:cluster_name)
      details << "*Database:* #{migration.database}" if migration.respond_to?(:database)
      details << "*DDL:* `#{migration.ddl_statement.truncate(80)}`" if migration.respond_to?(:ddl_statement)
      details << "*Requestor:* #{migration.requestor}" if migration.respond_to?(:requestor)
      details << "*Status:* #{status_label(migration)}"

      blocks << {
        type: "section",
        text: { type: "mrkdwn", text: details.join("\n") }
      }
    end

    if mig_url
      actions = []
      actions << { type: "button", text: { type: "plain_text", text: "View Migration" }, url: mig_url }

      if migration
        slack_action_base = "#{base_url}/slack_actions"

        if migration.status == 1
          actions << {
            type: "button",
            text: { type: "plain_text", text: ":white_check_mark: Approve" },
            url: "#{slack_action_base}/approve?id=#{migration.id}&lock_version=#{migration.lock_version}",
            style: "primary"
          }
        end

        if migration.status == 2
          actions << {
            type: "button",
            text: { type: "plain_text", text: ":rocket: Start Migration" },
            url: "#{slack_action_base}/start?id=#{migration.id}&lock_version=#{migration.lock_version}",
            style: "primary"
          }
        end

        if migration.status == 4
          actions << {
            type: "button",
            text: { type: "plain_text", text: ":arrows_counterclockwise: Rename" },
            url: "#{slack_action_base}/rename?id=#{migration.id}&lock_version=#{migration.lock_version}",
            style: "primary"
          }
        end
      end

      blocks << { type: "actions", elements: actions }
    end

    blocks << { type: "divider" }

    { blocks: blocks }
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
    else                      [":database:", "#439fe0"]
    end
  end

  def self.status_label(migration)
    Statuses.find_by_status(migration.status).try(:description) || "status #{migration.status}"
  rescue
    "status #{migration.status}"
  end
end
