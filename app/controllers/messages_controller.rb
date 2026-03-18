class MessagesController < ApplicationController
  before_action :set_conversation

  def create
    # Create the user message
    user_message = @conversation.messages.create!(
      role:    'user',
      content: params[:message][:content].to_s.strip,
      status:  'complete'
    )

    # Title the conversation from first message
    @conversation.auto_title_from(user_message.content)

    # Create a pending assistant message (will be filled in by the job)
    assistant_message = @conversation.messages.create!(
      role:   'assistant',
      status: 'pending'
    )

    ProcessMessageJob.perform_later(assistant_message.id)

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.append('messages', partial: 'messages/message', locals: { message: user_message }),
          turbo_stream.append('messages', partial: 'messages/message', locals: { message: assistant_message }),
          turbo_stream.replace('message_form', partial: 'messages/form', locals: { conversation: @conversation })
        ]
      end
      format.html { redirect_to @conversation }
    end
  end

  private

  def set_conversation
    @conversation = current_user.conversations.find(params[:conversation_id])
  rescue ActiveRecord::RecordNotFound
    redirect_to conversations_path, alert: 'Conversation not found.'
  end
end
