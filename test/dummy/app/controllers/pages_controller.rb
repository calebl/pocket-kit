class PagesController < ApplicationController
  def home
  end

  def note
    @note_id = params[:id]
  end

  def broken
    raise NoMethodError, "undefined method 'title' for nil (note #{params[:id]})"
  end
end
