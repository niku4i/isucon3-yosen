require 'sinatra/base'
require 'json'
require 'mysql2-cs-bind'
require 'digest/sha2'
require 'dalli'
require 'rack/session/dalli'
require 'erubis'
require 'redcarpet'
require 'redis'

class Isucon3App < Sinatra::Base
  $stdout.sync = true
  use Rack::Session::Dalli, {
    :key => 'isucon_session',
    :cache => Dalli::Client.new('localhost:11212')
  }

  helpers do
    set :erb, :escape_html => true

    def connection
      return $mysql if $mysql
      config = JSON.parse(IO.read(File.dirname(__FILE__) + "/../config/#{ ENV['ISUCON_ENV'] || 'local' }.json"))['database']
      $mysql = Mysql2::Client.new(
        :host => config['host'],
        :port => config['port'],
        :username => config['username'],
        :password => config['password'],
        :database => config['dbname'],
        :reconnect => true,
      )
    end

    def redis_client
      return $redis if $redis
      $redis = Redis.new(:path => "/tmp/redis.sock")
    end

    def get_user
      user_id = session["user_id"]
      username = session["username"]
      if user_id
        headers "Cache-Control" => "private"
      end
      return {"id" => user_id, "username" => username }|| {}
    end

    def require_user(user)
      unless user["username"]
        redirect "/"
        halt
      end
    end

    def gen_markdown(md)
      @markdown ||= Redcarpet::Markdown.new(Redcarpet::Render::HTML, :autolink => false, :space_after_headers => true)
      return @markdown.render(md)
    end

    def anti_csrf
      if params["sid"] != session["token"]
        halt 400, "400 Bad Request"
      end
    end

    def url_for(path)
      "http://#{request.host}:#{request.port}#{request.script_name}#{path}"
    end
    
    # @page 0, 1, 2 ...
    def get_memos(page)
      start = page * 100
      stop  = start + 99
      mysql = connection
      public_memo_ids = redis_client.lrange("public_memo_ids", start, stop)
      start_id = public_memo_ids.last
      end_id =  public_memo_ids.first
      memos = mysql.xquery("SELECT memos.*, users.username FROM memos JOIN users on users.id = memos.user JOIN (SELECT memos.id from memos WHERE is_private=0 AND id BETWEEN ? AND ? ORDER BY created_at DESC) as tmp on tmp.id = memos.id", start_id, end_id);
    end
  end

  get '/' do
    mysql = connection
    user  = get_user

    total = redis_client.get("total_count")
    memos = get_memos(0)
    erb :index, :layout => :base, :locals => {
      :memos => memos,
      :page  => 0,
      :total => total,
      :user  => user,
    }
  end

  get '/recent/:page' do
    mysql = connection
    user  = get_user

    page  = params["page"].to_i
    total = redis_client.get("total_count")
    memos = get_memos(page)
    if memos.count == 0
      halt 404, "404 Not Found"
    end
    erb :index, :layout => :base, :locals => {
      :memos => memos,
      :page  => page,
      :total => total,
      :user  => user,
    }
  end

  post '/signout' do
    user = get_user
    require_user(user)
    anti_csrf

    session.destroy
    redirect "/"
  end

  get '/signin' do
    user = get_user
    erb :signin, :layout => :base, :locals => {
      :user => user,
    }
  end

  post '/signin' do
    mysql = connection

    username = params[:username]
    password = params[:password]
    user = mysql.xquery('SELECT id, username, password, salt FROM users WHERE username=?', username).first
    if user && user["password"] == Digest::SHA256.hexdigest(user["salt"] + password)
      session.clear
      session["user_id"] = user["id"]
      session["username"] = user["username"]
      session["token"] = Digest::SHA256.hexdigest(Random.new.rand.to_s)
      mysql.xquery("UPDATE users SET last_access=now() WHERE id=?", user["id"])
      redirect "/mypage"
    else
      erb :signin, :layout => :base, :locals => {
        :user => {},
      }
    end
  end

  get '/mypage' do
    mysql = connection
    user  = get_user
    require_user(user)

    memos = mysql.xquery('SELECT id, content, is_private, created_at, updated_at FROM memos WHERE user=? ORDER BY created_at DESC', user["id"])
    erb :mypage, :layout => :base, :locals => {
      :user  => user,
      :memos => memos,
    }
  end

  get '/memo/:memo_id' do
    mysql = connection
    user  = get_user

    memo = mysql.xquery('SELECT id, user, content, is_private, created_at, updated_at FROM memos WHERE id=?', params[:memo_id]).first
    unless memo
      halt 404, "404 Not Found"
    end
    if memo["is_private"] == 1
      if user["id"] != memo["user"]
        halt 404, "404 Not Found"
      end
    end
    memo["username"] = mysql.xquery('SELECT username FROM users WHERE id=?', memo["user"]).first["username"]
    memo["content_html"] = gen_markdown(memo["content"])
    if user["id"] == memo["user"]
      cond = ""
      index = "FORCE INDEX(memos_idx_user_created_at)"
    else
      cond = "AND is_private=0"
      index = ""
    end
    older = mysql.xquery("SELECT id FROM memos #{index} WHERE user=? #{cond} AND created_at < ? ORDER BY created_at DESC LIMIT 1", memo["user"], memo["created_at"]).first
    newer = mysql.xquery("SELECT id FROM memos #{index} WHERE user=? #{cond} AND created_at > ? ORDER BY created_at LIMIT 1", memo["user"], memo["created_at"]).first
    erb :memo, :layout => :base, :locals => {
      :user  => user,
      :memo  => memo,
      :older => older,
      :newer => newer,
    }
  end

  post '/memo' do
    mysql = connection
    user  = get_user
    require_user(user)
    anti_csrf

    # if public memo
    if params["is_private"].to_i == 0
      redis_client.incr("total_count")
    end

    mysql.xquery(
      'INSERT INTO memos (user, content, is_private, created_at) VALUES (?, ?, ?, ?)',
      user["id"],
      params["content"],
      params["is_private"].to_i,
      Time.now,
    )
    memo_id = mysql.last_id

    # Store id in Redis list if public memo
    if params[:is_private].to_i == 0
      redis_client.lpush('public_memo_ids', memo_id)
    end

    redirect "/memo/#{memo_id}"
  end

  run! if app_file == $0
end
