class SlackActionsController < ApplicationController
  skip_before_action :verify_authenticity_token, raise: false

  def approve
    migration = Migration.find(params[:id])
    runtype = migration.initial_runtype || 1
    lock_version = params[:lock_version]

    if migration.approve!("slack_approver", runtype, lock_version)
      migration.reload
      Notifier.notify(
        "migration id #{migration.id} *approved via Slack* — runtype: #{runtype}",
        migration
      )
      audit_log(migration, "Approved via Slack action button")
      MigrationMailer.migration_status_change(migration).deliver_now rescue nil
      redirect_to migration_path(migration), notice: "Migration approved via Slack!"
    else
      redirect_to migration_path(migration), alert: "Could not approve — migration may have been updated. Refresh and try again."
    end
  end

  def start
    migration = Migration.find(params[:id])
    lock_version = params[:lock_version]

    success, maxed = migration.start!(lock_version)
    if success
      migration.reload
      Notifier.notify(
        "migration id #{migration.id} *started via Slack* — now running",
        migration
      )
      audit_log(migration, "Started via Slack action button")
      MigrationMailer.migration_status_change(migration).deliver_now rescue nil
      redirect_to migration_path(migration), notice: "Migration started via Slack!"
    else
      msg = maxed ? "Cluster already running max migrations." : "Could not start — migration may have been updated."
      redirect_to migration_path(migration), alert: msg
    end
  end

  def rename
    migration = Migration.find(params[:id])
    lock_version = params[:lock_version]

    if migration.rename!(lock_version)
      migration.reload
      Notifier.notify(
        "migration id #{migration.id} *rename triggered via Slack*",
        migration
      )
      audit_log(migration, "Rename triggered via Slack action button")
      MigrationMailer.migration_status_change(migration).deliver_now rescue nil
      redirect_to migration_path(migration), notice: "Rename triggered via Slack!"
    else
      redirect_to migration_path(migration), alert: "Could not rename — migration may have been updated."
    end
  end

  private

  def audit_log(migration, message)
    Comment.create(
      migration_id: migration.id,
      author: 'slack',
      comment: "[AUDIT] #{message} at #{Time.now.utc.strftime('%Y-%m-%d %H:%M:%S UTC')}"
    )
  rescue => e
    Rails.logger.warn("[AUDIT] Failed to create audit comment: #{e.message}")
  end
end
