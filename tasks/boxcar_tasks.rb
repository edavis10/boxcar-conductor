require 'highline/import'

# We'll handle our own printing of default options. Necessary to have
# "nice" output using indentstring
class HighLine::Question
  private
  def append_default()
  end
end

class Capistrano::Configuration
  ##
  # Read a file and evaluate it as an ERB template.
  # Path is relative to this file's directory.

  def render_erb_template(filename)
    template = File.read(filename)
    result   = ERB.new(template).result(binding)
  end

end

########################################################################
# Advanced Configuration
# Only the courageous of ninjas dare pass this!
########################################################################

role :web, boxcar_server
role :app, boxcar_server
role :db, boxcar_server, :primary => true
role :admin_web, "root@#{boxcar_server}", :no_release => true

# What database server are you using?
# Example:
set :database_name, { :development  => "#{application_name}_development",
                      :test         => "#{application_name}_test",
                      :production   => "#{application_name}_production" }

# user
set :user, boxcar_username
set :use_sudo, false

set :domain_names, Proc.new { HighLine.ask(indentstring("What is the primary domain name? |railsboxcar.com|")) { |q| q.default = "railsboxcar.com" } }

set :db_development,database_name[:development]
set :db_test, database_name[:test]
set :db_production, database_name[:production]

# Prompt user to set database user/pass
set :database_username, Proc.new { HighLine.ask(indentstring("What is your database username? |dbuser|")) { |q| q.default = "dbuser" } }
set :database_host, Proc.new {
  if setup_type.to_s == "quick"
    "localhost"
  else
    HighLine.ask(indentstring("What host is your database running on? |localhost|")) { |q| q.default = "localhost" }
  end
}
set :database_adapter, Proc.new {
  # currently, this prompt constitutes the longest prompt. Be sure to update indentstring if
  # any changes are made here
  choose do |menu|
    menu.layout = :one_line
    menu.prompt = "What database server will you be using?  "
    menu.choices(:postgresql, :mysql)
  end
}
set :database_password, Proc.new {
  if setup_type.to_s == "quick"
    dbpass = newpass(16)
    print indentstring("Creating random database password:")
    puts "#{dbpass}"
    dbpass
  else
    database_first = "" # Keeping asking for the password until they get it right twice in a row.
    loop do
      database_first = HighLine.ask(indentstring("Please enter your database user's password:")) { |q| q.echo = "." }
      database_confirm = HighLine.ask(indentstring("Please retype the password to confirm:")) { |q| q.echo = "." }
      break if database_first == database_confirm
    end
    database_first
  end
}

set :database_socket, Proc.new {
  if setup_type.to_s == "quick"
    "/var/run/mysqld/mysqld.sock"
  else
    HighLine.ask(indentstring("Where is the MySQL socket file? |/var/run/mysqld/mysqld.sock|")) { |q| q.default = "/var/run/mysqld/mysqld.sock" }
  end
}

set :database_port, Proc.new {
  if database_adapter.to_s == "postgresql"
    default = "5432"
  else
    default = "3306"
  end
  if setup_type.to_s == "quick"
    default
  else
    HighLine.ask(indentstring("What port does your database run on? |#{default}|")) { |q| q.default=default }
  end
}

# server type
set :server_type, Proc.new {
  if setup_type.to_s == "quick"
    :passenger
  else
    # indenting this prompt by hand for now. Can't figure out how to work in indentstring
    choose do |menu|
      menu.layout = :one_line
      menu.prompt = "    What web server will you be using?  "
      menu.choices(:passenger, :mongrel)
    end
  end
}

# directories
set :home, "/home/#{user}"
set :etc, "#{home}/etc"
set :log, "#{home}/log"
set :deploy_to, "#{home}/sites/#{application_name}"

set :app_shared_dir, "#{deploy_to}/shared"


# mongrel
# What port number should your mongrel cluster start on?
set :mongrel_port, Proc.new {
  HighLine.ask(indentstring("What port will your mongrel cluster start with? |8000|"), Integer) do |q|
    q.default = 8000
    q.in = 1024..65536
  end
}

# How many instances of mongrel should be in your cluster?
set :mongrel_servers, Proc.new {
  HighLine.ask(indentstring("How many mongrel servers should run? |3|"), Integer) do |q|
    q.default=3
    q.in = 1..10
  end
}

# what type of setup does the user want?
set :setup_type, Proc.new {
  # another manual indent
  choose do |menu|
    menu.layout = :one_line
    menu.prompt = "         What type of setup would you like?  "
    menu.choices(:quick, :custom)
  end
}

set :mongrel_conf, "#{etc}/mongrel_cluster.#{application_name}.conf"
set :mongrel_pid, "#{log}/mongrel_cluster.#{application_name}.pid"
set :mongrel_address, '127.0.0.1'
set :mongrel_environment, :production

