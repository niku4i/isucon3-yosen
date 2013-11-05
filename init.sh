mysql -uroot -proot isucon -e  "CREATE INDEX memos_idx_is_private_created_at ON memos (is_private,created_at);"
mysql -uroot -proot isucon -e  "CREATE INDEX memos_idx_user_created_at ON memos (user,created_at);"

redis-cli -s /tmp/redis.sock set total_count 20540
