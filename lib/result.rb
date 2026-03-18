# Lightweight result object for service layer operations.
#
#   result = SomeService.new(...).call
#   result.success?  # => true / false
#   result.value     # => the returned data on success
#   result.error     # => error message on failure
#
class Result
  attr_reader :value, :error

  def initialize(success:, value: nil, error: nil)
    @success = success
    @value   = value
    @error   = error
  end

  def self.ok(value = nil)    = new(success: true,  value: value)
  def self.fail(error)        = new(success: false, error: error)

  def success? = @success
  def failure? = !@success

  def on_success
    yield value if success?
    self
  end

  def on_failure
    yield error if failure?
    self
  end
end
