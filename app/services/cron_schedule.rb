require "fugit"

# Translates a human-friendly schedule ("every 2 hours", "daily at 3am") or a
# raw 5-field cron expression into a canonical cron string, using fugit's
# natural-language + cron parsers. Used by CronJob to resolve a schedule before
# the CrontabClient installs it.
module CronSchedule
  class Error < StandardError; end

  module_function

  # Returns a canonical "m h dom mon dow" cron string, or raises Error.
  def to_cron(input)
    text = input.to_s.strip
    raise Error, "Schedule is blank" if text.empty?

    parsed = begin
      Fugit.parse(text)
    rescue StandardError
      nil
    end

    unless parsed.respond_to?(:to_cron_s)
      raise Error, "Could not understand schedule: #{input.inspect}"
    end

    parsed.to_cron_s
  end

  # True when the input resolves to a valid cron schedule.
  def valid?(input)
    to_cron(input)
    true
  rescue Error
    false
  end
end
