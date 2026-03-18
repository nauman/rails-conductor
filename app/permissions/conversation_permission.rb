class ConversationPermission
  def initialize(user:, record: nil)
    @user   = user
    @record = record
  end

  def can?(action)
    case action
    when :create  then true
    when :read    then own_or_admin?
    when :update  then own_or_admin?
    when :destroy then own_or_admin?
    else false
    end
  end

  private

  def own_or_admin?
    return true if @user.admin?
    @record.present? && @record.user_id == @user.id
  end
end
