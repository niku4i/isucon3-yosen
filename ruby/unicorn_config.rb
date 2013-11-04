worker_processes 8
preload_app true
listen "/tmp/unicorn.sock"

#GC.respond_to?(:copy_on_write_friendly=) and GC.copy_on_write_friendly = true
#after_fork do |server, worker|
#  GC.disable
#end
