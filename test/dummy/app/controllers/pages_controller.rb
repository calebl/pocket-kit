class PagesController < ApplicationController
  def home
  end

  def note
    @note_id = params[:id]
  end
end
