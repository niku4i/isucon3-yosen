require 'redis'
require 'json'
require 'mysql2-cs-bind'
$redis = Redis.new(:path => "/tmp/redis.sock")
config = JSON.parse(IO.read(File.dirname(__FILE__) + "/../config/#{ ENV['ISUCON_ENV'] || 'local' }.json"))['database']
$mysql = Mysql2::Client.new(
  :host => config['host'],
  :port => config['port'],
  :username => config['username'],
  :password => config['password'],
  :database => config['dbname'],
  :reconnect => true,
)

ids = $mysql.xquery("SELECT memos.id from memos where is_private = 0 order by created_at ASC").map{|row| row['id']}
$redis.del "public_memo_ids"
$redis.lpush "public_memo_ids", ids
