require 'net/http'
require 'json'

class Notifier
  def self.notify(msg)
    slack_notify(msg)
    Rails.logger.info("[AUDIT] #{msg}")
  end

  private

  def self.slack_notify(msg)
    webhook_url = ENV['SLACK_WEBHOOK_URL']
    return if webhook_url.blank?

    migration_url = extract_migration_url(msg)
    payload = build_slack_payload(msg, migration_url)

    uri = URI.parse(webhook_url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.open_timeout = 5
    http.read_timeout = 5

    request = Net::HTTP::Post.new(uri.request_uri, {'Content-Type' => 'application/json'})
    request.body = payload.to_json

    begin
      response = http.request(request)
      unless response.is_a?(Net::HTTPSuccess)
        Rails.logger.warn("[Slack] Failed to send notification: #{response.code} #{response.body}")
      end
    rescue StandardError => e
      Rails.logger.warn("[Slack] Error sending notification: #{e.message}")
    end
  end

  def self.extract_migration_url(msg)
    if msg =~ /migration id (\d+)/
      migration_id = $1
      host = Rails.application.config.action_mailer.default_url_options[:host] rescue '127.0.0.1:3000'
      "http://#{host}/migrations/#{migration_id}"
    end
  end

  def self.build_slack_payload(msg, migration_url = nil)
    icon = if msg =~ /completed/
             ":white_check_mark:"
           elsif msg =~ /failed|error/
             ":x:"
           elsif msg =~ /approve|approval/
             ":eyes:"
           elsif msg =~ /cancel/
             ":no_entry_sign:"
           elsif msg =~ /started|running|preparing/
             ":rocket:"
           elsif msg =~ /paused/
             ":double_vertical_bar:"
           else
             ":database:"
           end

    text = "#{icon} *Shift Migration Update*\n#{msg}"
    text += "\n<#{migration_url}|View Migration>" if migration_url

    {
      text: text,
      unfurl_links: false,
      unfurl_media: false
    }
  end
end
