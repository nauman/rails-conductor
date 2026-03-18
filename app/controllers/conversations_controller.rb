class ConversationsController < ApplicationController
  before_action :set_conversation, only: [ :show, :destroy ]

  def index
    @conversations = current_user.conversations.recent
  end

  def show
    @messages    = @conversation.messages
    @new_message = Message.new
  end

  def create
    @conversation = current_user.conversations.create!(status: 'active')
    redirect_to @conversation
  end

  def destroy
    unless current_user.can?(:destroy, @conversation)
      return redirect_to conversations_path, alert: 'Not authorized.'
    end

    @conversation.destroy!
    redirect_to conversations_path, notice: 'Conversation deleted.'
  end

  private

  def set_conversation
    @conversation = current_user.conversations.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    redirect_to conversations_path, alert: 'Conversation not found.'
  end
end
