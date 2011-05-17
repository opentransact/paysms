require 'sinatra/base'
require 'active_support/all'
require 'twilio'
require 'oauth'
require 'oauth/consumer'
require 'oauth/token'
require 'opentransact'
class PaySMS < Sinatra::Base
  enable :sessions, :logging
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
  
  helpers do
    def logged_in?
      session[:phone].present?
    end
    
    def opentransact_client
      @opentransact_client ||= OpenTransact::Client.new opentransact_site, :consumer_key => ENV["OPENTRANSACT_KEY"], :consumer_secret => ENV["OPENTRANSACT_SECRET"], :token => opentransact_token[:token], :secret => opentransact_token[:secret]
    end
    
    def opentransact_consumer
      @opentransact_consumer ||= OAuth::Consumer.new ENV["OPENTRANSACT_KEY"], ENV["OPENTRANSACT_SECRET"], :site=>opentransact_site
    end
    
    def opentransact_site
      @opentransact_site ||= begin
        uri = URI.parse ENV["OPENTRANSACT_URL"]
        "#{uri.scheme}://#{uri.host}"
      end
    end
    
    def phone
      @phone ||= session[:phone]|| begin 
        normalize_phone params[:phone]||params[:From]
      end
    end
    
    def normalize_phone(number)
      number = number.gsub /\+[^\d]/, ''
      if number.size==10
        "1"+number 
      else
        number
      end
    end
    
    def opentransact_token
      @opentransact_token ||= begin
        ts = $redis.get("tokens:#{phone}:#{ENV["OPENTRANSACT_URL"]}")
        if ts
          t = ts.split(/&/)
          {:token=>t[0], :secret=>t[1]}
        end
      end
    end
    
    def currency
      @currency ||= begin
        if opentransact_token
          OpenTransact::Asset.new ENV["OPENTRANSACT_URL"], :client => opentransact_client
        end
      end
    end
    
    def url_for(path)
      @site_url ||= begin
        url = request.scheme + "://"
        url << request.host

        if request.scheme == "https" && request.port != 443 ||
           request.scheme == "http" && request.port != 80
         url << ":#{request.port}"
        end
        url
      end
      puts "URL: #{@site_url}"
      @site_url+path
    end
    
    def send_sms(text)
      puts "SEND_SMS to:#{phone} message: #{text}"
      Twilio::Sms.message(ENV["TWILIO_NUMBER"], phone, text)
    end
    
    def send_help
      send_sms "PaySMS: To pay someone send 'pay 12 support@picomoney.com', to fetch balance send 'balance'"
    end
    
    def register_phone(msg=nil)
      puts "register_phone: #{phone}"
      @code = ActiveSupport::SecureRandom.hex
      $redis.setex("phone:auth:#{@code}", 1.day.from_now.to_i, @phone)
      
      if msg.present?
        text = "#{msg} http://pays.ms/a/#{@code}"
      elsif $redis.get("phone:number:#{phone}") 
        text = "Follow this link to log in to PayS.MS http://pays.ms/a/#{@code}"
      else
        text = "Welcome to PayS.MS. Follow this link to register http://pays.ms/a/#{@code}"
      end
      
      @message = send_sms(text)
      
    end
  end

  get '/' do
    haml :index
  end
  
  post "/register" do
    if phone && phone=~/(\+1)?\d{10}/
      register_phone
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
    redirect "/"
  end
  
  post "/logout" do
    session[:phone] = nil
    redirect "/"
  end
  
  post "/twilio/sms" do
    if params[:AccountSid]==ENV["TWILIO_KEY"]
      puts "phone: #{phone}"
      if $redis.get("phone:number:#{phone}")
        
        if currency
          if params[:Body] =~ /(balance|pay +(\d+) +(([^@\s]+)@((?:[-a-z0-9]+\.)+[a-z]{2,}))( +(.*))?)/i
            if $1.downcase == "balance"
              puts "Currency Info: #{currency.info.inspect}"
              send_sms "PaySMS: Your balance is #{currency.balance}"
            else
              t = currency.transfer $2.to_i, $3, $7
              $redis.incr "payments"
              $redis.incrby "payments_amount", $2.to_i
              send_sms "PaySMS: You sent #{$2} #{ENV["OPENTRANSACT_NAME"]} to #{$3}"
            end
          else
            send_help
          end
        else
          register_phone "Please link your PicoMoney account"
        end
        
      else
        register_phone
      end
    end
    "OK"
  end
  
  get "/link" do
    if logged_in?
      request_token =  opentransact_consumer.get_request_token({:oauth_callback=>url_for("/oauth_callback")}, :scope=>ENV["OPENTRANSACT_URL"]) 
      session[request_token.token]=request_token.secret
      redirect request_token.authorize_url
    else
      redirect "/"
    end
  end
  
  get "/oauth_callback" do
    if logged_in? && session[params[:oauth_token]]
      @request_token = OAuth::RequestToken.new opentransact_consumer, params[:oauth_token], session[params[:oauth_token]]
    
      @access_token = @request_token.get_access_token :oauth_verifier=>params[:oauth_verifier]
      session[params[:oauth_token]]=nil
      $redis.set("tokens:#{session[:phone]}:#{ENV["OPENTRANSACT_URL"]}",[ @access_token.token, @access_token.secret].join("&"))  
      send_help
    end
    redirect "/"
  end
end
