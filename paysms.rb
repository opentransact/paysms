require 'sinatra/base'
require 'active_support/all'
require 'twilio'

class PaySMS < Sinatra::Base
  set :sessions, true
  set :haml, {:format => :html5 }
  set :root, File.dirname(__FILE__)
  set :public, Proc.new { File.join(root, "public") }

  configure do
    require 'redis'
    if ENV["REDISTOGO_URL"]
      uri = URI.parse(ENV["REDISTOGO_URL"])
      $redis = Redis.new(:host => uri.host, :port => uri.port, :password => uri.password)
    else
      $redis = Redis.new(:db => 7)
    end
    
    Twilio.connect(ENV["TWILIO_KEY"], ENV["TWILIO_SECRET"])
  end

  get '/' do
    haml :index
  end
  
  post "/register" do
    @phone = params[:phone]
    @phone.gsub! /[^\d]/, ''
    
    if @phone && @phone.size==10
      @code = ActiveSupport::SecureRandom.hex
      $redis.set("phone:auth:#{@code}",params[:phone])
      
      if $redis.get("phone:number:#{@phone}") 
        text = "Follow this link to log in to PayS.MS http://pays.ms/a/#{@code}"
      else
        text = "Welcome to PayS.MS. Follow this link to register http://pays.ms/a/#{@code}"
      end
      
      @message = Twilio::Sms.message(ENV["TWILIO_NUMBER"], params[:phone], text)
      haml :register
    else
      @phone = params[:phone]
      @error = "You must enter a 10 digit US number"
      haml :index
    end
  end
  
  get '/a/:code' do |code|
    @phone = $redis.get("phone:auth:#{code}")
    if @phone
      $redis.set("phone:number:#{@phone}",1)
      session[:phone] = @phone
    end
    haml :auth
  end
  
  post "/logout" do
    session[:phone] = nil
    redirect "/"
  end
  
  post "/twilio/sms" do
  end
  
end
