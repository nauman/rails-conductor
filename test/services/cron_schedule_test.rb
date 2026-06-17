require "test_helper"

class CronScheduleTest < ActiveSupport::TestCase
  test "passes through a raw 5-field cron expression" do
    assert_equal "0 3 * * *", CronSchedule.to_cron("0 3 * * *")
  end

  test "translates a friendly hourly interval to cron" do
    assert_equal "0 0,2,4,6,8,10,12,14,16,18,20,22 * * *", CronSchedule.to_cron("every 2 hours")
  end

  test "translates a friendly daily time to cron" do
    assert_equal "0 3 * * *", CronSchedule.to_cron("every day at 3am")
  end

  test "raises on an unparseable schedule" do
    assert_raises(CronSchedule::Error) { CronSchedule.to_cron("whenever I feel like it") }
  end

  test "raises on a blank schedule" do
    assert_raises(CronSchedule::Error) { CronSchedule.to_cron("  ") }
  end

  test "valid? reflects parseability without raising" do
    assert CronSchedule.valid?("0 3 * * *")
    refute CronSchedule.valid?("nonsense schedule")
  end
end
