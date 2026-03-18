class ConversationChannel < ApplicationCable::Channel
  def subscribed
    conversation = current_user&.conversations&.find_by(id: params[:conversation_id])
    conversation ? stream_for(conversation) : reject
  end

  def unsubscribed
    stop_all_streams
  end
end