set :boxcar_conductor_templates, 'vendor/plugins/boxcar-conductor/templates'

set :today, Time.now.strftime('%b %d, %Y').to_s

namespace :boxcar do
  desc 'Configure your Boxcar environment'
  task :config, :except => { :no_release => true } do
    run "mkdir -p #{home}/etc #{home}/log #{home}/sites"
    run "mkdir -p #{app_shared_dir}/config #{app_shared_dir}/log"
    puts ""
    setup_type
    database.configure
    setup
    createdb
    mongrel.cluster.generate unless server_type == :passenger
    puts ""
    say "Setup complete. Now run cap deploy:cold and you should be all set."
    puts ""
  end
  before "boxcar:config", "deploy:setup"

  desc 'Install and configure databases'
  task :setup, :roles => :admin_web do
    # Setting up some variables. Note that testdb *must* include the negation
    if database_adapter.to_s == "postgresql"
      installdb  = 'postgresql libpq-dev'
      dbname = "PostgreSQL"
      gemname = "pg"
      bindbname = "psql"
    elsif database_adapter.to_s == "mysql"
      installdb  = 'mysql-server mysql-client libmysqlclient15-dev'
      dbname = "MySQL"
      gemname = "mysql"
      bindbname = "mysql"
    end
    installgem = "gem install #{gemname} --no-ri --no-rdoc -q"
    installdb  = "aptitude -y -q install #{installdb} > /dev/null"

    puts "\n\nNow installing and configuring #{dbname}. If this is your first time"
    puts "deploying to this Boxcar with this database type the install could take"
    puts "a couple of minutes, so go get a cup of coffee, relax, and then come back.\n\n"

    print indentstring("Installing and configuring #{dbname}:")

    begin
      run "! which #{bindbname} >/dev/null"

      run installdb, :pty => true
      puts "#{dbname} installed"

      run installgem, { :shell => '/bin/bash --login', :pty => true }
      puts indentstring("#{gemname} gem installed", :end)
    rescue Capistrano::CommandError => e
      puts "#{dbname} already installed, skipping."
    end
  end

  desc 'Create application database and user'
  task :createdb, :roles => :admin_web do
    if database_adapter.to_s == "postgresql"
      psqlconfig = "CREATE ROLE #{database_username} PASSWORD '#{database_password}' NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT LOGIN; CREATE DATABASE #{db_production} OWNER #{database_username};"
      put psqlconfig, "/tmp/setupdb.sql"
      run "psql < /tmp/setupdb.sql", :shell => 'su postgres'
    elsif database_adapter.to_s == "mysql"
      mysqlconfig = "CREATE DATABASE #{db_production}; GRANT ALL PRIVILEGES ON #{db_production}.* TO #{database_username} IDENTIFIED BY '#{database_password}'"
      put mysqlconfig, "/tmp/setupdb.sql"
      run "mysql < /tmp/setupdb.sql"
    end
    run "rm -f /tmp/setupdb.sql"
    puts indentstring("database configured", :end)
  end

  namespace :deploy do
    desc "Link in the production database.yml"
    task :link_files, :except => { :no_release => true } do
      run "ln -nfs #{app_shared_dir}/config/database.yml #{release_path}/config/database.yml"
      run "ln -nfs #{app_shared_dir}/log #{release_path}/log"
    end
  end

  namespace :database do
    desc "Configure your Boxcar database"
    task :configure, :except => { :no_release => true } do
      database_configuration = render_erb_template("#{boxcar_conductor_templates}/databases/#{database_adapter}.yml.erb")
      put database_configuration, "#{app_shared_dir}/config/database.yml"
    end
  end

  namespace :mongrel do
    namespace :cluster do
      desc "Generate mongrel cluster configuration"
      task :generate, :except => { :no_release => true } do
        mongrel_cluster_configuration = render_erb_template("#{boxcar_conductor_templates}/mongrel_cluster.yml.erb")
        put mongrel_cluster_configuration, mongrel_conf
      end
    end
  end

  after "deploy:update_code", "boxcar:deploy:link_files"

end

def indentstring(inputstring, placement = :begin)
  #the size of the print "buffer". This should be >= the length of the longest string to be printed
  printgap = "                                                              "
  if placement == :begin
    pgsize = printgap.length - 1
    strsize = inputstring.length - 1
    printgap[pgsize - strsize, pgsize] = inputstring
    inputstring = printgap + "  "
  elsif placement == :end
    inputstring = printgap + "  " + inputstring
  end
end

def newpass(len)
  chars = ("a".."z").to_a + ("A".."Z").to_a + ("0".."9").to_a
  return Array.new(len){||chars[rand(chars.size)]}.join
end
