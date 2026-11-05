module PocketKit
  # Plays saved session replays on the app's own origin, with the vendored
  # rrweb player. `show` plays one the app saved, and as JSON returns its
  # events. They are available only on this machine, and
  # PocketKit.replay.viewer may restrict them further.
  class ReplaysController < PocketKit.replay.parent_controller.constantize
    before_action :require_viewer
    layout false

    def show
      Replay.expire
      events = Replay.read(params[:id])
      return head :not_found unless events

      respond_to do |format|
        format.html
        format.json { render json: events }
      end
    end

    private

    def require_viewer
      head :not_found unless Replay.local_request?(request) && Replay.viewable?(self)
    end
  end
end
