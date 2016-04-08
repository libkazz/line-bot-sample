require 'bundler/setup'
require 'sinatra'
require 'json'
require 'httpclient'
require 'certified'
require 'active_record'
require 'slack'

set :bind, '0.0.0.0'

ActiveRecord::Base.configurations = {
  "production" => {
    adapter: "sqlite3",
    database: "bot.db"
  }
}

ActiveRecord::Base.establish_connection(:production)

LINE_HTTP_HEADERS = {
  'Content-Type' => 'application/json; charset=UTF-8',
  'X-Line-ChannelID' => ENV["LINE_CHANNEL_ID"],
  'X-Line-ChannelSecret' => ENV["LINE_CHANNEL_SECRET"],
  'X-Line-Trusted-User-With-ACL' => ENV["LINE_CHANNEL_MID"]
}

class User < ActiveRecord::Base
  def generate_token!
    self.token = Digest::SHA256.hexdigest("BOT_#{line_user_id}")
  end

  def send_message_with_line(message)
    HTTPClient.new.post_content('https://trialbot-api.line.me/v1/events',
                                { to: [line_user_id],
                                  toChannel: 1383378250, # Fixed value
                                  eventType: "138311608800106203", # Fixed value
                                  content: { toType: 1, contentType: 1, text: message }
    }.to_json, LINE_HTTP_HEADERS)
  end
end

Slack.configure {|config| config.token = ENV["SLACK_TOKEN"] }
slack = Slack.realtime

post '/linebot/callback' do
  params = JSON.parse(request.body.read)

  params['result'].each do |message|
    user = User.find_or_create_by(line_user_id: message['content']['from'])

    if user.slack_user_id.blank?
      response = HTTPClient.new.get_content('https://trialbot-api.line.me/v1/profiles',
                                            { mids: message['content']['from'] },
                                            LINE_HTTP_HEADERS)

      json = JSON.parse(response)

      user.line_display_name = json["contacts"][0]["displayName"]
      user.generate_token!
      user.save

      user.send_message_with_line("ようこそ #{user.line_display_name} さん\n本人確認のため、SlackのBotに\ntoken[#{user.token}]\nを送信してください")
    else
      Slack::Client.new.chat_postMessage(text: message["content"]["text"],
                                         channel: ENV["SLACK_CHANNEL_NAME"],
                                         username: user.line_display_name)
    end
  end

  "OK"
end

get '/elb-status' do
  "OK"
end

slack.on :hello do
  puts 'Successfully connected.'
end

slack.on :message do |data|
  p data
  if token = data["text"][/token\[(.*?)\]/, 1]
    p token
    if user = User.find_by(token: token)
      user.slack_user_id = data["user"]
      user.save
      user.send_message_with_line("slackとの接続が確認できました")
    end
  end

  if data["type"] == "message" and not data["bot_id"]
    User.where.not(slack_user_id: nil).each do |user|
      user.send_message_with_line("#{user.line_display_name}: #{data["text"]}")
    end
  end
end

Thread.new do
  slack.start
end
