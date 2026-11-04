module PocketKit
  # Plays saved session replays on the app's own origin, with the vendored
  # rrweb player. `show` plays one the app saved, and as JSON returns its
  # events. Who may see them is PocketKit.replay.viewer (by default, only this
  # machine).
  class ReplaysController < PocketKit.replay.parent_controller.constantize
    before_action :require_viewer
    layout false

    def show
      events = Replay.read(params[:id])
      return head :not_found unless events

      respond_to do |format|
        format.html
        format.json { render json: events }
      end
    end

    private

    def require_viewer
      head :not_found unless Replay.viewable?(self)
    end
  end
end
