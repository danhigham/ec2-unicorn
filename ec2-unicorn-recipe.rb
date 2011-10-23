Capistrano::Configuration.instance(:must_exist).load do
  
  namespace :ec2_unicorn do
  
    desc <<-DESC
      Prepares upstream and server config files for the current application before deploy:setup
      and deploy
    DESC

    task :setup, :roles => :web, :except => { :no_release => true } do

      # generate unicorn config
      
      unicorn_content = <<-CONTENT
        # Sample verbose configuration file for Unicorn (not Rack)
        #
        # This configuration file documents many features of Unicorn
        # that may not be needed for some applications. See
        # http://unicorn.bogomips.org/examples/unicorn.conf.minimal.rb
        # for a much simpler configuration file.
        #
        # See http://unicorn.bogomips.org/Unicorn/Configurator.html for complete
        # documentation.

        # Use at least one worker per core if you're on a dedicated server,
        # more will usually help for _short_ waits on databases/caches.
        worker_processes 4

        # Since Unicorn is never exposed to outside clients, it does not need to
        # run on the standard HTTP port (80), there is no reason to start Unicorn
        # as root unless it's from system init scripts.
        # If running the master process as root and the workers as an unprivileged
        # user, do this to switch euid/egid in the workers (also chowns logs):
        # user "unprivileged_user", "unprivileged_group"

        # Help ensure your application will always spawn in the symlinked
        # "current" directory that Capistrano sets up.
        working_directory "#{current_path}" # available in 0.94.0+

        # listen on both a Unix domain socket and a TCP port,
        # we use a shorter backlog for quicker failover when busy
        listen "/tmp/.sock_#{application}", :backlog => 64
        listen 8080, :tcp_nopush => true

        # nuke workers after 30 seconds instead of 60 seconds (the default)
        timeout 30

        # feel free to point this anywhere accessible on the filesystem
        pid "#{shared_path}/pids/unicorn.pid"

        # By default, the Unicorn logger will write to stderr.
        # Additionally, ome applications/frameworks log to stderr or stdout,
        # so prevent them from going to /dev/null when daemonized here:
        stderr_path "#{shared_path}/log/unicorn.stderr.log"
        stdout_path "#{shared_path}/log/unicorn.stdout.log"

        # combine REE with "preload_app true" for memory savings
        # http://rubyenterpriseedition.com/faq.html#adapt_apps_for_cow
        preload_app true
        GC.respond_to?(:copy_on_write_friendly=) and
          GC.copy_on_write_friendly = true

      CONTENT

      File.open("./config/unicorn.conf", 'w') { |f| f.write(unicorn_content) }

      # generate upstream file
      
      upstream_content = <<-CONTENT
        upstream #{application} {
          
          # fail_timeout=0 means we always retry an upstream even if it failed
          # to return a good HTTP response (in case the Unicorn master nukes a
          # single worker for timing out).

          # for UNIX domain socket setups:
          server unix:/tmp/.sock_#{application} fail_timeout=0;

          # for TCP setups, point these to your backend servers
          # server 192.168.0.7:8080 fail_timeout=0;
          # server 192.168.0.8:8080 fail_timeout=0;
          # server 192.168.0.9:8080 fail_timeout=0;
        }
  
      CONTENT

      File.open("./config/nginx_upstream.conf", 'w') { |f| f.write(upstream_content) }
      
      # generate server file
      
      server_content = <<-CONTENT
        server {
          listen 80 default deferred; # for Linux

          client_max_body_size 4G;
          server_name #{host_header};

          # ~2 seconds is often enough for most folks to parse HTML/CSS and
          # retrieve needed images/icons/frames, connections are cheap in
          # nginx so increasing this is generally safe...
          keepalive_timeout 5;

          # path for static files
          root #{current_path}/static;

          # Prefer to serve static files directly from nginx to avoid unnecessary
          # data copies from the application server.
          #
          # try_files directive appeared in in nginx 0.7.27 and has stabilized
          # over time.  Older versions of nginx (e.g. 0.6.x) requires
          # "if (!-f $request_filename)" which was less efficient:
          # http://bogomips.org/unicorn.git/tree/examples/nginx.conf?id=v3.3.1#n127
          try_files $uri/index.html $uri.html $uri @app;

          location @app {
            # an HTTP header important enough to have its own Wikipedia entry:
            #   http://en.wikipedia.org/wiki/X-Forwarded-For
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;

            # enable this if and only if you use HTTPS, this helps Rack
            # set the proper protocol for doing redirects:
            # proxy_set_header X-Forwarded-Proto https;

            # pass the Host: header from the client right along so redirects
            # can be set properly within the Rack application
            proxy_set_header Host $http_host;

            # we don't want nginx trying to do something clever with
            # redirects, we set the Host: header above already.
            proxy_redirect off;

            # set "proxy_buffering off" *only* for Rainbows! when doing
            # Comet/long-poll/streaming.  It's also safe to set if you're using
            # only serving fast clients with Unicorn + nginx, but not slow
            # clients. You normally want nginx to buffer responses to slow
            # clients, even with Rails 3.1 streaming because otherwise a slow
            # client can become a bottleneck of Unicorn.
            #
            # The Rack application may also set "X-Accel-Buffering (yes|no)"
            # in the response headers do disable/enable buffering on a
            # per-response basis.
            # proxy_buffering off;

            proxy_pass http://#{application};
          }

          # Rails error pages
          error_page 500 502 503 504 /500.html;
          location = /500.html {
            root /var/www/#{application}/current/public;
          }
        }

      CONTENT
      
      File.open("./config/nginx_server.conf", 'w') { |f| f.write(server_content) }
      
      # upload files to server 
      upload("./config/nginx_server.conf", "#{current_path}/config/nginx_server.conf")
      upload("./config/nginx_upstream.conf", "#{current_path}/config/nginx_upstream.conf")
      upload("./config/unicorn.conf", "#{current_path}/config/unicorn.conf")
      
    end

    desc <<-DESC
      Generates content for remote /var/www/unicorn/servers.conf and /var/www/unicorn/upstreams.conf
    DESC

    task :update_unicorn_confs, :roles => :web do
      
      #run "rm -f /var/www/unicorn/#{application}_nginx_server.conf && rm -f /var/www/unicorn/#{application}_nginx_upstream.conf"
      run "ln -s -f #{current_path}/config/nginx_server.conf /var/www/unicorn/#{application}_nginx_server.conf"
      run "ln -s -f #{current_path}/config/nginx_upstream.conf /var/www/unicorn/#{application}_nginx_upstream.conf"
      
    end
    
    desc <<-DESC
      Ensures unicorn process for app is running, if it isn't, start it. If it is, restart it.
      Check for PIDs
    DESC

    task :start_unicorn do
      
      bash_script = <<-BASH
        if [ -e \"#{shared_path}/pids/unicorn.pid\" ];
        then
          echo "Unicorn pid file exists";
        else
          unicorn -D -c #{current_path}/config/unicorn.conf #{current_path}/config.ru;
        fi
      BASH

      run bash_script
    end

    task :stop_unicorn do
      
      bash_script = <<-BASH
        if [ -e \"#{shared_path}/pids/unicorn.pid\" ];
        then
          pid=`cat #{shared_path}/pids/unicorn.pid`;
          kill -s QUIT $pid;
          
        else
          echo "No pid file for unicorn";
        fi
      BASH
      
      run bash_script
    end

    task :restart_unicorn do

      bash_script = <<-BASH
        if [ -e \"#{shared_path}/pids/unicorn.pid\" ];
        then
          
          pid=`cat #{shared_path}/pids/unicorn.pid`;
          kill -s QUIT $pid;
          
          unicorn -D -c #{current_path}/config/unicorn.conf #{current_path}/config.ru;
        else
          
          unicorn -D -c #{current_path}/config/unicorn.conf #{current_path}/config.ru;
        fi
      BASH
      
      run bash_script
    end
    
    task :start_nginx do
      run "sudo /sbin/service nginx start"
    end

    task :stop_nginx do
      run "sudo /sbin/service nginx stop"
    end

    task :restart_nginx do
      run "sudo /sbin/service nginx restart"
    end
    
  end
  
  # add in hooks to run tasks at appropriate times
  after 'deploy:setup', 'ec2_unicorn:setup'
  after 'deploy', 'ec2_unicorn:setup'
  after 'deploy:setup', 'ec2_unicorn:update_unicorn_confs'
  
  after 'deploy', 'ec2_unicorn:restart_unicorn'
end