require 'sinatra/base'

class PaySMS < Sinatra::Base
  set :sessions, true

  get '/' do
    haml :index
  end
end
