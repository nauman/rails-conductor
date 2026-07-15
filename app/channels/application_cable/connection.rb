module ApplicationCable
  # Authenticate the websocket connection with the same passwordless session the
  # HTTP app uses. Without this, channels streamed live operational output
  # (deploys, script runs, DB pulls) to anyone who guessed a record id.
  class Connection < ActionCable::Connection::Base
    include Passwordless::ControllerHelpers

    identified_by :current_user

    def connect
      self.current_user = authenticate_by_session(User) || reject_unauthorized_connection
    end

    private

    # Passwordless::ControllerHelpers reads `session`. The /cable handshake runs
    # through the session middleware, so request.session is populated here.
    def session
      request.session
    end
  end
end
